#!/usr/bin/env bash
# =====================================================================
#  glm-bridge.sh — unified manager for the glm-bridge project
#  One file replaces install.sh + uninstall.sh
# ---------------------------------------------------------------------
#  Usage:
#    bash glm-bridge.sh --start       install (first time) + start the bridge
#                                     - generates a fresh topic on first install
#                                     - adds the `glm-bridge` command to PATH
#    bash glm-bridge.sh --stop        full stop (watchdog + tunnel + autostart)
#    bash glm-bridge.sh --status      show status
#    bash glm-bridge.sh --restart     restart
#    bash glm-bridge.sh --new-topic   rotate the ntfy topic and restart
#                                     (tell your AI assistant the new id!)
#    bash glm-bridge.sh --uninstall   stop + remove integration (cron + PATH
#                                     + state); keeps the project folder
#    bash glm-bridge.sh --purge       like --uninstall + delete project folder
#    bash glm-bridge.sh --help        this screen
#
#  Extra flags:
#    --yes       skip confirmation prompts (non-interactive use)
#    --no-wait   do not wait for the first tunnel URL after starting
#    --name X    server name (first install only — default: hostname)
#    --topic X   force a specific topic (first install only — restore/clone)
#
#  Notes:
#    * The topic is stored in ~/.glm-bridge/state.env and PERSISTS across
#      --stop / --start cycles (changes only via --new-topic or after
#      --uninstall).
#    * After the first --start the command works from any directory:
#      glm-bridge --status
#    * No root needed. Requires: bash, ssh, sed + (openssl or /dev/urandom)
# =====================================================================
set -u
: "${HOME:?ERROR: HOME is not set}"
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"

VERSION="2.1"
SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd)"
WATCHDOG_TEMPLATE="$SCRIPT_DIR/bridge/glm-watchdog.sh"
GLM_DIR="$HOME/.glm-bridge"
STATE_FILE="$GLM_DIR/state.env"
BIN_DIR="$HOME/.local/bin"
BIN_LINK="$BIN_DIR/glm-bridge"
TUNNEL_SIG='ssh -p 443 -R0:127.0.0.1:22'

log()  { echo "[glm-bridge] $*"; }
warn() { echo "[glm-bridge] WARNING: $*" >&2; }
die()  { echo "[glm-bridge] ERROR: $*" >&2; exit 1; }

# ---------- persisted state (topic survives stop/start) --------------
gen_topic() {
    if command -v openssl >/dev/null 2>&1; then
        printf 'glmb-fleet-%s' "$(openssl rand -hex 6)"
    elif [ -r /dev/urandom ]; then
        printf 'glmb-fleet-%s' "$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
    else
        printf 'glmb-fleet-%s%x' "$(date +%s)" "$RANDOM"
    fi
}

save_state() {
    mkdir -p "$GLM_DIR"
    { printf 'NTFY_TOPIC=%q\n' "$TOPIC"
      printf 'SERVER_NAME=%q\n' "$NAME"
      printf 'INSTALLED_AT=%q\n' "$INSTALLED_AT"
    } > "$STATE_FILE"
    chmod 600 "$STATE_FILE" 2>/dev/null || true
}

load_state() {
    NTFY_TOPIC=""; SERVER_NAME=""; INSTALLED_AT=""
    [ -f "$STATE_FILE" ] && . "$STATE_FILE"
    TOPIC="$NTFY_TOPIC"
    NAME="$SERVER_NAME"
    return 0
}

# ---------- PATH: the glm-bridge command from any directory ----------
path_install() {
    mkdir -p "$BIN_DIR" 2>/dev/null || true
    ln -sfn "$SELF" "$BIN_LINK" 2>/dev/null || { warn "could not create $BIN_LINK"; return 0; }
    if [ -f "$HOME/.bashrc" ] && ! grep -qs '^# >>> glm-bridge >>>$' "$HOME/.bashrc"; then
        { echo ""
          echo "# >>> glm-bridge >>>"
          echo 'export PATH="$HOME/.local/bin:$PATH"'
          echo "# <<< glm-bridge <<<"
        } >> "$HOME/.bashrc"
        log "added glm-bridge to PATH — open a new terminal or run: source ~/.bashrc"
    fi
    [ -f "$HOME/.bashrc" ] || {
        { echo "# >>> glm-bridge >>>"
          echo 'export PATH="$HOME/.local/bin:$PATH"'
          echo "# <<< glm-bridge <<<"
        } > "$HOME/.bashrc"
    }
    return 0
}

path_remove() {
    rm -f "$BIN_LINK"
    if [ -f "$HOME/.bashrc" ]; then
        sed -i '/^# >>> glm-bridge >>>$/,/^# <<< glm-bridge <<<$/d' "$HOME/.bashrc" 2>/dev/null || true
    fi
    return 0
}

# ---------- crontab: auto-start after reboot --------------------------
cron_add() {
    command -v crontab >/dev/null 2>&1 || { warn "crontab not available — autostart after reboot disabled"; return 0; }
    ( crontab -l 2>/dev/null | grep -v 'glm-watchdog.sh'
      echo "@reboot $GLM_DIR/glm-watchdog.sh >> $GLM_DIR/watchdog.log 2>&1" ) | crontab - 2>/dev/null \
        && log "autostart after reboot: enabled"
    return 0
}

cron_remove() {
    command -v crontab >/dev/null 2>&1 || return 0
    crontab -l 2>/dev/null | grep -q 'glm-watchdog.sh' || return 0
    ( crontab -l 2>/dev/null | grep -v 'glm-watchdog.sh' ) | crontab - 2>/dev/null \
        && log "autostart after reboot: removed"
    return 0
}

# ---------- bridge services --------------------------------------------
stop_services() {
    if pkill -f 'glm-watchdog.sh' 2>/dev/null; then
        log "watchdog: stopped"
    else
        log "watchdog: no process found"
    fi
    if pkill -f "$TUNNEL_SIG" 2>/dev/null; then
        log "pinggy tunnel: stopped"
    else
        log "pinggy tunnel: none"
    fi
    sleep 1
    return 0
}

render_watchdog() {
    [ -f "$WATCHDOG_TEMPLATE" ] || die "template not found:
  $WATCHDOG_TEMPLATE
Run this script from inside the glm-bridge project folder."
    grep -q '__TOPIC__' "$WATCHDOG_TEMPLATE" \
        || die "$WATCHDOG_TEMPLATE does not look like a valid watchdog template (missing __TOPIC__)."
    case "$NAME" in
        */*|*'&'*) die "invalid server name for template substitution: $NAME" ;;
    esac
    mkdir -p "$GLM_DIR"
    sed -e "s/__TOPIC__/$TOPIC/" -e "s/__SERVER__/$NAME/" \
        "$WATCHDOG_TEMPLATE" > "$GLM_DIR/glm-watchdog.sh.tmp"
    mv "$GLM_DIR/glm-watchdog.sh.tmp" "$GLM_DIR/glm-watchdog.sh"
    chmod +x "$GLM_DIR/glm-watchdog.sh"
    cp -f "$WATCHDOG_TEMPLATE" "$GLM_DIR/glm-watchdog.template.sh" 2>/dev/null || true
}

launch_watchdog() {
    setsid nohup "$GLM_DIR/glm-watchdog.sh" >> "$GLM_DIR/watchdog.log" 2>&1 < /dev/null &
    log "watchdog started (PID $!)"
}

grab_url() {
    local f url=""
    for f in "$GLM_DIR/current.json" "$GLM_DIR/tunnel_new.log"; do
        [ -f "$f" ] || continue
        url="$(grep -oE 'tcp://[A-Za-z0-9.-]+:[0-9]+' "$f" 2>/dev/null | head -1)"
        [ -n "$url" ] && { printf '%s' "$url"; return 0; }
    done
    return 1
}

wait_url() {  # $1 = number of cycles (5 s each)
    local i url=""
    for i in $(seq 1 "${1:-30}"); do
        sleep 5
        url="$(grab_url)" && break
    done
    [ -n "$url" ] && { printf '%s' "$url"; return 0; }
    return 1
}

url_parts() {  # $1 = tcp://host:port
    HOST="${1#tcp://}"; HOST="${HOST%%:*}"
    PORT="${1##*:}"
}

# ---------- commands -----------------------------------------------------
cmd_start() {
    load_state
    local fresh=0
    if [ -z "${TOPIC:-}" ]; then
        fresh=1
        TOPIC="${FORCED_TOPIC:-$(gen_topic)}"
        NAME="${BRIDGE_NAME:-$(hostname)}"
        INSTALLED_AT="$(date '+%F %T')"
        save_state
        log "fresh install — topic: $TOPIC"
        log "tell your AI assistant this id in the chat."
    else
        log "saved state found — reusing topic: $TOPIC"
    fi
    [ -n "${NAME:-}" ] || NAME="$(hostname)"
    render_watchdog
    log "watchdog rendered from local template"
    path_install
    stop_services
    rm -f "$GLM_DIR/tunnel_new.log" "$GLM_DIR/current.json" "$GLM_DIR/tunnel.pid"
    launch_watchdog
    cron_add
    if [ "$NO_WAIT" = 1 ]; then
        log "skipping URL wait (--no-wait) — check later: glm-bridge --status"
        return 0
    fi
    log "waiting for the first tunnel URL (up to 150 s)..."
    local url
    if url="$(wait_url 30)"; then
        url_parts "$url"
        local conn
        conn="ssh -p \"$PORT\" $(id -un 2>/dev/null || printf '%s' "${USER:-unknown}")@$HOST"
        cat > "$GLM_DIR/CONNECT.txt" <<EOF
generated : $(date '+%F %T')
topic     : $TOPIC
tunnel    : $url
command   : $conn
note      : this URL renews every ~50 min — always re-discover via the ntfy topic
EOF
        echo ""
        echo "=========================================================="
        echo "  GLM-BRIDGE IS RUNNING"
        echo "----------------------------------------------------------"
        echo "  Connection command : $conn"
        echo "  Current URL        : $url"
        echo "  ntfy topic         : $TOPIC"
        echo "  Project            : $SCRIPT_DIR"
        echo "  State dir          : $GLM_DIR"
        echo "----------------------------------------------------------"
        echo "  From any directory :  glm-bridge --status"
        echo "  Stop               :  glm-bridge --stop"
        echo "  Help               :  glm-bridge --help"
        echo "=========================================================="
    else
        warn "no tunnel URL after 150 s — services are up and the URL may arrive later"
        warn "watch: glm-bridge --status  or  tail -f $GLM_DIR/watchdog.log"
        return 1
    fi
}

cmd_stop() {
    load_state
    stop_services
    cron_remove
    echo "----------------------------------------------------------"
    log "bridge fully stopped (including autostart)."
    if [ -n "${TOPIC:-}" ]; then
        log "state saved — the SAME topic returns with:  glm-bridge --start"
        log "current topic: $TOPIC"
    else
        log "to start later:  bash $SELF --start"
    fi
}

cmd_status() {
    load_state
    local pid="" run_s="stopped" url="" cron_s="disabled" link_s="not installed"
    pid="$(pgrep -f 'glm-watchdog.sh' 2>/dev/null | head -1)"
    if [ -n "$pid" ]; then
        run_s="running (PID $pid, up $(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' '))"
    fi
    url="$(grab_url)" || url="unknown yet"
    crontab -l 2>/dev/null | grep -q 'glm-watchdog.sh' && cron_s="enabled"
    [ -L "$BIN_LINK" ] && link_s="installed ($BIN_LINK)"
    echo "=========================================================="
    echo "  GLM-BRIDGE — STATUS (v$VERSION)"
    echo "----------------------------------------------------------"
    echo "  Service            : $run_s"
    echo "  Current URL        : $url"
    echo "  ntfy topic         : ${TOPIC:-(not installed)}"
    echo "  Server name        : ${NAME:-$(hostname)}"
    echo "  Autostart @reboot  : $cron_s"
    echo "  Global command     : $link_s"
    echo "  Project folder     : $SCRIPT_DIR"
    echo "  State dir          : $GLM_DIR"
    echo "----------------------------------------------------------"
    echo "  Live log: tail -f $GLM_DIR/watchdog.log"
    echo "=========================================================="
}

cmd_new_topic() {
    load_state
    [ -n "${TOPIC:-}" ] || die "not installed yet — run --start first"
    [ -n "${NAME:-}" ] || NAME="$(hostname)"
    TOPIC="$(gen_topic)"
    INSTALLED_AT="$(date '+%F %T')"
    save_state
    render_watchdog
    stop_services
    rm -f "$GLM_DIR/tunnel_new.log" "$GLM_DIR/current.json" "$GLM_DIR/tunnel.pid"
    launch_watchdog
    cron_add
    echo ""
    echo "=========================================================="
    echo "  NEW TOPIC: $TOPIC"
    echo "  -> tell your AI assistant in the chat NOW"
    echo "=========================================================="
    [ "$NO_WAIT" = 1 ] && return 0
    local url
    if url="$(wait_url 30)"; then
        log "new URL: $url"
    else
        warn "URL not received yet — watch: glm-bridge --status"
        return 1
    fi
}

cmd_uninstall() {
    load_state
    if [ "$YES" != 1 ]; then
        printf "[glm-bridge] services stop and cron + PATH + state are removed. Continue? (y/N): "
        read -r ans
        case "$ans" in y|Y|yes|YES) ;; *) log "cancelled."; exit 0 ;; esac
    fi
    echo "=========================================================="
    echo "  GLM-BRIDGE UNINSTALL"
    echo "----------------------------------------------------------"
    stop_services
    cron_remove
    path_remove
    if [ -d "$GLM_DIR" ]; then
        rm -rf "$GLM_DIR"
        log "state dir removed: $GLM_DIR"
    fi
    log "topic ${TOPIC:-(unknown)} is now dead — if your AI still listens to it, tell it in the chat."
    if [ "$PURGE" = 1 ]; then
        log "removing project folder: $SCRIPT_DIR"
        cd "$HOME" || exit 1
        rm -rf "$SCRIPT_DIR"
        echo "----------------------------------------------------------"
        echo "  glm-bridge fully removed from this server."
        echo "  To come back: copy the project folder again and run"
        echo "    bash glm-bridge.sh --start   (generates a fresh topic)"
    else
        log "project folder kept: $SCRIPT_DIR (use --purge to delete it too)"
        echo "----------------------------------------------------------"
        echo "  To start again later:"
        echo "    bash $SCRIPT_DIR/glm-bridge.sh --start   (generates a fresh topic)"
    fi
    echo "=========================================================="
}

cmd_help() {
    cat <<'EOF'
glm-bridge — keeps your AI assistant connected to this server (one file does it all)

Usage:
  bash glm-bridge.sh --start        install (first time) + start
  bash glm-bridge.sh --stop         full stop
  bash glm-bridge.sh --status       show status
  bash glm-bridge.sh --restart      restart
  bash glm-bridge.sh --new-topic    new topic (tell your AI assistant!)
  bash glm-bridge.sh --uninstall    remove integration (keeps project folder)
  bash glm-bridge.sh --purge        remove + delete the project folder
  bash glm-bridge.sh --help         this help

Flags: --yes (skip prompts) | --no-wait (skip URL wait)
       --name X (server name, first install) | --topic X (force topic, first install)

After the first --start the command works from any directory:
  glm-bridge --status   |   glm-bridge --stop   |   glm-bridge --help
EOF
}

# ---------- argument parsing ---------------------------------------------
ACTION=""; PURGE=0; YES=0; NO_WAIT=0; BRIDGE_NAME=""; FORCED_TOPIC=""
while [ $# -gt 0 ]; do
    case "$1" in
        --start|start)         ACTION="start" ;;
        --stop|stop)           ACTION="stop" ;;
        --status|status)       ACTION="status" ;;
        --restart|restart)     ACTION="restart" ;;
        --new-topic|new-topic) ACTION="new-topic" ;;
        --uninstall|uninstall) ACTION="uninstall" ;;
        --purge)               ACTION="uninstall"; PURGE=1 ;;
        --yes|-y)              YES=1 ;;
        --no-wait)             NO_WAIT=1 ;;
        --name)                [ -n "${2:-}" ] || die "--name needs a value"; BRIDGE_NAME="$2"; shift ;;
        --topic)               [ -n "${2:-}" ] || die "--topic needs a value"; FORCED_TOPIC="$2"; shift ;;
        --version|-V)          echo "glm-bridge v$VERSION"; exit 0 ;;
        -h|--help|help)        cmd_help; exit 0 ;;
        *)                     die "unknown option: $1  (try --help)" ;;
    esac
    shift
done
[ -n "$ACTION" ] || { cmd_help; exit 1; }

case "$ACTION" in
    start)     cmd_start ;;
    stop)      cmd_stop ;;
    status)    cmd_status ;;
    restart)   log "restarting..."; cmd_start ;;
    new-topic) cmd_new_topic ;;
    uninstall) cmd_uninstall ;;
esac
