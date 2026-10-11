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
#    glm-bridge --ai-user create|status|rotate|lock|unlock|remove|key-only
#    glm-bridge --ai-sudo on|off            grant / revoke FULL sudo (loud warning)
#    glm-bridge --ai-key add <file|-> | list | revoke <fp>
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
#      --ai-sudo / --ai-key commands use sudo when YOU run them.
#      Requires: bash, ssh, sed + (openssl or /dev/urandom)
# =====================================================================
set -u
: "${HOME:?ERROR: HOME is not set}"
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"

VERSION="2.2"
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
    if ( crontab -l 2>/dev/null | grep -v 'glm-watchdog.sh'
         echo "@reboot $GLM_DIR/glm-watchdog.sh >> $GLM_DIR/watchdog.log 2>&1" ) | crontab - 2>/dev/null; then
        log "autostart after reboot: enabled"
    else
        warn "crontab - failed — autostart after reboot NOT installed (check: crontab -l)"
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
    AI_USER=""; AI_SUDO="off"; AI_CREATED_AT=""; AI_KEY_ONLY="off"; AI_KEY_PATH=""
    [ -f "$AI_STATE_FILE" ] && . "$AI_STATE_FILE"
    return 0
}

ai_state_save() {
    mkdir -p "$GLM_DIR" 2>/dev/null || true
    { printf 'AI_USER=%q\n' "$AI_USER"
      printf 'AI_SUDO=%q\n' "$AI_SUDO"
      printf 'AI_CREATED_AT=%q\n' "$AI_CREATED_AT"
      printf 'AI_KEY_ONLY=%q\n' "$AI_KEY_ONLY"
      printf 'AI_KEY_PATH=%q\n' "$AI_KEY_PATH"
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

ai_ak_file() {
    # Resolve the AI user's home dir from /etc/passwd instead of assuming
    # /home/$AI_USER — some systems use /home/users/*, /var/lib/*, etc.
    local home_dir
    home_dir="$(getent passwd "$1" 2>/dev/null | cut -d: -f6)"
    [ -n "$home_dir" ] || home_dir="/home/$1"
    printf '%s/.ssh/authorized_keys' "$home_dir"
}

ai_key_only_files_off() {  # remove the rule from the drop-in AND from a marked block
    rm -f "$SSHD_AI_CONF" 2>/dev/null || true
    if [ -f "$SSHD_MAIN" ] && grep -qs '^# >>> glm-bridge ai-user >>>$' "$SSHD_MAIN"; then
        sed -i '/^# >>> glm-bridge ai-user >>>$/,/^# <<< glm-bridge ai-user <<<$/d' "$SSHD_MAIN" 2>/dev/null || true
    fi
    return 0
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
    AI_SUDO="off"; AI_CREATED_AT="$(date '+%F %T')"; AI_KEY_ONLY="off"
    ai_state_save
    echo ""
    echo "=========================================================="
    echo "  DEDICATED AI USER CREATED"
    echo "----------------------------------------------------------"
    echo "  Username : $AI_USER"
    echo "  Password : $pass"
    echo "  Sudo     : OFF   (enable explicitly:  glm-bridge --ai-sudo on)"
    echo "  Home     : $ai_home (mode 750)"
    echo "----------------------------------------------------------"
    echo "  The password is shown ONCE — it lives only in /etc/shadow."
    echo "  PREFERRED: switch to key auth:"
    echo "    glm-bridge --ai-key add <pubkey-file>"
    echo "  If you keep password auth: paste the username + password"
    echo "  to your AI assistant in the CHAT (never into a file)."
    echo "=========================================================="
}

# ---------- auto-setup: keypair + user + key-only in one shot ----------
# DESIGN (v2.3): the PRIVATE key is generated in the AI SANDBOX (not on the
# server) at ~/.glm_keys/ai-key. Only the PUBLIC key is uploaded to the server
# and installed into the AI user's authorized_keys. This way every new AI
# session can connect using the same local private key without re-generating.
#
# Called from cmd_start() on a fresh install.
#
# The sandbox invokes this helper which:
#   1. Ensures ~/.glm_keys/ai-key exists locally (generates if missing).
#   2. Uploads ~/.glm_keys/ai-key.pub to the server via SFTP to a temp file.
#   3. Re-execs the script on the server via sudo to run ai_do_auto_install
#      with that temp file as the public key.
#
# When --start is invoked directly on the server (not from a sandbox), the
# keypair is still generated locally on that machine and the private key stays
# there — the user is responsible for copying it to their AI sandbox once.
ai_auto_setup() {
    log "auto-creating dedicated AI user with keypair (no password) ..."

    # 1. Generate keypair LOCALLY (in the caller's home, not on the server).
    #    For an AI sandbox this is ~/.glm_keys/ai-key; for a manual --start
    #    on the server it is also ~/.glm_keys/ai-key on that host.
    local keys_dir="$REAL_HOME/.glm_keys"
    mkdir -p "$keys_dir" 2>/dev/null || true
    if [ ! -f "$keys_dir/ai-key" ]; then
        command -v ssh-keygen >/dev/null 2>&1 \
            || die "ssh-keygen not found — required for AI user auto-setup. Install openssh-client."
        ssh-keygen -t ed25519 -f "$keys_dir/ai-key" -N "" \
            -C "glm-ai@$(hostname)-$(date +%s)" >/dev/null 2>&1 \
            || die "ssh-keygen failed"
        chmod 600 "$keys_dir/ai-key"
        chmod 644 "$keys_dir/ai-key.pub"
        log "AI keypair generated locally: $keys_dir/ai-key (private, stays here) + .pub (public)"
    else
        log "AI keypair already exists locally: $keys_dir/ai-key (reusing)"
    fi

    # 2. Stage the public key for the server-side installer.
    #    If we are on the server already, just use the file directly.
    #    If we are in a sandbox, the caller (an external script) is expected
    #    to upload $keys_dir/ai-key.pub to the server first; this function
    #    will then read it via SFTP from a known temp path. For the in-server
    #    --start path, we just use the local file.
    local pub_local="$keys_dir/ai-key.pub"
    local pub_remote="$GLM_DIR/ai-key.pub"   # used when --start runs on the server

    # Copy the public key into $GLM_DIR so ai_do_auto_install can read it
    # (whether called directly here or via sudo re-exec).
    mkdir -p "$GLM_DIR" 2>/dev/null || true
    cp -f "$pub_local" "$pub_remote" 2>/dev/null || true
    chmod 644 "$pub_remote" 2>/dev/null || true

    # 3. Install via sudo (subprocess — control returns here).
    if [ "$(id -u)" -eq 0 ]; then
        ai_do_auto_install "$pub_remote"
        return $?
    fi

    if sudo -n true 2>/dev/null; then
        sudo -n bash "$SELF" --ai-auto-install "$pub_remote"
    else
        log "AI user creation needs root — running via sudo (enter YOUR password if prompted)..."
        if ! sudo bash "$SELF" --ai-auto-install "$pub_remote"; then
            warn "AI user auto-install failed (sudo unavailable?)."
            warn "The bridge is still working. Run this manually later:"
            warn "  sudo bash $SELF --ai-auto-install $pub_remote"
            return 1
        fi
    fi
    return 0
}

# Internal: runs AS ROOT (re-execed via sudo). Creates ai-<rand> user with
# NO password, installs the given public key, and applies key-only sshd rule.
# $1 = path to public key file (on this machine)
# AI_KEY_PATH is recorded as the SANDBOX-side path so the AI knows where to
# look — it is informational only; the private key never lives on the server.
ai_do_auto_install() {
    local pubfile="${1:-}"
    [ -n "$pubfile" ] || die "--ai-auto-install needs a public key file path"
    [ -r "$pubfile" ] || die "cannot read public key: $pubfile"

    ai_state_load
    if [ -n "$AI_USER" ] && ai_user_exists "$AI_USER"; then
        log "AI user '$AI_USER' already exists — skipping auto-install"
        log "  (to recreate: glm-bridge --ai-user remove, then re-run --start or --ai-auto-install $pubfile)"
        return 0
    fi

    command -v useradd >/dev/null 2>&1 || die "useradd not found (need root)"
    local i suf
    AI_USER=""
    for i in 1 2 3; do
        suf="$(ai_rand_suffix)"
        [ -n "$suf" ] || die "could not generate a random suffix"
        ai_user_exists "ai-$suf" || { AI_USER="ai-$suf"; break; }
    done
    [ -n "$AI_USER" ] || die "could not find a free ai-* username"

    # Create user WITHOUT a password (locked from day one — key auth only).
    useradd -m -s /bin/bash "$AI_USER" || die "useradd failed for $AI_USER"
    passwd -l "$AI_USER" >/dev/null 2>&1 || true   # belt & suspenders

    local ai_home
    ai_home="$(getent passwd "$AI_USER" 2>/dev/null | cut -d: -f6)"
    ai_home="${ai_home:-/home/$AI_USER}"
    chmod 750 "$ai_home" 2>/dev/null || true

    # Install the public key into ~/.ssh/authorized_keys
    local sshd_dir akf
    sshd_dir="$ai_home/.ssh"
    akf="$(ai_ak_file "$AI_USER")"
    install -d -m 700 "$sshd_dir" 2>/dev/null || { mkdir -p "$sshd_dir"; chmod 700 "$sshd_dir"; }
    chown "$AI_USER" "$sshd_dir" 2>/dev/null || true
    cp -f "$pubfile" "$akf"
    chmod 600 "$akf"
    chown "$AI_USER" "$akf" 2>/dev/null || true

    # Save state BEFORE touching sshd (so we know who to clean up if it fails)
    AI_SUDO="off"; AI_CREATED_AT="$(date '+%F %T')"; AI_KEY_ONLY="off"
    # AI_KEY_PATH is the SANDBOX-side path (informational; the private key
    # never lives on the server). We use the conventional sandbox location.
    AI_KEY_PATH="$REAL_HOME/.glm_keys/ai-key"
    ai_state_save

    # Apply key-only sshd rule (inline of ai_cmd_key_only to avoid extra calls)
    if [ -d /etc/ssh/sshd_config.d ] && grep -Eiq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config.d' "$SSHD_MAIN" 2>/dev/null; then
        printf 'Match User %s\n    PasswordAuthentication no\n    KbdInteractiveAuthentication no\n' "$AI_USER" > "$SSHD_AI_CONF"
    else
        cp -f "$SSHD_MAIN" "$SSHD_MAIN.glm-backup" 2>/dev/null || true
        { echo "# >>> glm-bridge ai-user >>>"
          printf 'Match User %s\n    PasswordAuthentication no\n    KbdInteractiveAuthentication no\n' "$AI_USER"
          echo "# <<< glm-bridge ai-user <<<"
        } >> "$SSHD_MAIN"
    fi
    if ai_sshd_validate_reload; then
        AI_KEY_ONLY="on"; ai_state_save
        log "key-only SSH enabled for '$AI_USER' — sshd rejects passwords for this user."
    else
        ai_key_only_files_off
        [ -f "$SSHD_MAIN.glm-backup" ] && cp -f "$SSHD_MAIN.glm-backup" "$SSHD_MAIN"
        die "sshd config invalid — changes rolled back. AI user '$AI_USER' was created but key-only NOT applied."
    fi

    local fp
    fp="$(ssh-keygen -lf "$pubfile" 2>/dev/null | awk '{print $2" "$4}')"
    echo ""
    echo "=========================================================="
    echo "  DEDICATED AI USER CREATED  (key-based, no password)"
    echo "----------------------------------------------------------"
    echo "  Username        : $AI_USER"
    echo "  Auth mode       : SSH key only (password locked)"
    echo "  Public key      : $akf  (on the server)"
    echo "  Private key     : $AI_KEY_PATH  (in the AI SANDBOX — never on the server)"
    echo "  Key fingerprint : $fp"
    echo "  Sudo            : OFF   (enable:  glm-bridge --ai-sudo on)"
    echo "  Home            : $ai_home (mode 750)"
    echo "----------------------------------------------------------"
    echo "  HOW THE AI CONNECTS (the private key is already in its sandbox):"
    echo "    paramiko: c.connect(host, port, username='$AI_USER',"
    echo "              key_filename='$AI_KEY_PATH',"
    echo "              allow_agent=False, look_for_keys=False)"
    echo "  Verify the fingerprint matches what paramiko reports on first connect."
    echo "=========================================================="
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
        echo "=========================================================="
        return 0
    fi
    if ! ai_user_exists "$AI_USER"; then
        echo "  Username : $AI_USER  (in state, but MISSING on the system!)"
        echo "  Fix      : glm-bridge --ai-user remove   then create again"
        echo "=========================================================="
        return 0
    fi
    local shell_s groups_s locked="unknown" keys_s=""
    shell_s="$(getent passwd "$AI_USER" 2>/dev/null | cut -d: -f7)"
    groups_s="$(id -nG "$AI_USER" 2>/dev/null | tr ' ' ',')"
    case "$(passwd -S "$AI_USER" 2>/dev/null | awk '{print $2}')" in
        L|LK) locked="locked" ;;
        P|PS) locked="set" ;;
        NP)   locked="not set" ;;
    esac
    if [ -r "$(ai_ak_file "$AI_USER")" ]; then
        keys_s="$(grep -cE '^(ssh-|ecdsa-sha2-|sk-)' "$(ai_ak_file "$AI_USER")" 2>/dev/null)"
    elif [ "$(id -u)" -eq 0 ] || sudo -n true 2>/dev/null; then
        keys_s="$(sudo -n grep -cE '^(ssh-|ecdsa-sha2-|sk-)' "$(ai_ak_file "$AI_USER")" 2>/dev/null)"
    fi
    keys_s="${keys_s:-run with sudo to see}"
    echo "  Username : $AI_USER"
    echo "  Created  : ${AI_CREATED_AT:-unknown}"
    echo "  Shell    : $shell_s"
    echo "  Sudo     : $AI_SUDO"
    echo "  Key-only : $AI_KEY_ONLY"
    echo "  Password : $locked"
    echo "  SSH keys : $keys_s"
    echo "  Groups   : $groups_s"
    echo "----------------------------------------------------------"
    echo "  rotate password : glm-bridge --ai-user rotate"
    echo "  sudo on/off     : glm-bridge --ai-sudo on|off"
    echo "  keys            : glm-bridge --ai-key add|list|revoke"
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
    echo ""
    echo "=========================================================="
    echo "  AI PASSWORD ROTATED"
    echo "----------------------------------------------------------"
    echo "  Username : $AI_USER"
    echo "  Password : $pass   <- shown ONCE"
    echo "----------------------------------------------------------"
    echo "  Send the new password to your AI in the CHAT,"
    echo "  or better — move to key auth:  glm-bridge --ai-key add <pubkey>"
    echo "=========================================================="
}

ai_cmd_lock() {
    require_root --ai-user lock
    ai_require_user
    local nologin_bin
    nologin_bin="$(command -v nologin 2>/dev/null || printf '/usr/sbin/nologin')"
    usermod -L "$AI_USER" 2>/dev/null || true
    usermod -s "$nologin_bin" "$AI_USER" || die "could not set the nologin shell"
    log "AI user '$AI_USER' LOCKED — shell=nologin + password lock: SSH access blocked (keys too)."
    log "restore access with:  glm-bridge --ai-user unlock"
}

ai_cmd_unlock() {
    require_root --ai-user unlock
    ai_require_user
    usermod -s /bin/bash "$AI_USER" || die "could not restore the shell"
    usermod -U "$AI_USER" 2>/dev/null || true
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
    if [ "$AI_KEY_ONLY" = "on" ]; then
        ai_key_only_files_off
        ai_sshd_validate_reload || warn "verify the sshd config manually (sshd -t)"
    fi
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
        log "sudo: OFF for '$AI_USER'."
    fi
}

ai_key_add() {
    local src="${1:-}"
    [ -n "$src" ] || die "usage: glm-bridge --ai-key add <pubkey-file|->   ('-' = read stdin)"
    require_root --ai-key add "$src"
    ai_require_user
    local line
    if [ "$src" = "-" ]; then
        line="$(cat)"
    else
        [ -r "$src" ] || die "cannot read $src"
        line="$(head -n1 "$src")"
    fi
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    case "$line" in
        ssh-ed25519\ AAAA*|ssh-rsa\ AAAA*|ecdsa-sha2-*\ AAAA*|sk-ssh-ed25519@openssh.com\ AAAA*|sk-ecdsa-sha2-nistp256@openssh.com\ AAAA*) ;;
        *) die "not an OpenSSH public key (expected: ssh-ed25519 AAAA... [comment])" ;;
    esac
    local sshd_dir akf
    # Resolve actual home dir (some systems use /home/users/* etc.)
    sshd_dir="$(getent passwd "$AI_USER" 2>/dev/null | cut -d: -f6)"
    sshd_dir="${sshd_dir:-/home/$AI_USER}/.ssh"
    akf="$(ai_ak_file "$AI_USER")"
    install -d -m 700 "$sshd_dir" 2>/dev/null || { mkdir -p "$sshd_dir"; chmod 700 "$sshd_dir"; }
    chown "$AI_USER" "$sshd_dir" 2>/dev/null || true
    if [ -f "$akf" ] && grep -qxF "$line" "$akf" 2>/dev/null; then
        log "key already installed for '$AI_USER' — nothing to do."
    else
        printf '%s\n' "$line" >> "$akf"
        chmod 600 "$akf"
        chown "$AI_USER" "$akf" 2>/dev/null || true
        log "public key installed for '$AI_USER'."
    fi
    ssh-keygen -lf "$akf" 2>/dev/null | sed 's/^/  /'
    log "this key now authenticates '$AI_USER' over SSH — no password needed."
}

ai_key_list() {
    ai_require_user
    local akf; akf="$(ai_ak_file "$AI_USER")"
    echo "=========================================================="
    echo "  SSH KEYS for AI user '$AI_USER'"
    echo "----------------------------------------------------------"
    if [ -r "$akf" ]; then
        ssh-keygen -lf "$akf" 2>/dev/null | sed 's/^/  /'
    elif [ "$(id -u)" -eq 0 ] || sudo -n true 2>/dev/null; then
        sudo -n ssh-keygen -lf "$akf" 2>/dev/null | sed 's/^/  /'
    else
        echo "  authorized_keys not readable without root — re-run with sudo."
    fi
    echo "=========================================================="
    return 0
}

ai_key_revoke() {
    local fp="${1:-}"
    [ -n "$fp" ] || die "usage: glm-bridge --ai-key revoke <fingerprint-prefix>   (see: --ai-key list)"
    require_root --ai-key revoke "$fp"
    ai_require_user
    local akf tmpf newf ltmp removed=0 fpline
    akf="$(ai_ak_file "$AI_USER")"
    [ -r "$akf" ] || die "cannot read $akf (no keys installed?)"
    tmpf="$(mktemp)"; newf="$(mktemp)"; ltmp="$(mktemp)"
    cp -f "$akf" "$tmpf"
    while IFS= read -r l; do
        [ -z "$l" ] && continue
        printf '%s\n' "$l" > "$ltmp"
        fpline="$(ssh-keygen -lf "$ltmp" 2>/dev/null || true)"
        if printf '%s' "$fpline" | grep -qi "$fp"; then
            removed=$((removed + 1))
            printf '  removed: %s\n' "$fpline"
        else
            printf '%s\n' "$l" >> "$newf"
        fi
    done < "$tmpf"
    rm -f "$ltmp"
    if [ "$removed" -eq 0 ]; then
        rm -f "$tmpf" "$newf"
        log "no key matches '$fp' — nothing removed."
        return 0
    fi
    cat "$newf" > "$akf"
    chmod 600 "$akf"
    chown "$AI_USER" "$akf" 2>/dev/null || true
    rm -f "$tmpf" "$newf"
    log "$removed key(s) revoked for '$AI_USER'."
}

ai_cmd_key() {
    local sub="${1:-}"; shift 2>/dev/null || true
    case "$sub" in
        add)    ai_key_add "$@" ;;
        list)   ai_key_list ;;
        revoke) ai_key_revoke "$@" ;;
        *) die "usage: glm-bridge --ai-key add <pubkey-file|-> | list | revoke <fp>" ;;
    esac
}

ai_cmd_key_only() {
    local want="${AI_ARGS[0]:-on}"
    case "$want" in on|off) ;; *) die "usage: glm-bridge --ai-user key-only on|off" ;; esac
    require_root --ai-user key-only "$want"
    ai_require_user
    if [ "$want" = "on" ]; then
        if [ -d /etc/ssh/sshd_config.d ] && grep -Eiq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config.d' "$SSHD_MAIN" 2>/dev/null; then
            printf 'Match User %s\n    PasswordAuthentication no\n    KbdInteractiveAuthentication no\n' "$AI_USER" > "$SSHD_AI_CONF"
        else
            cp -f "$SSHD_MAIN" "$SSHD_MAIN.glm-backup" 2>/dev/null || true
            { echo "# >>> glm-bridge ai-user >>>"
              printf 'Match User %s\n    PasswordAuthentication no\n    KbdInteractiveAuthentication no\n' "$AI_USER"
              echo "# <<< glm-bridge ai-user <<<"
            } >> "$SSHD_MAIN"
        fi
        if ai_sshd_validate_reload; then
            AI_KEY_ONLY="on"; ai_state_save
            log "key-only SSH enabled for '$AI_USER' — sshd rejects passwords for this user."
            log "sudo with password still works when logged in on the server."
            log "undo:  glm-bridge --ai-user key-only off"
        else
            ai_key_only_files_off
            [ -f "$SSHD_MAIN.glm-backup" ] && cp -f "$SSHD_MAIN.glm-backup" "$SSHD_MAIN"
            die "sshd config invalid — changes rolled back, nothing applied"
        fi
    else
        ai_key_only_files_off
        if ai_sshd_validate_reload; then
            AI_KEY_ONLY="off"; ai_state_save
            log "key-only mode OFF — password auth allowed again for '$AI_USER'."
        else
            die "sshd reload failed after removing the rule — check 'sshd -t' manually"
        fi
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
    log "waiting for the first tunnel URL (up to 150 s)..."
    local url
    if url="$(wait_url 30)"; then
        url_parts "$url"
        local conn ssh_user
        ai_state_load
        if [ -n "$AI_USER" ] && ai_user_exists "$AI_USER"; then
            ssh_user="$AI_USER"
            conn="ssh -i $AI_KEY_PATH -p \"$PORT\" $ssh_user@$HOST"
        else
            ssh_user="$(id -un 2>/dev/null || printf '%s' "${USER:-unknown}")"
            conn="ssh -p \"$PORT\" $ssh_user@$HOST"
        fi
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
        if [ -n "$AI_USER" ] && ai_user_exists "$AI_USER"; then
            echo "----------------------------------------------------------"
            echo "  Dedicated AI user  : $AI_USER  (key-based auth)"
            echo "  Private key (sandbox) : $AI_KEY_PATH"
            echo "  Public key (server)    : $(ai_ak_file "$AI_USER")"
            local pub_for_fp="$GLM_DIR/ai-key.pub"
            [ -r "$pub_for_fp" ] || pub_for_fp="$(ai_ak_file "$AI_USER")"
            echo "  Key fingerprint    : $(ssh-keygen -lf "$pub_for_fp" 2>/dev/null | awk '{print $2" "$4}')"
            echo "  Auth mode          : key-only=${AI_KEY_ONLY}, sudo=${AI_SUDO}"
            echo "  >>> The private key is in the AI sandbox at $AI_KEY_PATH <<<"
            echo "  >>> If missing, the AI must generate it: ssh-keygen -t ed25519 -f $AI_KEY_PATH -N \"\" <<<"
            echo "  >>> then upload the .pub: glm-bridge --ai-key add $AI_KEY_PATH.pub <<<"
        fi
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
    pid="$(pgrep -f 'bash[[:space:]]+[^[:space:]]*glm-watchdog\.sh' 2>/dev/null | head -1)"
    if [ -n "$pid" ]; then
        run_s="running (PID $pid, up $(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' '))"
    fi
    url="$(grab_url)" || url="unknown yet"
    crontab -l 2>/dev/null | grep -q 'glm-watchdog.sh' && cron_s="enabled"
    [ -L "$BIN_LINK" ] && link_s="installed ($BIN_LINK)"
    ai_state_load
    local ai_s="(none — auto-created on first --start; or run: glm-bridge --ai-user create)"
    local ai_fp="(none)" ai_key_path="(none)" ai_last="(no login yet)" ai_auth="(n/a)"
    if [ -n "$AI_USER" ]; then
        if ai_user_exists "$AI_USER"; then
            ai_s="$AI_USER"
            # Key fingerprint (from the installed authorized_keys)
            local akf
            akf="$(ai_ak_file "$AI_USER")"
            if [ -r "$akf" ]; then
                ai_fp="$(ssh-keygen -lf "$akf" 2>/dev/null | awk '{print $2" ("$4")"}')"
                [ -n "$ai_fp" ] || ai_fp="(unreadable)"
            elif [ "$(id -u)" -eq 0 ] || sudo -n true 2>/dev/null; then
                ai_fp="$(sudo -n ssh-keygen -lf "$akf" 2>/dev/null | awk '{print $2" ("$4")"}')"
                [ -n "$ai_fp" ] || ai_fp="(run with sudo to see)"
            else
                ai_fp="(run with sudo to see)"
            fi
            # Private key path (only if tracked)
            ai_key_path="${AI_KEY_PATH:-(not tracked)}"
            # Auth mode label
            if [ "$AI_KEY_ONLY" = "on" ]; then
                ai_auth="key-only (passwords rejected by sshd)"
            else
                ai_auth="password allowed (key-only OFF)"
            fi
            # Last login (from `last`)
            ai_last="$(last -n 1 "$AI_USER" 2>/dev/null | head -1 | tr -s ' ')"
            [ -n "$ai_last" ] || ai_last="(no login yet)"
        else
            ai_s="$AI_USER (MISSING on system!)"
            ai_fp="—"; ai_key_path="—"; ai_last="—"; ai_auth="—"
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
    echo "  Global command     : $link_s"
    echo "  Project folder     : $SCRIPT_DIR"
    echo "  State dir          : $GLM_DIR"
    echo "----------------------------------------------------------"
    echo "  Dedicated AI user  : $ai_s"
    echo "  Auth mode          : $ai_auth"
    echo "  Key fingerprint    : $ai_fp"
    echo "  Private key (sandbox) : $ai_key_path"
    echo "  Sudo               : ${AI_SUDO:-off}"
    echo "  Last login         : $ai_last"
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
  bash glm-bridge.sh --stop         full stop
  bash glm-bridge.sh --status       show status
  bash glm-bridge.sh --restart      restart
  bash glm-bridge.sh --new-topic    new topic (tell your AI assistant!)
  bash glm-bridge.sh --uninstall    remove integration (keeps project folder)
  bash glm-bridge.sh --purge        remove + delete the project folder
  bash glm-bridge.sh --help         this help

Dedicated AI user (optional; uses sudo when YOU run these):
  --start                               also auto-creates an ai-<random> user +
                                         ed25519 keypair on FIRST install
                                         (key-only auth, password locked)
  glm-bridge --ai-user create         new user ai-<random> + password (shown ONCE)
  glm-bridge --ai-user status         AI user, sudo state, keys, lock state
  glm-bridge --ai-user rotate         new password for the AI user (shown ONCE)
  glm-bridge --ai-user lock|unlock    instantly block / restore AI SSH access
  glm-bridge --ai-user remove         delete the AI user and its home (--yes skips)
  glm-bridge --ai-user key-only on|off  sshd: key auth ONLY for the AI user
  glm-bridge --ai-sudo on|off         grant / revoke FULL sudo for the AI user
  glm-bridge --ai-key add <file|->    install a public key ('-' = read stdin)
  glm-bridge --ai-key list            list installed keys + fingerprints
  glm-bridge --ai-key revoke <fp>     remove keys matching a fingerprint prefix
  glm-bridge --status                 shows the AI username, key fingerprint,
                                       private key path, key-only/sudo state,
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
        --ai-user)
            [ -n "${2:-}" ] || die "--ai-user needs a subcommand (create|status|rotate|lock|unlock|remove|key-only)"
            ACTION="ai-user"; AI_SUB="$2"; shift 2; AI_ARGS=("$@"); break ;;
        --ai-sudo)
            [ -n "${2:-}" ] || die "--ai-sudo needs on or off"
            ACTION="ai-sudo"; AI_SUB="$2"; shift 2; AI_ARGS=("$@"); break ;;
        --ai-key)
            [ -n "${2:-}" ] || die "--ai-key needs a subcommand (add|list|revoke)"
            ACTION="ai-key"; AI_SUB="$2"; shift 2; AI_ARGS=("$@"); break ;;
        --ai-auto-install)
            [ -n "${2:-}" ] || die "--ai-auto-install needs a public key file path"
            ACTION="ai-auto-install"; AI_SUB="$2"; shift 2; AI_ARGS=("$@"); break ;;
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
    ai-user)
        case "$AI_SUB" in
            create)   ai_cmd_create ;;
            status)   ai_cmd_status ;;
            rotate)   ai_cmd_rotate ;;
            lock)     ai_cmd_lock ;;
            unlock)   ai_cmd_unlock ;;
            remove)   ai_cmd_remove ;;
            key-only) ai_cmd_key_only ;;
            *) die "unknown --ai-user subcommand: $AI_SUB (try --help)" ;;
        esac ;;
    ai-sudo)   ai_cmd_sudo "$AI_SUB" ;;
    ai-key)    ai_cmd_key "$AI_SUB" ${AI_ARGS[@]+"${AI_ARGS[@]}"} ;;
    ai-auto-install) ai_do_auto_install "$AI_SUB" ;;
esac
