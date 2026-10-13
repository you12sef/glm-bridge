# 🤖 AI HANDOFF — glm-bridge server access

> **TO THE AI READING THIS:** You are taking over operational access to a remote
> server (Ubuntu, behind NAT). A watchdog on the server keeps a pinggy free tunnel
> alive and publishes its CURRENT URL to an ntfy.sh topic. Read this file fully,
> run the verification in §6, then reply `READY — awaiting orders` and wait for
> the user's commands. Do not build anything else. Do not ask for more context.
> If the user wants to talk to you through ntfy notifications
> (approval / command loop), follow §10 — and remember: notifications
> are a MEANS, the mission itself arrives in the chat.
> Your SSH identity is a dedicated AI user + its password (§11) — both come
> from `glm-bridge --status` / `--handoff` output pasted by the owner in chat.

---

## 1. Situation / الوضع

- Server SSH is exposed through a **pinggy free tunnel** whose address **changes every
  ~60 minutes** (hard limit of the free tier).
- `~/.glm-bridge/glm-watchdog.sh` on the server (no root) renews the tunnel every
  **50 minutes**, sends a **HEARTBEAT every 5 minutes**, and publishes messages:
  `RENEW <server> tcp://host:port` and `HEARTBEAT <server> tcp://host:port`
  to the ntfy topic below.
- A crontab keeps the watchdog alive: `@reboot` starts it after a server reboot,
  and a `*/5` supervision entry restarts it within ~5 minutes if the process
  ever dies. The watchdog logs its own exit reason to `watchdog.log`.
- Your sandbox **cannot run ZeroTier** but **CAN make outbound SSH connections**
  (paramiko or the ssh binary).

## 2. USER-FILLED BLOCK / يملؤه المستخدم في الشات

> **The owner generates a paste-ready snippet with**:
>   `glm-bridge --handoff`
> This prints ONLY the lines below (no PID, no uptime, no logs).
> The owner pastes them in the chat — that's all you need to start.

```text
NTFY TOPIC   : <the USER pastes it in the CHAT — glm-bridge.sh generates
               one per install and it PERSISTS across --stop/--start and
               reboots; always use the latest topic the user sent.
               Format example: glmb-fleet-64aaf6b02cad>
SERVER NAME  : <paste — or read it from the RENEW/HEARTBEAT messages>
SSH USER     : <paste — the dedicated 'ai-*' user created by glm-bridge;
               prefer it over the owner's personal account>
SSH PASSWORD : <paste — the AI user's password shown in the handoff snippet;
               chat only, NEVER save into any file. Rotatable any time via
               'glm-bridge --ai-user rotate' (§11)>
FIRST CONNECTION COMMAND (printed by glm-bridge.sh --start — use ONLY for
first contact or if the ntfy topic is unreachable):
  ssh -p "<PORT>" <USER>@<LINK>
```

> **TOPIC LIFETIME / مهم:** the topic is generated once at install and
> PERSISTS across `--stop` / `--start` cycles and server reboots (stored in
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
SSHUSER = "<paste>"     # from §2 (the dedicated ai-* user)
SSHPASS = "<paste>"     # from §2 (the AI user's password)

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
| Topic has no messages | Watchdog down. Connect via §2 fallback command, then run on the server: `bash <project-folder>/glm-bridge.sh --start` (restarts with the SAME topic stored in state). Note: the cron supervision normally revives a dead watchdog within ~5 min by itself. |
| Watchdog died — why? | The reason is never silent: read the tail of `~/.glm-bridge/watchdog.log` — the watchdog logs `watchdog exiting — reason: ...` on every exit (SIGTERM, SIGINT, ...). |
| Server rebooted | `@reboot` crontab auto-restarts the watchdog. Wait ≤2 min then §4. |
| Need to stop everything | `bash <project-folder>/glm-bridge.sh --stop` (stops watchdog+tunnels+autostart; the SAME topic returns on `--start`). For full removal: `--uninstall` (also removes cron + PATH + state; topic dies) or `--purge` (also deletes the project folder). |
| Need a kit file that is missing on the server | The kit is self-contained (no repo). Recreate it on the server via SSH (here-doc / printf) or push it from your sandbox with `sftp.put()` (§5). |
| AI password rejected | It may have been rotated. Ask the owner to paste the fresh `glm-bridge --status` output (it shows the current password). Do NOT conclude the tunnel is broken. |

Server-side state (diagnose via SSH): `~/.glm-bridge/` →
`state.env` (NTFY_TOPIC + SERVER_NAME — the topic source of truth),
`ai-user.env` (AI_USER + AI_PASS — mode 600, owner-readable),
`watchdog.log` (daemon + exit reasons + publish failures),
`bridge.log` (every manager action, timestamped),
`current.json`, `CONNECT.txt`, `tunnel_new.log`, `tunnel.pid`.

## 8. Security rules / قواعد الأمان

- The ntfy topic is embedded here BY DESIGN (user decision) so any AI can discover URLs.
- The SSH password lives ONLY in the chat — never write it to files, code, or outputs.
- The password you receive belongs to the dedicated `ai-*` user — NOT to the
  owner's personal account. The AI user has no sudo by default; its OS
  permissions ARE the security policy (§11).
- If the owner rotates the password (`--ai-user rotate`), the new one appears
  in `--status`/`--handoff` output — they will paste it in the chat.
- Suggest rotating the password after the project ends, or `--ai-user lock/remove`.

## 9. Context summary / ملخص سريع

- ZeroTier is impossible in the AI sandbox (no root/TUN) → this bridge replaces it.
  Full protocol details: `README.md` in the project folder (lives on the server).
- Kit files: `glm-bridge.sh` (UNIFIED manager: `--start/--stop/--status/--restart/--new-topic/--uninstall/--purge` — generates the topic at first install, persists it in `~/.glm-bridge/state.env`, adds the `glm-bridge` command to PATH via symlink + marked .bashrc block + best-effort `/usr/local/bin` link; ALSO manages the optional dedicated AI user: `--ai-user create|status|rotate|lock|unlock|remove`, `--ai-sudo on|off`; logs every action to `~/.glm-bridge/bridge.log`),
  `bridge/glm-watchdog.sh` (daemon template; the rendered copy runs as `~/.glm-bridge/glm-watchdog.sh`; logs exits + publish failures, self-trims its log, refuses to run twice),
  `bridge/glm-bootstrap.sh` (AI-driven remote installer; writes `state.env` + both crontab entries),
  `bridge/discover.py` (optional AI tool),
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
  2. watchdog system messages → message starts with `RENEW`, `HEARTBEAT` or `WATCHDOG-START`;
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
            if txt.split()[:1] and txt.split()[0] in ("RENEW", "HEARTBEAT", "WATCHDOG-START"): continue
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

## 11. Dedicated AI user & password auth / يوزر مخصص للـ AI

> The server has a dedicated OS user for you: username `ai-xxxxxxxx`,
> created automatically on the first `glm-bridge --start`. You authenticate
> with a **PASSWORD** — there are no SSH keys in this design. The password
> is generated by glm-bridge, stored on the server in
> `~/.glm-bridge/ai-user.env` (mode 600) and displayed by
> `glm-bridge --status` and `glm-bridge --handoff`; the owner pastes it to
> you in the chat.

### 11.1 How YOU (the AI) connect

1. Discover the current tunnel URL from the ntfy topic (§4).
2. Take the AI username + password from the handoff snippet / `--status`
   output pasted by the owner in the chat (§11.2).
3. Connect with paramiko using **password auth only**:
   ```python
   import paramiko
   c = paramiko.SSHClient()
   c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
   c.connect(host, port,
             username=AI_USER,                   # ai-<rand> from --status
             password=AI_PASS,                   # from --status / handoff snippet
             allow_agent=False, look_for_keys=False,
             timeout=25, banner_timeout=25, auth_timeout=25)
   ```
4. If you get `Authentication failed`:
   - The password was probably rotated (`glm-bridge --ai-user rotate`) —
     ask the owner to paste the fresh `--status` output. Do NOT conclude
     the tunnel is broken — RENEW/HEARTBEAT keeps flowing even when auth fails.
   - The user may have been locked (`--ai-user lock`) or removed — ask (§11.5).
5. NEVER generate or install SSH keys for this user — the design is
   password-only; keys are out of scope for this kit.

### 11.2 Reading the AI user info from `--status`

`glm-bridge --status` prints everything you need:
- `Dedicated AI user` — the `ai-<rand>` username (password auth)
- `AI password` — the CURRENT password (shown in plaintext for the owner
  to paste in chat)
- `Sudo` — `off` by default; `on` only if the owner enabled it
- `Supervision` — cron watchdog supervision state
- `Last login` — last time you (or anyone) connected as this user

The same values appear in the paste-ready `--handoff` snippet.

### 11.3 Sudo — explicit only

- Sudo is OFF by default and is toggled explicitly: `glm-bridge --ai-sudo on|off`.
- If sudo is ON: any privileged or destructive command STILL goes through
  the §10 approval loop FIRST.
- If sudo is OFF: do not attempt privilege escalation — ask the owner in chat.
  The AI user has no sudo password, so `sudo` will fail anyway; this is by
  design. Security is enforced by the user's OS permissions, not by hidden
  tricks.

### 11.4 Revocation signals

The owner can instantly:
- `glm-bridge --ai-user lock` → SSH blocked (nologin shell + password lock)
- `glm-bridge --ai-user remove` → user deleted + home removed
- `glm-bridge --ai-user rotate` → password changed (new one appears in `--status`)

If SSH starts failing with "Permission denied" while RENEW/HEARTBEAT keep
flowing normally on the topic, ASK whether the AI user was locked/removed
or the password rotated — do not conclude the tunnel is broken.

### 11.5 Architecture — why password + OS permissions

**Design principle:** the AI identity is a dedicated OS user whose password
is displayable and rotatable, and whose power is bounded by its own
permissions:

- The owner's personal account/password NEVER travels to any AI chat.
- The AI user has a normal shell but no sudo by default — every privileged
  action requires an explicit owner decision (approval loop §10 or
  `--ai-sudo on`).
- An explicit sshd rule (`/etc/ssh/sshd_config.d/glm-bridge-ai.conf`,
  `Match User ai-<rand>` + `PasswordAuthentication yes`) guarantees the AI
  user can always log in with its password, independent of any future global
  sshd hardening.
- Everything is auditable: logins in `last`/`auth.log`, manager actions in
  `~/.glm-bridge/bridge.log`, daemon life in `watchdog.log`.
- No key material exists anywhere: nothing to generate, lose, copy between
  sandboxes, or wait for the owner to install.
