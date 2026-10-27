# Burrow

WireGuard over a WebSocket tunnel (wstunnel) for macOS and Windows.

## Install on a Mac

1. Download the DMG for your Mac from the [Releases](../../releases) page:
   - `Burrow-arm64.dmg` for Apple Silicon (M1/M2/M3/M4)
   - `Burrow-x86_64.dmg` for Intel
2. Open the DMG and drag **Burrow** to **Applications**.
3. First launch (unsigned builds only): right-click Burrow, choose **Open**, then **Open** again.
   If macOS still blocks it, run: `xattr -dr com.apple.quarantine /Applications/Burrow.app`
4. On first connect Burrow asks for your password once to install its network helper.

To remove everything, run **Burrow Uninstall.command** from the DMG.

## Build locally (on a Mac)

    brew install python   # 3.11+
    bash build-mac.sh     # produces dist/Burrow-<arch>.dmg

## Publish a release

    git tag v1.1.0 && git push origin v1.1.0

GitHub Actions builds both Mac DMGs (and the Windows installer) and attaches them to the release.
You can also run the workflow manually from the Actions tab; the DMGs appear as run artifacts.

## Optional: signed and notarized builds (needs an Apple Developer account)

Add these repository secrets (Settings > Secrets and variables > Actions):
`MAC_CERT_P12` (base64 of your Developer ID Application .p12), `MAC_CERT_PASSWORD`,
`CODESIGN_IDENTITY` (e.g. `Developer ID Application: Your Name (TEAMID)`),
`NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, `NOTARY_PASSWORD` (app-specific password).
Without them the build is ad-hoc signed and users follow step 3 above.
