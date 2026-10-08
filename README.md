# glm-bridge

One-command dynamic SSH bridge for NAT'd servers using **pinggy free tunnels** +
**ntfy.sh**. Built so that an AI assistant (GLM, ChatGPT, Claude, ...) can keep
accessing your server even though the free tunnel address changes every 60 minutes.

## How it works

```
SERVER (behind NAT)                          AI SANDBOX (any chat)
┌───────────────────────────────┐            ┌──────────────────────────┐
│ glm-watchdog.sh (no root):    │            │ reads ntfy topic →       │
│ • pinggy tunnel (SSH exposed) │──ntfy.sh──▶│   current tcp://host:port│
│ • renews every 50 min         │            │ connects via SSH         │
│ • heartbeat every 5 min       │◀────────────│   (paramiko)             │
│ • publishes current URL       │            │ ready for your orders    │
└───────────────────────────────┘            └──────────────────────────┘
```

## Quick start — on the server (one command)

```bash
curl -fsSL https://raw.githubusercontent.com/<USER>/<REPO>/main/install.sh -o install.sh
bash install.sh <USER>/<REPO> [server-name]
```

The installer downloads the project, installs the watchdog, starts everything,
and prints the connection command:

```
ssh -p "PORT" username@link
```

## Give your AI access — one file

Open **`AI-HANDOFF.md`**, fill the small USER block (topic already embedded),
paste it + the printed command + the SSH password **directly in your AI chat**.
The AI discovers the live URL, connects, verifies, and replies `READY`.
Full protocol details: **`README-PROTOCOL` section inside AI-HANDOFF + this file.**

## Repository files

| File | Purpose | Runs on |
|------|---------|---------|
| `install.sh` | one-command installer: downloads kit, installs watchdog, prints `ssh -p "PORT" user@link` | server |
| `glm-watchdog.sh` | the daemon: renews tunnel every 50 min, heartbeats every 5 min, publishes URL to ntfy | server |
| `glm-bootstrap.sh` | alternative installer used when the AI pushes the kit remotely | server |
| `discover.py` | optional tool: list servers / connect / remote-install | AI sandbox |
| `AI-HANDOFF.md` | **the single file you give to any AI** (topic embedded) | AI chat |
| `README.md` | this file | — |

## Security notes

- The **ntfy topic is embedded in this repo by design** (user decision) so any AI can
  read tunnel URLs. If the repo is PUBLIC, the topic is semi-public: anyone can see
  your tunnel addresses (SSH itself stays password-protected). Prefer a **private
  repo** — but then `install.sh` needs an authenticated fetch — or rotate the topic
  regularly by editing `install.sh` + re-running it on the servers.
- The SSH **password is never stored in any file** — paste it in the AI chat only,
  and rotate it (`passwd`) after the project.
- SSH sessions through pinggy relays are end-to-end encrypted; relays see ciphertext only.

## Requirements

- Server: Ubuntu/Debian-like with `bash`, `ssh`, `curl` or `wget`, `sed`. No root.
- AI sandbox: Python 3 + `pip install paramiko` + outbound HTTPS to ntfy.sh.
