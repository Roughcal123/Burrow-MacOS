#!/bin/bash
# Build Burrow.app and a drag-to-Applications DMG. Run on a Mac (needs Homebrew + Python 3.11+).
set -euo pipefail
cd "$(dirname "$0")"
for f in burrow-helper.sh install-helper.sh; do
  [ -f "resources/$f" ] || { echo "Missing resources/$f - upload the whole 'resources' folder to the repo root"; exit 1; }
done
mkdir -p resources
command -v brew >/dev/null || { echo "Install Homebrew first: https://brew.sh"; exit 1; }
brew install wireguard-tools wireguard-go
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt pyinstaller
ARCH=$(uname -m)
cp "$(brew --prefix)/bin/wg" "$(brew --prefix)/bin/wireguard-go" resources/
otool -L resources/wg resources/wireguard-go
python app.py --icon
rm -rf burrow.iconset && mkdir burrow.iconset
for s in 16 32 64 128 256 512; do
  sips -z $s $s burrow.png --out burrow.iconset/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) burrow.png --out burrow.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns burrow.iconset -o burrow.icns
pyinstaller --noconfirm --windowed --name Burrow --icon burrow.icns \
  --add-data "resources:resources" --collect-data certifi --collect-submodules keyring --copy-metadata keyring app.py
codesign --force --deep --sign - dist/Burrow.app
rm -rf dmg && mkdir dmg && cp -R dist/Burrow.app dmg/ && ln -s /Applications dmg/Applications
hdiutil create -volname Burrow -srcfolder dmg -ov -format UDZO "dist/Burrow-$ARCH.dmg"
echo "Done: dist/Burrow-$ARCH.dmg"
