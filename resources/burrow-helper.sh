#!/bin/bash
# Burrow network helper (macOS). Runs as root via sudo; every argument is validated.
#   burrow-helper.sh up <uid> <server_ip> <tunnel_ip> <dns> <mtu>   (stdin: private key, server public key)
#   burrow-helper.sh down
set -uo pipefail
D=/usr/local/libexec/burrow
ST=/var/run/burrow.state
NAMEF=/var/run/burrow.name
B64='^[A-Za-z0-9+/]{43}=$'
IP4='^[0-9]{1,3}(\.[0-9]{1,3}){3}$'

down() {
  if [ -f "$ST" ]; then
    { read -r SVC; read -r OLD; read -r SRV; } < "$ST"
    route -q -n delete -host "$SRV" >/dev/null 2>&1
    [ -n "$SVC" ] && networksetup -setdnsservers "$SVC" $OLD >/dev/null 2>&1
    rm -f "$ST"
  fi
  pkill -f "$D/wireguard-go" >/dev/null 2>&1
  rm -f "$NAMEF"
  dscacheutil -flushcache >/dev/null 2>&1
  killall -HUP mDNSResponder >/dev/null 2>&1
  return 0
}

up() {
  UIDN=${1:-}; SRV=${2:-}; ADDR=${3:-}; DNS=${4:-}; MTU=${5:-}
  [[ $UIDN =~ ^[0-9]+$ && $SRV =~ $IP4 && $ADDR =~ $IP4 && $DNS =~ $IP4 && $MTU =~ ^[0-9]{3,4}$ ]] \
    || { echo "bad arguments" >&2; exit 2; }
  read -r PRIV; read -r PUB
  [[ $PRIV =~ $B64 && $PUB =~ $B64 ]] || { echo "bad key" >&2; exit 2; }
  down
  GW=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}')
  IFACE=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
  [ -n "$IFACE" ] || { echo "no network connection" >&2; exit 3; }

  WG_TUN_NAME_FILE=$NAMEF "$D/wireguard-go" utun >/dev/null 2>&1 || { echo "wireguard-go failed" >&2; exit 4; }
  for _ in $(seq 1 50); do [ -s "$NAMEF" ] && break; sleep 0.1; done
  TUN=$(cat "$NAMEF" 2>/dev/null); [ -n "$TUN" ] || { echo "no tunnel device" >&2; exit 4; }
  chmod 644 "$NAMEF"   # wireguard-go creates it root-only; the app (running as the user) must read the name
  for _ in $(seq 1 50); do [ -S "/var/run/wireguard/$TUN.sock" ] && break; sleep 0.1; done
  chown "$UIDN" "/var/run/wireguard/$TUN.sock"   # lets the app run "wg show" without root

  CONF=$(mktemp); chmod 600 "$CONF"
  printf '[Interface]\nPrivateKey = %s\n[Peer]\nPublicKey = %s\nAllowedIPs = 0.0.0.0/0\nEndpoint = 127.0.0.1:51821\nPersistentKeepalive = 25\n' \
    "$PRIV" "$PUB" > "$CONF"
  "$D/wg" setconf "$TUN" "$CONF"; RC=$?; rm -f "$CONF"
  [ $RC -eq 0 ] || { down; echo "wg setconf failed" >&2; exit 5; }
  ifconfig "$TUN" inet "$ADDR" "$ADDR" alias && ifconfig "$TUN" mtu "$MTU" up || { down; exit 6; }

  SVC=$(networksetup -listnetworkserviceorder | awk -v d="$IFACE" '/^\([0-9]+\)/{sub(/^\([0-9]+\) /,""); n=$0} index($0,"Device: " d ")"){print n; exit}')
  OLD=$(networksetup -getdnsservers "$SVC" 2>/dev/null | tr '\n' ' ')
  case "$OLD" in *"aren't any"*|"") OLD=Empty;; esac
  printf '%s\n%s\n%s\n' "$SVC" "$OLD" "$SRV" > "$ST"

  # server must bypass the tunnel (wstunnel's own connection), everything else goes through it
  if [ -n "$GW" ]; then route -q -n add -host "$SRV" "$GW"; else route -q -n add -host "$SRV" -interface "$IFACE"; fi
  route -q -n add -inet 0.0.0.0/1 -interface "$TUN"
  route -q -n add -inet 128.0.0.0/1 -interface "$TUN"
  # IPv6 has no path through the tunnel: send it into the (empty) tunnel so it can't leak
  route -q -n add -inet6 ::/1 -interface "$TUN" >/dev/null 2>&1
  route -q -n add -inet6 8000::/1 -interface "$TUN" >/dev/null 2>&1
  [ -n "$SVC" ] && networksetup -setdnsservers "$SVC" "$DNS"
  dscacheutil -flushcache >/dev/null 2>&1; killall -HUP mDNSResponder >/dev/null 2>&1
  exit 0
}

case "${1:-}" in
  up) shift; up "$@" ;;
  down) down ;;
  *) echo "usage: up|down" >&2; exit 2 ;;
esac
