# Deploying the printer setup site

The `docs/` folder is a complete, static GitHub Pages site. Once it's live, any
Mac **or Windows** user adds the office printer by visiting the page and pasting
one line into Terminal (Mac) or PowerShell (Windows). No app, no Apple Developer
account, no Python — the Mac backend is Perl (every Mac has it) and the Windows
installer is plain PowerShell (every PC has it).

The page auto-detects the OS and shows the right flow; a `macOS | Windows` toggle
in the header lets users switch manually.

## What's in here

All site files live under `docs/`.

| File | Purpose |
|------|---------|
| `index.html` | The page users visit — a 5-step wizard (welcome → login → open Terminal/PowerShell → paste command → done), **OS-aware (Mac/Windows)**, EN/SV, dark theme matching `cc-onboarding-personas`. Generates each user's personalized command. |
| **macOS** | |
| `install.sh` | The `curl … \| bash` installer. Dependency-free. |
| `km9100auth` | The Perl CUPS backend the installer deploys (injects PJL auth, strips the `KMCOETYPE` line that breaks GUI prints). |
| `km-c250i-driver.pkg` | The Konica Minolta C250i Mac driver (47 MB, signed by KM). Extracted from `IT6PSMACOS_536AMU.dmg`; installs the `KONICAMINOLTAC250i` PPD. |
| **Windows** | |
| `install.ps1` | The `irm … \| iex` installer. Self-elevates (UAC), prompts for initials + PIN, downloads the driver, applies the `RpcAuthnLevelPrivacyEnabled=0` registry fix + `cmdkey` credential + Olivetti PS driver. Source of truth: `printer-windows-setup/web_install.ps1`. |
| `printer-driver-win-x64.zip` | Olivetti Universal PS v3.9.12 driver, x64 only (52 MB). Zipped from `printer-windows-setup/GEUPDPSWin_3912040MU/driver/win_x64`; INF `KOAWNAA_.inf` at the zip root. Fetched at runtime by `install.ps1`. |

## One-time setup

1. **Drivers — already bundled.** `docs/km-c250i-driver.pkg` (Mac, 47 MB) and
   `docs/printer-driver-win-x64.zip` (Windows, 52 MB) are both in place, so no
   action needed. They're large binaries committed to the repo; if you'd rather
   not commit them, move them to GitHub *Release* assets and set
   `PRINTER_DRIVER_URL` (env var, read by both `install.sh` and `install.ps1`)
   to those URLs.

2. **Push to GitHub and enable Pages.**
   ```sh
   git init && git add docs && git commit -m "printer setup site"
   git branch -M main && git remote add origin <your-repo> && git push -u origin main
   ```
   Repo → Settings → Pages → Source: *Deploy from a branch* → `main` / `/docs`.

3. **Point the domain.** Add a DNS `CNAME` record for `printer.bernting.se` →
   `<youruser>.github.io` (same pattern as `cc-onboarding-personas`). GitHub Pages
   will issue HTTPS automatically. If you don't want a custom domain, delete
   `docs/CNAME` and update the URLs in `index.html` (`MAC_INSTALL_URL` /
   `WIN_INSTALL_URL`), `SITE` in `install.sh`, and `$Site` in `install.ps1` to the
   `…github.io/<repo>` URL.

4. **Share the link.** Send people to `https://pages.bernting.se/room-business-center-skrivare`. That's it.

## Updating later

- Change the Mac backend? Edit `docs/km9100auth` directly, commit, push. (The
  local `install_printer.sh` keeps its own copy at `bin/km9100auth`; both are
  gitignored, on-disk only.)
- Change the Windows installer? Edit `docs/install.ps1` directly, commit, push.
  The local `printer-windows-setup/web_install.ps1` is the original source for
  reference.
- Installers fetch the latest `install.sh` / `install.ps1` (and the Mac backend)
  at run time, so users get fixes automatically the next time they run it.

## Notes

- **Mac:** the generated command contains the user's PIN by default (convenient).
  Users who prefer not to can tick the box on the page; the installer then prompts
  for the PIN in Terminal instead. `install.sh` also removes the no-auth
  `_192_168_9_15`-style duplicate queue macOS auto-creates and sets
  `Room_Business_Center_Olivetti_MF224` as the default — the two things that broke printing originally.
- **Windows:** the `irm … | iex` one-liner never carries the PIN — `install.ps1`
  always prompts for initials + PIN inside the elevated PowerShell window. The
  three things it must do together (any one alone fails silently): the
  `RpcAuthnLevelPrivacyEnabled=0` registry fix, the `cmdkey` Credential Manager
  entry, and the official Olivetti PostScript driver. See
  `printer-windows-setup/README.md` for the full background.
- The Windows installer can't be run from this Mac (no Windows). It was written to
  mirror the field-tested `printer-windows-setup/auto_install_printer.ps1`
  step-for-step and passes a PowerShell AST parse; verify it on a real PC before
  wide rollout.
