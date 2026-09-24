# XEQM Community Public Nodes

Tooling for operators running a public node published as `cpn-N.xeqmlabs.com`.

## HTTPS for wallet RPC

The 1.1.0 wallets default to HTTPS endpoints, so a `cpn-*` node needs TLS on :443 to be used.

**Design:** the `cpn-*` records are **DNS-only** A records (XEQMLabs maintains the IP↔operator mapping
in Cloudflare). Each node terminates its own TLS via Caddy + Let's Encrypt — direct, auto-renewing,
no middleman. We deliberately do **not** Cloudflare-proxy the RPC (edge caching/size/timeout limits
degrade wallet `get_blocks`, and it would centralize community RPC through one account).

### Setup

Prereqs: `cpn-N.xeqmlabs.com` points at your host (we maintain that — ping us if your IP changed),
your public RPC answers on `127.0.0.1:9232` (`rpc-public=…:9232`), and **80 + 443 are open in both the
OS firewall and your cloud firewall/security-list**.

```bash
curl -fsSLO https://raw.githubusercontent.com/XEQMLabs/xeqm-community-nodes/main/setup-rpc-tls.sh
less setup-rpc-tls.sh                       # review
sudo bash setup-rpc-tls.sh cpn-N.xeqmlabs.com   # your hostname; add a port arg if not 9232
```

Caddy obtains and renews the cert (HTTP-01 — works because the A record already points at you).
Idempotent. If the cert doesn't issue it's ~always 80/443 blocked at the cloud firewall or a stale
A record — verify reachability from outside: `curl -sI http://cpn-N.xeqmlabs.com`.

> **Already exposing your RPC directly?** If your node currently binds RPC to a public interface
> (`--rpc-bind-ip` / `--confirm-external-bind`, or `rpc-bind-ip` / `confirm-external-bind` in the
> config), **remove those and bind RPC to localhost** (`rpc-public=127.0.0.1:9232`). Otherwise you
> keep an unencrypted public RPC alongside the new HTTPS one — the whole point is that :443 (Caddy)
> is the only public surface. The setup script warns if it sees the old flags. _(Thanks to the
> community operator who flagged this.)_

### Optional hardening
Once HTTPS is confirmed, set `rpc-public=127.0.0.1:9232` and close 9232 at the firewall so :443 is
the only public surface.
