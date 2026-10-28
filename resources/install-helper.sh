#!/bin/bash
# Run once as root (Burrow triggers this with a macOS admin prompt).
set -euo pipefail
SRC="$1"; D=/usr/local/libexec/burrow
mkdir -p "$D" /etc/sudoers.d
for f in wg wireguard-go burrow-helper.sh; do install -o root -g wheel -m 755 "$SRC/$f" "$D/$f"; done
xattr -dr com.apple.quarantine "$D" 2>/dev/null || true
T=$(mktemp)
echo '%admin ALL=(root) NOPASSWD: /usr/local/libexec/burrow/burrow-helper.sh' > "$T"
visudo -cf "$T" >/dev/null
install -o root -g wheel -m 440 "$T" /etc/sudoers.d/burrow
rm -f "$T"
