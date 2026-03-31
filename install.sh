#!/usr/bin/env bash
# =============================================================================
# install.sh — OpenClaw Plug-and-Play Installer for Ubuntu
# =============================================================================
#
# Usage:
#   # Run from the cloned repo:
#   chmod +x install.sh && ./install.sh
#
#   # Or run directly from GitHub:
#   curl -fsSL https://raw.githubusercontent.com/condestable2000/openclaw-reference-setup/main/install.sh | bash
#
# What this script does:
#   1. Installs system dependencies (ffmpeg, jq, python3, etc.)
#   2. Installs Node.js 24 via NodeSource
#   3. Installs openclaw@latest globally via npm
#   4. Creates a dedicated 'agent' OS user (dual-user isolation)
#   5. Creates the workspace directory structure
#   6. Copies reference templates (SOUL.md, AGENTS.md, USER.md, TOPOLOGY.md)
#   7. Writes a base openclaw.json config
#   8. Installs Piper TTS (local, no cloud API)
#   9. Installs Faster-Whisper STT in a Python virtualenv
#  10. Installs Ollama (local LLM runner)
#  11. Creates a systemd service for the OpenClaw gateway
#  12. Applies security hardening (permissions, checksums, helper scripts)
#
# Requirements:
#   - Ubuntu 22.04+ (x86_64 or arm64)
#   - Regular user with sudo access (do NOT run as root)
#
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Colors & output helpers
# ---------------------------------------------------------------------------
BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
RESET='\033[0m'

log()    { echo -e "${GREEN}[✔]${RESET} $*"; }
info()   { echo -e "${CYAN}[→]${RESET} $*"; }
warn()   { echo -e "${YELLOW}[⚠]${RESET} $*"; }
error()  { echo -e "${RED}[✘]${RESET} $*" >&2; }
header() {
    echo ""
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════${RESET}"
    echo -e "${BOLD}${CYAN}  $*${RESET}"
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════${RESET}"
}

# ---------------------------------------------------------------------------
# Configuration defaults (override via environment variables)
# ---------------------------------------------------------------------------
AGENT_USER="${AGENT_USER:-agent}"
GATEWAY_PORT="${GATEWAY_PORT:-18789}"
NODE_MAJOR="${NODE_MAJOR:-24}"
PIPER_VERSION="${PIPER_VERSION:-2023.11.14-2}"
REPO_URL="https://raw.githubusercontent.com/condestable2000/openclaw-reference-setup/main"

# Detect if we're running interactively (not via curl | bash)
INTERACTIVE=false
[[ -t 0 ]] && INTERACTIVE=true

# Resolve the directory where this script lives (works with both local and piped runs)
if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "bash" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    SCRIPT_DIR="$(pwd)"
fi

AGENT_HOME="/home/$AGENT_USER"
OPENCLAW_DIR="$AGENT_HOME/.openclaw"
WORKSPACE="$OPENCLAW_DIR/workspace"
CREDENTIALS_DIR="$AGENT_HOME/.credentials"
LOG_DIR="$OPENCLAW_DIR/logs"
OPENCLAW_CONFIG="$OPENCLAW_DIR/openclaw.json"

# ---------------------------------------------------------------------------
# Trap for cleanup on errors
# ---------------------------------------------------------------------------
TMP_WORKDIR=""
cleanup() {
    [[ -n "$TMP_WORKDIR" && -d "$TMP_WORKDIR" ]] && rm -rf "$TMP_WORKDIR"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Helper: copy a file only if the destination doesn't already exist
# ---------------------------------------------------------------------------
copy_if_missing() {
    local src="$1"
    local dst="$2"
    local owner="${3:-$AGENT_USER:$AGENT_USER}"
    local mode="${4:-644}"
    if [[ -f "$dst" ]]; then
        warn "Already exists, skipping: $(basename "$dst")"
    else
        sudo cp "$src" "$dst"
        sudo chown "$owner" "$dst"
        sudo chmod "$mode" "$dst"
        log "Installed: $dst"
    fi
}

# ---------------------------------------------------------------------------
# Helper: fetch a remote file into a temp directory
# ---------------------------------------------------------------------------
fetch_file() {
    local url="$1"
    local dest="$2"
    if ! wget -q --timeout=30 "$url" -O "$dest"; then
        warn "Failed to download: $url"
        return 1
    fi
}

# ============================================================================
# STEP 0: Preflight checks
# ============================================================================
header "Preflight Checks"

# Must NOT run as root
if [[ "$EUID" -eq 0 ]]; then
    error "Do not run this script as root. Run as a regular user with sudo access."
    exit 1
fi

# Check for Ubuntu
if ! grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
    warn "This installer is designed for Ubuntu. Other Debian-based distros may work."
fi

# Check sudo access
if ! sudo -v 2>/dev/null; then
    error "This script requires sudo access. Add your user to the sudoers group first."
    exit 1
fi

# Check architecture
ARCH=$(uname -m)
if [[ "$ARCH" != "x86_64" && "$ARCH" != "aarch64" ]]; then
    warn "Architecture '$ARCH' may not be fully supported. Tested on x86_64 and arm64."
fi

log "User:         $(whoami) (UID: $EUID)"
log "OS:           $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2 || uname -s)"
log "Architecture: $ARCH"
log "Hostname:     $(hostname)"
log "Script dir:   $SCRIPT_DIR"

# ============================================================================
# STEP 1: System dependencies
# ============================================================================
header "Installing System Dependencies"

info "Updating package lists..."
sudo apt-get update -qq

SYSTEM_PACKAGES=(
    # Core utilities
    curl wget git ca-certificates gnupg
    # Build tools
    build-essential
    # Media processing
    ffmpeg lame sox
    # Data processing
    jq pandoc
    # Python runtime
    python3 python3-pip python3-venv
    # Security tools
    openssl
    # Convenience
    trash-cli htop
)

info "Installing: ${SYSTEM_PACKAGES[*]}"
sudo apt-get install -y --no-install-recommends "${SYSTEM_PACKAGES[@]}"
log "System packages installed."

# ============================================================================
# STEP 2: Node.js
# ============================================================================
header "Installing Node.js $NODE_MAJOR"

install_nodejs() {
    info "Adding NodeSource repository for Node.js $NODE_MAJOR..."
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | sudo -E bash -
    sudo apt-get install -y nodejs
}

if command -v node &>/dev/null; then
    NODE_VER=$(node --version | sed 's/v//' | cut -d'.' -f1)
    if [[ "$NODE_VER" -ge 22 ]]; then
        log "Node.js $(node --version) is already installed (meets minimum v22.16+)."
        if [[ "$NODE_VER" -lt "$NODE_MAJOR" ]]; then
            warn "Node.js $NODE_MAJOR is recommended. Current: $(node --version). Upgrading..."
            install_nodejs
        fi
    else
        warn "Node.js $(node --version) is too old (need v22.16+). Upgrading..."
        install_nodejs
    fi
else
    install_nodejs
fi

log "Node.js: $(node --version)"
log "npm:     $(npm --version)"

# ============================================================================
# STEP 3: Install OpenClaw
# ============================================================================
header "Installing OpenClaw"

if command -v openclaw &>/dev/null; then
    CURRENT_VER=$(openclaw --version 2>/dev/null || echo "unknown")
    info "OpenClaw already installed ($CURRENT_VER). Updating to latest..."
fi

info "Running: npm install -g openclaw@latest"
sudo npm install -g openclaw@latest

OPENCLAW_VER=$(openclaw --version 2>/dev/null || echo "installed")
OPENCLAW_BIN=$(which openclaw)
log "OpenClaw $OPENCLAW_VER → $OPENCLAW_BIN"

# ============================================================================
# STEP 4: Dual-User Isolation
# ============================================================================
header "Dual-User Isolation — Creating Agent User"

if id "$AGENT_USER" &>/dev/null; then
    log "Agent user '$AGENT_USER' already exists (UID: $(id -u "$AGENT_USER"))."
else
    info "Creating dedicated agent user '$AGENT_USER'..."
    sudo useradd -m -s /bin/bash "$AGENT_USER"

    # Set a cryptographically random password (for recovery only — no interactive login)
    AGENT_PASS=$(openssl rand -base64 32 | tr -d '=+/')
    echo "$AGENT_USER:$AGENT_PASS" | sudo chpasswd

    # Store the password in a root-only file for recovery
    echo "$AGENT_PASS" | sudo tee /root/.openclaw_agent_pass > /dev/null
    sudo chmod 600 /root/.openclaw_agent_pass

    log "Agent user '$AGENT_USER' created."
    info "Recovery password stored in /root/.openclaw_agent_pass (chmod 600)."
fi

# Verify agent user has no sudo
if sudo -l -U "$AGENT_USER" 2>/dev/null | grep -qE "NOPASSWD|ALL"; then
    warn "Agent user '$AGENT_USER' appears to have sudo. REMOVE IT: sudo visudo"
else
    log "Confirmed: agent user has no sudo access (principle of least privilege)."
fi

# Add to docker group if Docker is installed (for container sandboxing)
if command -v docker &>/dev/null; then
    sudo usermod -aG docker "$AGENT_USER"
    log "Agent user added to 'docker' group (for sandbox support)."
fi

# ============================================================================
# STEP 5: Workspace Directory Structure
# ============================================================================
header "Creating Workspace Structure"

DIRS_TO_CREATE=(
    "$OPENCLAW_DIR"
    "$WORKSPACE"
    "$WORKSPACE/memory"
    "$WORKSPACE/skills"
    "$WORKSPACE/checksums"
    "$CREDENTIALS_DIR"
    "$LOG_DIR"
    "$AGENT_HOME/.openclaw/voices"
    "$AGENT_HOME/.venvs"
)

for DIR in "${DIRS_TO_CREATE[@]}"; do
    if [[ ! -d "$DIR" ]]; then
        sudo mkdir -p "$DIR"
        info "Created: $DIR"
    fi
done

# Set ownership
sudo chown -R "$AGENT_USER:$AGENT_USER" "$OPENCLAW_DIR"
sudo chown -R "$AGENT_USER:$AGENT_USER" "$CREDENTIALS_DIR"
sudo chown -R "$AGENT_USER:$AGENT_USER" "$AGENT_HOME/.venvs"

# Set permissions
sudo chmod 700 "$CREDENTIALS_DIR"       # Only agent user can read credentials
sudo chmod 700 "$OPENCLAW_DIR"         # Protect the entire .openclaw dir
sudo chmod 755 "$WORKSPACE"            # Workspace readable

log "Workspace structure ready at $WORKSPACE"

# ============================================================================
# STEP 6: Reference Templates
# ============================================================================
header "Installing Reference Templates"

TMP_WORKDIR=$(mktemp -d)

# Determine template source (local repo checkout or remote download)
TEMPLATES_DIR="$SCRIPT_DIR/templates"
EXAMPLES_DIR="$SCRIPT_DIR/examples"

if [[ -d "$TEMPLATES_DIR" && -f "$TEMPLATES_DIR/SOUL.md" ]]; then
    info "Using local templates from repository..."
    SOUL_SRC="$TEMPLATES_DIR/SOUL.md"
    AGENTS_SRC="$TEMPLATES_DIR/AGENTS.md"
    USER_SRC="$TEMPLATES_DIR/USER.md"
    TOPOLOGY_SRC="$TEMPLATES_DIR/TOPOLOGY.md"
    EXEC_APPROVALS_SRC="$EXAMPLES_DIR/exec-approvals-example.json"
else
    info "Downloading templates from GitHub..."
    for FILE in templates/SOUL.md templates/AGENTS.md templates/USER.md templates/TOPOLOGY.md examples/exec-approvals-example.json; do
        DEST="$TMP_WORKDIR/$(basename "$FILE")"
        fetch_file "$REPO_URL/$FILE" "$DEST" || warn "Could not fetch $FILE"
    done
    SOUL_SRC="$TMP_WORKDIR/SOUL.md"
    AGENTS_SRC="$TMP_WORKDIR/AGENTS.md"
    USER_SRC="$TMP_WORKDIR/USER.md"
    TOPOLOGY_SRC="$TMP_WORKDIR/TOPOLOGY.md"
    EXEC_APPROVALS_SRC="$TMP_WORKDIR/exec-approvals-example.json"
fi

# Install templates (skip if already customized)
[[ -f "$SOUL_SRC" ]]            && copy_if_missing "$SOUL_SRC"            "$WORKSPACE/SOUL.md"
[[ -f "$AGENTS_SRC" ]]          && copy_if_missing "$AGENTS_SRC"          "$WORKSPACE/AGENTS.md"
[[ -f "$USER_SRC" ]]            && copy_if_missing "$USER_SRC"            "$WORKSPACE/USER.md"
[[ -f "$TOPOLOGY_SRC" ]]        && copy_if_missing "$TOPOLOGY_SRC"        "$WORKSPACE/TOPOLOGY.md"
[[ -f "$EXEC_APPROVALS_SRC" ]]  && copy_if_missing "$EXEC_APPROVALS_SRC"  "$OPENCLAW_DIR/exec-approvals.json" "$AGENT_USER:$AGENT_USER" "640"

# ============================================================================
# STEP 7: OpenClaw Configuration (openclaw.json)
# ============================================================================
header "Configuring OpenClaw"

ANTHROPIC_KEY=""
OPENAI_KEY=""
TELEGRAM_TOKEN=""

if [[ -f "$OPENCLAW_CONFIG" ]]; then
    warn "openclaw.json already exists — skipping. Edit manually: sudo nano $OPENCLAW_CONFIG"
else
    if $INTERACTIVE; then
        echo ""
        info "You can configure API keys now, or press Enter to skip any field."
        info "Keys will be stored with chmod 600 in $CREDENTIALS_DIR"
        echo ""
        read -rp "  Anthropic API key (claude models) [Enter to skip]: " ANTHROPIC_KEY
        read -rp "  OpenAI API key [Enter to skip]:                     " OPENAI_KEY
        read -rp "  Telegram bot token [Enter to skip]:                 " TELEGRAM_TOKEN
        read -rp "  Gateway port [$GATEWAY_PORT]:                       " USER_PORT
        [[ -n "$USER_PORT" ]] && GATEWAY_PORT="$USER_PORT"
    else
        warn "Non-interactive mode: skipping API key prompts. Configure manually later."
        warn "  Edit: $OPENCLAW_CONFIG"
        warn "  Edit: $CREDENTIALS_DIR/env"
    fi

    # Write the minimal openclaw.json config (no secrets inside)
    sudo tee "$OPENCLAW_CONFIG" > /dev/null <<ENDOFCONFIG
{
  "gateway": {
    "port": $GATEWAY_PORT,
    "bind": "loopback"
  },
  "agent": {
    "model": "anthropic/claude-opus-4-6"
  },
  "agents": {
    "defaults": {
      "workspace": "$WORKSPACE"
    }
  }
}
ENDOFCONFIG

    sudo chown "$AGENT_USER:$AGENT_USER" "$OPENCLAW_CONFIG"
    sudo chmod 600 "$OPENCLAW_CONFIG"
    log "openclaw.json created (port $GATEWAY_PORT, model: anthropic/claude-opus-4-6)."

    # Build the credentials env file (loaded by systemd)
    ENV_FILE="$CREDENTIALS_DIR/env"
    sudo touch "$ENV_FILE"
    sudo chown "$AGENT_USER:$AGENT_USER" "$ENV_FILE"
    sudo chmod 600 "$ENV_FILE"

    if [[ -n "$ANTHROPIC_KEY" ]]; then
        echo "ANTHROPIC_API_KEY=$ANTHROPIC_KEY" | sudo tee -a "$ENV_FILE" > /dev/null
        log "Anthropic API key saved to $ENV_FILE"
    fi
    if [[ -n "$OPENAI_KEY" ]]; then
        echo "OPENAI_API_KEY=$OPENAI_KEY" | sudo tee -a "$ENV_FILE" > /dev/null
        log "OpenAI API key saved to $ENV_FILE"
    fi
    if [[ -n "$TELEGRAM_TOKEN" ]]; then
        echo "TELEGRAM_BOT_TOKEN=$TELEGRAM_TOKEN" | sudo tee -a "$ENV_FILE" > /dev/null
        log "Telegram bot token saved to $ENV_FILE"
    fi
fi

# ============================================================================
# STEP 8: Piper TTS (local text-to-speech, no cloud)
# ============================================================================
header "Installing Piper TTS"

VOICE_DIR="$AGENT_HOME/.openclaw/voices"

if command -v piper &>/dev/null; then
    log "Piper already installed: $(piper --version 2>/dev/null || echo 'ok')"
else
    case "$ARCH" in
        x86_64)  PIPER_ARCH="amd64" ;;
        aarch64) PIPER_ARCH="arm64" ;;
        armv7l)  PIPER_ARCH="armv7" ;;
        *)
            warn "Architecture '$ARCH' not supported by prebuilt Piper. Skipping TTS install."
            PIPER_ARCH=""
            ;;
    esac

    if [[ -n "${PIPER_ARCH:-}" ]]; then
        PIPER_URL="https://github.com/rhasspy/piper/releases/download/${PIPER_VERSION}/piper_linux_${PIPER_ARCH}.tar.gz"
        PIPER_TMP="$TMP_WORKDIR/piper.tar.gz"
        info "Downloading Piper $PIPER_VERSION for $PIPER_ARCH..."

        if wget -q --show-progress --timeout=60 "$PIPER_URL" -O "$PIPER_TMP"; then
            tar -xzf "$PIPER_TMP" -C "$TMP_WORKDIR"
            sudo cp "$TMP_WORKDIR/piper/piper" /usr/local/bin/piper
            sudo chmod +x /usr/local/bin/piper
            log "Piper installed at /usr/local/bin/piper"

            # Download a default English voice model
            info "Downloading default English voice (en_US-lessac-high)..."
            VOICE_BASE="https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/high"
            if wget -q --show-progress --timeout=120 \
                    "$VOICE_BASE/en_US-lessac-high.onnx" \
                    -O "$TMP_WORKDIR/en_US-lessac-high.onnx"; then
                wget -q --timeout=30 \
                    "$VOICE_BASE/en_US-lessac-high.onnx.json" \
                    -O "$TMP_WORKDIR/en_US-lessac-high.onnx.json" || true
                sudo cp "$TMP_WORKDIR/en_US-lessac-high.onnx"      "$VOICE_DIR/"
                sudo cp "$TMP_WORKDIR/en_US-lessac-high.onnx.json" "$VOICE_DIR/" 2>/dev/null || true
                sudo chown -R "$AGENT_USER:$AGENT_USER" "$VOICE_DIR"
                log "Voice model installed at $VOICE_DIR/en_US-lessac-high.onnx"
            else
                warn "Could not download voice model. Download it manually:"
                warn "  $VOICE_BASE/en_US-lessac-high.onnx → $VOICE_DIR/"
            fi
        else
            warn "Could not download Piper. Skipping. Install manually from:"
            warn "  https://github.com/rhasspy/piper/releases"
        fi
    fi
fi

# ============================================================================
# STEP 9: Faster-Whisper (local speech-to-text, no cloud)
# ============================================================================
header "Installing Faster-Whisper (STT)"

WHISPER_VENV="$AGENT_HOME/.venvs/whisper"

if [[ -f "$WHISPER_VENV/bin/activate" ]]; then
    log "Whisper virtualenv already exists at $WHISPER_VENV"
else
    info "Creating Python virtualenv for Faster-Whisper..."
    sudo -u "$AGENT_USER" python3 -m venv "$WHISPER_VENV"
    info "Installing faster-whisper (this may take a few minutes)..."
    sudo -u "$AGENT_USER" "$WHISPER_VENV/bin/pip" install --quiet --upgrade pip
    sudo -u "$AGENT_USER" "$WHISPER_VENV/bin/pip" install --quiet faster-whisper
    log "faster-whisper installed in $WHISPER_VENV"
fi

# Create a whisper wrapper script
WHISPER_WRAPPER="/usr/local/bin/whisper-transcribe"
if [[ ! -f "$WHISPER_WRAPPER" ]]; then
    sudo tee "$WHISPER_WRAPPER" > /dev/null <<ENDOFSCRIPT
#!/usr/bin/env bash
# whisper-transcribe — Transcribe audio file using Faster-Whisper
# Usage: whisper-transcribe <audio_file> [model_size]
# Default model: base (auto-downloads on first use)
# Available models: tiny, base, small, medium, large-v3
set -euo pipefail
VENV="$WHISPER_VENV"
MODEL="\${2:-base}"
INPUT="\$1"
"\$VENV/bin/python3" - "\$INPUT" "\$MODEL" <<'PYEOF'
import sys
from faster_whisper import WhisperModel
audio_file, model_size = sys.argv[1], sys.argv[2]
model = WhisperModel(model_size, device="cpu", compute_type="int8")
segments, _ = model.transcribe(audio_file)
for segment in segments:
    print(segment.text.strip())
PYEOF
ENDOFSCRIPT
    sudo chmod +x "$WHISPER_WRAPPER"
    log "Created wrapper: $WHISPER_WRAPPER"
fi

# ============================================================================
# STEP 10: Ollama (local LLM runner)
# ============================================================================
header "Installing Ollama (Local LLM)"

if command -v ollama &>/dev/null; then
    log "Ollama already installed: $(ollama --version 2>/dev/null || echo 'ok')"
else
    info "Installing Ollama..."
    curl -fsSL https://ollama.com/install.sh | sh
    log "Ollama installed."
fi

# ============================================================================
# STEP 11: Helper Scripts
# ============================================================================
header "Creating Helper Scripts"

# tts.sh — Piper TTS wrapper
sudo tee /usr/local/bin/tts.sh > /dev/null <<'ENDOFSCRIPT'
#!/usr/bin/env bash
# tts.sh — Convert text to MP3 using local Piper TTS
# Usage: tts.sh "Text to speak" [output_file.mp3]
# Returns: path to the generated MP3
set -euo pipefail
VOICE_DIR="$HOME/.openclaw/voices"
MODEL="${PIPER_MODEL:-$VOICE_DIR/en_US-lessac-high.onnx}"
INPUT="${1:-}"
OUTPUT="${2:-}"
if [[ -z "$INPUT" ]]; then
    echo "Usage: tts.sh <text> [output.mp3]" >&2
    exit 1
fi
TMP_WAV=$(mktemp /tmp/tts_XXXXXX.wav)
trap 'rm -f "$TMP_WAV"' EXIT
if [[ -z "$OUTPUT" ]]; then
    OUTPUT=$(mktemp /tmp/tts_XXXXXX.mp3)
fi
echo "$INPUT" | piper --model "$MODEL" --output_file "$TMP_WAV"
lame -q 5 "$TMP_WAV" "$OUTPUT" 2>/dev/null
echo "$OUTPUT"
ENDOFSCRIPT
sudo chmod +x /usr/local/bin/tts.sh
log "Created /usr/local/bin/tts.sh"

# safe_curl.sh — Egress-controlled curl wrapper
sudo tee /usr/local/bin/safe_curl.sh > /dev/null <<'ENDOFSCRIPT'
#!/usr/bin/env bash
# safe_curl.sh — Egress-controlled curl wrapper
# Blocks HTTP requests to domains not in the allowlist.
# To add a domain: edit the ALLOWED_DOMAINS array below.
set -euo pipefail

ALLOWED_DOMAINS=(
    "api.anthropic.com"
    "api.openai.com"
    "api.telegram.org"
    "huggingface.co"
    "ollama.com"
    "pypi.org"
    "files.pythonhosted.org"
    "deb.nodesource.com"
    "registry.npmjs.org"
    "api.github.com"
    "github.com"
    "raw.githubusercontent.com"
    "openweathermap.org"
    "wttr.in"
)

# Extract URL from arguments
URL=""
for arg in "$@"; do
    if [[ "$arg" =~ ^https?:// ]]; then
        URL="$arg"
        break
    fi
done

# If no URL found, pass through (pipes, local calls, etc.)
if [[ -z "$URL" ]]; then
    exec curl "$@"
fi

# Extract domain
DOMAIN=$(echo "$URL" | sed -E 's|https?://([^/:]+).*|\1|')

# Check allowlist
for allowed in "${ALLOWED_DOMAINS[@]}"; do
    if [[ "$DOMAIN" == "$allowed" || "$DOMAIN" == *".$allowed" ]]; then
        exec curl "$@"
    fi
done

echo "[safe_curl.sh] BLOCKED: '$DOMAIN' is not in the egress allowlist." >&2
echo "To allow it, add '$DOMAIN' to ALLOWED_DOMAINS in /usr/local/bin/safe_curl.sh" >&2
exit 1
ENDOFSCRIPT
sudo chmod +x /usr/local/bin/safe_curl.sh
log "Created /usr/local/bin/safe_curl.sh"

# openclaw-status — Quick status check
sudo tee /usr/local/bin/openclaw-status > /dev/null <<ENDOFSCRIPT
#!/usr/bin/env bash
# openclaw-status — Show OpenClaw gateway status
echo "=== OpenClaw Gateway ==="
systemctl status openclaw-gateway --no-pager -l 2>/dev/null || echo "(service not found)"
echo ""
echo "=== Gateway Health ==="
curl -sf "http://127.0.0.1:${GATEWAY_PORT}/health" 2>/dev/null | python3 -m json.tool 2>/dev/null || echo "(gateway not responding)"
echo ""
echo "=== Recent Logs ==="
journalctl -u openclaw-gateway -n 20 --no-pager 2>/dev/null || \
    tail -n 20 "${LOG_DIR}/gateway.log" 2>/dev/null || echo "(no logs found)"
ENDOFSCRIPT
sudo chmod +x /usr/local/bin/openclaw-status
log "Created /usr/local/bin/openclaw-status"

# ============================================================================
# STEP 12: systemd Service
# ============================================================================
header "Setting Up systemd Gateway Service"

SERVICE_FILE="/etc/systemd/system/openclaw-gateway.service"

if [[ -f "$SERVICE_FILE" ]]; then
    log "systemd service already exists at $SERVICE_FILE"
else
    info "Creating systemd service: openclaw-gateway..."
    sudo tee "$SERVICE_FILE" > /dev/null <<ENDOFSERVICE
[Unit]
Description=OpenClaw Personal AI Assistant Gateway
Documentation=https://docs.openclaw.ai/gateway
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=120
StartLimitBurst=5

[Service]
Type=simple
User=$AGENT_USER
Group=$AGENT_USER
WorkingDirectory=$AGENT_HOME

ExecStart=$OPENCLAW_BIN gateway --port $GATEWAY_PORT
Restart=on-failure
RestartSec=15
TimeoutStopSec=30

# Output
StandardOutput=append:$LOG_DIR/gateway.log
StandardError=append:$LOG_DIR/gateway-error.log

# Environment
Environment=HOME=$AGENT_HOME
Environment=NODE_ENV=production
EnvironmentFile=-$CREDENTIALS_DIR/env

# Security hardening
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=$AGENT_HOME
ProtectHome=no
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictNamespaces=yes
RestrictRealtime=yes
SystemCallFilter=@system-service

[Install]
WantedBy=multi-user.target
ENDOFSERVICE

    sudo systemctl daemon-reload
    sudo systemctl enable openclaw-gateway
    log "Service created and enabled: openclaw-gateway"
fi

# Ensure credentials env file exists (even if empty)
ENV_FILE="$CREDENTIALS_DIR/env"
if [[ ! -f "$ENV_FILE" ]]; then
    sudo touch "$ENV_FILE"
    sudo chown "$AGENT_USER:$AGENT_USER" "$ENV_FILE"
    sudo chmod 600 "$ENV_FILE"
    log "Created empty credentials env file: $ENV_FILE"
fi

# ============================================================================
# STEP 13: Security Hardening
# ============================================================================
header "Applying Security Hardening"

info "Setting file permissions..."

# Secure the entire .openclaw directory tree
sudo chown -R "$AGENT_USER:$AGENT_USER" "$OPENCLAW_DIR"
sudo chmod 700 "$OPENCLAW_DIR"
sudo chmod 700 "$CREDENTIALS_DIR"
sudo chmod 600 "$ENV_FILE"
[[ -f "$OPENCLAW_CONFIG" ]] && sudo chmod 600 "$OPENCLAW_CONFIG"
[[ -f "$OPENCLAW_DIR/exec-approvals.json" ]] && sudo chmod 640 "$OPENCLAW_DIR/exec-approvals.json"

# Protect log directory
sudo chmod 750 "$LOG_DIR"

info "Generating SHA256 checksums for critical files..."
CHECKSUM_DIR="$WORKSPACE/checksums"
sudo mkdir -p "$CHECKSUM_DIR"
for CRITICAL_FILE in \
    "$WORKSPACE/SOUL.md" \
    "$WORKSPACE/AGENTS.md" \
    "$OPENCLAW_CONFIG" \
    "$OPENCLAW_DIR/exec-approvals.json"; do
    if [[ -f "$CRITICAL_FILE" ]]; then
        BASENAME=$(basename "$CRITICAL_FILE")
        sudo sh -c "sha256sum '$CRITICAL_FILE' > '$CHECKSUM_DIR/${BASENAME}.sha256'"
        sudo chown "$AGENT_USER:$AGENT_USER" "$CHECKSUM_DIR/${BASENAME}.sha256"
        info "  Checksum saved: $CHECKSUM_DIR/${BASENAME}.sha256"
    fi
done
sudo chown -R "$AGENT_USER:$AGENT_USER" "$CHECKSUM_DIR"
log "Security hardening applied."

# ============================================================================
# STEP 14: Verify Installation
# ============================================================================
header "Verifying Installation"

check_cmd() {
    local cmd="$1"
    local label="${2:-$cmd}"
    if command -v "$cmd" &>/dev/null; then
        log "$label: $(command -v "$cmd")"
    else
        warn "$label: NOT FOUND"
    fi
}

check_cmd node    "Node.js"
check_cmd npm     "npm"
check_cmd openclaw "OpenClaw"
check_cmd ffmpeg  "ffmpeg"
check_cmd jq      "jq"
check_cmd lame    "lame"
check_cmd sox     "SoX"
check_cmd pandoc  "pandoc"
check_cmd piper   "Piper TTS"
check_cmd ollama  "Ollama"
check_cmd python3 "Python 3"

log "Agent user '$AGENT_USER': UID $(id -u "$AGENT_USER" 2>/dev/null || echo '?')"
log "Workspace: $WORKSPACE"
[[ -d "$WORKSPACE/memory" ]] && log "Memory dir: $WORKSPACE/memory"
[[ -f "$OPENCLAW_CONFIG" ]] && log "Config:    $OPENCLAW_CONFIG"
[[ -f "$OPENCLAW_DIR/exec-approvals.json" ]] && log "Exec approvals: $OPENCLAW_DIR/exec-approvals.json"

# Check Whisper venv
[[ -f "$AGENT_HOME/.venvs/whisper/bin/activate" ]] && \
    log "Whisper venv: $AGENT_HOME/.venvs/whisper"

# ============================================================================
# STEP 15: Start the Gateway
# ============================================================================
header "Starting OpenClaw Gateway"

if [[ -f "$SERVICE_FILE" ]]; then
    if sudo systemctl is-active --quiet openclaw-gateway; then
        log "Gateway service is already running."
        sudo systemctl restart openclaw-gateway
        log "Service restarted."
    else
        info "Starting openclaw-gateway service..."
        sudo systemctl start openclaw-gateway || warn "Service failed to start. Check logs: sudo journalctl -u openclaw-gateway -n 50"
        sleep 3
        if sudo systemctl is-active --quiet openclaw-gateway; then
            log "Gateway is running!"
        else
            warn "Gateway may not have started correctly."
            warn "Run: sudo journalctl -u openclaw-gateway -n 30 --no-pager"
        fi
    fi
fi

# ============================================================================
# DONE — Summary
# ============================================================================
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${GREEN}║   OpenClaw Installation Complete! 🦞              ║${RESET}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "${BOLD}Installed components:${RESET}"
echo "  • OpenClaw:         $(openclaw --version 2>/dev/null || echo 'installed')"
echo "  • Node.js:          $(node --version)"
echo "  • Ollama:           $(ollama --version 2>/dev/null || echo 'installed')"
echo "  • Piper TTS:        $(command -v piper &>/dev/null && echo 'installed' || echo 'not installed')"
echo "  • Faster-Whisper:   $([[ -f "$AGENT_HOME/.venvs/whisper/bin/activate" ]] && echo 'installed' || echo 'not installed')"
echo "  • ffmpeg / lame:    $(command -v ffmpeg &>/dev/null && echo 'installed' || echo 'missing')"
echo ""
echo -e "${BOLD}System configuration:${RESET}"
echo "  • Agent user:       $AGENT_USER (no sudo, isolated)"
echo "  • Workspace:        $WORKSPACE"
echo "  • Config:           $OPENCLAW_CONFIG (chmod 600)"
echo "  • Credentials:      $CREDENTIALS_DIR (chmod 700)"
echo "  • Logs:             $LOG_DIR"
echo "  • Gateway port:     $GATEWAY_PORT (loopback only)"
echo "  • systemd service:  openclaw-gateway"
echo ""
echo -e "${BOLD}${YELLOW}IMPORTANT — What to do next:${RESET}"
echo ""
echo "  1. Customize your agent identity:"
echo "     sudo nano $WORKSPACE/SOUL.md"
echo "     (Replace [Agent Name] with a name you like)"
echo ""
echo "  2. Add your personal context:"
echo "     sudo nano $WORKSPACE/USER.md"
echo ""
echo "  3. Add API keys (if you skipped the prompts):"
echo "     sudo nano $CREDENTIALS_DIR/env"
echo "     (Add lines like: ANTHROPIC_API_KEY=sk-ant-...)"
echo "     sudo systemctl restart openclaw-gateway"
echo ""
echo "  4. Connect a messaging channel (Telegram recommended):"
echo "     sudo -u $AGENT_USER openclaw onboard"
echo ""
echo "  5. Review the exec approvals allowlist:"
echo "     sudo nano $OPENCLAW_DIR/exec-approvals.json"
echo ""
echo "  6. Check gateway health:"
echo "     openclaw-status"
echo "     sudo -u $AGENT_USER openclaw doctor"
echo ""
echo "  7. Check service status:"
echo "     sudo systemctl status openclaw-gateway"
echo "     sudo journalctl -u openclaw-gateway -f"
echo ""
echo -e "${BOLD}Useful commands:${RESET}"
echo "  openclaw-status                     — Quick health check"
echo "  sudo -u $AGENT_USER openclaw doctor    — Full diagnostics"
echo "  sudo systemctl restart openclaw-gateway — Restart gateway"
echo "  tts.sh \"Hello world\"               — Test TTS"
echo "  whisper-transcribe audio.ogg        — Test STT"
echo ""
echo -e "${BOLD}Documentation:${RESET}  https://docs.openclaw.ai"
echo -e "${BOLD}Reference repo:${RESET} https://github.com/condestable2000/openclaw-reference-setup"
echo ""
