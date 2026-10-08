#!/usr/bin/env bash
# =====================================================================
# install.sh — glm-bridge one-command installer
#
# Downloads the project from GitHub onto THIS server, generates a FRESH
# ntfy topic id (new on EVERY install), installs & starts the tunnel
# watchdog, then prints the SSH connection command + the topic id.
#
# Usage (on the server):
#   bash install.sh <USER/REPO> [server-name]
#   bash install.sh https://raw.githubusercontent.com/USER/REPO [server-name]
# Example:
#   bash install.sh myuser/glm-bridge pronet-movies
#
# Requirements: bash, ssh, curl (or wget), sed. No root needed.
# Re-run safe (repairs/replaces the watchdog) — NOTE: every run generates a NEW ntfy topic id.
# =====================================================================
set -u

# ---- EMBEDDED CONFIG (edit here only if you know why) ---------------
# ntfy.sh registry topic — GENERATED FRESH on every install (public by design).
# New install => new topic id; the user pastes it into AI-HANDOFF.md (§2)
# and tells the AI in the chat. Override: export NTFY_TOPIC (rarely needed).
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
# ---------------------------------------------------------------------

REPO_ARG="${1:-}"
SERVER_NAME="${2:-$(hostname)}"
GLM_DIR="$HOME/.glm-bridge"
RAW=""

log()  { echo -e "[install] $*"; }
fail() { echo -e "[install] ERROR: $*" >&2; exit 1; }

# ---------- normalize repo argument -> raw base URL ----------
normalize_repo() {
    local a="${REPO_ARG%/}"
    a="${a%/install.sh}"
    case "$a" in
        https://raw.githubusercontent.com/*)
            local path="${a#https://raw.githubusercontent.com/}"
            local segs
            segs=$(echo "$path" | awk -F/ '{print NF}')
            if [ "$segs" -ge 4 ]; then RAW="$a"; else RAW="$a/main"; fi
            ;;
        https://github.com/*)
            RAW="https://raw.githubusercontent.com/${a#https://github.com/}/main"
            ;;
        */*)
            RAW="https://raw.githubusercontent.com/$a/main"
            ;;
        *)
            fail "usage: bash install.sh <USER/REPO or raw-url> [server-name]"
            ;;
    esac
}

# ---------- fetch a file from the repo (main -> master fallback) ----------
fetch_file() {
    local rel="$1" dest="$2" url
    if command -v curl >/dev/null 2>&1; then
        url="$RAW/$rel"
        curl -fsSL --max-time 30 "$url" -o "$dest" && return 0
        if echo "$RAW" | grep -q '/main$'; then
            url="${RAW%/main}/master/$rel"
            curl -fsSL --max-time 30 "$url" -o "$dest" && return 0
        fi
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 30 -O "$dest" "$RAW/$rel" && return 0
        if echo "$RAW" | grep -q '/main$'; then
            wget -q -T 30 -O "$dest" "${RAW%/main}/master/$rel" && return 0
        fi
    else
        fail "need curl or wget to download files"
    fi
    fail "cannot download '$rel' from $RAW (check repo is public & branch is main/master)"
}

# ---------- main ----------
[ -n "$REPO_ARG" ] || fail "usage: bash install.sh <USER/REPO> [server-name]"
normalize_repo
log "repo raw base : $RAW"
log "server name   : $SERVER_NAME"
log "ntfy topic    : $NTFY_TOPIC (generated fresh for this install)"

mkdir -p "$GLM_DIR"
fetch_file "glm-watchdog.sh" "$GLM_DIR/glm-watchdog.template.sh"
log "downloaded glm-watchdog.sh"

# render watchdog with embedded topic + server name
sed -e "s/__TOPIC__/$NTFY_TOPIC/" -e "s/__SERVER__/$SERVER_NAME/" \
    "$GLM_DIR/glm-watchdog.template.sh" > "$GLM_DIR/glm-watchdog.sh"
chmod +x "$GLM_DIR/glm-watchdog.sh"

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
CONN="ssh -p \"$PORT\" $USER@$HOST"

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
echo "  State dir  : $GLM_DIR"
echo "----------------------------------------------------------"
echo "  NOTE: this URL lives ~50 min. The watchdog renews it and"
echo "  publishes the new one to the ntfy topic automatically."
echo "=========================================================="
