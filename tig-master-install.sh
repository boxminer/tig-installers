# === tig-master-install.sh ===
#!/usr/bin/env bash
set -euo pipefail

API_KEY="${1:-}"; PLAYER_ID="${2:-}"; PER_CHALLENGE="${3:-5}"
MASTER_BASE="${MASTER_BASE:-http://localhost:80}"

if [[ -z "$API_KEY" || -z "$PLAYER_ID" ]]; then
  echo "Usage: $0 <API_KEY> <PLAYER_ID> [PER_CHALLENGE=5]"
  exit 1
fi

echo "[*] Dépendances (apt)"
sudo apt update
sudo apt install -y jq curl git python3-requests ca-certificates

echo "[*] Master déjà lancé ? (ok si oui)"
cd ~/tig-monorepo/tig-benchmarker 2>/dev/null || true
if [[ ! -f master.yml ]]; then
  cd ~
  rm -rf tig-monorepo
  git clone https://github.com/tig-foundation/tig-monorepo.git
  cd tig-monorepo/tig-benchmarker
  [ -f .env.example ] && cp .env.example .env || true
  docker compose -f master.yml up -d
fi

echo "[*] Générateur de config (/opt/tig-tools/build_config.sh)"
sudo mkdir -p /opt/tig-tools && sudo chown "$USER:$USER" /opt/tig-tools
cat <<'SEED' | sudo tee /opt/tig-tools/build_config.sh >/dev/null
#!/usr/bin/env bash
set -euo pipefail
OUT="/opt/tig-tools/config.seed.json"
PER_CHALLENGE="${PER_CHALLENGE:-5}"
declare -A C2NAME=([c001]="satisfiability" [c002]="vehicle_routing" [c003]="knapsack" [c004]="vector_search" [c005]="hypergraph")
tmp=$(mktemp); echo "[]" > "$tmp"
for cid in c001 c002 c003 c004 c005; do
  img="ghcr.io/tig-foundation/tig-monorepo/${C2NAME[$cid]}/runtime:0.0.1"
  echo ">> Listing $cid via $img"
  ids=$(docker run --rm "$img" list_algorithms 2>/dev/null \
        | grep -E "status:[[:space:]]*active" \
        | sed -E 's/.*id:[[:space:]]*(c[0-9]{3}_[a-z0-9]+).*/\1/' \
        | head -n "$PER_CHALLENGE" || true)
  [ -z "$ids" ] && { echo "WARN: aucun algo ACTIF détecté pour $cid"; continue; }
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    jq --arg aid "$id" \
       '. += [{"algorithm_id":$aid,"num_nonces":40,"batch_size":8,"weight":1,"difficulty_range":[0,0.5],"selected_difficulties":[]}]' \
       "$tmp" > "$tmp.new" && mv "$tmp.new" "$tmp"
  done <<< "$ids"
done
cat > "$OUT" <<JSON
{
  "api_url": "https://mainnet-api.tig.foundation",
  "api_key": "<A RENSEIGNER>",
  "player_id": "<A RENSEIGNER>",
  "max_concurrent_benchmarks": 4,
  "time_between_resubmissions": 60000,
  "time_before_batch_retry": 60000,
  "slaves": [
    {"name_regex":"cpu-.*","algorithm_id_regex":"c00[123].*","max_concurrent_batches":1},
    {"name_regex":"gpu-.*","algorithm_id_regex":"c00[45].*","max_concurrent_batches":1}
  ],
  "algo_selection": $(cat "$tmp")
}
JSON
rm -f "$tmp"
echo "Config seed générée: $OUT"
SEED
sudo chmod +x /opt/tig-tools/build_config.sh

echo "[*] Pré-pull des runtimes (optionnel)"
for c in satisfiability vehicle_routing knapsack vector_search hypergraph; do
  docker pull ghcr.io/tig-foundation/tig-monorepo/$c/runtime:0.0.1 || true
done

echo "[*] Construire seed d'algos (PER_CHALLENGE=$PER_CHALLENGE)"
PER_CHALLENGE="$PER_CHALLENGE" /opt/tig-tools/build_config.sh

echo "[*] Injection des credentials dans le JSON et push vers le Master"
sudo jq --arg k "$API_KEY" --arg p "$PLAYER_ID" '.api_key=$k | .player_id=$p' \
  /opt/tig-tools/config.seed.json | \
curl -s -X POST -H "Content-Type: application/json" --data-binary @- \
  "$MASTER_BASE/update-config" >/dev/null

echo "[*] Autopilot (horaire)"
sudo mkdir -p /opt/tig-autopilot && sudo chown "$USER:$USER" /opt/tig-autopilot
cat <<'PY' | sudo tee /opt/tig-autopilot/autopilot.py >/dev/null
#!/usr/bin/env python3
import os, requests, random
MASTER_BASE=os.getenv("MASTER_BASE","http://localhost:80")
EPSILON=float(os.getenv("EPSILON","0.15")); TOP_K=int(os.getenv("TOP_K","1")); MIN_AGE=int(os.getenv("MIN_AGE","300"))
def get(p): return requests.get(f"{MASTER_BASE}{p}",timeout=15).json()
def post(p,b): r=requests.post(f"{MASTER_BASE}{p}",json=b,timeout=20); r.raise_for_status(); return r.json() if r.content else {}
def score(s):
    sols=s.get("solutions") or s.get("accepted_solutions") or 0
    dur=s.get("runtime_seconds") or s.get("duration") or 0
    atps=s.get("avg_time_per_solution"); return (1.0/atps) if (atps and atps>0) else ((sols/dur) if dur else 0.0)
def main():
    cfg=get("/get-config"); latest=get("/get-latest-data"); sel=cfg.get("algo_selection",[])
    if not sel: print("No algo_selection. Seed /config first."); return
    per={}; 
    for it in latest.get("algorithms",[]):
        aid=it.get("algorithm_id") or it.get("id"); 
        if not aid: continue
        age=it.get("age_seconds"); 
        if age is not None and age<MIN_AGE: continue
        per[aid]=it
    buckets={}
    for it in sel:
        aid=it.get("algorithm_id"); 
        if not aid: continue
        cid=aid[:4]; buckets.setdefault(cid,[]).append((aid, score(per.get(aid,{}))))
    new=[]
    for cid,pairs in buckets.items():
        pairs.sort(key=lambda x:x[1], reverse=True)
        for aid,_ in pairs[:TOP_K]:
            base=next((x for x in sel if x.get("algorithm_id")==aid),{"batch_size":8,"num_nonces":40,"difficulty_range":[0,0.5],"selected_difficulties":[]})
            new.append({"algorithm_id":aid,"num_nonces":base.get("num_nonces",40),"batch_size":base.get("batch_size",8),"weight":10,"difficulty_range":base.get("difficulty_range",[0,0.5]),"selected_difficulties":base.get("selected_difficulties",[])})
    chosen={x["algorithm_id"] for x in new}; others=[x for x in sel if x.get("algorithm_id") not in chosen]
    random.shuffle(others); budget=max(1,int(len(sel)*EPSILON))
    for base in others[:budget]:
        base={**{"batch_size":8,"num_nonces":40,"difficulty_range":[0,0.5],"selected_difficulties":[]}, **base, "weight":1}
        new.append({"algorithm_id":base["algorithm_id"],"num_nonces":base["num_nonces"],"batch_size":base["batch_size"],"weight":base["weight"],"difficulty_range":base["difficulty_range"],"selected_difficulties":base["selected_difficulties"]})
    ncfg=dict(cfg); ncfg["algo_selection"]=new; post("/update-config", ncfg); print(f"Updated config with {len(new)} algorithms.")
if __name__=="__main__": main()
PY
sudo chmod +x /opt/tig-autopilot/autopilot.py
(crontab -l 2>/dev/null; echo "0 * * * * MASTER_BASE=$MASTER_BASE /usr/bin/python3 /opt/tig-autopilot/autopilot.py >> /var/log/tig-autopilot.log 2>&1") | crontab -

echo "[*] Health-guard (*/30) + outils"
sudo mkdir -p /opt/tig-guard && sudo chown "$USER:$USER" /opt/tig-guard
cat <<'PY' | sudo tee /opt/tig-guard/health_guard.py >/dev/null
#!/usr/bin/env python3
import os, json, time, requests, statistics, pathlib, re
MASTER_BASE=os.getenv("MASTER_BASE","http://localhost:80")
STATE_FILE=os.getenv("STATE_FILE","/opt/tig-guard/health_state.json")
BAN_FILE=os.getenv("BAN_FILE","/opt/tig-guard/banned_slaves.json")
SPS_FLOOR_RATIO=float(os.getenv("SPS_FLOOR_RATIO","0.40"))
FAIL_RATE_MAX=float(os.getenv("FAIL_RATE_MAX","0.30"))
MIN_ACTIVITY_SEC=int(os.getenv("MIN_ACTIVITY_SEC","300"))
FAIL_STREAK_BAN=int(os.getenv("FAIL_STREAK_BAN","3"))
UNBAN_AFTER_HOURS=int(os.getenv("UNBAN_AFTER_HOURS","24"))
def get(p): return requests.get(f"{MASTER_BASE}{p}",timeout=15).json()
def post(p,b): r=requests.post(f"{MASTER_BASE}{p}",json=b,timeout=20); r.raise_for_status(); return r.json() if r.content else {}
def load(p,d): 
    try: return json.load(open(p))
    except: return d
def save(p,o): pathlib.Path(os.path.dirname(p)).mkdir(parents=True, exist_ok=True); json.dump(o, open(p,"w"), indent=2, sort_keys=True)
def extract(latest):
    out={}
    if isinstance(latest.get("slaves"),list):
        for s in latest["slaves"]:
            name=s.get("name") or s.get("slave_name") or ""
            if not name: continue
            for cid,st in (s.get("challenges") or {}).items():
                if st.get("age_seconds") is not None and st["age_seconds"]<MIN_ACTIVITY_SEC: continue
                d=out.setdefault(name,{}).setdefault(cid,{"solutions":0,"duration":0.0,"failures":0})
                d["solutions"]+=int(st.get("solutions",0)); d["duration"]+=float(st.get("runtime_seconds",0) or st.get("duration",0)); d["failures"]+=int(st.get("failures",0))
        if out: return out
    if isinstance(latest.get("algorithms"),list):
        for a in latest["algorithms"]:
            cid=(a.get("algorithm_id") or a.get("id") or "")[:4]
            for row in (a.get("per_slave") or a.get("by_slave") or []):
                name=row.get("slave") or row.get("name") or ""
                if not name: continue
                if row.get("age_seconds") is not None and row["age_seconds"]<MIN_ACTIVITY_SEC: continue
                d=out.setdefault(name,{}).setdefault(cid,{"solutions":0,"duration":0.0,"failures":0})
                d["solutions"]+=int(row.get("solutions",0)); d["duration"]+=float(row.get("runtime_seconds",0) or row.get("duration",0)); d["failures"]+=int(row.get("failures",0))
        if out: return out
    return out
def sps(x): dur=x.get("duration",0.0); return (x.get("solutions",0)/dur) if dur else 0.0
def decide(per,state):
    meds={}
    for cid in ("c001","c002","c003","c004","c005"):
        vals=[sps(per[n][cid]) for n in per if cid in per[n] and sps(per[n][cid])>0]
        if len(vals)>=3: meds[cid]=statistics.median(vals)
    suspects=set()
    for name,byc in per.items():
        bad=False
        for cid,st in byc.items():
            if meds.get(cid,0)>0 and sps(st)<0.40*meds[cid] and st.get("duration",0)>60: bad=True
            sols=st.get("solutions",0); fail=st.get("failures",0)
            if (fail+sols)>=5 and (fail/max(1,fail+sols))>0.30: bad=True
        if bad: suspects.add(name)
    now=int(time.time()); streak=state.setdefault("streaks",{}); to_ban=set(); to_unban=set()
    for n in suspects:
        streak[n]=streak.get(n,0)+1
        if streak[n]>=3: to_ban.add(n)
    for n in list(streak.keys()):
        if n not in suspects: streak[n]=0
    bans=state.setdefault("bans",{})
    for n,info in list(bans.items()):
        if now-info.get("ts",now)>24*3600: to_unban.add(n)
    return to_ban,to_unban
def apply_bans(cfg,banned):
    rules=list(cfg.get("slaves",[]))
    if banned:
        name_regex="^(%s)$"%("|".join(re.escape(x) for x in sorted(banned)))
        rules=[{"name_regex":name_regex,"algorithm_id_regex":".*","max_concurrent_batches":0}] + rules
    cfg=dict(cfg); cfg["slaves"]=rules; return cfg
def main():
    cfg=get("/get-config"); latest=get("/get-latest-data"); per=extract(latest)
    if not per: print("health-guard: pas de stats par slave."); return
    state=load(STATE_FILE,{}); to_ban,to_unban=decide(per,state)
    bans=load(BAN_FILE,{})
    now=int(time.time()); [bans.pop(n,None) for n in to_unban]; [bans.__setitem__(n,{"ts":now}) for n in to_ban]
    if bans: post("/update-config", apply_bans(cfg,set(bans.keys()))); print("health-guard: bannis -> " + ", ".join(sorted(bans.keys())) )
    else: print("health-guard: aucun ban actif.")
    state["bans"]=bans; save(STATE_FILE,state); save(BAN_FILE,bans)
if __name__=="__main__": main()
PY
sudo chmod +x /opt/tig-guard/health_guard.py

cat <<'SHH' | sudo tee /opt/tig-guard/show_bans.sh >/dev/null
#!/usr/bin/env bash
f="/opt/tig-guard/banned_slaves.json"; [ -s "$f" ] || { echo "Aucun rig banni."; exit 0; }
jq -r 'to_entries[] | "\(.key)\t\(.value.ts)"' "$f" | while IFS=$'\t' read -r name ts; do
  when=$( [ -n "$ts" ] && date -d "@$ts" "+%F %T" || echo "n/a" )
  printf "%-32s  banned_at=%s\n" "$name" "$when"
done
SHH
sudo chmod +x /opt/tig-guard/show_bans.sh

cat <<'SHH' | sudo tee /opt/tig-guard/unban.sh >/dev/null
#!/usr/bin/env bash
set -euo pipefail
name="${1:-}"; [ -z "$name" ] && { echo "Usage: $0 <SLAVE_NAME>"; exit 1; }
file="/opt/tig-guard/banned_slaves.json"; tmp="$(mktemp)"; [ -f "$file" ] || echo "{}" > "$file"
jq "del(.\"$name\")" "$file" > "$tmp" && mv "$tmp" "$file"
/usr/bin/python3 /opt/tig-guard/health_guard.py >/dev/null || true
echo "Débanni: $name"
SHH
sudo chmod +x /opt/tig-guard/unban.sh

(crontab -l 2>/dev/null; echo "*/30 * * * * MASTER_BASE=$MASTER_BASE /usr/bin/python3 /opt/tig-guard/health_guard.py >> /var/log/tig-guard.log 2>&1") | crontab -

echo "OK. Charge / vérifie la config:"
echo "  curl -s -X POST -H 'Content-Type: application/json' --data-binary @/opt/tig-tools/config.seed.json $MASTER_BASE/update-config"
echo "  curl -s $MASTER_BASE/get-config | jq '.algo_selection | length'"
