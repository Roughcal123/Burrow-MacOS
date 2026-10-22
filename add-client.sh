#!/usr/bin/env bash
# Run on the VPS as root: sudo bash add-client.sh <client_public_key>
# Registers the client on wg0 (once) and prints a connection code for Burrow.
set -euo pipefail
IF=${IF:-wg0}
PUB="${1:?usage: sudo bash add-client.sh <client_public_key>}"
[[ $PUB =~ ^[A-Za-z0-9+/]{43}=$ ]] || { echo "That doesn't look like a WireGuard public key"; exit 1; }
[ "$(id -u)" = 0 ] || { echo "Run as root"; exit 1; }
CONF=/etc/wireguard/$IF.conf
PREFIX=$(cut -d= -f2 /etc/wstunnel/wstunnel.env)
SRVPUB=$(wg show "$IF" public-key)
IP4=$(curl -4fsS https://ifconfig.me)
BASE=$(ip -4 -o addr show "$IF" | awk '{print $4}' | cut -d/ -f1 | cut -d. -f1-3)
ADDR=$(wg show "$IF" allowed-ips | awk -v k="$PUB" '$1==k{print $2}' | cut -d/ -f1)
if [ -z "$ADDR" ]; then
  USED=$( { wg show "$IF" allowed-ips; ip -4 -o addr show "$IF"; } | grep -oE "${BASE//./\\.}\.[0-9]+" || true)
  for n in $(seq 2 254); do grep -qx "$BASE.$n" <<<"$USED" || { ADDR="$BASE.$n"; break; }; done
  wg set "$IF" peer "$PUB" allowed-ips "$ADDR/32"
  grep -q "$PUB" "$CONF" || printf '\n[Peer]\n# burrow\nPublicKey = %s\nAllowedIPs = %s/32\n' "$PUB" "$ADDR" >> "$CONF"
fi
CODE=$(printf '{"ip":"%s","pub":"%s","prefix":"%s","addr":"%s/32"}' "$IP4" "$SRVPUB" "$PREFIX" "$ADDR" | base64 -w0)
echo; echo "Paste this into Burrow > Settings > Connection code:"; echo; echo "$CODE"; echo
