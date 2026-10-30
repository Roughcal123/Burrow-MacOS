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

## Set up the server (automatic, one key per person)

Get any small Ubuntu, Debian or Fedora VPS (1 vCPU / 512 MB is plenty) and note its IP and a login with sudo.

**Zero-click builds (recommended).** Simplest and safest: run `sudo burrow-admin code` on the VPS and save the printed code as the repository secret `BURROW_CODE`; no SSH login is needed. Alternatively: Add repository secrets `BURROW_SSH_HOST`, `BURROW_SSH_USER`,
`BURROW_SSH_PASSWORD`, then push a tag. During the build GitHub logs in to the VPS, sets it up, and bakes an
**enrollment code** into the app (your SSH login stays in GitHub secrets and is never put in the app).
When anyone opens Burrow for the first time, the app creates **its own private key on that device**, registers
the matching public key with your server through the tunnel, and connects. Nothing to type.

**Manual.** SSH in and run:

    curl -fsSL https://raw.githubusercontent.com/<you>/<repo>/main/server-setup.sh | sudo bash

then paste the printed enrollment code into Burrow > Settings > Connection code > Import.

### Managing devices (on the server)

    sudo burrow-admin list              # every enrolled device
    sudo burrow-admin revoke <name|ip>  # cut one device off
    sudo burrow-admin rotate            # new enrollment token for future installs (existing devices keep working)
    sudo burrow-admin code              # reprint the enrollment code

Limits: 250 devices, and at most 30 new devices per 10 minutes. The enrollment code lets whoever holds the app
register new devices, so keep the repo/releases private and rotate the token if a build leaks.
If your VPS provider has its own cloud firewall, allow inbound **TCP 443** there.

**Already running nginx on 443 (a website)?** The setup script detects it, runs wstunnel on `127.0.0.1:8443`
and adds a single secret-path `location` to your 443 sites (`/etc/nginx/snippets/burrow.conf`). Your websites are
not affected; the originals are backed up under `/root/burrow-backup-*/nginx`. If nginx rejects the change, it is rolled back.

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
