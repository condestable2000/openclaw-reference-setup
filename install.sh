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

DIM='\033[2m'

log()    { echo -e " ${GREEN}✓${RESET} $*"; }
info()   { echo -e "  ${CYAN}→${RESET} $*"; }
warn()   { echo -e " ${YELLOW}!${RESET} $*"; }
error()  { echo -e "\n${RED}  ✗ ERROR: $*${RESET}\n" >&2; exit 1; }
header() {
    echo ""
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════${RESET}"
    echo -e "${BOLD}${CYAN}  $*${RESET}"
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════${RESET}"
}

TOTAL_STEPS=15
step() {
    echo ""
    echo -e "${BOLD}${CYAN}[$1/$TOTAL_STEPS]${RESET} ${BOLD}$2${RESET}\n"
}

# ask <prompt> <varname> [default]
# Reads from /dev/tty so it works with curl | bash
ask() {
    local prompt="$1" varname="$2" default="${3:-}"
    local display_default=""
    [[ -n "$default" ]] && display_default=" ${DIM}[$default]${RESET}"
    echo -en "  ${BOLD}${prompt}${RESET}${display_default}: " >/dev/tty
    local val
    read -r val </dev/tty || val=""
    [[ -z "$val" ]] && val="$default"
    printf -v "$varname" '%s' "$val"
}

# ask_secret <prompt> <varname>  — hides input
ask_secret() {
    local prompt="$1" varname="$2"
    echo -en "  ${BOLD}${prompt}${RESET}: " >/dev/tty
    local val
    read -rs val </dev/tty || val=""
    echo >/dev/tty
    printf -v "$varname" '%s' "$val"
}

# confirm <prompt>  — returns 0 for yes, 1 for no
confirm() {
    echo -en "  ${BOLD}$1${RESET} ${DIM}[s/N]${RESET}: " >/dev/tty
    local ans
    read -r ans </dev/tty || ans=""
    [[ "$ans" =~ ^[sS]$ ]]
}

# separator line
sep() { echo -e "  ${DIM}──────────────────────────────────────────────────${RESET}"; }

# ---------------------------------------------------------------------------
# Configuration defaults (override via environment variables)
# ---------------------------------------------------------------------------
AGENT_USER="${AGENT_USER:-agent}"
GATEWAY_PORT="${GATEWAY_PORT:-18789}"
NODE_MAJOR="${NODE_MAJOR:-24}"
PIPER_VERSION="${PIPER_VERSION:-2023.11.14-2}"
REPO_URL="https://raw.githubusercontent.com/condestable2000/openclaw-reference-setup/main"

# Detect if a real terminal is available for user input
# Works correctly with both 'curl | bash' and direct execution
INTERACTIVE=false
[[ -e /dev/tty ]] && INTERACTIVE=true

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

# ── Banner ──────────────────────────────────────────────────────────────────
clear 2>/dev/null || true
echo ""
echo -e "${BOLD}"
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║                                                ║"
echo "  ║   🦞  OpenClaw Installer                       ║"
echo "  ║        Referencia de producción para Ubuntu    ║"
echo "  ║                                                ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${RESET}"
echo -e "  Instala y configura OpenClaw con seguridad en minutos."
echo -e "  ${DIM}https://github.com/condestable2000/openclaw-reference-setup${RESET}"
echo ""

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
step 0 "Verificando el sistema"

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
# STEP 7: Wizard de configuración mínima
# ============================================================================
header "Configuración de tu agente"

# Variables que recoge el wizard
WIZARD_AGENT_NAME=""
WIZARD_PROVIDER=""        # anthropic | openai
WIZARD_API_KEY=""
WIZARD_MODEL=""
WIZARD_CHANNEL=""         # telegram | discord | whatsapp | none
WIZARD_CHANNEL_TOKEN=""
WIZARD_CHANNEL_CONFIG=""
ANTHROPIC_KEY=""
OPENAI_KEY=""
TELEGRAM_TOKEN=""

if [[ -f "$OPENCLAW_CONFIG" ]]; then
    warn "openclaw.json ya existe — se mantiene la configuración existente."
    info "Para reconfigurar: sudo -u $AGENT_USER openclaw onboard"
else
    if $INTERACTIVE; then
        echo ""
        echo -e "  Responde estas preguntas para configurar lo mínimo necesario."
        echo -e "  ${DIM}Todos los valores se pueden cambiar después.${RESET}"
        echo ""

        # ── [1/4] Nombre del agente ────────────────────────────────────────
        echo -e "  ${BOLD}[1/4] Nombre de tu agente${RESET}"
        sep
        echo -e "  ${DIM}El nombre con el que se presentará tu IA.${RESET}"
        echo -e "  ${DIM}Ejemplos: Atlas, Jarvis, Luna, Max${RESET}"
        echo ""
        ask "Nombre del agente" WIZARD_AGENT_NAME "Atlas"
        echo ""

        # ── [2/4] Proveedor de IA ──────────────────────────────────────────
        echo -e "  ${BOLD}[2/4] Proveedor de IA${RESET}"
        sep
        echo -e "  ${DIM}Qué modelo usará tu agente para pensar.${RESET}"
        echo ""
        echo -e "    ${BOLD}1)${RESET} Anthropic Claude  ${DIM}(recomendado — sk-ant-...)${RESET}"
        echo -e "    ${BOLD}2)${RESET} OpenAI GPT         ${DIM}(sk-...)${RESET}"
        echo ""
        ask "Elige proveedor" _PROVIDER_CHOICE "1"
        echo ""

        if [[ "$_PROVIDER_CHOICE" == "2" ]]; then
            WIZARD_PROVIDER="openai"
            WIZARD_MODEL="openai/gpt-4o"
            echo -e "  ${DIM}Obtén tu clave en: https://platform.openai.com/api-keys${RESET}"
            echo ""
            while true; do
                ask_secret "API Key de OpenAI" WIZARD_API_KEY
                if [[ "${WIZARD_API_KEY:0:3}" == "sk-" && ${#WIZARD_API_KEY} -gt 20 ]]; then
                    log "API key de OpenAI aceptada."
                    break
                elif [[ -z "$WIZARD_API_KEY" ]]; then
                    warn "Sin API key — podrás añadirla después en $CREDENTIALS_DIR/env"
                    break
                else
                    warn "La clave no parece válida (debe empezar por sk-). Inténtalo de nuevo o deja vacío."
                fi
            done
            OPENAI_KEY="$WIZARD_API_KEY"
        else
            WIZARD_PROVIDER="anthropic"
            WIZARD_MODEL="anthropic/claude-opus-4-6"
            echo -e "  ${DIM}Obtén tu clave en: https://console.anthropic.com/settings/keys${RESET}"
            echo ""
            while true; do
                ask_secret "API Key de Anthropic" WIZARD_API_KEY
                if [[ "${WIZARD_API_KEY:0:7}" == "sk-ant-" && ${#WIZARD_API_KEY} -gt 20 ]]; then
                    log "API key de Anthropic aceptada."
                    break
                elif [[ -z "$WIZARD_API_KEY" ]]; then
                    warn "Sin API key — podrás añadirla después en $CREDENTIALS_DIR/env"
                    break
                else
                    warn "La clave no parece válida (debe empezar por sk-ant-). Inténtalo de nuevo o deja vacío."
                fi
            done
            ANTHROPIC_KEY="$WIZARD_API_KEY"
        fi
        echo ""

        # ── [3/4] Canal de mensajería ──────────────────────────────────────
        echo -e "  ${BOLD}[3/4] Canal de mensajería${RESET}"
        sep
        echo -e "  ${DIM}Cómo te comunicarás con tu agente.${RESET}"
        echo ""
        echo -e "    ${BOLD}1)${RESET} Telegram   ${DIM}(recomendado — @BotFather)${RESET}"
        echo -e "    ${BOLD}2)${RESET} Discord    ${DIM}(discord.com/developers)${RESET}"
        echo -e "    ${BOLD}3)${RESET} WhatsApp   ${DIM}(configuración avanzada)${RESET}"
        echo -e "    ${BOLD}4)${RESET} Configurar más tarde"
        echo ""
        ask "Elige canal" _CHANNEL_CHOICE "1"
        echo ""

        case "$_CHANNEL_CHOICE" in
            2)
                WIZARD_CHANNEL="discord"
                echo -e "  ${DIM}Token del bot en: https://discord.com/developers/applications${RESET}"
                echo ""
                ask_secret "Token de bot de Discord" WIZARD_CHANNEL_TOKEN
                WIZARD_CHANNEL_CONFIG='"discord": { "token": "'"$WIZARD_CHANNEL_TOKEN"'" }'
                ;;
            3)
                WIZARD_CHANNEL="whatsapp"
                warn "WhatsApp requiere enlazar el dispositivo con QR después de instalar."
                info "Ejecuta cuando quieras: sudo -u $AGENT_USER openclaw channels login"
                WIZARD_CHANNEL_TOKEN=""
                ;;
            4)
                WIZARD_CHANNEL="none"
                warn "Sin canal — usa WebChat local o configura más tarde con: sudo -u $AGENT_USER openclaw onboard"
                WIZARD_CHANNEL_TOKEN=""
                ;;
            *)
                WIZARD_CHANNEL="telegram"
                echo -e "  ${DIM}Crea un bot con @BotFather en Telegram y copia el token.${RESET}"
                echo -e "  ${DIM}El token tiene formato:  123456789:ABCdefGHIjklMNOpqrSTUvwxyz${RESET}"
                echo ""
                while true; do
                    ask_secret "Token de bot de Telegram" WIZARD_CHANNEL_TOKEN
                    if [[ "$WIZARD_CHANNEL_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]{30,}$ ]]; then
                        log "Token de Telegram aceptado."
                        break
                    elif [[ -z "$WIZARD_CHANNEL_TOKEN" ]]; then
                        warn "Sin token — podrás añadirlo después en $CREDENTIALS_DIR/env"
                        break
                    else
                        warn "El token no parece válido. Inténtalo de nuevo o deja vacío."
                    fi
                done
                TELEGRAM_TOKEN="$WIZARD_CHANNEL_TOKEN"
                WIZARD_CHANNEL_CONFIG='"telegram": { "botToken": "'"$WIZARD_CHANNEL_TOKEN"'" }'
                ;;
        esac
        echo ""

        # ── [4/4] Puerto del gateway ───────────────────────────────────────
        echo -e "  ${BOLD}[4/4] Puerto del gateway${RESET}"
        sep
        echo -e "  ${DIM}Puerto local donde escuchará el gateway (solo loopback).${RESET}"
        echo ""
        ask "Puerto" USER_PORT "$GATEWAY_PORT"
        [[ "$USER_PORT" =~ ^[0-9]+$ ]] && GATEWAY_PORT="$USER_PORT"
        echo ""

        # ── Resumen y confirmación ─────────────────────────────────────────
        CHANNEL_DISPLAY="${WIZARD_CHANNEL:-ninguno}"
        [[ "$CHANNEL_DISPLAY" == "none" ]] && CHANNEL_DISPLAY="configurar más tarde"
        KEY_DISPLAY="${DIM}(no configurada)${RESET}"
        [[ -n "$WIZARD_API_KEY" ]] && KEY_DISPLAY="✓ configurada"

        echo -e "  ${BOLD}Resumen de configuración:${RESET}"
        echo "  ┌─────────────────────────────────────────────────────┐"
        printf  "  │  %-10s  %-38s│\n" "Agente:"    "$WIZARD_AGENT_NAME"
        printf  "  │  %-10s  %-38s│\n" "Proveedor:" "${WIZARD_PROVIDER:-anthropic} (${WIZARD_MODEL:-claude-opus-4-6})"
        echo -e "  │  API key:    $KEY_DISPLAY"
        printf  "  │  %-10s  %-38s│\n" "Canal:"     "$CHANNEL_DISPLAY"
        printf  "  │  %-10s  %-38s│\n" "Puerto:"    "$GATEWAY_PORT"
        echo    "  └─────────────────────────────────────────────────────┘"
        echo ""

        if ! confirm "¿Guardar esta configuración?"; then
            warn "Configuración cancelada. Se usarán los valores por defecto."
            WIZARD_AGENT_NAME="Atlas"
            WIZARD_PROVIDER="anthropic"
            WIZARD_MODEL="anthropic/claude-opus-4-6"
            ANTHROPIC_KEY=""
            OPENAI_KEY=""
            TELEGRAM_TOKEN=""
        fi
    else
        warn "Modo no interactivo (curl | bash sin terminal): omitiendo wizard."
        warn "Configura manualmente después:"
        warn "  sudo nano $CREDENTIALS_DIR/env"
        WIZARD_AGENT_NAME="Atlas"
        WIZARD_PROVIDER="anthropic"
        WIZARD_MODEL="anthropic/claude-opus-4-6"
    fi

    # ── Aplicar nombre al SOUL.md ──────────────────────────────────────────
    if [[ -n "$WIZARD_AGENT_NAME" && -f "$WORKSPACE/SOUL.md" ]]; then
        sudo sed -i "s/\\[Agent Name\\]/$WIZARD_AGENT_NAME/g" "$WORKSPACE/SOUL.md"
        log "Nombre del agente aplicado a SOUL.md: $WIZARD_AGENT_NAME"
    fi

    # ── Modelo en openclaw.json ────────────────────────────────────────────
    FINAL_MODEL="${WIZARD_MODEL:-anthropic/claude-opus-4-6}"

    # ── Construir sección channels para openclaw.json ─────────────────────
    CHANNELS_BLOCK=""
    if [[ -n "${WIZARD_CHANNEL_CONFIG:-}" ]]; then
        CHANNELS_BLOCK=",
  \"channels\": {
    ${WIZARD_CHANNEL_CONFIG}
  }"
    fi

    # Write the minimal openclaw.json config (no secrets inside)
    sudo tee "$OPENCLAW_CONFIG" > /dev/null <<ENDOFCONFIG
{
  "gateway": {
    "port": $GATEWAY_PORT,
    "bind": "loopback"
  },
  "agent": {
    "model": "$FINAL_MODEL"
  },
  "agents": {
    "defaults": {
      "workspace": "$WORKSPACE"
    }
  }$CHANNELS_BLOCK
}
ENDOFCONFIG

    sudo chown "$AGENT_USER:$AGENT_USER" "$OPENCLAW_CONFIG"
    sudo chmod 600 "$OPENCLAW_CONFIG"
    log "openclaw.json creado (puerto $GATEWAY_PORT, modelo: $FINAL_MODEL)."

    # ── Guardar secretos en el fichero de entorno (cargado por systemd) ───
    ENV_FILE="$CREDENTIALS_DIR/env"
    sudo touch "$ENV_FILE"
    sudo chown "$AGENT_USER:$AGENT_USER" "$ENV_FILE"
    sudo chmod 600 "$ENV_FILE"

    if [[ -n "$ANTHROPIC_KEY" ]]; then
        echo "ANTHROPIC_API_KEY=$ANTHROPIC_KEY" | sudo tee -a "$ENV_FILE" > /dev/null
        log "API key de Anthropic guardada en $ENV_FILE"
    fi
    if [[ -n "$OPENAI_KEY" ]]; then
        echo "OPENAI_API_KEY=$OPENAI_KEY" | sudo tee -a "$ENV_FILE" > /dev/null
        log "API key de OpenAI guardada en $ENV_FILE"
    fi
    if [[ -n "$TELEGRAM_TOKEN" ]]; then
        echo "TELEGRAM_BOT_TOKEN=$TELEGRAM_TOKEN" | sudo tee -a "$ENV_FILE" > /dev/null
        log "Token de Telegram guardado en $ENV_FILE"
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
StartLimitIntervalSec=300
StartLimitBurst=3

[Service]
Type=simple
User=$AGENT_USER
Group=$AGENT_USER
WorkingDirectory=$AGENT_HOME

# Abort start if no API key has been configured yet
ExecStartPre=/bin/bash -c 'grep -qE "(ANTHROPIC_API_KEY|OPENAI_API_KEY)=.+" $CREDENTIALS_DIR/env || { echo "ERROR: No API key found in $CREDENTIALS_DIR/env — add ANTHROPIC_API_KEY or OPENAI_API_KEY and run: sudo systemctl start openclaw-gateway"; exit 1; }'

ExecStart=$OPENCLAW_BIN gateway --port $GATEWAY_PORT
Restart=on-failure
RestartSec=30
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
# STEP 15: Start the Gateway (only if API key is present)
# ============================================================================
header "Starting OpenClaw Gateway"

# Determine if there is at least one API key configured
ENV_FILE="$CREDENTIALS_DIR/env"
HAS_KEY=false
if [[ -f "$ENV_FILE" ]] && sudo grep -qE '(ANTHROPIC_API_KEY|OPENAI_API_KEY)=.+' "$ENV_FILE" 2>/dev/null; then
    HAS_KEY=true
fi

if [[ -f "$SERVICE_FILE" ]]; then
    if $HAS_KEY; then
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
                warn "Gateway did not start correctly."
                warn "Check: sudo journalctl -u openclaw-gateway -n 30 --no-pager"
            fi
        fi
    else
        warn "Gateway service NOT started — no API key configured."
        warn "Service is installed and enabled but will not run until you add a key."
        info "See the 'What to do next' section below."
    fi
fi

# ============================================================================
# DONE — Resumen final
# ============================================================================

# Determinar estado de API key y canal
KEY_STATUS="no configurada"
KEY_OK=false
if sudo grep -qE '(ANTHROPIC_API_KEY|OPENAI_API_KEY)=.+' "$CREDENTIALS_DIR/env" 2>/dev/null; then
    KEY_STATUS="${GREEN}✓ configurada${RESET}"
    KEY_OK=true
fi

CHANNEL_SUMMARY="${WIZARD_CHANNEL:-ninguno}"
[[ "$CHANNEL_SUMMARY" == "none" || -z "$CHANNEL_SUMMARY" ]] && CHANNEL_SUMMARY="configurar más tarde"

GW_STATUS="detenido (falta API key)"
if $KEY_OK && sudo systemctl is-active --quiet openclaw-gateway 2>/dev/null; then
    GW_STATUS="${GREEN}✓ en ejecución${RESET} (puerto $GATEWAY_PORT)"
elif $KEY_OK; then
    GW_STATUS="${YELLOW}instalado, no iniciado${RESET}"
fi

echo ""
echo -e "${BOLD}${GREEN}"
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║                                                ║"
echo "  ║   🦞  ¡Instalación completada!                 ║"
echo "  ║                                                ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${RESET}"

echo -e "  ${BOLD}Componentes instalados:${RESET}"
echo "  ────────────────────────────────────────────────"
printf  "    %-20s %s\n" "OpenClaw:"      "$(openclaw --version 2>/dev/null || echo 'instalado')"
printf  "    %-20s %s\n" "Node.js:"       "$(node --version)"
printf  "    %-20s %s\n" "Ollama:"        "$(ollama --version 2>/dev/null | head -1 || echo 'instalado')"
printf  "    %-20s %s\n" "Piper TTS:"     "$(command -v piper &>/dev/null && echo 'instalado' || echo 'no instalado')"
printf  "    %-20s %s\n" "Faster-Whisper:" "$([[ -f "$AGENT_HOME/.venvs/whisper/bin/activate" ]] && echo 'instalado' || echo 'no instalado')"
printf  "    %-20s %s\n" "ffmpeg / lame:" "$(command -v ffmpeg &>/dev/null && echo 'instalado' || echo 'error')"
echo ""
echo -e "  ${BOLD}Configuración del sistema:${RESET}"
echo "  ────────────────────────────────────────────────"
printf  "    %-20s %s\n" "Usuario agente:" "$AGENT_USER (sin sudo, aislado)"
printf  "    %-20s %s\n" "Workspace:"     "$WORKSPACE"
printf  "    %-20s %s\n" "Credenciales:"  "$CREDENTIALS_DIR (chmod 700)"
printf  "    %-20s %s\n" "Logs:"          "$LOG_DIR"
printf  "    %-20s %s\n" "Canal:"         "$CHANNEL_SUMMARY"
echo -e "    $(printf '%-20s' 'API key:')      $KEY_STATUS"
echo -e "    $(printf '%-20s' 'Gateway:')      $GW_STATUS"
echo ""

if ! $KEY_OK; then
    echo -e "  ${RED}${BOLD}╔════════════════════════════════════════════════════╗${RESET}"
    echo -e "  ${RED}${BOLD}║  ★  ACCIÓN REQUERIDA — el gateway no puede arrancar  ║${RESET}"
    echo -e "  ${RED}${BOLD}╚════════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo -e "  Añade tu API key y arranca el servicio:"
    echo ""
    echo -e "    ${CYAN}sudo nano $CREDENTIALS_DIR/env${RESET}"
    echo ""
    echo -e "    ${DIM}# Añade UNA de estas líneas:${RESET}"
    echo -e "    ${DIM}ANTHROPIC_API_KEY=sk-ant-...${RESET}"
    echo -e "    ${DIM}OPENAI_API_KEY=sk-...${RESET}"
    echo ""
    echo -e "    ${CYAN}sudo systemctl start openclaw-gateway${RESET}"
    echo ""
fi

echo -e "  ${BOLD}Próximos pasos:${RESET}"
echo "  ────────────────────────────────────────────────"
echo ""
echo -e "    ${BOLD}1.${RESET} Personaliza la identidad de tu agente:"
echo -e "       ${CYAN}sudo nano $WORKSPACE/SOUL.md${RESET}"
echo ""
echo -e "    ${BOLD}2.${RESET} Añade tu contexto personal:"
echo -e "       ${CYAN}sudo nano $WORKSPACE/USER.md${RESET}"
echo ""
echo -e "    ${BOLD}3.${RESET} Wizard nativo (canal, modelo, avanzado):"
echo -e "       ${CYAN}sudo -u $AGENT_USER openclaw onboard${RESET}"
echo ""
echo -e "    ${BOLD}4.${RESET} Comprueba el estado del gateway:"
echo -e "       ${CYAN}openclaw-status${RESET}"
echo -e "       ${CYAN}sudo journalctl -u openclaw-gateway -f${RESET}"
echo ""
echo -e "  ${BOLD}Comandos útiles:${RESET}"
echo "  ────────────────────────────────────────────────"
echo -e "    ${CYAN}openclaw-status${RESET}                          Ver estado"
echo -e "    ${CYAN}sudo systemctl restart openclaw-gateway${RESET}  Reiniciar"
echo -e "    ${CYAN}sudo -u $AGENT_USER openclaw doctor${RESET}       Diagnóstico completo"
echo -e "    ${CYAN}tts.sh \"Hola mundo\"${RESET}                     Test TTS"
echo ""
echo -e "  ${BOLD}Documentación:${RESET}   https://docs.openclaw.ai"
echo -e "  ${BOLD}Repositorio:${RESET}     https://github.com/condestable2000/openclaw-reference-setup"
echo ""
