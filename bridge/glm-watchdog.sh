#!/usr/bin/env bash
# =============================================================
# glm-watchdog.sh — Pinggy tunnel auto-renewal daemon
# Part of the "glm-bridge" kit (see README.md)
#
# Job:
#   - Maintain ONE pinggy free tunnel: ssh -p 443 -R0:127.0.0.1:22 tcp@free.pinggy.io
#   - Renew it every RENEW_SECS (default 50 min, before the 60 min free limit)
#   - Publish the current URL to an ntfy.sh topic (RENEW / HEARTBEAT messages)
#   - Write local state to ~/.glm-bridge/current.json
#
# Reliability:
#   - Logs its own exit (trap on INT/TERM/EXIT) — a watchdog death is never
#     silent in watchdog.log.
#   - Failed ntfy publishes are logged with the HTTP code / error class.
#   - Single-instance check: a second watchdog started by accident (cron
#     supervision race, manual double-start) exits immediately.
#   - watchdog.log is self-trimmed so it cannot grow unbounded.
#
# Runs WITHOUT root. Placeholders __TOPIC__ / __SERVER__ are replaced by
# glm-bridge.sh (render_watchdog) or glm-bootstrap.sh.
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

# ---- single instance: lock-file arbitration (can never match itself) ----
# Why not pgrep? A "$(pgrep -f ...)" check forks a command-substitution
# subshell whose argv is an exact copy of this script's argv, so pgrep
# always "finds" that sibling and EVERY watchdog would exit at startup
# (the cron supervisor would then relaunch it every 5 min — same death).
# A lock cannot lie: the kernel releases flock the instant the holder
# dies (any signal, even kill -9); the mkdir fallback + pid check covers
# systems without flock and stale locks.
MYPID=$$ LOCK="$GLM_DIR/watchdog.lock"
GLM_LOCKED=""
if command -v flock >/dev/null 2>&1 && [ -w "$GLM_DIR" ]; then
    exec 9>>"$LOCK" 2>/dev/null
    if flock -n 9 2>/dev/null; then
        GLM_LOCKED="flock"
    else
        exec 9>&- 2>/dev/null || true
    fi
fi
if [ -z "$GLM_LOCKED" ]; then
    if ! mkdir "$LOCK.dir" 2>/dev/null; then
        _oldpid="$(head -1 "$LOCK.dir/pid" 2>/dev/null || true)"
        if [ -n "$_oldpid" ] && ! kill -0 "$_oldpid" 2>/dev/null; then
            rm -rf "$LOCK.dir"
            mkdir "$LOCK.dir" 2>/dev/null || true
        fi
    fi
    if mkdir "$LOCK.dir" 2>/dev/null; then
        GLM_LOCKED="mkdir"
    else
        _oldpid="$(head -1 "$LOCK.dir/pid" 2>/dev/null || head -1 "$LOCK" 2>/dev/null || true)"
        log "another watchdog holds the lock (pid ${_oldpid:-unknown}) — this one exits"
        exit 0
    fi
fi
printf '%s
' "$MYPID" > "$LOCK" 2>/dev/null || true
if [ "$GLM_LOCKED" = "mkdir" ]; then
    printf '%s
' "$MYPID" > "$LOCK.dir/pid" 2>/dev/null || true
fi

# ---- exit logging: a watchdog death is never silent ---------------------
GLM_EXIT_REASON="normal run ended"
trap 'GLM_EXIT_REASON="SIGINT (Ctrl+C)"; exit 0' INT
trap 'GLM_EXIT_REASON="SIGTERM (stopped or killed)"; exit 0' TERM
trap 'rm -rf "$GLM_DIR/watchdog.lock.dir" 2>/dev/null; log "watchdog exiting — reason: $GLM_EXIT_REASON"' EXIT

publish() { # $1 = message body — failures are LOGGED, never swallowed
    local msg="$1" rc=""
    if command -v curl >/dev/null 2>&1; then
        rc="$(curl -s -m 15 -o /dev/null -w '%{http_code}' \
              -H "Title: glm-bridge $SERVER_NAME" -d "$msg" \
              "https://ntfy.sh/$NTFY_TOPIC" 2>/dev/null)"
        case "${rc:-}" in
            2??) : ;;
            "")  log "PUBLISH-FAIL: no response from ntfy (network down?) msg='${msg}'" ;;
            *)   log "PUBLISH-FAIL: http=${rc} msg='${msg}'" ;;
        esac
    elif command -v wget >/dev/null 2>&1; then
        if ! wget -q -T 15 --header="Title: glm-bridge $SERVER_NAME" \
             --post-data="$msg" "https://ntfy.sh/$NTFY_TOPIC" >/dev/null 2>&1; then
            log "PUBLISH-FAIL: wget error msg='${msg}'"
        fi
    elif command -v python3 >/dev/null 2>&1; then
        if ! NTFY_TOPIC="$NTFY_TOPIC" SERVER_NAME="$SERVER_NAME" msg="$msg" python3 - <<'PY' >/dev/null 2>&1
import os, urllib.request
topic = os.environ["NTFY_TOPIC"]
req = urllib.request.Request(
    "https://ntfy.sh/" + topic,
    data=os.environ["msg"].encode(),
    headers={"Title": "glm-bridge " + os.environ["SERVER_NAME"]},
)
urllib.request.urlopen(req, timeout=15)
PY
        then
            log "PUBLISH-FAIL: python3 error msg='${msg}'"
        fi
    else
        log "WARN: no curl/wget/python3 — cannot publish to ntfy"
    fi
}

tunnel_alive() { # $1 = tcp://host:port
    local hostport="${1#tcp://}" host port
    host="${hostport%%:*}"; port="${hostport##*:}"
    timeout 8 bash -c "echo >/dev/tcp/$host/$port" 2>/dev/null
}

trim_logs() { # keep watchdog.log bounded (tail+mv is safe: log() reopens per write)
    if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 2097152 ]; then
        tail -n 1000 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
        log "watchdog.log trimmed (was > 2 MB)"
    fi
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
HOUSE=0
log "===== watchdog started: server=$SERVER_NAME topic=$NTFY_TOPIC pid=$$ ====="
publish "WATCHDOG-START $SERVER_NAME on $(hostname)"
while true; do
    HOUSE=$((HOUSE + 1))
    if [ $((HOUSE % 60)) -eq 0 ]; then   # ~every 20 min
        trim_logs
    fi
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
