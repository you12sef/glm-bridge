#!/usr/bin/env bash
# =============================================================
# glm-watchdog.sh — Pinggy tunnel auto-renewal daemon
# Part of the "glm-bridge" kit (see README-PROTOCOL.md)
#
# Job:
#   - Maintain ONE pinggy free tunnel: ssh -p 443 -R0:127.0.0.1:22 tcp@free.pinggy.io
#   - Renew it every RENEW_SECS (default 50 min, before the 60 min free limit)
#   - Publish the current URL to an ntfy.sh topic (RENEW / HEARTBEAT messages)
#   - Write local state to ~/.glm-bridge/current.json
#
# Runs WITHOUT root. Placeholders __TOPIC__ / __SERVER__ are replaced by glm-bootstrap.sh
# =============================================================
GLM_DIR="$HOME/.glm-bridge"
NTFY_TOPIC="__TOPIC__"
SERVER_NAME="__SERVER__"
RENEW_SECS="${GLM_RENEW_SECS:-3000}"      # 50 min
HEARTBEAT_SECS="${GLM_HEARTBEAT_SECS:-300}" # 5 min
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes"
LOG="$GLM_DIR/watchdog.log"
STATE="$GLM_DIR/current.json"

mkdir -p "$GLM_DIR"
log() { echo "[$(date '+%F %T')] $$ $*" >> "$LOG"; }

publish() { # $1 = message body
    local msg="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -s -m 15 -H "Title: glm-bridge $SERVER_NAME" -d "$msg" "https://ntfy.sh/$NTFY_TOPIC" >/dev/null 2>&1
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 15 --header="Title: glm-bridge $SERVER_NAME" --post-data="$msg" "https://ntfy.sh/$NTFY_TOPIC" >/dev/null 2>&1
    elif command -v python3 >/dev/null 2>&1; then
        NTFY_TOPIC="$NTFY_TOPIC" SERVER_NAME="$SERVER_NAME" msg="$msg" python3 - <<'PY' >/dev/null 2>&1
import os, urllib.request
topic = os.environ["NTFY_TOPIC"]
req = urllib.request.Request(
    "https://ntfy.sh/" + topic,
    data=os.environ["msg"].encode(),
    headers={"Title": "glm-bridge " + os.environ["SERVER_NAME"]},
)
urllib.request.urlopen(req, timeout=15)
PY
    else
        log "WARN: no curl/wget/python3 — cannot publish to ntfy"
    fi
}

tunnel_alive() { # $1 = tcp://host:port
    local hostport="${1#tcp://}" host port
    host="${hostport%%:*}"; port="${hostport##*:}"
    timeout 8 bash -c "echo >/dev/tcp/$host/$port" 2>/dev/null
}

start_tunnel() {
    local urlf="$GLM_DIR/tunnel_new.log" url i
    rm -f "$urlf"
    setsid nohup ssh -p 443 -R0:127.0.0.1:22 $SSH_OPTS \
        tcp@free.pinggy.io > "$urlf" 2>&1 < /dev/null &
    echo $! > "$GLM_DIR/tunnel.pid"
    for i in $(seq 1 24); do          # up to 120 s
        sleep 5
        url=$(grep -oE 'tcp://[A-Za-z0-9.-]+:[0-9]+' "$urlf" 2>/dev/null | head -1)
        [ -n "$url" ] && { echo "$url"; return 0; }
    done
    return 1
}

renew() {
    log "renewing tunnel (url='$CUR_URL' alive=$ALIVE age=${AGE}s)"
    [ -f "$GLM_DIR/tunnel.pid" ] && kill "$(cat "$GLM_DIR/tunnel.pid")" 2>/dev/null
    pkill -f 'ssh -p 443 -R0:127.0.0.1:22' 2>/dev/null
    sleep 2
    local new_url ts
    new_url=$(start_tunnel) || true
    if [ -n "${new_url:-}" ]; then
        CUR_URL="$new_url"
        START_TS=$(date +%s)
        ts=$(date '+%F %T')
        # Write JSON safely. printf %s does NOT escape " or \, so use python3
        # when available to produce a valid JSON document (defensive against
        # unusual hostnames / usernames containing quotes or backslashes).
        if command -v python3 >/dev/null 2>&1; then
            SERVER_NAME="$SERVER_NAME" CUR_URL="$CUR_URL" WHOAMI="$(whoami)" TS="$ts" \
                python3 -c '
import json, os
print(json.dumps({
    "server": os.environ["SERVER_NAME"],
    "url": os.environ["CUR_URL"],
    "user": os.environ["WHOAMI"],
    "renewed_at": os.environ["TS"],
}))' > "$STATE"
        else
            printf '{"server":"%s","url":"%s","user":"%s","renewed_at":"%s"}\n' \
                "$SERVER_NAME" "$CUR_URL" "$(whoami)" "$ts" > "$STATE"
        fi
        publish "RENEW $SERVER_NAME $CUR_URL"
        log "new tunnel: $CUR_URL"
        return 0
    fi
    log "FAILED to obtain tunnel URL (retry in 60 s)"
    return 1
}

# ---------------- main loop ----------------
CUR_URL=""
START_TS=$(date +%s)
LAST_BEAT=0
log "===== watchdog started: server=$SERVER_NAME topic=$NTFY_TOPIC ====="
publish "WATCHDOG-START $SERVER_NAME on $(hostname)"
while true; do
    NOW=$(date +%s)
    AGE=$(( NOW - START_TS ))
    if [ -n "$CUR_URL" ]; then
        if tunnel_alive "$CUR_URL"; then ALIVE=true; else ALIVE=false; fi
    else
        ALIVE=false
    fi
    if [ -z "$CUR_URL" ] || [ "$ALIVE" = false ] || [ "$AGE" -ge "$RENEW_SECS" ]; then
        if renew; then
            LAST_BEAT=$(date +%s)
            continue
        fi
    elif [ $(( NOW - LAST_BEAT )) -ge "$HEARTBEAT_SECS" ]; then
        publish "HEARTBEAT $SERVER_NAME $CUR_URL"
        log "heartbeat: $CUR_URL"
        LAST_BEAT=$NOW
    fi
    sleep 20
done
