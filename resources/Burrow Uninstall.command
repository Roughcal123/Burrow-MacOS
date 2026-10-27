#!/bin/bash
# Fully removes Burrow: tunnel, root helper, sudoers rule, settings, and the app.
echo "This will remove Burrow, its network helper and all saved settings and keys."
read -r -p "Continue? [y/N] " a
[[ $a =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }
echo "Administrator password may be requested."
sudo /usr/local/libexec/burrow/burrow-helper.sh down 2>/dev/null
sudo rm -rf /usr/local/libexec/burrow /etc/sudoers.d/burrow
rm -rf "$HOME/Library/Application Support/Burrow"
pkill -x Burrow 2>/dev/null
rm -rf /Applications/Burrow.app
sudo pkgutil --forget com.burrow.helper >/dev/null 2>&1
echo "Burrow has been removed."
