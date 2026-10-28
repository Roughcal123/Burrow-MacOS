#!/bin/bash
# Build Burrow.app and a drag-to-Applications DMG. Run on a Mac (needs Homebrew + Python 3.11+).
# Optional signing: export CODESIGN_IDENTITY="Developer ID Application: Name (TEAMID)"
# Optional notarization: also export NOTARY_APPLE_ID, NOTARY_TEAM_ID, NOTARY_PASSWORD (app-specific password)
set -euo pipefail
cd "$(dirname "$0")"

for f in resources/burrow-helper.sh resources/install-helper.sh "resources/Burrow Uninstall.command" pkg/scripts/postinstall; do
  [ -f "$f" ] || { echo "Missing $f - commit the whole repo, including 'resources' and 'pkg'"; exit 1; }
done
command -v brew >/dev/null || { echo "Install Homebrew first: https://brew.sh"; exit 1; }

brew list wireguard-tools >/dev/null 2>&1 || brew install wireguard-tools
brew list wireguard-go >/dev/null 2>&1 || brew install wireguard-go
python3 -m venv .venv && source .venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt pyinstaller

ARCH=$(uname -m)
mkdir -p dist
rm -f resources/wg resources/wireguard-go   # earlier copies are read-only
cp "$(brew --prefix)/bin/wg" "$(brew --prefix)/bin/wireguard-go" resources/
chmod 755 resources/wg resources/wireguard-go
otool -L resources/wg resources/wireguard-go
# The tools run on machines without Homebrew, so they must not depend on brew libraries.
if otool -L resources/wg resources/wireguard-go | grep -E "/(opt|usr/local)/(homebrew|Cellar|opt)"; then
  echo "ERROR: a bundled tool links against a Homebrew library"; exit 1
fi

# --- icon ---
QT_QPA_PLATFORM=offscreen python app.py --icon
[ -f burrow.png ] || { echo "Icon generation failed"; exit 1; }
rm -rf burrow.iconset && mkdir burrow.iconset
for s in 16 32 64 128 256 512; do
  sips -z $s $s burrow.png --out burrow.iconset/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) burrow.png --out burrow.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns burrow.iconset -o burrow.icns

# --- helper installer (.pkg): ONE admin prompt, no osascript tricks ---
chmod +x pkg/scripts/postinstall resources/burrow-helper.sh "resources/Burrow Uninstall.command"
rm -rf pkgsrc && mkdir -p pkgsrc/private/tmp/burrow-helper-payload
cp resources/wg resources/wireguard-go resources/burrow-helper.sh pkgsrc/private/tmp/burrow-helper-payload/
V=$(grep -m1 '^VERSION' app.py | cut -d'"' -f2)
pkgbuild --root pkgsrc --scripts pkg/scripts --identifier com.burrow.helper \
  --version "$V" --install-location / "dist/BurrowHelper.pkg"

# --- optional zero-click setup: provision the VPS now and bake in a connection CODE only ---
# (BURROW_SSH_* come from CI secrets; the SSH login itself is NOT put in the app.)
rm -f resources/preset.json
if [ -n "${BURROW_CODE:-}" ]; then
  # Preferred: the enrollment code printed by server-setup.sh (or `sudo burrow-admin code`). No SSH login needed.
  python - <<'PY'
import base64, json, os
d = json.loads(base64.b64decode(os.environ["BURROW_CODE"].strip()))
assert d.get("ip") and d.get("prefix") and d.get("token"), "BURROW_CODE is not an enrollment code"
json.dump({"code": d}, open("resources/preset.json", "w"))
print("Baked the enrollment code into this build")
PY
elif [ -n "${BURROW_SSH_HOST:-}" ]; then
  python app.py --make-preset
fi

# --- app ---
pyinstaller --noconfirm --windowed --name Burrow --icon burrow.icns \
  --osx-bundle-identifier com.burrow.app \
  --add-data "resources:resources" \
  --add-data "dist/BurrowHelper.pkg:resources" \
  --add-data "server-setup.sh:resources" --hidden-import paramiko \
  --collect-data certifi --collect-submodules keyring --copy-metadata keyring app.py

# Sign LAST, after every --add-data, or the added resources invalidate the signature.
SIGN_ID="${CODESIGN_IDENTITY:--}"
if [ "$SIGN_ID" = "-" ]; then
  codesign --force --deep --sign - dist/Burrow.app
else
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_ID" dist/Burrow.app
fi
codesign --verify --deep --strict dist/Burrow.app

# --- DMG ---
rm -rf dmg && mkdir dmg
cp -R dist/Burrow.app dmg/
cp "resources/Burrow Uninstall.command" dmg/
ln -s /Applications dmg/Applications
DMG="dist/Burrow-$ARCH.dmg"
rm -f "$DMG"
hdiutil create -volname Burrow -srcfolder dmg -ov -format UDZO "$DMG"

if [ "$SIGN_ID" != "-" ]; then
  codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
  if [ -n "${NOTARY_APPLE_ID:-}" ]; then
    xcrun notarytool submit "$DMG" --apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" \
      --password "$NOTARY_PASSWORD" --wait
    xcrun stapler staple "$DMG"
  fi
fi
echo "Done: $DMG"
