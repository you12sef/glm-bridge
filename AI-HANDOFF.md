# 🤖 AI HANDOFF — glm-bridge server access

> **TO THE AI READING THIS:** You are taking over operational access to a remote
> server (Ubuntu, behind NAT). A watchdog on the server keeps a pinggy free tunnel
> alive and publishes its CURRENT URL to an ntfy.sh topic. Read this file fully,
> run the verification in §6, then reply `READY — awaiting orders` and wait for
> the user's commands. Do not build anything else. Do not ask for more context.
> If the user wants to talk to you through ntfy notifications
> (approval / command loop), follow §10 — and remember: notifications
> are a MEANS, the mission itself arrives in the chat.
> If the user set up a dedicated AI user for you or prefers key auth,
> follow §11 — it replaces password-in-chat entirely.

---

## 1. Situation / الوضع

- Server SSH is exposed through a **pinggy free tunnel** whose address **changes every
  ~60 minutes** (hard limit of the free tier).
- `~/.glm-bridge/glm-watchdog.sh` on the server (no root) renews the tunnel every
  **50 minutes**, sends a **HEARTBEAT every 5 minutes**, and publishes messages:
  `RENEW <server> tcp://host:port` and `HEARTBEAT <server> tcp://host:port`
  to the ntfy topic below.
- Your sandbox **cannot run ZeroTier** but **CAN make outbound SSH connections**
  (paramiko or the ssh binary).

## 2. USER-FILLED BLOCK / يملؤه المستخدم في الشات

> **The owner can now generate a paste-ready snippet with**:
>   `glm-bridge --handoff`
> This prints ONLY the four lines below (no PID, no uptime, no logs).
> The owner pastes them in the chat — that's all you need to start.

```text
NTFY TOPIC   : <the USER pastes it in the CHAT — glm-bridge.sh generates
               one per install and it PERSISTS across --stop/--start;
               always use the latest topic the user sent.
               Format example: glmb-fleet-64aaf6b02cad>
SERVER NAME  : <paste — or read it from the RENEW/HEARTBEAT messages>
SSH USER     : <paste — may be the owner's own account OR a DEDICATED
               'ai-*' user created by glm-bridge (see §11); prefer the
               dedicated one when provided>
SSH PASSWORD : <paste — chat only, NEVER save into any file. With a
               dedicated ai-* user this password is disposable and
               rotatable (§11.2), and key auth (§11.1) may replace it>
FIRST CONNECTION COMMAND (printed by glm-bridge.sh --start — use ONLY for
first contact or if the ntfy topic is unreachable):
  ssh -p "<PORT>" <USER>@<LINK>
```

> **TOPIC LIFETIME / مهم:** the topic is generated once at install and
> PERSISTS across `--stop` / `--start` cycles (stored in
> `~/.glm-bridge/state.env`). It changes ONLY via `glm-bridge --new-topic`
> or after `glm-bridge --uninstall`. The user sends the CURRENT topic in the
> CHAT. If discovery on the topic you have returns empty, do NOT conclude
> the server is down — first ask in chat if the topic changed.

## 3. Golden rule / القاعدة الذهبية

**The URL above goes stale within ~50 minutes.** ALWAYS fetch the CURRENT URL from
the ntfy topic before connecting. The printed command is a *fallback* for the very
first contact or for repairing the server when ntfy discovery fails.

## 4. Discovery — get the live URL / سحب الرابط الحالي

Run in your sandbox (plain bash, no dependencies):

```bash
curl -s "https://ntfy.sh/<TOPIC-FROM-CHAT>/json?poll=1&since=all" \
  | python3 -c "
import sys, json
best, ts = '', 0
for line in sys.stdin:
    try: m = json.loads(line)
    except: continue
    p = m.get('message','').split()
    if len(p) >= 3 and p[0] in ('RENEW','HEARTBEAT') and p[2].startswith('tcp://'):
        if m.get('time',0) >= ts:
            ts, best = m.get('time',0), p[2]
print(best)  # tcp://host:port  ← live RIGHT NOW
"
```

If the output is empty → the watchdog is down or the server lost internet.
Fall back to the FIRST CONNECTION COMMAND (§2), fix the server (§7), done.

## 5. Connect & verify / الاتصال والتحقق

```python
# pip install paramiko   (sandbox may reset env between messages — reinstall freely)
import json, urllib.request, paramiko

TOPIC   = "<TOPIC-FROM-CHAT>"     # user pastes the current topic in the CHAT
SSHUSER = "<paste>"     # from §2
SSHPASS = "<paste>"     # from §2

def current_url():
    with urllib.request.urlopen(
        f"https://ntfy.sh/{TOPIC}/json?poll=1&since=all", timeout=25) as r:
        best, ts = "", 0
        for line in r.read().decode(errors="replace").splitlines():
            try: m = json.loads(line)
            except Exception: continue
            p = m.get("message", "").split()
            if len(p) >= 3 and p[0] in ("RENEW", "HEARTBEAT") and p[2].startswith("tcp://"):
                if m.get("time", 0) >= ts:
                    ts, best = m.get("time", 0), p[2]
        return best

url = current_url()
assert url, "no live URL on topic — use the fallback command"
hostport = url.replace("tcp://", "")
host, port = hostport.rsplit(":", 1)

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(host, int(port), username=SSHUSER, password=SSHPASS,
          timeout=25, allow_agent=False, look_for_keys=False,
          banner_timeout=25, auth_timeout=25)
_, out, err = c.exec_command("hostname && whoami && uptime", timeout=15)
print(out.read().decode(), err.read().decode())
c.close()
```

For file transfers use `sftp = c.open_sftp()` → `sftp.put(local, remote)` / `sftp.get(...)`.

## 6. Your first action / أول إجراء لك

1. Run §4 → get URL. 2. Run §5 → see hostname/uptime. 3. Reply:
   `READY — bridge verified on <SERVER NAME>, awaiting orders`.

## 7. Repairs / الإصلاحات

| Problem | Fix |
|---------|-----|
| SSH died mid-work | It's the 50-min renewal. Re-run §4 → §5. Do NOT re-setup. |
| Topic has no messages | Watchdog down. Connect via §2 fallback command, then run on the server: `bash <project-folder>/glm-bridge.sh --start` (restarts with the SAME topic stored in state). |
| Server rebooted | `@reboot` crontab auto-restarts the watchdog. Wait ≤2 min then §4. |
| Need to stop everything | `bash <project-folder>/glm-bridge.sh --stop` (stops watchdog+tunnels+autostart; the SAME topic returns on `--start`). For full removal: `--uninstall` (also removes cron + PATH + state; topic dies) or `--purge` (also deletes the project folder). |
| Need a kit file that is missing on the server | The kit is self-contained (no repo). Recreate it on the server via SSH (here-doc / printf) or push it from your sandbox with `sftp.put()` (§5). |

Server-side state (diagnose via SSH): `~/.glm-bridge/` →
`state.env` (NTFY_TOPIC + SERVER_NAME — the topic source of truth),
`watchdog.log`, `current.json`, `tunnel_new.log`, `tunnel.pid`, `CONNECT.txt`.

## 8. Security rules / قواعد الأمان

- The ntfy topic is embedded here BY DESIGN (user decision) so any AI can discover URLs.
- The SSH password lives ONLY in the chat — never write it to files, code, or outputs.
- If the user rotates the password, they will paste the new one in the chat.
- Suggest rotating the password after the project ends (`passwd`).

## 9. Context summary / ملخص سريع

- Built 2026-10-08. ZeroTier was impossible in the AI sandbox (no root/TUN) → replaced
  by this bridge. Full protocol details: `README.md` in the project folder (lives on the server).
- Kit files: `glm-bridge.sh` (UNIFIED manager: `--start/--stop/--status/--restart/--new-topic/--uninstall/--purge` — generates the topic at first install, persists it in `~/.glm-bridge/state.env`, adds the `glm-bridge` command to PATH via symlink + marked .bashrc block; ALSO manages the optional dedicated AI user: `--ai-user create|status|rotate|lock|unlock|remove|key-only`, `--ai-sudo on|off`, `--ai-key add|list|revoke`), `bridge/glm-watchdog.sh` (daemon template; the rendered copy runs as `~/.glm-bridge/glm-watchdog.sh`),
  `bridge/glm-bootstrap.sh` (AI-driven remote installer), `bridge/discover.py` (optional AI tool),
  `AI-HANDOFF.md` (this file), `README.md`. No GitHub repo — the kit is copied to the server as a plain folder.

## 10. Notification bridge — two-way comms & approvals / جسر الإشعارات

> **PURPOSE FIRST / الهدف أولاً:** ntfy notifications are **only a transport
> channel (وسيلة)** — never the mission. The MISSION (build a runtime environment,
> fix a server problem, code a feature, deploy a service, ...) is given to you
> **in the chat**, or you wait for it. "Talking via notifications" is not the goal;
> it is how approvals, progress reports and short commands travel while you do the
> real work on the server.

### 10.1 The approval loop

1. Publish to the topic with the header **`Tags: robot`** so you can recognize your
   own messages later.
2. When an action was not explicitly ordered, **ask permission first** via a
   notification ("may I create ~/X? reply: yes / no").
3. The user replies from the ntfy app as a plain text message (no robot tag).
4. Execute on the server (§5 pattern), then publish a short result notification
   (`Tags: robot`).
5. Keep listening for the next user command (§10.4).

### 10.2 Receiving messages — the traps (already solved, do NOT rediscover them)

- **Poll, don't stream.** Use
  `GET https://ntfy.sh/<TOPIC>/json?poll=1&since=<epoch>` every ~6 s.
  A sandbox bash call is capped at ~10 min, so listen in cycles of ~4–5 min.
- **Filter out, in this order:**
  1. your own messages → `"robot" in tags`;
  2. watchdog system messages → message starts with `RENEW` or `HEARTBEAT`;
  3. the one-word artifact `triggered` (and similar) that the ntfy app publishes
     when the user taps an action button — it is NOT a user command.
- **Dedup across runs by message id.** `since=<unix-seconds>` is supported, but if
  you use a "look back N seconds" window you WILL re-catch old messages on every
  cycle. Persist a state file `{"since": <last epoch>, "seen": [<last 100 ids>]}`
  and skip seen ids — this is bulletproof.
- **Act on the first real user message, exit, execute, then start a fresh listen
  cycle** for the next one.

### 10.3 Publishing a notification

```bash
curl -fsS -H "Title: ..." -H "Priority: high" -H "Tags: robot" \
     -d "short UTF-8 text (Arabic works fine)" "https://ntfy.sh/<TOPIC>"
```

Keep bodies short (a few lines): summary in the Title, key numbers/paths in the
body; truncate long command output to the first/last few lines.

### 10.4 Minimal listener (stdlib only — paste-ready; the sandbox resets between sessions)

```python
import json, os, sys, time, urllib.request
TOPIC = "glmb-fleet-XXXXXXXXXXXX"   # current topic: user sends it in the CHAT (persists across stop/start)
STATE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".ntfy_since")
def load():
    try: st = json.load(open(STATE)); return int(st["since"]), set(st["seen"])
    except Exception: return int(time.time()) - 60, set()   # first run: 60s lookback
def save(since, seen):
    try: json.dump({"since": since, "seen": list(seen)[-100:]}, open(STATE, "w"))
    except Exception: pass
since, seen = load()
deadline = time.time() + 240                      # one listen cycle (~4 min)
while time.time() < deadline:
    u = f"https://ntfy.sh/{TOPIC}/json?poll=1&since={since}"
    with urllib.request.urlopen(u, timeout=25) as r:
        for line in r.read().decode(errors="replace").splitlines():
            try: m = json.loads(line)
            except Exception: continue
            if m.get("event") != "message" or m.get("id") in seen: continue
            seen.add(m["id"]); since = max(since, m.get("time", since)); save(since, seen)
            txt = (m.get("message") or "").strip()
            if "robot" in (m.get("tags") or []): continue                    # my own
            if txt.split()[:1] and txt.split()[0] in ("RENEW", "HEARTBEAT"): continue
            if txt == "triggered": continue                                  # app artifact
            print("USER_MSG", txt); sys.exit(0)     # first real msg -> act on it
    time.sleep(6)
print("TIMEOUT - no user message")
```

### 10.5 Executing what you receive

- Always **discover the current tunnel URL from the topic first** (§4) — it rotates
  every ~50 min; use the first-contact command only as fallback.
- The SSH password travels ONLY in the chat / an environment variable — never into
  any file, on any machine.
- Run commands non-interactively (`exec_command`), capture stdout+stderr+exit code.
- If a received command looks destructive (`rm -rf /`, `mkfs`, `dd if=`, fork
  bombs), refuse it and say so via a notification.

### 10.6 Who initiates what

- The user gives the **mission in the chat** → you work on the server and use the
  notification loop for approvals and progress reports.
- The user may also push short **commands via notifications** → poll the topic at
  the start of every turn and execute queued messages in order.
- Between your turns nothing runs in the sandbox: if you are idle and the user
  sends an ntfy command, they will ping the chat (any word) to wake you — then
  poll the topic FIRST, execute, and report back via notification + chat.

## 11. Dedicated AI user & key auth / يوزر مخصص ومفاتيح SSH

> The server has a dedicated OS user for you (username `ai-xxxxxxxx`,
> created automatically on first `glm-bridge --start`). Auth is **SSH key
> only** — there is no password to leak. **The keypair is generated in
> YOUR sandbox**, not on the server: the private key stays at
> `~/.glm_keys/ai-key` and never leaves; only the public key was uploaded
> to the server once and installed into `~ai/.ssh/authorized_keys`.

### 11.1 Where the private key lives — READ THIS FIRST

**Before doing anything else, check for the private key in your sandbox:**

```bash
ls -la ~/.glm_keys/ai-key 2>/dev/null
```

- **If it exists** → use it to connect (§11.2). Do NOT generate a new key.
- **If it does NOT exist** → your sandbox was reset. You have two options:
  1. **Regenerate + re-install** (cleanest, ~30 seconds):
     ```bash
     mkdir -p ~/.glm_keys
     ssh-keygen -t ed25519 -f ~/.glm_keys/ai-key -N "" -C "glm-ai@$(hostname)"
     chmod 600 ~/.glm_keys/ai-key
     # Then ask the owner in chat to run:
     #   glm-bridge --ai-key add ~/.glm_keys/ai-key.pub
     # (the .pub is not secret — safe to paste in chat or ntfy)
     ```
  2. **Ask the owner** to re-run `glm-bridge --start` (it re-installs the
     auto-generated key). This requires the owner, not you.

> ⚠️ NEVER generate a new keypair without first checking `~/.glm_keys/ai-key`.
> Doing so creates a second key that the server doesn't know about, and you'll
> be stuck waiting for the owner to install it — exactly the trap that the
> v2.3 design fixes.

### 11.2 How YOU (the AI) connect

1. Discover the current tunnel URL from the ntfy topic (§4).
2. Read the AI username + fingerprint from `glm-bridge --status` (§11.3).
3. Connect with paramiko using the **local** private key:
   ```python
   import paramiko
   c = paramiko.SSHClient()
   c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
   c.connect(host, port,
             username=AI_USER,                   # ai-<rand> from --status
             key_filename=os.path.expanduser('~/.glm_keys/ai-key'),
             allow_agent=False, look_for_keys=False,
             timeout=25, banner_timeout=25, auth_timeout=25)
   ```
4. **Verify the fingerprint** — paramiko prints it on first connect. It must
   match the `Key fingerprint` field from `--status`. If it doesn't, abort
   (possible MITM) and ask the owner in chat.
5. If you get `Authentication failed`:
   - Check that `~/.glm_keys/ai-key` exists (§11.1).
   - Check that the key fingerprint matches `--status`. If the sandbox was
     reset and you regenerated a new key, the owner must install the new
     `.pub` (§11.1 option 1).
   - Do NOT conclude the tunnel is broken — RENEW/HEARTBEAT keeps flowing
     even when auth fails.

### 11.3 Reading the AI user info from `--status`

`glm-bridge --status` prints everything you need:
- `Dedicated AI user` — the `ai-<rand>` username
- `Auth mode` — `key-only (passwords rejected by sshd)` (this is what you want)
- `Key fingerprint` — SHA256 fingerprint of the installed public key
  (must match what paramiko reports on first connect — verify to detect MITM)
- `Private key (sandbox)` — where the private key SHOULD be in your sandbox:
  `~/.glm_keys/ai-key`. If the path is shown but the file is missing, see §11.1.
- `Sudo` — `off` by default; `on` if the owner enabled it
- `Last login` — last time you (or anyone) connected as this user

### 11.4 Sudo — explicit only

- Sudo is OFF by default and is toggled explicitly: `glm-bridge --ai-sudo on|off`.
- If sudo is ON: any privileged or destructive command STILL goes through
  the §10 approval loop FIRST.
- If sudo is OFF: do not attempt privilege escalation — ask the owner in chat.
  The AI user has no sudo password (it was never set), so `sudo` will fail
  anyway; this is by design.

### 11.5 Revocation signals

The owner can instantly:
- `glm-bridge --ai-user lock` → SSH blocked (nologin shell + password lock)
- `glm-bridge --ai-user remove` → user deleted + home removed + key gone
- `glm-bridge --ai-key revoke <fp>` → that specific key removed from authorized_keys

If SSH starts failing with "Permission denied" while RENEW/HEARTBEAT keep
flowing normally on the topic, ASK whether the AI user was locked/removed
or the key revoked — do not conclude the tunnel is broken.

### 11.6 Architecture — why the key lives in the sandbox

**Design principle:** the private key is generated ONCE in the AI sandbox and
never leaves it. Only the public key travels to the server. This way:

- Every new AI session finds the key already present at `~/.glm_keys/ai-key`
  and connects immediately — no key-generation round-trip, no waiting for the
  owner to install anything.
- The server never holds the private key, so compromising the server does not
  compromise the AI's identity.
- Rotating the key is the AI's choice (regenerate locally + ask owner to
  install the new `.pub`), not the server's.

**Old design (v2.2, deprecated):** the keypair was generated on the server and
the AI was expected to `scp` the private key down. This failed in practice
because new AI sessions didn't know the key existed and generated their own,
creating a deadlock where the AI waited forever for the owner to install a
key the server had never seen.
