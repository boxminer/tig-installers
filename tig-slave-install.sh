# === tig-slave-install.sh ===
#!/usr/bin/env bash
set -euo pipefail

MASTER_IP="${1:-}"; MASTER_PORT="${2:-5115}"; NAME_PREFIX="${3:-}" ; CPU_WORKERS="${4:-auto}"
if [[ -z "$MASTER_IP" ]]; then
  echo "Usage: $0 <MASTER_IP> [MASTER_PORT=5115] [NAME_PREFIX=''] [CPU_WORKERS=auto|N]"
  exit 1
fi

log(){ echo -e "\e[1;32m[*]\e[0m $*"; }
warn(){ echo -e "\e[1;33m[!]\e[0m $*"; }

# Docker
log "Docker"
if ! command -v docker >/dev/null 2>&1; then curl -fsSL https://get.docker.com | sh; fi
usermod -aG docker "${SUDO_USER:-$USER}" || true
docker compose version >/dev/null 2>&1 || { echo "Docker Compose plugin manquant"; exit 1; }

# Repo
REPO_DIR="/opt/tig-slaves/tig-monorepo/tig-benchmarker"
mkdir -p /opt/tig-slaves
if [[ ! -d /opt/tig-slaves/tig-monorepo ]]; then
  git clone https://github.com/tig-foundation/tig-monorepo.git /opt/tig-slaves/tig-monorepo
fi
cd "$REPO_DIR"

HOST=$(hostname | tr -cd '[:alnum:]-')
rand4(){ tr -dc a-f0-9 </dev/urandom | head -c 4; }

# CPU worker
if [[ "$CPU_WORKERS" == "auto" ]]; then CPU_WORKERS="$(nproc)"; fi
CPU_ID="${NAME_PREFIX}cpu-${HOST}-$(rand4)"
log "CPU worker: $CPU_ID (workers=$CPU_WORKERS)"
cat > /opt/tig-slaves/env.cpu <<EOF
UI_PORT=80
MASTER_PORT=$MASTER_PORT
MASTER_IP=$MASTER_IP
SLAVE_NAME=$CPU_ID
NUM_WORKERS=$CPU_WORKERS
EOF
COMPOSE_PROJECT_NAME="tig-cpu" docker compose --env-file /opt/tig-slaves/env.cpu -f slave.yml up -d slave satisfiability vehicle_routing knapsack

# GPU(s)
if command -v nvidia-smi >/dev/null 2>&1; then
  mapfile -t GPU_IDX < <(nvidia-smi --query-gpu=index --format=csv,noheader | sed '/^$/d')
  mapfile -t GPU_NAME < <(nvidia-smi --query-gpu=name  --format=csv,noheader | sed '/^$/d')
  if [[ ${#GPU_IDX[@]} -gt 0 ]]; then
    log "NVIDIA détecté (${#GPU_IDX[@]} GPU). Installation nvidia-container-toolkit…"
    distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor | tee /usr/share/keyrings/nvidia-container-toolkit.gpg >/dev/null
    curl -fsSL https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
    apt update && apt install -y nvidia-container-toolkit
    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker
    for i in "${!GPU_IDX[@]}"; do
      idx="${GPU_IDX[$i]}"; model="$(echo "${GPU_NAME[$i]}" | sed -E 's/[[:space:]]+/-/g; s/[^A-Za-z0-9-]//g')"
      GPU_ID="${NAME_PREFIX}gpu-${HOST}-${model}-#${idx}-$(rand4)"
      log "GPU#$idx → $GPU_ID"
      cat > "/opt/tig-slaves/env.gpu.$idx" <<EOF
UI_PORT=80
MASTER_PORT=$MASTER_PORT
MASTER_IP=$MASTER_IP
SLAVE_NAME=$GPU_ID
NUM_WORKERS=1
NVIDIA_VISIBLE_DEVICES=$idx
EOF
      COMPOSE_PROJECT_NAME="tig-gpu-$idx" NVIDIA_VISIBLE_DEVICES="$idx" \
        docker compose --env-file "/opt/tig-slaves/env.gpu.$idx" -f slave.yml up -d slave vector_search hypergraph
    done
  else
    warn "nvidia-smi présent mais aucune carte visible."
  fi
else
  if lspci | grep -qi nvidia; then
    warn "Cartes NVIDIA détectées sans pilote (nvidia-smi absent). Installe d'abord les pilotes."
  fi
fi

log "Terminé. UI Master: http://$MASTER_IP/"
