#!/usr/bin/env bash
# Run on the VPS as root.
#   sudo burrow-add-client                 -> creates a NEW client key on the server, prints a ready-to-paste code
#   sudo burrow-add-client <public_key>    -> registers a key you already have (Burrow > Settings shows it)
set -euo pipefail
IF=${IF:-wg0}
[ "$(id -u)" = 0 ] || { echo "Run as root (sudo)"; exit 1; }
PRIV=""
if [ -z "${1:-}" ]; then
  PRIV=$(wg genkey); PUB=$(printf '%s' "$PRIV" | wg pubkey)
else
  PUB="$1"
  [[ $PUB =~ ^[A-Za-z0-9+/]{43}=$ ]] || { echo "That doesn't look like a WireGuard public key"; exit 1; }
fi
CONF=/etc/wireguard/$IF.conf
PREFIX=$(cut -d= -f2 /etc/wstunnel/wstunnel.env)
SRVPUB=$(wg show "$IF" public-key)
IP4=$(curl -4fsS https://ifconfig.me || curl -4fsS https://api.ipify.org)
BASE=$(ip -4 -o addr show "$IF" | awk '{print $4}' | cut -d/ -f1 | cut -d. -f1-3)
ADDR=$(wg show "$IF" allowed-ips | awk -v k="$PUB" '$1==k{print $2}' | cut -d/ -f1)
if [ -z "$ADDR" ]; then
  USED=$( { wg show "$IF" allowed-ips; ip -4 -o addr show "$IF"; } | grep -oE "${BASE//./\\.}\.[0-9]+" || true)
  for n in $(seq 2 254); do grep -qx "$BASE.$n" <<<"$USED" || { ADDR="$BASE.$n"; break; }; done
  [ -n "$ADDR" ] || { echo "No free addresses left"; exit 1; }
  wg set "$IF" peer "$PUB" allowed-ips "$ADDR/32"
  grep -q "$PUB" "$CONF" || printf '\n[Peer]\n# burrow\nPublicKey = %s\nAllowedIPs = %s/32\n' "$PUB" "$ADDR" >> "$CONF"
fi
if [ -n "$PRIV" ]; then
  CODE=$(printf '{"ip":"%s","pub":"%s","prefix":"%s","addr":"%s/32","priv":"%s"}' "$IP4" "$SRVPUB" "$PREFIX" "$ADDR" "$PRIV" | base64 -w0)
  echo; echo "Paste this into Burrow > Settings > Connection code, click Import, then Save."
  echo "(It contains this device's private key - treat it like a password.)"
else
  CODE=$(printf '{"ip":"%s","pub":"%s","prefix":"%s","addr":"%s/32"}' "$IP4" "$SRVPUB" "$PREFIX" "$ADDR" | base64 -w0)
  echo; echo "Paste this into Burrow > Settings > Connection code, click Import, then Save."
fi
echo; echo "$CODE"; echo
