# 🤖 AI HANDOFF — glm-bridge server access

> **TO THE AI READING THIS:** You are taking over operational access to a remote
> server (Ubuntu, behind NAT). A watchdog on the server keeps a pinggy free tunnel
> alive and publishes its CURRENT URL to an ntfy.sh topic. Read this file fully,
> run the verification in §6, then reply `READY — awaiting orders` and wait for
> the user's commands. Do not build anything else. Do not ask for more context.
> If the user wants to talk to you through ntfy notifications
> (approval / command loop), follow §10 — and remember: notifications
> are a MEANS, the mission itself arrives in the chat.

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

```text
NTFY TOPIC   : glmb-fleet-64aaf6b02cad
SERVER NAME  : <paste — or read it from the RENEW/HEARTBEAT messages>
SSH USER     : <paste>
SSH PASSWORD : <paste — chat only, NEVER save into any file>
FIRST CONNECTION COMMAND (printed by install.sh — use ONLY for first contact
or if the ntfy topic is unreachable):
  ssh -p "<PORT>" <USER>@<LINK>
```

## 3. Golden rule / القاعدة الذهبية

**The URL above goes stale within ~50 minutes.** ALWAYS fetch the CURRENT URL from
the ntfy topic before connecting. The printed command is a *fallback* for the very
first contact or for repairing the server when ntfy discovery fails.

## 4. Discovery — get the live URL / سحب الرابط الحالي

Run in your sandbox (plain bash, no dependencies):

```bash
curl -s "https://ntfy.sh/glmb-fleet-64aaf6b02cad/json?poll=1&since=all" \
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

TOPIC   = "glmb-fleet-64aaf6b02cad"
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
| Topic has no messages | Watchdog down. Connect via §2 fallback command, then re-run: `setsid nohup bash <repo>/install.sh <USER/REPO> <SERVER NAME> &` — or push the kit files from the repo via SFTP and run install.sh. |
| Server rebooted | `@reboot` crontab auto-restarts the watchdog. Wait ≤2 min then §4. |
| Need file from the repo on the server | `curl -fsSL https://raw.githubusercontent.com/<USER>/<REPO>/main/<file> -o /tmp/<file>` |

Server-side state (diagnose via SSH): `~/.glm-bridge/` →
`watchdog.log`, `current.json`, `tunnel_new.log`, `tunnel.pid`, `CONNECT.txt`.

## 8. Security rules / قواعد الأمان

- The ntfy topic is embedded here BY DESIGN (user decision) so any AI can discover URLs.
- The SSH password lives ONLY in the chat — never write it to files, code, or outputs.
- If the user rotates the password, they will paste the new one in the chat.
- Suggest rotating the password after the project ends (`passwd`).

## 9. Context summary / ملخص سريع

- Built 2026-10-08. ZeroTier was impossible in the AI sandbox (no root/TUN) → replaced
  by this bridge. Full protocol details: `README.md` in the user's GitHub repo.
- Kit files: `install.sh` (server one-command installer), `glm-watchdog.sh` (daemon),
  `glm-bootstrap.sh` (AI-driven remote installer), `discover.py` (optional AI tool),
  `AI-HANDOFF.md` (this file), `README.md`.

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
TOPIC = "glmb-fleet-XXXXXXXXXXXX"
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
