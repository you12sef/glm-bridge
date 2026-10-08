#!/usr/bin/env bash
# =============================================================
# glm-bootstrap.sh — Install & start the glm-bridge watchdog on THIS server.
# Part of the "glm-bridge" kit (see README-PROTOCOL.md)
#
# Usage (run as a normal user that owns the SSH account):
#   bash glm-bootstrap.sh <ntfy-topic> [server-name]
# Example:
#   bash glm-bootstrap.sh glmb-fleet-XXXXXXXXXXXX pronet-movies
#
# Requirements: bash, ssh, and (curl OR wget OR python3) for ntfy publishing.
# Idempotent: safe to re-run (repairs / replaces an old watchdog).
# Runs WITHOUT root.
# =============================================================
set -u

TOPIC="${1:-}"
SERVER="${2:-$(hostname)}"
GLM_DIR="$HOME/.glm-bridge"

if [ -z "$TOPIC" ]; then
    echo "usage: $0 <ntfy-topic> [server-name]" >&2
    exit 1
fi

# locate glm-watchdog.sh: next to this script, or already installed
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC=""
for cand in "$HERE/glm-watchdog.sh" "$GLM_DIR/glm-watchdog.sh"; do
    [ -f "$cand" ] && SRC="$cand" && break
done
[ -n "$SRC" ] || { echo "ERROR: glm-watchdog.sh not found next to bootstrap or in $GLM_DIR" >&2; exit 2; }

mkdir -p "$GLM_DIR"

# render watchdog with real topic/server name (tmp then mv: safe re-install)
sed -e "s/__TOPIC__/$TOPIC/" -e "s/__SERVER__/$SERVER/" "$SRC" > "$GLM_DIR/glm-watchdog.sh.tmp"
mv "$GLM_DIR/glm-watchdog.sh.tmp" "$GLM_DIR/glm-watchdog.sh"
chmod +x "$GLM_DIR/glm-watchdog.sh"
cp -f "$SRC" "$GLM_DIR/glm-watchdog.template.sh" 2>/dev/null || true

# stop previous watchdog + all old pinggy tunnels (clean slate)
pkill -f 'glm-watchdog.sh' 2>/dev/null
pkill -f 'ssh -p 443 -R0:127.0.0.1:22' 2>/dev/null
sleep 2

# start watchdog fully detached (survives SSH disconnect)
setsid nohup "$GLM_DIR/glm-watchdog.sh" >> "$GLM_DIR/watchdog.log" 2>&1 < /dev/null &
WD_PID=$!
echo "watchdog started, PID=$WD_PID"

# auto-start on reboot via user crontab (best effort, no root needed)
if command -v crontab >/dev/null 2>&1; then
    ( crontab -l 2>/dev/null | grep -v 'glm-watchdog.sh' ; \
      echo "@reboot $GLM_DIR/glm-watchdog.sh >> $GLM_DIR/watchdog.log 2>&1" ) | crontab - 2>/dev/null \
        && echo "crontab @reboot entry installed"
fi

echo "installed OK"
echo "  dir:   $GLM_DIR"
echo "  topic: $TOPIC"
echo "  state: $GLM_DIR/current.json  (appears ~30-60 s after start)"
