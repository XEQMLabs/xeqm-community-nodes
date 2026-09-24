#!/usr/bin/env bash
# setup-rpc-tls.sh — put HTTPS in front of an XEQM public node's RPC for the 1.1.0 wallets.
#
# Installs Caddy as a reverse proxy on :443 -> your local public RPC, with an
# auto-renewing Let's Encrypt certificate (no certbot, no cron). Review before running.
#
#   sudo ./setup-rpc-tls.sh cpn-N.xeqmlabs.com          # your published community hostname
#   sudo ./setup-rpc-tls.sh cpn-N.xeqmlabs.com 9232     # if your public RPC isn't on 9232
#
# Prereqs: the hostname's A record already points at THIS host (XEQMLabs maintains cpn-* records),
# and ports 80+443 are open in BOTH the OS firewall AND your cloud provider's firewall/security list.
set -euo pipefail

HOST="${1:-}"; RPC_PORT="${2:-9232}"
[[ -n "$HOST" ]] || { echo "usage: sudo $0 <hostname> [rpc_port]"; exit 1; }
[[ $EUID -eq 0 ]] || { echo "run with sudo/root"; exit 1; }

echo "==> XEQM public-node TLS setup for ${HOST} -> 127.0.0.1:${RPC_PORT}"

# 1. sanity: is a public RPC actually answering locally? (don't wrap TLS around nothing / a bare SN)
if ! curl -fsS --max-time 6 "http://127.0.0.1:${RPC_PORT}/json_rpc" \
      -H 'Content-Type: application/json' \
      -d '{"jsonrpc":"2.0","id":"0","method":"get_info"}' >/dev/null 2>&1; then
  echo "ERROR: no public RPC on 127.0.0.1:${RPC_PORT}."
  echo "       Set 'rpc-public=127.0.0.1:${RPC_PORT}' on your PUBLIC node and retry (Caddy fronts it on :443)."
  echo "       Note: a bare service node has no public RPC — this script is for public nodes only."
  exit 1
fi

# 1b. Warn if the node still exposes its RPC directly (old-style public bind).
# With Caddy terminating TLS on :443, a lingering --rpc-bind-ip /
# --confirm-external-bind leaves an UNENCRYPTED public RPC alongside it —
# redundant and a security risk. (Reported by a community operator: remove the
# old flags when moving to the Caddy setup.)
if pgrep -af 'xeqm-d' 2>/dev/null | grep -qE -- '--rpc-bind-ip|--confirm-external-bind' \
   || grep -rqsE -- '(--)?rpc-bind-ip|(--)?confirm-external-bind' /etc/systemd/system/*xeqm* /etc/xeqm* 2>/dev/null; then
  echo "WARNING: this node still binds its RPC to a public interface"
  echo "         (--rpc-bind-ip / --confirm-external-bind, or rpc-bind-ip/confirm-external-bind in config)."
  echo "         With Caddy fronting TLS on :443 that leaves an UNENCRYPTED public RPC exposed."
  echo "         Remove those, bind RPC to localhost (rpc-public=127.0.0.1:${RPC_PORT}), and restart your node."
  echo "         Continuing in 5s (Ctrl-C to fix first)…"
  sleep 5
fi

# 2. pre-flight: does ${HOST} resolve to THIS machine? (stale A record = cert will fail)
MYIP="$(curl -fsS --max-time 6 https://api.ipify.org 2>/dev/null || true)"
DNSIP="$(getent hosts "$HOST" | awk '{print $1; exit}' || true)"
if [[ -n "$MYIP" && -n "$DNSIP" && "$MYIP" != "$DNSIP" ]]; then
  echo "WARNING: ${HOST} resolves to ${DNSIP} but this host's public IP looks like ${MYIP}."
  echo "         The Let's Encrypt challenge will FAIL until the A record points here."
  echo "         Ask XEQMLabs to update the cpn-* record, then re-run. Continuing in 5s (Ctrl-C to abort)…"
  sleep 5
fi

# 3. install Caddy (official apt repo) if missing
if ! command -v caddy >/dev/null 2>&1; then
  echo "==> installing Caddy"
  apt-get install -y -q debian-keyring debian-archive-keyring apt-transport-https curl >/dev/null
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
  apt-get update -q >/dev/null && apt-get install -y -q caddy >/dev/null
fi
echo "==> caddy $(caddy version | awk '{print $1}')"

# 4. Caddyfile: TLS -> local RPC; keep admin-style endpoints off the public surface
cat > /etc/caddy/Caddyfile <<CF
${HOST} {
    reverse_proxy 127.0.0.1:${RPC_PORT}
    encode gzip
    @blocked path /set_log* /stop_daemon* /out_peers* /in_peers* /update* /mining_status* /start_mining* /stop_mining*
    respond @blocked 403
}
CF

# 5. open the OS firewall (ufw) if present — 80 = ACME challenge + redirect, 443 = HTTPS
if command -v ufw >/dev/null 2>&1; then ufw allow 80/tcp >/dev/null 2>&1 || true; ufw allow 443/tcp >/dev/null 2>&1 || true; fi

# 6. start + wait for the cert
systemctl restart caddy
echo -n "==> obtaining certificate"
for _ in $(seq 1 20); do
  if curl -fsS --max-time 6 "https://${HOST}/json_rpc" -H 'Content-Type: application/json' \
       -d '{"jsonrpc":"2.0","id":"0","method":"get_info"}' >/dev/null 2>&1; then
    echo; echo "==> SUCCESS: https://${HOST}/json_rpc is live (cert issued, auto-renews)."; exit 0
  fi
  echo -n "."; sleep 6
done

echo; echo "==> Caddy is running but https://${HOST} isn't answering yet."
echo "    Almost always: 80/443 not open in your CLOUD firewall (OCI VCN / AWS SG / GCP), or the A record isn't pointing here yet."
echo "    Check:  sudo journalctl -u caddy -n 30"
exit 1
