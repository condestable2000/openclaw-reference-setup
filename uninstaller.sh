#!/usr/bin/env bash
# =============================================================================
# uninstaller.sh — Desinstalador de OpenClaw para Ubuntu
# =============================================================================
#
# Uso:
#   chmod +x uninstaller.sh && ./uninstaller.sh
#
#   O directamente desde GitHub:
#   curl -fsSL https://raw.githubusercontent.com/condestable2000/openclaw-reference-setup/main/uninstaller.sh | bash
#
# Qué hace este script:
#   1. Para y elimina el servicio systemd openclaw-gateway
#   2. Elimina el usuario 'agent' y su directorio home completo
#   3. Desinstala el paquete npm openclaw
#   4. Elimina los scripts de ayuda (/usr/local/bin/tts.sh, etc.)
#   5. Elimina Piper TTS (/usr/local/bin/piper)
#   6. Elimina whisper-transcribe (/usr/local/bin/whisper-transcribe)
#   7. Desinstala Ollama (opcional)
#   8. Desinstala Node.js (opcional)
#
# Requisitos:
#   - Ubuntu 22.04+
#   - Usuario con acceso sudo (NO ejecutar como root)
#
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Colores y helpers de salida
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

TOTAL_STEPS=8
step() {
    echo ""
    echo -e "${BOLD}${CYAN}[$1/$TOTAL_STEPS]${RESET} ${BOLD}$2${RESET}\n"
}

sep() { echo -e "  ${DIM}──────────────────────────────────────────────────${RESET}"; }

# confirm <prompt>  — devuelve 0 para sí, 1 para no
confirm() {
    echo -en "  ${BOLD}$1${RESET} ${DIM}[s/N]${RESET}: " >/dev/tty
    local ans
    read -r ans </dev/tty || ans=""
    [[ "$ans" =~ ^[sS]$ ]]
}

# ---------------------------------------------------------------------------
# Configuración (deben coincidir con los valores del installer)
# ---------------------------------------------------------------------------
AGENT_USER="${AGENT_USER:-agent}"
GATEWAY_PORT="${GATEWAY_PORT:-18789}"

AGENT_HOME="/home/$AGENT_USER"
OPENCLAW_DIR="$AGENT_HOME/.openclaw"
CREDENTIALS_DIR="$AGENT_HOME/.credentials"

SERVICE_FILE="/etc/systemd/system/openclaw-gateway.service"

# Detectar terminal disponible
INTERACTIVE=false
[[ -e /dev/tty ]] && INTERACTIVE=true

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
clear 2>/dev/null || true
echo ""
echo -e "${BOLD}${RED}"
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║                                                ║"
echo "  ║   🦞  OpenClaw Uninstaller                     ║"
echo "  ║        Elimina la instalación de producción    ║"
echo "  ║                                                ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${RESET}"
echo -e "  Este script elimina todos los componentes instalados"
echo -e "  por ${BOLD}install.sh${RESET} de esta máquina Ubuntu."
echo -e "  ${DIM}https://github.com/condestable2000/openclaw-reference-setup${RESET}"
echo ""

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

# No ejecutar como root
if [[ "$EUID" -eq 0 ]]; then
    error "No ejecutes este script como root. Usa un usuario normal con sudo."
fi

# Verificar sudo
if ! sudo -v 2>/dev/null; then
    error "Este script requiere acceso sudo."
fi

# Confirmación global antes de empezar
echo -e "  ${YELLOW}${BOLD}ATENCIÓN:${RESET} Esta operación es ${RED}${BOLD}irreversible${RESET}."
echo -e "  Se eliminará el usuario ${BOLD}$AGENT_USER${RESET} y ${RED}TODOS${RESET} sus datos."
echo ""

if $INTERACTIVE; then
    if ! confirm "¿Confirmas que quieres desinstalar OpenClaw por completo?"; then
        echo ""
        echo -e "  Desinstalación ${GREEN}cancelada${RESET}. No se ha modificado nada."
        echo ""
        exit 0
    fi
    echo ""
fi

# Opciones avanzadas (solo en modo interactivo)
REMOVE_OLLAMA=false
REMOVE_NODEJS=false
REMOVE_WORKSPACE_BACKUP=true

if $INTERACTIVE; then
    echo -e "  ${BOLD}Opciones adicionales:${RESET}"
    sep
    echo ""

    if command -v ollama &>/dev/null; then
        if confirm "¿Desinstalar también Ollama (LLM local)?"; then
            REMOVE_OLLAMA=true
        fi
        echo ""
    fi

    if command -v node &>/dev/null; then
        if confirm "¿Desinstalar también Node.js?"; then
            REMOVE_NODEJS=true
        fi
        echo ""
    fi

    if [[ -d "$OPENCLAW_DIR" ]]; then
        echo -e "  ${DIM}El workspace contiene los ficheros de memoria y configuración del agente.${RESET}"
        if confirm "¿Hacer una copia de seguridad del workspace antes de borrar?"; then
            REMOVE_WORKSPACE_BACKUP=true
        else
            REMOVE_WORKSPACE_BACKUP=false
        fi
        echo ""
    fi
fi

# ============================================================================
# STEP 1: Parar y eliminar el servicio systemd
# ============================================================================
step 1 "Eliminando servicio systemd: openclaw-gateway"

if systemctl list-units --full -all 2>/dev/null | grep -q "openclaw-gateway.service"; then
    info "Parando el servicio openclaw-gateway..."
    sudo systemctl stop openclaw-gateway 2>/dev/null || true

    info "Deshabilitando el inicio automático..."
    sudo systemctl disable openclaw-gateway 2>/dev/null || true

    if [[ -f "$SERVICE_FILE" ]]; then
        sudo rm -f "$SERVICE_FILE"
        info "Eliminado: $SERVICE_FILE"
    fi

    sudo systemctl daemon-reload
    sudo systemctl reset-failed 2>/dev/null || true
    log "Servicio openclaw-gateway eliminado."
else
    warn "El servicio openclaw-gateway no estaba instalado. Continuando..."
    # Limpiar el fichero por si acaso existe huérfano
    if [[ -f "$SERVICE_FILE" ]]; then
        sudo rm -f "$SERVICE_FILE"
        sudo systemctl daemon-reload
        info "Eliminado fichero de servicio huérfano: $SERVICE_FILE"
    fi
fi

# ============================================================================
# STEP 2: Copia de seguridad del workspace (si se solicitó)
# ============================================================================
step 2 "Copia de seguridad del workspace"

BACKUP_PATH=""
if [[ -d "$OPENCLAW_DIR" ]] && $REMOVE_WORKSPACE_BACKUP; then
    BACKUP_PATH="/tmp/openclaw-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    info "Creando copia de seguridad en: $BACKUP_PATH"
    sudo tar -czf "$BACKUP_PATH" -C "$AGENT_HOME" .openclaw 2>/dev/null || true
    sudo chmod 644 "$BACKUP_PATH"
    log "Copia guardada en: ${BOLD}$BACKUP_PATH${RESET}"
    info "Para restaurar: sudo tar -xzf $BACKUP_PATH -C /home/$AGENT_USER/"
else
    warn "Sin copia de seguridad — el workspace se eliminará definitivamente."
fi

# ============================================================================
# STEP 3: Eliminar usuario 'agent' y su directorio home
# ============================================================================
step 3 "Eliminando usuario '$AGENT_USER' y sus datos"

if id "$AGENT_USER" &>/dev/null; then
    info "Eliminando procesos del usuario $AGENT_USER..."
    # Matar todos los procesos del usuario antes de borrar
    sudo pkill -u "$AGENT_USER" 2>/dev/null || true
    sleep 1

    info "Eliminando usuario '$AGENT_USER' y su directorio home..."
    sudo userdel -r "$AGENT_USER" 2>/dev/null || {
        # Si falla userdel -r, eliminar home manualmente
        warn "userdel -r falló, eliminando home manualmente..."
        sudo rm -rf "$AGENT_HOME"
        sudo userdel "$AGENT_USER" 2>/dev/null || true
    }
    log "Usuario '$AGENT_USER' y directorio $AGENT_HOME eliminados."
else
    warn "El usuario '$AGENT_USER' no existe. Continuando..."
    # Eliminar directorio home huérfano si existe
    if [[ -d "$AGENT_HOME" ]]; then
        sudo rm -rf "$AGENT_HOME"
        info "Directorio huérfano eliminado: $AGENT_HOME"
    fi
fi

# Eliminar fichero de contraseña de recuperación
if [[ -f /root/.openclaw_agent_pass ]]; then
    sudo rm -f /root/.openclaw_agent_pass
    log "Eliminado: /root/.openclaw_agent_pass"
fi

# ============================================================================
# STEP 4: Desinstalar openclaw (npm global)
# ============================================================================
step 4 "Desinstalando paquete npm: openclaw"

if command -v openclaw &>/dev/null; then
    OPENCLAW_VER=$(openclaw --version 2>/dev/null || echo "desconocida")
    info "Desinstalando openclaw@$OPENCLAW_VER..."
    sudo npm uninstall -g openclaw
    log "openclaw desinstalado."
else
    warn "openclaw no estaba instalado como paquete npm global. Continuando..."
fi

# ============================================================================
# STEP 5: Eliminar scripts de ayuda
# ============================================================================
step 5 "Eliminando scripts de ayuda"

HELPER_SCRIPTS=(
    "/usr/local/bin/tts.sh"
    "/usr/local/bin/safe_curl.sh"
    "/usr/local/bin/openclaw-status"
    "/usr/local/bin/whisper-transcribe"
)

for SCRIPT in "${HELPER_SCRIPTS[@]}"; do
    if [[ -f "$SCRIPT" ]]; then
        sudo rm -f "$SCRIPT"
        log "Eliminado: $SCRIPT"
    else
        info "No encontrado (ya eliminado): $SCRIPT"
    fi
done

# ============================================================================
# STEP 6: Eliminar Piper TTS
# ============================================================================
step 6 "Eliminando Piper TTS"

if command -v piper &>/dev/null; then
    PIPER_BIN=$(command -v piper)
    sudo rm -f "$PIPER_BIN"
    log "Eliminado: $PIPER_BIN"
else
    warn "Piper TTS no estaba instalado. Continuando..."
fi

# ============================================================================
# STEP 7: Desinstalar Ollama (si se solicitó)
# ============================================================================
step 7 "Ollama (LLM local)"

if $REMOVE_OLLAMA; then
    if command -v ollama &>/dev/null; then
        info "Parando servicio de Ollama..."
        sudo systemctl stop ollama 2>/dev/null || true
        sudo systemctl disable ollama 2>/dev/null || true

        info "Eliminando binario de Ollama..."
        sudo rm -f /usr/local/bin/ollama /usr/bin/ollama

        # Eliminar servicio systemd de Ollama si existe
        if [[ -f /etc/systemd/system/ollama.service ]]; then
            sudo rm -f /etc/systemd/system/ollama.service
            sudo systemctl daemon-reload
            info "Servicio systemd de Ollama eliminado."
        fi

        # Eliminar usuario ollama si existe
        if id "ollama" &>/dev/null; then
            sudo userdel -r ollama 2>/dev/null || sudo userdel ollama 2>/dev/null || true
            info "Usuario 'ollama' eliminado."
        fi

        # Eliminar modelos descargados (pueden ocupar mucho espacio)
        if [[ -d /usr/share/ollama ]]; then
            sudo rm -rf /usr/share/ollama
            info "Modelos de Ollama eliminados de /usr/share/ollama"
        fi
        if [[ -d /root/.ollama ]]; then
            sudo rm -rf /root/.ollama
            info "Directorio /root/.ollama eliminado."
        fi

        sudo systemctl reset-failed 2>/dev/null || true
        log "Ollama desinstalado."
    else
        warn "Ollama no estaba instalado."
    fi
else
    info "Ollama conservado (no se solicitó su eliminación)."
fi

# ============================================================================
# STEP 8: Desinstalar Node.js (si se solicitó)
# ============================================================================
step 8 "Node.js"

if $REMOVE_NODEJS; then
    if command -v node &>/dev/null; then
        NODE_VER=$(node --version)
        info "Desinstalando Node.js $NODE_VER..."
        sudo apt-get remove -y nodejs 2>/dev/null || true
        sudo apt-get autoremove -y 2>/dev/null || true

        # Eliminar repositorio NodeSource si existe
        if [[ -f /etc/apt/sources.list.d/nodesource.list ]]; then
            sudo rm -f /etc/apt/sources.list.d/nodesource.list
            info "Repositorio NodeSource eliminado."
        fi
        if ls /etc/apt/sources.list.d/nodesource* 2>/dev/null | grep -q .; then
            sudo rm -f /etc/apt/sources.list.d/nodesource*
        fi

        sudo apt-get update -qq 2>/dev/null || true
        log "Node.js $NODE_VER desinstalado."
    else
        warn "Node.js no estaba instalado."
    fi
else
    info "Node.js conservado (no se solicitó su eliminación)."
fi

# ============================================================================
# RESUMEN FINAL
# ============================================================================
echo ""
echo -e "${BOLD}${GREEN}"
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║                                                ║"
echo "  ║   🦞  ¡Desinstalación completada!              ║"
echo "  ║                                                ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo -e "${RESET}"

echo -e "  ${BOLD}Resumen de lo eliminado:${RESET}"
echo "  ────────────────────────────────────────────────"
printf  "    %-30s %s\n" "Servicio openclaw-gateway:"  "eliminado"
printf  "    %-30s %s\n" "Usuario '$AGENT_USER':"       "eliminado (home incluido)"
printf  "    %-30s %s\n" "openclaw (npm global):"       "$( command -v openclaw &>/dev/null && echo 'PENDIENTE' || echo 'eliminado')"
printf  "    %-30s %s\n" "Scripts de ayuda:"            "eliminados"
printf  "    %-30s %s\n" "Piper TTS:"                   "$( command -v piper &>/dev/null && echo 'PENDIENTE' || echo 'eliminado')"
$REMOVE_OLLAMA && \
printf  "    %-30s %s\n" "Ollama:"                       "$( command -v ollama &>/dev/null && echo 'PENDIENTE' || echo 'eliminado')"
$REMOVE_NODEJS && \
printf  "    %-30s %s\n" "Node.js:"                      "$( command -v node &>/dev/null && echo 'PENDIENTE' || echo 'eliminado')"
echo ""

if [[ -n "$BACKUP_PATH" ]] && [[ -f "$BACKUP_PATH" ]]; then
    echo -e "  ${BOLD}Copia de seguridad:${RESET}"
    echo "  ────────────────────────────────────────────────"
    echo -e "    ${CYAN}$BACKUP_PATH${RESET}"
    echo -e "    ${DIM}Para restaurar: sudo tar -xzf $BACKUP_PATH -C /home/$AGENT_USER/${RESET}"
    echo ""
fi

echo -e "  ${BOLD}Para reinstalar desde cero:${RESET}"
echo "  ────────────────────────────────────────────────"
echo -e "    ${CYAN}curl -fsSL https://raw.githubusercontent.com/condestable2000/openclaw-reference-setup/main/install.sh | bash${RESET}"
echo ""
echo -e "  ${BOLD}Documentación:${RESET}   https://docs.openclaw.ai"
echo -e "  ${BOLD}Repositorio:${RESET}     https://github.com/condestable2000/openclaw-reference-setup"
echo ""
