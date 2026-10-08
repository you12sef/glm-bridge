#!/usr/bin/env python3
"""
glm-bridge discovery & connect tool — usable by ANY AI or human in ANY chat.
Part of the "glm-bridge" kit (see README-PROTOCOL.md).

The server runs a watchdog that publishes its current pinggy tunnel URL
to an ntfy.sh topic. This tool reads that topic and connects.

Usage:
  # 1) List live servers (no SSH needed):
  python3 discover.py --topic glmb-fleet-XXXXXXXXXXXX --list

  # 2) Run a command on a server through its current tunnel:
  python3 discover.py --topic glmb-fleet-XXXXXXXXXXXX \
      --connect pronet-movies --cmd 'hostname && uptime' \
      --user admin --password 'PASSWORD'

  # 3) Install/repair the watchdog on a NEW server (after connecting manually
  #    to a tunnel URL the user gives you):
  python3 discover.py --topic TOPIC --install-user admin --install-pass 'PASS' \
      --tunnel-host <pinggy-host> --tunnel-port <port> \
      --push /path/to/glm-watchdog.sh --push /path/to/glm-bootstrap.sh

Requires: requests-less — only stdlib. paramiko ONLY needed for --connect/--install.
"""
import argparse
import json
import sys
import urllib.request

RENEW_KINDS = ("RENEW", "HEARTBEAT")


def fetch_messages(topic):
    url = f"https://ntfy.sh/{topic}/json?poll=1&since=all"
    with urllib.request.urlopen(url, timeout=25) as r:
        for line in r.read().decode(errors="replace").splitlines():
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def latest_servers(topic):
    out = {}
    for m in fetch_messages(topic):
        parts = m.get("message", "").split()
        if len(parts) >= 3 and parts[0] in RENEW_KINDS and parts[2].startswith("tcp://"):
            rec = out.get(parts[1])
            cur = {
                "server": parts[1],
                "url": parts[2],
                "kind": parts[0],
                "time": m.get("time", ""),
            }
            if rec is None or cur["time"] > rec["time"]:
                out[parts[1]] = cur
    return out


def connect_ssh(host, port, user, password, timeout=30):
    import paramiko

    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(host, port=port, username=user, password=password,
              timeout=timeout, allow_agent=False, look_for_keys=False,
              banner_timeout=30, auth_timeout=30)
    return c


def run_cmd(c, cmd, timeout=30):
    _, stdout, stderr = c.exec_command(cmd, timeout=timeout)
    out = stdout.read().decode(errors="replace").strip()
    err = stderr.read().decode(errors="replace").strip()
    rc = stdout.channel.recv_exit_status()
    return rc, out, err


def parse_url(url):
    hostport = url.replace("tcp://", "")
    host, port = hostport.rsplit(":", 1)
    return host, int(port)


def main():
    ap = argparse.ArgumentParser(description="glm-bridge discovery tool")
    ap.add_argument("--topic", required=True, help="ntfy.sh topic (secret)")
    ap.add_argument("--list", action="store_true", help="list live servers")
    ap.add_argument("--connect", metavar="SERVER", help="connect to named server")
    ap.add_argument("--cmd", default="hostname && whoami && date", help="command to run")
    ap.add_argument("--user", default="admin")
    ap.add_argument("--password", default="")
    ap.add_argument("--install-user")
    ap.add_argument("--install-pass")
    ap.add_argument("--tunnel-host", help="temp tunnel host for --install")
    ap.add_argument("--tunnel-port", type=int, help="temp tunnel port for --install")
    ap.add_argument("--push", action="append", default=[],
                    help="local file to SFTP-push during --install (repeatable)")
    ap.add_argument("--server-name", default=None, help="name for --install")
    args = ap.parse_args()

    servers = latest_servers(args.topic)
    if not servers:
        print("[!] No live servers found on topic (no RENEW/HEARTBEAT messages).")
        print("    - is the watchdog running on the server?")
        print("    - ntfy.sh free keeps messages ~12h; watchdog heartbeats every 5 min.")
        sys.exit(2)

    if args.list or not args.connect:
        print(f"Live servers on topic '{args.topic}':")
        for name, s in sorted(servers.items()):
            print(f"  {name:24s} {s['url']:55s} ({s['kind']} @ {s['time']})")
        if not args.connect:
            return

    if args.connect:
        if args.connect not in servers:
            print(f"[!] Server '{args.connect}' not in live list: {list(servers)}")
            sys.exit(3)
        s = servers[args.connect]
        host, port = parse_url(s["url"])
        print(f"[*] Connecting {args.connect} via {s['url']} ...")
        c = connect_ssh(host, port, args.user, args.password)
        rc, out, err = run_cmd(c, args.cmd)
        print(out)
        if err:
            print("[stderr]", err)
        c.close()
        print(f"[+] exit={rc}")

    if args.install_user:
        if not (args.tunnel_host and args.tunnel_port):
            ap.error("--install-user requires --tunnel-host/--tunnel-port")
        host, port = args.tunnel_host, args.tunnel_port
        print(f"[*] Installing glm-bridge on {host}:{port} ...")
        c = connect_ssh(host, port, args.install_user, args.install_pass)
        sftp = c.open_sftp()
        try:
            c.exec_command("mkdir -p /tmp/glm-install")
            for f in args.push:
                remote = f"/tmp/glm-install/{f.split('/')[-1]}"
                sftp.put(f, remote)
                print(f"    pushed {f} -> {remote}")
            name = args.server_name or "new-server"
            rc, out, err = run_cmd(c, (
                "setsid nohup bash /tmp/glm-install/glm-bootstrap.sh "
                f"{args.topic} {name} > /tmp/glm-install/bootstrap-run.log 2>&1 "
                "< /dev/null & echo BOOTSTRAP_PID=$!"
            ), timeout=15)
            print("    ", out or err)
        finally:
            sftp.close()
            c.close()
        print("[+] Bootstrap launched detached. Poll ntfy for the new server's RENEW message.")
        print("    Then verify:  python3 discover.py --topic ... --list")


if __name__ == "__main__":
    main()
