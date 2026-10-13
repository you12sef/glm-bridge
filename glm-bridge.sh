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
#  Dedicated AI user (optional — a separate OS user just for the AI):
#    glm-bridge --ai-user create|status|rotate|lock|unlock|remove
#    glm-bridge --ai-sudo on|off            grant / revoke FULL sudo (loud warning)
#    The AI user authenticates with a PASSWORD that glm-bridge generates and
#    stores in ~/.glm-bridge/ai-user.env (mode 600). --status and --handoff
#    display it, so the owner can paste it to any AI assistant in the chat.
#    Security policy is enforced by the OS permissions of that user itself
#    (no sudo by default, instant lock/remove, every action audited) — no SSH
#    keys are used anywhere in this design.
#    These need root — the script re-runs itself via sudo when you call them.
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
#    * No root needed for the bridge itself; the optional --ai-user /
#      --ai-sudo commands use sudo when YOU run them.
#      Requires: bash, ssh, sed + (openssl or /dev/urandom)
# =====================================================================
set -u
: "${HOME:?ERROR: HOME is not set}"
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"

VERSION="1.0"
SELF="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd)"
WATCHDOG_TEMPLATE="$SCRIPT_DIR/bridge/glm-watchdog.sh"
# When re-executed via sudo (AI-user commands), keep state in the INVOKING
# user's home — not in /root.
REAL_HOME="$HOME"
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    REAL_HOME="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)"
    REAL_HOME="${REAL_HOME:-$HOME}"
fi
GLM_DIR="$REAL_HOME/.glm-bridge"
STATE_FILE="$GLM_DIR/state.env"
BIN_DIR="$REAL_HOME/.local/bin"
BIN_LINK="$BIN_DIR/glm-bridge"
TUNNEL_SIG='ssh -p 443 -R0:127.0.0.1:22'

log()  { echo "[glm-bridge] $*"; }
warn() { echo "[glm-bridge] WARNING: $*" >&2; }
die()  { echo "[glm-bridge] ERROR: $*" >&2; exit 1; }

# ---------- action log (manager-side audit trail) ----------------------
alog() {  # every mutating manager action lands in $GLM_DIR/bridge.log
    mkdir -p "$GLM_DIR" 2>/dev/null || true
    local who="${SUDO_USER:-$(id -un 2>/dev/null || echo unknown)}"
    echo "[$(date '+%F %T')] $who $*" >> "$GLM_DIR/bridge.log" 2>/dev/null || true
    if [ -f "$GLM_DIR/bridge.log" ] \
       && [ "$(wc -c < "$GLM_DIR/bridge.log" 2>/dev/null || echo 0)" -gt 524288 ] 2>/dev/null; then
        tail -n 500 "$GLM_DIR/bridge.log" > "$GLM_DIR/.bridge.log.tmp" 2>/dev/null \
            && mv "$GLM_DIR/.bridge.log.tmp" "$GLM_DIR/bridge.log"
    fi
    return 0
}

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
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        chown "$SUDO_USER" "$STATE_FILE" 2>/dev/null || true
    fi
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
    if [ -f "$REAL_HOME/.bashrc" ] && ! grep -qs '^# >>> glm-bridge >>>$' "$REAL_HOME/.bashrc"; then
        { echo ""
          echo "# >>> glm-bridge >>>"
          echo 'export PATH="$HOME/.local/bin:$PATH"'
          echo "# <<< glm-bridge <<<"
        } >> "$REAL_HOME/.bashrc"
        log "added glm-bridge to PATH — open a new terminal or run: source ~/.bashrc"
    fi
    [ -f "$REAL_HOME/.bashrc" ] || {
        { echo "# >>> glm-bridge >>>"
          echo 'export PATH="$HOME/.local/bin:$PATH"'
          echo "# <<< glm-bridge <<<"
        } > "$REAL_HOME/.bashrc"
    }
    # Non-interactive shells (ssh host 'glm-bridge --status') do NOT source
    # .bashrc — expose the command system-wide when we can (best effort).
    if [ "$(id -u)" -eq 0 ]; then
        ln -sfn "$SELF" /usr/local/bin/glm-bridge 2>/dev/null || true
    elif sudo -n true 2>/dev/null; then
        sudo -n ln -sfn "$SELF" /usr/local/bin/glm-bridge 2>/dev/null || true
    fi
    return 0
}

path_remove() {
    rm -f "$BIN_LINK"
    if [ -f "$REAL_HOME/.bashrc" ]; then
        sed -i '/^# >>> glm-bridge >>>$/,/^# <<< glm-bridge <<<$/d' "$REAL_HOME/.bashrc" 2>/dev/null || true
    fi
    return 0
}

# ---------- crontab: auto-start after reboot --------------------------
cron_add() {
    command -v crontab >/dev/null 2>&1 || { warn "crontab not available — autostart after reboot disabled"; return 0; }
    # Two lines: @reboot (boot-time start) + a */5 supervision entry that
    # restarts the watchdog if the process ever dies silently. The double
    # pgrep + sleep guards against a restart race; the watchdog itself also
    # refuses to run twice (single-instance check).
    if ( crontab -l 2>/dev/null | grep -v 'glm-watchdog.sh'
         echo "@reboot $GLM_DIR/glm-watchdog.sh >> $GLM_DIR/watchdog.log 2>&1"
         echo "*/5 * * * * pgrep -f 'bash[[:space:]]+[^[:space:]]*glm-watchdog\\.sh' >/dev/null 2>&1 || { sleep 15; pgrep -f 'bash[[:space:]]+[^[:space:]]*glm-watchdog\\.sh' >/dev/null 2>&1 || ( setsid nohup $GLM_DIR/glm-watchdog.sh >> $GLM_DIR/watchdog.log 2>&1 < /dev/null & ) ; }"
       ) | crontab - 2>/dev/null; then
        log "autostart after reboot: enabled + runtime supervision every 5 min"
    else
        warn "crontab - failed — autostart/supervision NOT installed (check: crontab -l)"
    fi
    return 0
}

cron_remove() {
    command -v crontab >/dev/null 2>&1 || return 0
    crontab -l 2>/dev/null | grep -q 'glm-watchdog.sh' || return 0
    if ( crontab -l 2>/dev/null | grep -v 'glm-watchdog.sh' ) | crontab - 2>/dev/null; then
        log "autostart after reboot: removed"
    else
        warn "crontab - failed while removing the @reboot entry — verify manually: crontab -l"
    fi
    return 0
}

# ---------- bridge services --------------------------------------------
stop_services() {
    # Match the watchdog daemon only (bash $GLM_DIR/glm-watchdog.sh),
    # NOT editors/pagers/grep that happen to mention the same string.
    # The leading [a-z/]* allows for absolute paths under /home, /bin, etc.
    if pkill -f 'bash[[:space:]]+[^[:space:]]*glm-watchdog\.sh' 2>/dev/null; then
        log "watchdog: stopped"
    else
        log "watchdog: no process found"
    fi
    if pkill -f "$TUNNEL_SIG" 2>/dev/null; then
        log "pinggy tunnel: stopped"
    else
        log "pinggy tunnel: none"
    fi
    # release the watchdog lock so a fresh start can acquire it immediately
    rm -rf "$GLM_DIR/watchdog.lock" "$GLM_DIR/watchdog.lock.dir" 2>/dev/null || true
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

# ---------- dedicated AI user (optional; these commands use sudo) --------
# Password-based design: the AI user owns a generated password stored in
# the state file; access control = the OS permissions of that user itself.
AI_STATE_FILE="$GLM_DIR/ai-user.env"
SSHD_AI_CONF="/etc/ssh/sshd_config.d/glm-bridge-ai.conf"
SSHD_MAIN="/etc/ssh/sshd_config"

require_root() {  # $@ = full glm-bridge args to re-exec with root
    [ "$(id -u)" -eq 0 ] && return 0
    command -v sudo >/dev/null 2>&1 || die "root required and sudo is not available"
    log "this action needs root — re-running via sudo (enter YOUR password if prompted)..."
    exec sudo bash "$SELF" "$@"
}

ai_rand_suffix() {
    local s=""
    command -v openssl >/dev/null 2>&1 && s="$(openssl rand -hex 4 2>/dev/null)"
    [ -n "$s" ] || s="$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
    [ -n "$s" ] && printf '%s' "$s"
    return 0
}

ai_gen_password() {
    local p=""
    command -v openssl >/dev/null 2>&1 && p="$(openssl rand -base64 24 2>/dev/null | tr -dc 'A-Za-z0-9' | cut -c1-20)"
    [ -n "$p" ] || p="$(tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 20)"
    [ -n "$p" ] || die "could not generate a random password"
    printf '%s' "$p"
}

ai_state_load() {
    AI_USER=""; AI_SUDO="off"; AI_CREATED_AT=""; AI_PASS=""
    [ -f "$AI_STATE_FILE" ] && . "$AI_STATE_FILE"
    return 0
}

ai_state_save() {
    mkdir -p "$GLM_DIR" 2>/dev/null || true
    { printf 'AI_USER=%q\n' "$AI_USER"
      printf 'AI_SUDO=%q\n' "$AI_SUDO"
      printf 'AI_CREATED_AT=%q\n' "$AI_CREATED_AT"
      printf 'AI_PASS=%q\n' "$AI_PASS"
    } > "$AI_STATE_FILE"
    chmod 600 "$AI_STATE_FILE" 2>/dev/null || true
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
        chown "$SUDO_USER" "$AI_STATE_FILE" 2>/dev/null || true
    fi
    return 0
}

ai_user_exists() { getent passwd "$1" >/dev/null 2>&1; }

ai_require_user() {
    ai_state_load
    [ -n "$AI_USER" ] || die "no dedicated AI user configured — run: glm-bridge --ai-user create"
    ai_user_exists "$AI_USER" \
        || die "state points to '$AI_USER' but it does not exist — fix: glm-bridge --ai-user remove (then create)"
}

ai_sshd_rule_files_off() {  # remove the glm-bridge ai-user sshd rule (drop-in AND marked block)
    rm -f "$SSHD_AI_CONF" 2>/dev/null || true
    if [ -f "$SSHD_MAIN" ] && grep -qs '^# >>> glm-bridge ai-user >>>$' "$SSHD_MAIN"; then
        sed -i '/^# >>> glm-bridge ai-user >>>$/,/^# <<< glm-bridge ai-user <<<$/d' "$SSHD_MAIN" 2>/dev/null || true
    fi
    return 0
}

ai_sshd_allow_password() {  # ensure sshd accepts PASSWORD auth for the AI user
    # Explicit Match rule so AI login keeps working even if the owner later
    # hardens the GLOBAL sshd config. Replaces any previous glm-bridge rule.
    ai_sshd_rule_files_off
    local rule
    rule="$(printf 'Match User %s\n    PasswordAuthentication yes\n' "$AI_USER")"
    if [ -d /etc/ssh/sshd_config.d ] && grep -Eiq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config.d' "$SSHD_MAIN" 2>/dev/null; then
        printf '%s\n' "$rule" > "$SSHD_AI_CONF"
    else
        cp -f "$SSHD_MAIN" "$SSHD_MAIN.glm-backup" 2>/dev/null || true
        { echo "# >>> glm-bridge ai-user >>>"
          printf '%s\n' "$rule"
          echo "# <<< glm-bridge ai-user <<<"
        } >> "$SSHD_MAIN"
    fi
    if ai_sshd_validate_reload; then
        return 0
    fi
    ai_sshd_rule_files_off
    [ -f "$SSHD_MAIN.glm-backup" ] && cp -f "$SSHD_MAIN.glm-backup" "$SSHD_MAIN"
    warn "sshd config invalid — changes rolled back"
    return 1
}

ai_sshd_validate_reload() {
    command -v sshd >/dev/null 2>&1 || { warn "sshd binary not found — cannot validate config"; return 1; }
    sshd -t 2>/dev/null || { warn "sshd -t: configuration is invalid"; return 1; }
    if command -v systemctl >/dev/null 2>&1; then
        systemctl reload sshd 2>/dev/null || systemctl reload ssh 2>/dev/null || service ssh reload 2>/dev/null || {
            warn "rule applied, but could not reload the ssh service — run: sudo systemctl reload ssh"
            return 0
        }
    else
        service ssh reload 2>/dev/null || warn "rule applied — reload the ssh service manually"
    fi
    return 0
}

ai_cmd_create() {
    require_root --ai-user create
    ai_state_load
    if [ -n "$AI_USER" ] && ai_user_exists "$AI_USER"; then
        die "AI user '$AI_USER' already exists — see: glm-bridge --ai-user status (or remove first)"
    fi
    command -v useradd >/dev/null 2>&1 || die "useradd not found"
    command -v chpasswd >/dev/null 2>&1 || die "chpasswd not found"
    local i suf pass
    AI_USER=""
    for i in 1 2 3; do
        suf="$(ai_rand_suffix)"
        [ -n "$suf" ] || die "could not generate a random suffix"
        ai_user_exists "ai-$suf" || { AI_USER="ai-$suf"; break; }
    done
    [ -n "$AI_USER" ] || die "could not find a free ai-* username"
    pass="$(ai_gen_password)"
    useradd -m -s /bin/bash "$AI_USER" || die "useradd failed for $AI_USER"
    printf '%s:%s\n' "$AI_USER" "$pass" | chpasswd || die "could not set the password"
    # Resolve the actual home directory (some systems use /home/users/* etc.)
    local ai_home
    ai_home="$(getent passwd "$AI_USER" 2>/dev/null | cut -d: -f6)"
    ai_home="${ai_home:-/home/$AI_USER}"
    chmod 750 "$ai_home" 2>/dev/null || true
    AI_SUDO="off"; AI_CREATED_AT="$(date '+%F %T')"; AI_PASS="$pass"
    ai_state_save
    if ai_sshd_allow_password; then
        log "sshd: password auth explicitly allowed for '$AI_USER' (rule: $SSHD_AI_CONF or a marked block)."
    else
        warn "could not assert the sshd allow-rule — AI password login relies on the global sshd config."
    fi
    alog "ai-user create user=$AI_USER"
    echo ""
    echo "=========================================================="
    echo "  DEDICATED AI USER CREATED  (password auth)"
    echo "----------------------------------------------------------"
    echo "  Username : $AI_USER"
    echo "  Password : $pass"
    echo "  Sudo     : OFF   (enable explicitly:  glm-bridge --ai-sudo on)"
    echo "  Home     : $ai_home (mode 750)"
    echo "----------------------------------------------------------"
    echo "  The password is stored in $AI_STATE_FILE (mode 600) and is"
    echo "  displayed by 'glm-bridge --status' and 'glm-bridge --handoff'."
    echo "  Paste username + password to your AI assistant in the CHAT."
    echo "  Security is enforced by the user's OS permissions: no sudo by"
    echo "  default; instant lock/remove via --ai-user lock | remove."
    echo "=========================================================="
}

# ---------- auto-setup: dedicated AI user (password auth) in one shot ----------
# DESIGN: --start on a fresh install creates the dedicated AI user
# automatically (ai-<random> + a generated password). The password is stored
# in ~/.glm-bridge/ai-user.env (mode 600) and displayed by --status and
# --handoff, so the owner can paste username + password to any AI assistant
# in the chat. Access control is enforced by the OS permissions of that user
# (no sudo by default; instant lock/remove) — no SSH keys anywhere.
# Re-running --start reuses an existing AI user; nothing is regenerated.
ai_auto_setup() {
    ai_state_load
    if [ -n "$AI_USER" ] && ai_user_exists "$AI_USER"; then
        log "dedicated AI user already exists: $AI_USER (reusing — password via glm-bridge --status)"
        return 0
    fi
    log "auto-creating dedicated AI user with a generated password ..."

    if [ "$(id -u)" -eq 0 ]; then
        ai_cmd_create
        return $?
    fi

    if sudo -n true 2>/dev/null; then
        sudo -n bash "$SELF" --ai-user create
    else
        log "AI user creation needs root — running via sudo (enter YOUR password if prompted)..."
        if ! sudo bash "$SELF" --ai-user create; then
            warn "AI user auto-setup failed (sudo unavailable?)."
            warn "The bridge is still working. Run this manually later:"
            warn "  glm-bridge --ai-user create"
            return 1
        fi
    fi
    return 0
}

ai_cmd_status() {
    ai_state_load
    echo "=========================================================="
    echo "  GLM-BRIDGE — DEDICATED AI USER (v$VERSION)"
    echo "----------------------------------------------------------"
    if [ -z "$AI_USER" ]; then
        echo "  Not configured."
        echo "  Optional: a separate OS user just for your AI assistant,"
        echo "  so your own password never reaches the AI. Create it:"
        echo "    glm-bridge --ai-user create"
        echo "  (it is also created automatically on the first --start)"
        echo "=========================================================="
        return 0
    fi
    if ! ai_user_exists "$AI_USER"; then
        echo "  Username : $AI_USER  (in state, but MISSING on the system!)"
        echo "  Fix      : glm-bridge --ai-user remove   then create again"
        echo "=========================================================="
        return 0
    fi
    local shell_s groups_s locked="unknown"
    shell_s="$(getent passwd "$AI_USER" 2>/dev/null | cut -d: -f7)"
    groups_s="$(id -nG "$AI_USER" 2>/dev/null | tr ' ' ',')"
    case "$(passwd -S "$AI_USER" 2>/dev/null | awk '{print $2}')" in
        L|LK) locked="locked" ;;
        P|PS) locked="set" ;;
        NP)   locked="not set" ;;
    esac
    echo "  Username : $AI_USER"
    echo "  Created  : ${AI_CREATED_AT:-unknown}"
    echo "  Shell    : $shell_s"
    echo "  Sudo     : $AI_SUDO"
    echo "  Password : ${AI_PASS:-(not stored — run: glm-bridge --ai-user rotate)}"
    echo "             (shadow state: $locked)"
    echo "  Groups   : $groups_s"
    echo "----------------------------------------------------------"
    echo "  rotate password : glm-bridge --ai-user rotate"
    echo "  sudo on/off     : glm-bridge --ai-sudo on|off"
    echo "  lock / remove   : glm-bridge --ai-user lock | remove"
    echo "=========================================================="
    return 0
}

ai_cmd_rotate() {
    require_root --ai-user rotate
    ai_require_user
    local pass
    pass="$(ai_gen_password)"
    printf '%s:%s\n' "$AI_USER" "$pass" | chpasswd || die "could not set the new password"
    AI_PASS="$pass"
    ai_state_save
    ai_sshd_allow_password \
        || warn "password-auth sshd rule could not be re-asserted (check sshd config manually)"
    alog "ai-user rotate user=$AI_USER"
    echo ""
    echo "=========================================================="
    echo "  AI PASSWORD ROTATED"
    echo "----------------------------------------------------------"
    echo "  Username : $AI_USER"
    echo "  Password : $pass"
    echo "----------------------------------------------------------"
    echo "  Stored in $AI_STATE_FILE and shown by --status / --handoff."
    echo "  Paste the new password to your AI assistant in the CHAT."
    echo "=========================================================="
}

ai_cmd_lock() {
    require_root --ai-user lock
    ai_require_user
    local nologin_bin
    nologin_bin="$(command -v nologin 2>/dev/null || printf '/usr/sbin/nologin')"
    usermod -L "$AI_USER" 2>/dev/null || true
    usermod -s "$nologin_bin" "$AI_USER" || die "could not set the nologin shell"
    alog "ai-user lock user=$AI_USER"
    log "AI user '$AI_USER' LOCKED — shell=nologin + password lock: SSH access blocked."
    log "restore access with:  glm-bridge --ai-user unlock"
}

ai_cmd_unlock() {
    require_root --ai-user unlock
    ai_require_user
    usermod -s /bin/bash "$AI_USER" || die "could not restore the shell"
    usermod -U "$AI_USER" 2>/dev/null || true
    alog "ai-user unlock user=$AI_USER"
    log "AI user '$AI_USER' UNLOCKED — shell=bash, password re-enabled."
}

ai_cmd_remove() {
    require_root --ai-user remove
    ai_state_load
    [ -n "$AI_USER" ] || die "no dedicated AI user configured"
    if ! ai_user_exists "$AI_USER"; then
        rm -f "$AI_STATE_FILE"
        log "state pointed to missing user '$AI_USER' — state cleared."
        return 0
    fi
    if [ "${AI_ARGS[0]:-}" != "--yes" ] && [ "$YES" != 1 ]; then
        local ans=""
        printf "[glm-bridge] delete user '%s' AND its home directory? Type the username to confirm: " "$AI_USER"
        read -r ans
        [ "$ans" = "$AI_USER" ] || { log "cancelled."; return 0; }
    fi
    ai_sshd_rule_files_off
    ai_sshd_validate_reload || warn "verify the sshd config manually (sshd -t)"
    alog "ai-user remove user=$AI_USER"
    if userdel -r "$AI_USER" 2>/dev/null; then
        log "user '$AI_USER' deleted (home removed)."
    elif ai_user_exists "$AI_USER"; then
        warn "userdel failed (user logged in?) — '$AI_USER' still exists"
    else
        log "user '$AI_USER' deleted (home was already gone)."
    fi
    rm -f "$AI_STATE_FILE"
    log "AI user state cleared: $AI_STATE_FILE"
    return 0
}

ai_cmd_sudo() {
    local want="${1:-}"
    case "$want" in on|off) ;; *) die "usage: glm-bridge --ai-sudo on|off" ;; esac
    require_root --ai-sudo "$want"
    ai_require_user
    if [ "$want" = "on" ]; then
        getent group sudo >/dev/null 2>&1 || die "no 'sudo' group on this system (non-Debian layout?)"
        if id -nG "$AI_USER" 2>/dev/null | grep -qw sudo; then
            log "AI user '$AI_USER' is already in the sudo group."
        else
            usermod -aG sudo "$AI_USER" || die "could not add $AI_USER to the sudo group"
            log "AI user '$AI_USER' added to the sudo group."
        fi
        AI_SUDO="on"; ai_state_save
        alog "ai-sudo on user=$AI_USER"
        echo ""
        echo "=========================================================="
        echo "  WARNING — SUDO ENABLED FOR THE AI USER"
        echo "----------------------------------------------------------"
        echo "  '$AI_USER' can now run ANY command as root"
        echo "  (sudo <cmd>, authenticated with the AI user's own password)."
        echo "  Extra care: privileged/destructive commands must go through"
        echo "  your approval loop (AI-HANDOFF.md section 10) FIRST."
        echo "  Turn it off any time:  glm-bridge --ai-sudo off"
        echo "=========================================================="
    else
        if id -nG "$AI_USER" 2>/dev/null | grep -qw sudo; then
            gpasswd -d "$AI_USER" sudo 2>/dev/null || deluser "$AI_USER" sudo 2>/dev/null \
                || die "could not remove $AI_USER from the sudo group"
            log "AI user '$AI_USER' removed from the sudo group."
        else
            log "AI user '$AI_USER' was not in the sudo group."
        fi
        AI_SUDO="off"; ai_state_save
        alog "ai-sudo off user=$AI_USER"
        log "sudo: OFF for '$AI_USER'."
    fi
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
    if [ "$fresh" = 1 ]; then
        ai_auto_setup || warn "AI user auto-setup did not complete — bridge still works; run 'glm-bridge --ai-user create' later"
    fi
    stop_services
    rm -f "$GLM_DIR/tunnel_new.log" "$GLM_DIR/current.json" "$GLM_DIR/tunnel.pid"
    launch_watchdog
    cron_add
    if [ "$NO_WAIT" = 1 ]; then
        log "skipping URL wait (--no-wait) — check later: glm-bridge --status"
        return 0
    fi
    # Make it clear the watchdog is detached and Ctrl+C is safe.
    log "watchdog is running detached — Ctrl+C is SAFE; the bridge continues in the background."
    log "watch live progress:  tail -f $GLM_DIR/watchdog.log"
    log "waiting for the first tunnel URL (up to 150 s)..."
    local url
    if url="$(wait_url 30)"; then
        url_parts "$url"
        local conn ssh_user
        ai_state_load
        if [ -n "$AI_USER" ] && ai_user_exists "$AI_USER"; then
            ssh_user="$AI_USER"
        else
            ssh_user="$(id -un 2>/dev/null || printf '%s' "${USER:-unknown}")"
        fi
        conn="ssh -p \"$PORT\" $ssh_user@$HOST"
        cat > "$GLM_DIR/CONNECT.txt" <<EOF
generated : $(date '+%F %T')
topic     : $TOPIC
tunnel    : $url
command   : $conn
password  : glm-bridge --status   (the dedicated AI user's password)
note      : this URL renews every ~50 min — always re-discover via the ntfy topic
EOF
        chmod 600 "$GLM_DIR/CONNECT.txt" 2>/dev/null || true
        echo ""
        echo "=========================================================="
        echo "  GLM-BRIDGE IS RUNNING"
        echo "----------------------------------------------------------"
        echo "  Connection command : $conn"
        echo "  Current URL        : $url"
        echo "  ntfy topic         : $TOPIC"
        echo "  Project            : $SCRIPT_DIR"
        echo "  State dir          : $GLM_DIR"
        if [ -n "$AI_USER" ] && ai_user_exists "$AI_USER"; then
            echo "----------------------------------------------------------"
            echo "  Dedicated AI user  : $AI_USER  (password auth)"
            echo "  AI password        : ${AI_PASS:-(not stored — run: glm-bridge --ai-user rotate)}"
            echo "  Sudo               : ${AI_SUDO:-off}  (security enforced by this user's OS permissions)"
            echo "  The password is also shown by: glm-bridge --status | --handoff"
        fi
        echo "----------------------------------------------------------"
        echo "  From any directory :  glm-bridge --status"
        echo "  Stop               :  glm-bridge --stop"
        echo "  Help               :  glm-bridge --help"
        echo "=========================================================="
    else
        warn "no tunnel URL after 150 s — but the watchdog IS running and will keep trying."
        warn "the URL may arrive in another 1-2 minutes (pinggy can be slow on first connect)."
        warn "to monitor:   tail -f $GLM_DIR/watchdog.log"
        warn "to check now: glm-bridge --status"
        warn "(this exit is NOT an error — the bridge continues in the background)"
        return 0   # was: return 1 — but the bridge IS working, just slow to register
    fi
}

cmd_stop() {
    load_state
    stop_services
    cron_remove
    alog "stop"
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
    local pid="" run_s="stopped" url="" cron_s="disabled" sup_s="disabled" link_s="not installed"
    pid="$(pgrep -f 'bash[[:space:]]+[^[:space:]]*glm-watchdog\.sh' 2>/dev/null | head -1)"
    if [ -n "$pid" ]; then
        run_s="running (PID $pid, up $(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' '))"
    fi
    url="$(grab_url)" || url="unknown yet"
    crontab -l 2>/dev/null | grep -q '^@reboot.*glm-watchdog.sh' && cron_s="enabled"
    crontab -l 2>/dev/null | grep -F '*/5' | grep -q 'glm-watchdog' && sup_s="enabled (every 5 min)"
    [ -L "$BIN_LINK" ] && link_s="installed ($BIN_LINK)"
    ai_state_load
    local ai_s="(none — auto-created on first --start; or run: glm-bridge --ai-user create)"
    local ai_pass="(n/a)" ai_last="(no login yet)" ai_sudo="(n/a)"
    if [ -n "$AI_USER" ]; then
        if ai_user_exists "$AI_USER"; then
            ai_s="$AI_USER (password auth)"
            ai_pass="${AI_PASS:-(not stored — run: glm-bridge --ai-user rotate)}"
            ai_sudo="${AI_SUDO:-off}"
            # Last login (from `last`)
            ai_last="$(last -n 1 "$AI_USER" 2>/dev/null | head -1 | tr -s ' ')"
            [ -n "$ai_last" ] || ai_last="(no login yet)"
        else
            ai_s="$AI_USER (MISSING on system!)"
            ai_pass="—"; ai_last="—"; ai_sudo="—"
        fi
    fi
    echo "=========================================================="
    echo "  GLM-BRIDGE — STATUS (v$VERSION)"
    echo "----------------------------------------------------------"
    echo "  Service            : $run_s"
    echo "  Current URL        : $url"
    echo "  ntfy topic         : ${TOPIC:-(not installed)}"
    echo "  Server name        : ${NAME:-$(hostname)}"
    echo "  Autostart @reboot  : $cron_s"
    echo "  Supervision        : $sup_s"
    echo "  Global command     : $link_s"
    echo "  Project folder     : $SCRIPT_DIR"
    echo "  State dir          : $GLM_DIR"
    echo "----------------------------------------------------------"
    echo "  Dedicated AI user  : $ai_s"
    echo "  AI password        : $ai_pass"
    echo "  Sudo               : $ai_sudo"
    echo "  Last login         : $ai_last"
    echo "----------------------------------------------------------"
    echo "  Live log: tail -f $GLM_DIR/watchdog.log"
    echo "  Action log: $GLM_DIR/bridge.log"
    echo "=========================================================="
    # Append the AI handoff snippet so the user can grab just the part
    # they need to paste in chat for their AI assistant.
    print_handoff_snippet
}

# ---------- handoff snippet (just the lines to paste in chat) ----------
# Detects whether we're running over an SSH session — if so, skip the
# clipboard copy (it would land on the wrong machine anyway). The snippet
# is always printed; the clipboard part is best-effort and local-only.
print_handoff_snippet() {
    load_state
    ai_state_load

    # Compute the AI user info we want to show
    local ai_user_str="(none — run: glm-bridge --ai-user create)"
    local ai_pass_str="(n/a)"

    if [ -n "$AI_USER" ] && ai_user_exists "$AI_USER"; then
        ai_user_str="$AI_USER"
        ai_pass_str="${AI_PASS:-(not stored — run: glm-bridge --ai-user rotate)}"
    fi

    # Build the snippet as a single string (so we can also copy it to clipboard)
    local snip=""
    snip+="=== GLM-BRIDGE AI HANDOFF ==="$'\n'
    snip+="ntfy topic   : ${TOPIC:-(not installed)}"$'\n'
    snip+="AI username  : $ai_user_str"$'\n'
    snip+="AI password  : $ai_pass_str"$'\n'
    snip+="============================="$'\n'
    snip+="Discover the live URL via the ntfy topic (AI-HANDOFF.md §4)."$'\n'
    snip+="Connect with paramiko: c.connect(host, port, username='$ai_user_str',"$'\n'
    snip+="  password='$ai_pass_str', allow_agent=False, look_for_keys=False)"

    # Print the snippet
    echo ""
    echo "###### AI HANDOFF SNIPPET — paste this in chat for your AI ######"
    printf '%s\n' "$snip"
    echo "################################################################"

    # Smart clipboard copy: only if we're NOT in an SSH session
    # (otherwise the clipboard is the server's, not the user's local machine)
    if [ -z "${SSH_CONNECTION:-}${SSH_CLIENT:-}${SSH_TTY:-}" ]; then
        local clip_tool=""
        for t in xclip xsel pbcopy wl-copy; do
            if command -v "$t" >/dev/null 2>&1; then
                clip_tool="$t"
                break
            fi
        done
        if [ -n "$clip_tool" ]; then
            case "$clip_tool" in
                xclip)        printf '%s' "$snip" | xclip -selection clipboard 2>/dev/null && echo "[copied to clipboard via xclip]" ;;
                xsel)         printf '%s' "$snip" | xsel --clipboard --input 2>/dev/null && echo "[copied to clipboard via xsel]" ;;
                pbcopy)       printf '%s' "$snip" | pbcopy 2>/dev/null && echo "[copied to clipboard via pbcopy]" ;;
                wl-copy)      printf '%s' "$snip" | wl-copy 2>/dev/null && echo "[copied to clipboard via wl-copy]" ;;
            esac
        else
            echo "[no clipboard tool found — copy the snippet manually]"
        fi
    else
        # We're inside SSH — don't try to copy
        echo "[SSH session detected — clipboard copy skipped; copy the snippet manually]"
    fi
}

cmd_new_topic() {
    load_state
    [ -n "${TOPIC:-}" ] || die "not installed yet — run --start first"
    [ -n "${NAME:-}" ] || NAME="$(hostname)"
    TOPIC="$(gen_topic)"
    INSTALLED_AT="$(date '+%F %T')"
    save_state
    alog "new-topic topic=$TOPIC"
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
    ai_state_load
    local ans=""
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
    alog "uninstall purge=$PURGE"
    if [ -n "${AI_USER:-}" ] && ai_user_exists "$AI_USER"; then
        log "AI user '$AI_USER' is left in place — remove it with:  glm-bridge --ai-user remove"
    fi
    if [ -d "$GLM_DIR" ]; then
        rm -rf "$GLM_DIR"
        log "state dir removed: $GLM_DIR"
    fi
    log "topic ${TOPIC:-(unknown)} is now dead — if your AI still listens to it, tell it in the chat."
    if [ "$PURGE" = 1 ]; then
        log "removing project folder: $SCRIPT_DIR"
        cd "$REAL_HOME" || exit 1
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
  bash glm-bridge.sh --install      alias for --start
  bash glm-bridge.sh --stop         full stop
  bash glm-bridge.sh --status       show status (+ AI handoff snippet at the end)
  bash glm-bridge.sh --handoff      print ONLY the AI handoff snippet (paste-ready)
  bash glm-bridge.sh --restart      restart
  bash glm-bridge.sh --new-topic    new topic (tell your AI assistant!)
  bash glm-bridge.sh --uninstall    remove integration (keeps project folder)
  bash glm-bridge.sh --purge        remove + delete the project folder
  bash glm-bridge.sh --help         this help

  Ctrl+C during --start is SAFE — the watchdog runs detached and keeps trying
  to obtain a tunnel URL. Check progress with: glm-bridge --status

Dedicated AI user (password auth; uses sudo when YOU run these):
  --start                               also auto-creates an ai-<random> user
                                         with a generated password on FIRST install
  glm-bridge --ai-user create         new user ai-<random> + generated password
  glm-bridge --ai-user status         AI user details + the current password
  glm-bridge --ai-user rotate         new password for the AI user
  glm-bridge --ai-user lock|unlock    instantly block / restore AI SSH access
  glm-bridge --ai-user remove         delete the AI user and its home (--yes skips)
  glm-bridge --ai-sudo on|off         grant / revoke FULL sudo for the AI user
  glm-bridge --status                 shows the AI username, its password,
                                       sudo state, supervision state,
                                       and last login

Flags: --yes (skip prompts) | --no-wait (skip URL wait)
       --name X (server name, first install) | --topic X (force topic, first install)

After the first --start the command works from any directory:
  glm-bridge --status   |   glm-bridge --stop   |   glm-bridge --help
EOF
}

# ---------- argument parsing ---------------------------------------------
ACTION=""; PURGE=0; YES=0; NO_WAIT=0; BRIDGE_NAME=""; FORCED_TOPIC=""
AI_SUB=""; AI_ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --start|start|--install|install)  ACTION="start" ;;
        --stop|stop)           ACTION="stop" ;;
        --status|status)       ACTION="status" ;;
        --handoff|handoff)     ACTION="handoff" ;;
        --restart|restart)     ACTION="restart" ;;
        --new-topic|new-topic) ACTION="new-topic" ;;
        --uninstall|uninstall) ACTION="uninstall" ;;
        --purge)               ACTION="uninstall"; PURGE=1 ;;
        --yes|-y)              YES=1 ;;
        --no-wait)             NO_WAIT=1 ;;
        --name)                [ -n "${2:-}" ] || die "--name needs a value"; BRIDGE_NAME="$2"; shift ;;
        --topic)               [ -n "${2:-}" ] || die "--topic needs a value"; FORCED_TOPIC="$2"; shift ;;
        --ai-user)
            [ -n "${2:-}" ] || die "--ai-user needs a subcommand (create|status|rotate|lock|unlock|remove)"
            ACTION="ai-user"; AI_SUB="$2"; shift 2; AI_ARGS=("$@"); break ;;
        --ai-sudo)
            [ -n "${2:-}" ] || die "--ai-sudo needs on or off"
            ACTION="ai-sudo"; AI_SUB="$2"; shift 2; AI_ARGS=("$@"); break ;;
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
    handoff)   print_handoff_snippet ;;
    restart)   log "restarting..."; cmd_start ;;
    new-topic) cmd_new_topic ;;
    uninstall) cmd_uninstall ;;
    ai-user)
        case "$AI_SUB" in
            create)   ai_cmd_create ;;
            status)   ai_cmd_status ;;
            rotate)   ai_cmd_rotate ;;
            lock)     ai_cmd_lock ;;
            unlock)   ai_cmd_unlock ;;
            remove)   ai_cmd_remove ;;
            *) die "unknown --ai-user subcommand: $AI_SUB (try --help)" ;;
        esac ;;
    ai-sudo)   ai_cmd_sudo "$AI_SUB" ;;
esac
