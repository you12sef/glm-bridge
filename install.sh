#!/usr/bin/env bash
# =====================================================================
# install.sh — glm-bridge integrated project installer
#
# The whole project lives in THIS folder (no GitHub, no downloads).
# Run this script from inside the project folder and it will:
#   1. generate a FRESH ntfy topic id for THIS install
#   2. render the local watchdog template into ~/.glm-bridge
#   3. start it detached + add a @reboot crontab entry
#   4. wait for the first tunnel URL, then print the SSH connection
#      command + the new topic id
#
# Usage (inside the project folder):
#   bash install.sh [server-name]
# Example:
#   bash install.sh pronet-movies
#
# Requirements: bash, ssh, sed, and (openssl OR /dev/urandom) for the topic id.
# No root needed. Re-run safe (repairs/replaces the watchdog) — every run
# generates a NEW ntfy topic id.
# =====================================================================
set -u

# ---- project layout (files ship with this repo) --------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHDOG_TEMPLATE="$SCRIPT_DIR/bridge/glm-watchdog.sh"

# ---- ntfy topic: GENERATED FRESH on every install (public by design).
# New install => new topic id; paste it into AI-HANDOFF.md (§2) and tell
# your AI in the chat. Override: export NTFY_TOPIC (rarely needed).
gen_topic() {
    if command -v openssl >/dev/null 2>&1; then
        printf 'glmb-fleet-%s' "$(openssl rand -hex 6)"
    elif [ -r /dev/urandom ]; then
        printf 'glmb-fleet-%s' "$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"
    else
        printf 'glmb-fleet-%s%x' "$(date +%s)" "$RANDOM"
    fi
}
NTFY_TOPIC="${NTFY_TOPIC:-$(gen_topic)}"

RENEW_NOTE="watchdog renews the tunnel every 50 min; current URL always on ntfy"

SERVER_NAME="${1:-$(hostname)}"
GLM_DIR="$HOME/.glm-bridge"

log()  { echo -e "[install] $*"; }
fail() { echo -e "[install] ERROR: $*" >&2; exit 1; }

# ---------- friendly guard: the old GitHub-arg habit ----------------
case "${1:-}" in
    */*|http://*|https://*)
        fail "install.sh no longer downloads from GitHub — the project is fully local now.
Run it from inside the project folder:   bash install.sh [server-name]"
        ;;
esac

# ---------- sanity: the project must be complete in this folder ------
[ -f "$WATCHDOG_TEMPLATE" ] || fail "watchdog template not found at:
  $WATCHDOG_TEMPLATE
Run this script from inside the glm-bridge project folder."

grep -q '__TOPIC__' "$WATCHDOG_TEMPLATE" || fail "$WATCHDOG_TEMPLATE does not look like the watchdog template (missing __TOPIC__)."

log "project dir   : $SCRIPT_DIR"
log "server name   : $SERVER_NAME"
log "ntfy topic    : $NTFY_TOPIC (generated fresh for this install)"

mkdir -p "$GLM_DIR"

# render watchdog with embedded topic + server name (tmp then mv: safe re-install)
sed -e "s/__TOPIC__/$NTFY_TOPIC/" -e "s/__SERVER__/$SERVER_NAME/" \
    "$WATCHDOG_TEMPLATE" > "$GLM_DIR/glm-watchdog.sh.tmp"
mv "$GLM_DIR/glm-watchdog.sh.tmp" "$GLM_DIR/glm-watchdog.sh"
chmod +x "$GLM_DIR/glm-watchdog.sh"
cp -f "$WATCHDOG_TEMPLATE" "$GLM_DIR/glm-watchdog.template.sh" 2>/dev/null || true
log "watchdog rendered from local template"

# clean slate: stop previous watchdog + all old pinggy tunnels
pkill -f 'glm-watchdog.sh' 2>/dev/null
pkill -f 'ssh -p 443 -R0:127.0.0.1:22' 2>/dev/null
sleep 2
rm -f "$GLM_DIR/tunnel_new.log" "$GLM_DIR/current.json" "$GLM_DIR/tunnel.pid"

# start watchdog fully detached (survives SSH disconnect)
setsid nohup "$GLM_DIR/glm-watchdog.sh" >> "$GLM_DIR/watchdog.log" 2>&1 < /dev/null &
WD_PID=$!
log "watchdog started (PID $WD_PID)"

# auto-start after reboot (user crontab, no root)
if command -v crontab >/dev/null 2>&1; then
    ( crontab -l 2>/dev/null | grep -v 'glm-watchdog.sh'
      echo "@reboot $GLM_DIR/glm-watchdog.sh >> $GLM_DIR/watchdog.log 2>&1" ) | crontab - 2>/dev/null \
        && log "@reboot crontab entry installed"
fi

# wait for the tunnel URL (up to ~2.5 min)
URL=""
for i in $(seq 1 30); do
    sleep 5
    if [ -f "$GLM_DIR/current.json" ]; then
        URL=$(grep -oE 'tcp://[A-Za-z0-9.-]+:[0-9]+' "$GLM_DIR/current.json" 2>/dev/null | head -1)
    fi
    if [ -z "$URL" ] && [ -f "$GLM_DIR/tunnel_new.log" ]; then
        URL=$(grep -oE 'tcp://[A-Za-z0-9.-]+:[0-9]+' "$GLM_DIR/tunnel_new.log" 2>/dev/null | head -1)
    fi
    [ -n "$URL" ] && break
done
[ -n "$URL" ] || fail "no tunnel URL after 150 s — see $GLM_DIR/watchdog.log and $GLM_DIR/tunnel_new.log"

HOSTPORT="${URL#tcp://}"
HOST="${HOSTPORT%%:*}"
PORT="${HOSTPORT##*:}"
CUR_USER="$(id -un 2>/dev/null || printf '%s' "${USER:-unknown}")"
CONN="ssh -p \"$PORT\" $CUR_USER@$HOST"

# save for later reference on the server
cat > "$GLM_DIR/CONNECT.txt" <<EOF
generated : $(date '+%F %T')
topic     : $NTFY_TOPIC
tunnel    : $URL
command   : $CONN
note      : $RENEW_NOTE — this printed URL expires; always re-discover via ntfy
EOF

echo
echo "=========================================================="
echo "  GLM-BRIDGE INSTALLED OK"
echo "----------------------------------------------------------"
echo "  Connection command (paste into AI-HANDOFF.md -> USER block):"
echo
echo "    $CONN"
echo
echo "  Tunnel URL : $URL"
echo "  ntfy topic : $NTFY_TOPIC   <- FRESH topic for THIS install"
echo "               -> paste it into AI-HANDOFF.md (§2) and tell your"
echo "                  AI in the CHAT (the AI listens to it too)."
echo "  Project    : $SCRIPT_DIR (fully local — no GitHub needed)"
echo "  State dir  : $GLM_DIR"
echo "----------------------------------------------------------"
echo "  NOTE: this URL lives ~50 min. The watchdog renews it and"
echo "  publishes the new one to the ntfy topic automatically."
echo "=========================================================="
