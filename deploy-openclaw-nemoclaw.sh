#!/usr/bin/env bash
# deploy-openclaw-nemoclaw.sh
# Deploys OpenClaw locally inside NemoClaw (OpenShell) sandbox
# with context-hub integration and restricted filesystem access.
#
# Allowed folders (read-write):
#   /home/roman/Документы/КОД/gigachat/РАЗБОРЫ/
#   /home/roman/Документы/БИБЛИОТЕКА/
# All other host folders are blocked by OpenShell sandbox policy.

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────

SANDBOX_NAME="${NEMOCLAW_SANDBOX_NAME:-openclaw-dev}"
OPENCLAW_REPO="https://github.com/openclaw/openclaw.git"
NEMOCLAW_REPO="https://github.com/romannekrasovaillm/NemoClaw.git"
CONTEXTHUB_REPO="https://github.com/romannekrasovaillm/context-hub.git"

INSTALL_DIR="${NEMOCLAW_INSTALL_DIR:-$HOME/.nemoclaw-deploy}"
OPENCLAW_DIR="$INSTALL_DIR/openclaw"
NEMOCLAW_DIR="$INSTALL_DIR/NemoClaw"
CONTEXTHUB_DIR="$INSTALL_DIR/context-hub"
STATE_DIR="$HOME/.nemoclaw"
CREDENTIALS_FILE="$STATE_DIR/credentials.json"

# DeepSeek API (reasoning model)
DEEPSEEK_API_KEY="${DEEPSEEK_API_KEY:-}"
DEEPSEEK_BASE_URL="https://api.deepseek.com"
DEEPSEEK_MODEL="deepseek-reasoner"

# Allowed host directories (bind-mounted into sandbox)
ALLOWED_DIR_1="/home/roman/Документы/КОД/gigachat/РАЗБОРЫ"
ALLOWED_DIR_2="/home/roman/Документы/БИБЛИОТЕКА"
ALLOWED_DIR_3="/home/roman/Документы/КОД/gigachat/РАЗБОРЫ/recipes_taxonomy"

# Sandbox mount points
SANDBOX_MOUNT_1="/workspace/razborы"
SANDBOX_MOUNT_2="/workspace/biblioteka"
SANDBOX_MOUNT_3="/workspace/recipes_taxonomy"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ── Helpers ───────────────────────────────────────────────────────────────────

log()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[✗]${NC} $*" >&2; }
info()  { echo -e "${CYAN}[→]${NC} $*"; }

die() { err "$@"; exit 1; }

check_command() {
  command -v "$1" &>/dev/null || die "'$1' not found. Please install it first."
}

# ── Step 0: Preflight checks ─────────────────────────────────────────────────

preflight() {
  info "Running preflight checks..."

  check_command git
  check_command node
  check_command npm
  check_command docker

  # Verify Node >= 20
  NODE_MAJOR=$(node -e 'console.log(process.versions.node.split(".")[0])')
  if (( NODE_MAJOR < 20 )); then
    die "Node.js 20+ required (found v$(node -v)). Install via nvm or your package manager."
  fi

  # Verify Docker is running
  if ! docker info &>/dev/null; then
    die "Docker daemon is not running. Start Docker and try again."
  fi

  # Verify allowed directories exist
  if [[ ! -d "$ALLOWED_DIR_1" ]]; then
    die "Required directory does not exist: $ALLOWED_DIR_1"
  fi
  if [[ ! -d "$ALLOWED_DIR_2" ]]; then
    die "Required directory does not exist: $ALLOWED_DIR_2"
  fi
  if [[ ! -d "$ALLOWED_DIR_3" ]]; then
    warn "Directory does not exist yet (will be created if needed): $ALLOWED_DIR_3"
  fi

  # Warn if DeepSeek API key is not set
  if [[ -z "$DEEPSEEK_API_KEY" ]]; then
    warn "DEEPSEEK_API_KEY is not set. You will be prompted during credential setup."
  fi

  log "Preflight checks passed."
}

# ── Step 1: Clone/update repos ───────────────────────────────────────────────

clone_repos() {
  info "Setting up installation directory: $INSTALL_DIR"
  mkdir -p "$INSTALL_DIR"

  # OpenClaw (main project)
  if [[ -d "$OPENCLAW_DIR/.git" ]]; then
    info "Updating OpenClaw..."
    git -C "$OPENCLAW_DIR" pull --rebase origin main 2>/dev/null || \
      git -C "$OPENCLAW_DIR" pull --rebase 2>/dev/null || true
  else
    info "Cloning OpenClaw..."
    git clone "$OPENCLAW_REPO" "$OPENCLAW_DIR"
  fi

  # NemoClaw
  if [[ -d "$NEMOCLAW_DIR/.git" ]]; then
    info "Updating NemoClaw..."
    git -C "$NEMOCLAW_DIR" pull --rebase origin main 2>/dev/null || \
      git -C "$NEMOCLAW_DIR" pull --rebase 2>/dev/null || true
  else
    info "Cloning NemoClaw..."
    git clone "$NEMOCLAW_REPO" "$NEMOCLAW_DIR"
  fi

  # context-hub
  if [[ -d "$CONTEXTHUB_DIR/.git" ]]; then
    info "Updating context-hub..."
    git -C "$CONTEXTHUB_DIR" pull --rebase origin main 2>/dev/null || \
      git -C "$CONTEXTHUB_DIR" pull --rebase 2>/dev/null || true
  else
    info "Cloning context-hub..."
    git clone "$CONTEXTHUB_REPO" "$CONTEXTHUB_DIR"
  fi

  log "All repositories ready."
  info "  openclaw:     $OPENCLAW_DIR"
  info "  NemoClaw:     $NEMOCLAW_DIR"
  info "  context-hub:  $CONTEXTHUB_DIR"
}

# ── Step 2: Install dependencies ─────────────────────────────────────────────

install_deps() {
  info "Installing OpenClaw dependencies and building..."
  if [[ -f "$OPENCLAW_DIR/package.json" ]]; then
    # OpenClaw uses pnpm workspaces; npm install does not work here.
    if ! command -v pnpm &>/dev/null; then
      info "Installing pnpm..."
      npm install -g pnpm
    fi
    (cd "$OPENCLAW_DIR" && pnpm install && pnpm build) || \
      warn "OpenClaw build failed. The gateway may not work from source mount."
  fi

  info "Installing NemoClaw dependencies..."
  (cd "$NEMOCLAW_DIR" && npm install --omit=dev)

  info "Building NemoClaw plugin..."
  if [[ -d "$NEMOCLAW_DIR/nemoclaw" ]]; then
    (cd "$NEMOCLAW_DIR/nemoclaw" && npm install && npm run build 2>/dev/null || true)
  fi

  info "Installing context-hub CLI..."
  (cd "$CONTEXTHUB_DIR" && npm install)

  # Make chub CLI available
  if [[ -f "$CONTEXTHUB_DIR/cli/bin/chub" ]]; then
    chmod +x "$CONTEXTHUB_DIR/cli/bin/chub"
    # Symlink into a path location
    mkdir -p "$INSTALL_DIR/bin"
    ln -sf "$CONTEXTHUB_DIR/cli/bin/chub" "$INSTALL_DIR/bin/chub"
  fi

  log "Dependencies installed."
}

# ── Step 3: Configure DeepSeek credentials ───────────────────────────────────

configure_credentials() {
  mkdir -p "$STATE_DIR"

  if [[ -f "$CREDENTIALS_FILE" ]]; then
    # Check if already has deepseek key
    if grep -q "deepseek_api_key" "$CREDENTIALS_FILE" 2>/dev/null; then
      log "DeepSeek credentials already configured: $CREDENTIALS_FILE"
      return
    fi
  fi

  # Use env var if available, otherwise prompt
  local api_key="$DEEPSEEK_API_KEY"
  if [[ -z "$api_key" ]]; then
    echo ""
    warn "DeepSeek API key is required for reasoning inference."
    echo "  Get one at: https://platform.deepseek.com/api_keys"
    echo ""
    read -rsp "Enter DeepSeek API key (or press Enter to skip): " api_key
    echo ""
  fi

  if [[ -z "$api_key" ]]; then
    warn "Skipping DeepSeek credentials. Set DEEPSEEK_API_KEY env var and rerun."
    return
  fi

  cat > "$CREDENTIALS_FILE" <<CRED_EOF
{
  "deepseek_api_key": "$api_key",
  "deepseek_base_url": "$DEEPSEEK_BASE_URL",
  "deepseek_model": "$DEEPSEEK_MODEL"
}
CRED_EOF
  chmod 600 "$CREDENTIALS_FILE"
  DEEPSEEK_API_KEY="$api_key"
  log "DeepSeek credentials saved to $CREDENTIALS_FILE"
}

# ── Step 4: Generate sandbox filesystem policy ───────────────────────────────

generate_fs_policy() {
  local policy_dir="$STATE_DIR/policies"
  mkdir -p "$policy_dir"

  info "Generating restrictive filesystem policy..."

  cat > "$policy_dir/restricted-fs.yaml" <<'POLICY_EOF'
# Filesystem policy: only allowed directories are mounted read-write.
# All other host paths are denied by OpenShell Landlock policy.
kind: filesystem
version: v1
metadata:
  name: restricted-workspace
  description: >
    Allows read-write access only to designated project folders.
    All other host filesystem paths are blocked.
rules:
  # Deny everything by default (OpenShell sandbox baseline)
  - action: deny
    path: /
    access: [read, write, execute]

  # Allow sandbox workspace (internal)
  - action: allow
    path: /sandbox
    access: [read, write, execute]

  # Allow temp
  - action: allow
    path: /tmp
    access: [read, write]

  # Allowed project directories (bind-mounted from host)
  - action: allow
    path: /workspace/razborы
    access: [read, write]

  - action: allow
    path: /workspace/biblioteka
    access: [read, write]

  - action: allow
    path: /workspace/recipes_taxonomy
    access: [read, write]

  # context-hub data (read-only inside sandbox)
  - action: allow
    path: /workspace/context-hub
    access: [read]
POLICY_EOF

  log "Filesystem policy written to $policy_dir/restricted-fs.yaml"
}

# ── Step 5: Generate network policy ──────────────────────────────────────────

generate_network_policy() {
  local policy_dir="$STATE_DIR/policies"
  mkdir -p "$policy_dir"

  info "Generating network egress policy..."

  cat > "$policy_dir/network-egress.yaml" <<'NET_EOF'
# Network egress: deny-by-default, allow only required endpoints.
kind: network
version: v1
metadata:
  name: openclaw-sandbox-egress
  description: Minimal egress for OpenClaw + DeepSeek inference + context-hub.
rules:
  # DeepSeek inference API (reasoning model)
  - action: allow
    destination: api.deepseek.com
    ports: [443]

  # DeepSeek platform (auth, key validation)
  - action: allow
    destination: "*.deepseek.com"
    ports: [443]

  # OpenClaw services
  - action: allow
    destination: api.openclaw.ai
    ports: [443]

  - action: allow
    destination: "*.openclaw.ai"
    ports: [443]

  # GitHub (for context-hub content fetching)
  - action: allow
    destination: github.com
    ports: [443]

  - action: allow
    destination: raw.githubusercontent.com
    ports: [443]

  # npm registry (plugin installs)
  - action: allow
    destination: registry.npmjs.org
    ports: [443]

  # DNS
  - action: allow
    destination: "*"
    ports: [53]
    protocol: udp
NET_EOF

  log "Network policy written to $policy_dir/network-egress.yaml"
}

# ── Step 6: Create and launch the sandbox ─────────────────────────────────────

create_sandbox() {
  local nemoclaw_bin="$NEMOCLAW_DIR/bin/nemoclaw.js"

  if [[ ! -f "$nemoclaw_bin" ]]; then
    die "NemoClaw CLI not found at $nemoclaw_bin"
  fi

  info "Creating OpenShell sandbox '$SANDBOX_NAME'..."

  # Check if sandbox already exists
  if node "$nemoclaw_bin" "$SANDBOX_NAME" status &>/dev/null 2>&1; then
    warn "Sandbox '$SANDBOX_NAME' already exists."
    read -rp "Destroy and recreate? [y/N]: " RECREATE
    if [[ "${RECREATE,,}" == "y" ]]; then
      info "Destroying existing sandbox..."
      node "$nemoclaw_bin" "$SANDBOX_NAME" destroy || true
    else
      log "Keeping existing sandbox."
      return
    fi
  fi

  # Build docker run args with bind mounts for allowed directories only
  # OpenShell sandbox create with volume mounts
  local docker_args=""
  docker_args+=" -v $(printf '%q' "$ALLOWED_DIR_1"):$SANDBOX_MOUNT_1:rw"
  docker_args+=" -v $(printf '%q' "$ALLOWED_DIR_2"):$SANDBOX_MOUNT_2:rw"
  docker_args+=" -v $(printf '%q' "$ALLOWED_DIR_3"):$SANDBOX_MOUNT_3:rw"
  docker_args+=" -v $CONTEXTHUB_DIR:/workspace/context-hub:ro"

  # If nemoclaw supports openshell sandbox create with extra docker args
  if command -v openshell &>/dev/null; then
    info "Using openshell CLI directly..."
    openshell sandbox create "$SANDBOX_NAME" \
      --image "node:22-slim" \
      --volume "$ALLOWED_DIR_1:$SANDBOX_MOUNT_1:rw" \
      --volume "$ALLOWED_DIR_2:$SANDBOX_MOUNT_2:rw" \
      --volume "$ALLOWED_DIR_3:$SANDBOX_MOUNT_3:rw" \
      --volume "$CONTEXTHUB_DIR:/workspace/context-hub:ro" \
      --policy "$STATE_DIR/policies/restricted-fs.yaml" \
      --policy "$STATE_DIR/policies/network-egress.yaml" \
      2>&1 || true
  else
    # Fallback: use Docker directly with OpenShell-compatible security
    info "OpenShell CLI not found. Using Docker with manual security hardening..."

    # Remove stale container with the same name if present
    docker rm -f "$SANDBOX_NAME" 2>/dev/null || true

    # Ensure allowed host directories exist (create if missing)
    mkdir -p "$ALLOWED_DIR_1" "$ALLOWED_DIR_2" "$ALLOWED_DIR_3"

    # Build volume args — only mount directories that exist on the host
    local vol_args=()
    vol_args+=(-v "$ALLOWED_DIR_1:$SANDBOX_MOUNT_1:rw")
    vol_args+=(-v "$ALLOWED_DIR_2:$SANDBOX_MOUNT_2:rw")
    vol_args+=(-v "$ALLOWED_DIR_3:$SANDBOX_MOUNT_3:rw")
    [[ -d "$CONTEXTHUB_DIR" ]] && vol_args+=(-v "$CONTEXTHUB_DIR:/workspace/context-hub:ro")

    # Mount locally-built openclaw so binaries are available inside the container
    vol_args+=(-v "$OPENCLAW_DIR:/opt/openclaw:ro")
    # Mount host bin dir (contains chub symlink)
    vol_args+=(-v "$INSTALL_DIR/bin:/opt/hostbin:ro")

    # Use --entrypoint to skip docker-entrypoint.sh (it needs setuid
    # which is blocked by no-new-privileges). Run node directly as
    # a keep-alive process.
    docker run -d \
      --name "$SANDBOX_NAME" \
      --hostname "$SANDBOX_NAME" \
      --entrypoint /usr/local/bin/node \
      --tmpfs /tmp:rw,nosuid,size=512m \
      --tmpfs /sandbox:rw,exec,size=2g \
      "${vol_args[@]}" \
      -e "CHUB_CONTENT_DIR=/workspace/context-hub/content" \
      -e "DEEPSEEK_API_KEY=$DEEPSEEK_API_KEY" \
      -e "DEEPSEEK_BASE_URL=$DEEPSEEK_BASE_URL" \
      -e "DEEPSEEK_MODEL=$DEEPSEEK_MODEL" \
      -e "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/sandbox/node_modules/.bin:/sandbox/bin" \
      -e "HOME=/sandbox" \
      -w /sandbox \
      node:22-slim \
      -e "setInterval(()=>{},1<<30)"

    # Give the container a moment to start, then verify
    sleep 2
    local state
    state=$(docker inspect -f '{{.State.Status}}' "$SANDBOX_NAME" 2>/dev/null || echo "missing")
    if [[ "$state" != "running" ]]; then
      err "Container is '$state' instead of 'running'. Logs:"
      docker logs "$SANDBOX_NAME" 2>&1 || true
      die "Fix the issue above and retry."
    fi
  fi

  log "Sandbox '$SANDBOX_NAME' created."
}

# ── Step 7: Install OpenClaw + context-hub inside sandbox ─────────────────────

setup_sandbox_interior() {
  info "Setting up OpenClaw inside sandbox..."

  # Install git (npm packages), psmisc (fuser for --force), procps (pkill for restart)
  docker exec "$SANDBOX_NAME" sh -c '
    apt-get update -qq && apt-get install -y -qq git psmisc procps >/dev/null 2>&1
  ' 2>&1 || warn "Could not install packages inside container."

  # Create wrapper scripts in /sandbox/bin so openclaw and chub are on PATH
  docker exec "$SANDBOX_NAME" sh -c '
    mkdir -p /sandbox/bin /sandbox/node_modules /sandbox/.openclaw

    # Prefer locally-mounted build; fall back to npm install from registry
    if [ -f /opt/openclaw/openclaw.mjs ]; then
      cat > /sandbox/bin/openclaw <<WRAPPER
#!/bin/sh
exec /usr/local/bin/node /opt/openclaw/openclaw.mjs "\$@"
WRAPPER
      chmod +x /sandbox/bin/openclaw
    else
      echo "[!] openclaw.mjs not found in source mount — installing from npm..."
      npm install -g openclaw@latest 2>&1 || echo "[!] npm install openclaw failed"
    fi

    # Create chub wrapper that runs context-hub CLI
    if [ -f /workspace/context-hub/cli/bin/chub ]; then
      cat > /sandbox/bin/chub <<WRAPPER
#!/bin/sh
exec /usr/local/bin/node /workspace/context-hub/cli/bin/chub "\$@"
WRAPPER
      chmod +x /sandbox/bin/chub
      echo "[✓] chub CLI installed"
    elif [ -f /opt/hostbin/chub ]; then
      # Fallback: copy from host bin mount
      cp /opt/hostbin/chub /sandbox/bin/chub 2>/dev/null || true
      chmod +x /sandbox/bin/chub 2>/dev/null || true
      echo "[✓] chub CLI installed (from hostbin)"
    else
      echo "[!] chub CLI not available (context-hub/cli/bin/chub not found)"
    fi

    # Verify openclaw is callable
    if /sandbox/bin/openclaw --version 2>/dev/null; then
      echo "[✓] openclaw CLI available"
    else
      echo "[!] openclaw CLI installed but version check failed (may still work)"
    fi
  ' 2>&1 || warn "Sandbox interior setup had issues."

  # Verify context-hub mount
  docker exec "$SANDBOX_NAME" sh -c '
    if [ -d /workspace/context-hub ]; then
      echo "[✓] context-hub mounted at /workspace/context-hub"
      ls /workspace/context-hub/ 2>/dev/null || true
    fi
  '

  # Verify allowed directories are accessible
  docker exec "$SANDBOX_NAME" sh -c '
    echo "=== Verifying mounted directories ==="

    if [ -d "'"$SANDBOX_MOUNT_1"'" ]; then
      echo "[✓] РАЗБОРЫ mounted and accessible"
      ls "'"$SANDBOX_MOUNT_1"'" | head -5
    else
      echo "[✗] РАЗБОРЫ not accessible"
    fi

    if [ -d "'"$SANDBOX_MOUNT_2"'" ]; then
      echo "[✓] БИБЛИОТЕКА mounted and accessible"
      ls "'"$SANDBOX_MOUNT_2"'" | head -5
    else
      echo "[✗] БИБЛИОТЕКА not accessible"
    fi

    if [ -d "'"$SANDBOX_MOUNT_3"'" ]; then
      echo "[✓] recipes_taxonomy mounted and accessible"
      ls "'"$SANDBOX_MOUNT_3"'" | head -5
    else
      echo "[✗] recipes_taxonomy not accessible"
    fi

    echo ""
    echo "=== Verifying restricted access ==="
    ls /home 2>/dev/null && echo "[✗] WARNING: /home is accessible!" || echo "[✓] /home is blocked"
    ls /etc/shadow 2>/dev/null && echo "[✗] WARNING: /etc/shadow readable!" || echo "[✓] /etc/shadow is blocked"
  '

  # Symlink mounted host directories into the agent workspace so the agent
  # can discover user files without leaving its configured workspace root.
  info "Creating workspace symlinks to mounted host directories..."
  docker exec "$SANDBOX_NAME" sh -c '
    mkdir -p /sandbox/.openclaw/workspace
    ln -sfn '"$SANDBOX_MOUNT_1"' /sandbox/.openclaw/workspace/razborы
    ln -sfn '"$SANDBOX_MOUNT_2"' /sandbox/.openclaw/workspace/biblioteka
    ln -sfn '"$SANDBOX_MOUNT_3"' /sandbox/.openclaw/workspace/recipes_taxonomy
    ln -sfn /workspace/context-hub /sandbox/.openclaw/workspace/context-hub

    echo "[✓] Workspace symlinks created:"
    ls -la /sandbox/.openclaw/workspace/
  '

  log "Sandbox interior configured."
}

# ── Step 8: Configure OpenClaw gateway ────────────────────────────────────────

configure_gateway() {
  info "Configuring OpenClaw gateway..."

  # Write config using the schema that OpenClaw's config wizard produces.
  # DeepSeek is registered as a custom OpenAI-compatible provider.
  docker exec "$SANDBOX_NAME" sh -c '
    mkdir -p /sandbox/.openclaw

    cat > /sandbox/.openclaw/openclaw.json <<GWEOF
{
  "models": {
    "mode": "merge",
    "providers": {
      "custom-api-deepseek-com": {
        "baseUrl": "'"$DEEPSEEK_BASE_URL"'",
        "apiKey": "'"$DEEPSEEK_API_KEY"'",
        "api": "openai-completions",
        "models": [
          {
            "id": "'"$DEEPSEEK_MODEL"'",
            "name": "'"$DEEPSEEK_MODEL"' (DeepSeek)",
            "reasoning": true,
            "input": ["text"],
            "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 },
            "contextWindow": 64000,
            "maxTokens": 8192
          }
        ]
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "custom-api-deepseek-com/'"$DEEPSEEK_MODEL"'"
      },
      "workspace": "/sandbox/.openclaw/workspace"
    }
  },
  "gateway": {
    "mode": "local",
    "port": 18789,
    "bind": "loopback"
  }
}
GWEOF

    echo "[✓] OpenClaw config written (DeepSeek + gateway)"
  ' 2>&1 || warn "Gateway config may need manual adjustment."

  log "Gateway configured."
}

# ── Step 9: Enable networking for inference (controlled) ──────────────────────

enable_inference_network() {
  info "Verifying network access for inference..."

  # Container starts with default bridge network so npm install works.
  # Optionally create a dedicated network for tighter control.
  docker network create "${SANDBOX_NAME}-inference" 2>/dev/null || true
  docker network connect "${SANDBOX_NAME}-inference" "$SANDBOX_NAME" 2>/dev/null || true

  # Verify DNS + HTTPS connectivity from inside the container
  docker exec "$SANDBOX_NAME" sh -c \
    'wget -q --spider https://api.deepseek.com 2>/dev/null && echo "[✓] DeepSeek API reachable" || echo "[!] DeepSeek API not reachable (check network)"' \
    2>&1 || true

  log "Inference network configured."
}

# ── Step 10: Start OpenClaw gateway inside sandbox ────────────────────────────

start_gateway() {
  info "Starting OpenClaw gateway inside sandbox..."

  docker exec -d "$SANDBOX_NAME" sh -c '
    export HOME=/sandbox
    export OPENCLAW_CONFIG=/sandbox/.openclaw/openclaw.json
    export PATH="/sandbox/bin:$PATH"

    # Start gateway in background using the wrapper script
    if [ -x /sandbox/bin/openclaw ]; then
      /sandbox/bin/openclaw gateway run --bind loopback --port 18789 --force \
        > /tmp/openclaw-gateway.log 2>&1 &
      echo $! > /tmp/openclaw-gateway.pid
      echo "[✓] Gateway started (PID: $(cat /tmp/openclaw-gateway.pid))"
    else
      echo "[!] OpenClaw binary not found at /sandbox/bin/openclaw"
    fi
  ' 2>&1

  log "Gateway launch initiated."
}

# ── Step 11: Print summary ───────────────────────────────────────────────────

print_summary() {
  echo ""
  echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  OpenClaw в NemoClaw (OpenShell) — развёртывание завершено${NC}"
  echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
  echo ""
  echo -e "  Sandbox:         ${GREEN}$SANDBOX_NAME${NC}"
  echo -e "  Gateway port:    ${GREEN}18789${NC} (loopback)"
  echo -e "  Inference:       ${GREEN}DeepSeek Reasoner (deepseek-reasoner / V3.2)${NC}"
  echo -e "  API endpoint:    ${GREEN}$DEEPSEEK_BASE_URL${NC}"
  echo ""
  echo -e "  ${CYAN}Доступные директории:${NC}"
  echo -e "    ${GREEN}$SANDBOX_MOUNT_1${NC}  ←  $ALLOWED_DIR_1"
  echo -e "    ${GREEN}$SANDBOX_MOUNT_2${NC}  ←  $ALLOWED_DIR_2"
  echo -e "    ${GREEN}$SANDBOX_MOUNT_3${NC}  ←  $ALLOWED_DIR_3"
  echo -e "    ${GREEN}/workspace/context-hub${NC}  ←  context-hub (только чтение)"
  echo ""
  echo -e "  ${RED}Все остальные папки хоста заблокированы.${NC}"
  echo ""
  echo -e "  ${CYAN}Команды управления:${NC}"
  echo -e "    Подключиться:  docker exec -it $SANDBOX_NAME bash"
  echo -e "    Логи:          docker exec $SANDBOX_NAME cat /tmp/openclaw-gateway.log"
  echo -e "    Статус:        docker exec $SANDBOX_NAME openclaw gateway status --deep"
  echo -e "    Остановить:    docker stop $SANDBOX_NAME"
  echo -e "    Удалить:       docker rm -f $SANDBOX_NAME"
  echo ""
  echo -e "  ${CYAN}context-hub внутри sandbox:${NC}"
  echo -e "    chub search <запрос>       — поиск документации"
  echo -e "    chub get <id> --lang py    — получить API-документ"
  echo -e "    chub annotate <id> <note>  — добавить заметку"
  echo ""
  echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
}

# ── Usage / Help ──────────────────────────────────────────────────────────────

usage() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  --clone-only    Clone all GitHub repos and exit (no sandbox/deploy)"
  echo "  --help          Show this help"
  echo ""
  echo "Environment variables:"
  echo "  DEEPSEEK_API_KEY          DeepSeek API key for reasoning inference"
  echo "  NEMOCLAW_SANDBOX_NAME     Sandbox container name (default: openclaw-dev)"
  echo "  NEMOCLAW_INSTALL_DIR      Installation directory (default: ~/.nemoclaw-deploy)"
  echo ""
  echo "GitHub repositories cloned:"
  echo "  openclaw:     $OPENCLAW_REPO"
  echo "  NemoClaw:     $NEMOCLAW_REPO"
  echo "  context-hub:  $CONTEXTHUB_REPO"
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
  # Parse arguments
  local clone_only=false
  for arg in "$@"; do
    case "$arg" in
      --clone-only) clone_only=true ;;
      --help|-h) usage; exit 0 ;;
    esac
  done

  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║  OpenClaw + NemoClaw (OpenShell) + context-hub deployment  ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
  echo ""

  if [[ "$clone_only" == true ]]; then
    info "Clone-only mode: cloning repositories..."
    check_command git
    clone_repos
    log "Done. Repos cloned to $INSTALL_DIR"
    echo ""
    echo -e "  ${CYAN}Следующий шаг — полное развёртывание:${NC}"
    echo -e "    DEEPSEEK_API_KEY=\"sk-...\" $0"
    exit 0
  fi

  preflight
  clone_repos
  install_deps
  configure_credentials
  generate_fs_policy
  generate_network_policy
  create_sandbox
  setup_sandbox_interior
  configure_gateway
  enable_inference_network
  start_gateway
  print_summary
}

main "$@"
