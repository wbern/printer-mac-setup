#!/usr/bin/env bash
# Install the office printer (Olivetti MF224 / KM bizhub C250i at 192.168.9.15)
# on this Mac. Mirrors the Windows side's auto_install_printer.ps1.
#
# Usage:
#   ./install_printer.sh                          # interactive prompt
#   ./install_printer.sh -u abc -p 1234            # non-interactive
#   ./install_printer.sh -u abc -p 1234 --no-test  # skip the smoke-test print
#
# What it does:
#   1. If the KM C250i PPD isn't installed, installs a bundled driver (.pkg
#      or .dmg) sitting next to this script (or in a 'driver/' subdir).
#   2. Installs the km9100auth CUPS backend (sudo, one-time per Mac).
#   3. Creates or reconfigures the Room_Business_Center_Olivetti_MF224 CUPS queue to use that
#      backend with the user's own credentials.
#   4. Smoke-tests by sending a small print and polling the printer's SNMP
#      job log to confirm it actually printed (not just CUPS-completed).

set -euo pipefail

PRINTER_HOST="192.168.9.15"
PRINTER_PORT=9100
QUEUE_NAME="Room_Business_Center_Olivetti_MF224"
PPD_GZ="/Library/Printers/PPDs/Contents/Resources/KONICAMINOLTAC250i.gz"
BACKEND_DEST="/usr/libexec/cups/backend/km9100auth"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_SRC="$SCRIPT_DIR/bin/km9100auth"
VERIFIER="$SCRIPT_DIR/verify/verify_jobs.py"

USER_NAME=""
USER_PIN=""
RUN_TEST=1

die() { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--user)     USER_NAME="$2"; shift 2 ;;
        -p|--password) USER_PIN="$2"; shift 2 ;;
        --no-test)     RUN_TEST=0; shift ;;
        -h|--help)
            sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) die "unknown argument: $1" ;;
    esac
done

[[ "$(uname)" == "Darwin" ]] || die "this installer is macOS-only"

# If the KM driver isn't installed, try to install one bundled next to this
# script — first look for a *.pkg in the script dir or driver/ subdir, then
# fall back to mounting any *.dmg and installing the pkg inside.
install_bundled_driver() {
    local pkg dmg mount
    pkg=$(find "$SCRIPT_DIR" "$SCRIPT_DIR/driver" -maxdepth 1 -iname '*.pkg' -type f 2>/dev/null | head -1)
    if [[ -n "$pkg" ]]; then
        info "installing bundled driver: $(basename "$pkg")"
        sudo installer -pkg "$pkg" -target /
        return $?
    fi
    dmg=$(find "$SCRIPT_DIR" "$SCRIPT_DIR/driver" -maxdepth 1 -iname '*.dmg' -type f 2>/dev/null | head -1)
    if [[ -n "$dmg" ]]; then
        info "mounting bundled driver image: $(basename "$dmg")"
        mount=$(hdiutil attach "$dmg" -nobrowse -readonly -plist 2>/dev/null |
                python3 -c 'import plistlib,sys; d=plistlib.loads(sys.stdin.buffer.read()); print(next((e["mount-point"] for e in d["system-entities"] if "mount-point" in e), ""))')
        [[ -d "$mount" ]] || { echo "could not mount $dmg" >&2; return 1; }
        pkg=$(find "$mount" -maxdepth 3 -iname '*.pkg' -type f 2>/dev/null | head -1)
        if [[ -n "$pkg" ]]; then
            info "installing $(basename "$pkg") from mounted image"
            sudo installer -pkg "$pkg" -target /
            local rc=$?
            hdiutil detach "$mount" -quiet || true
            return $rc
        fi
        hdiutil detach "$mount" -quiet || true
        echo "no .pkg found inside $dmg" >&2
        return 1
    fi
    return 1
}

if [[ ! -f "$PPD_GZ" ]]; then
    info "KM C250i PPD not present — looking for a bundled driver next to this script"
    if install_bundled_driver && [[ -f "$PPD_GZ" ]]; then
        info "driver installed"
    else
        die "KM C250i PPD still missing after install attempt.
Drop the Konica Minolta bizhub C250i Mac driver (.pkg or .dmg) next to this
script (or into a 'driver/' subdir) and re-run. The driver comes from the
Konica Minolta support portal — search for 'bizhub C250i Mac PS driver'."
    fi
fi

[[ -x "$BACKEND_SRC" ]] || die "backend script not found at $BACKEND_SRC"

if [[ -z "$USER_NAME" ]]; then
    read -rp "Printer username (e.g. abc): " USER_NAME
fi
if [[ -z "$USER_PIN" ]]; then
    read -rsp "Printer PIN: " USER_PIN
    echo
fi
[[ -n "$USER_NAME" && -n "$USER_PIN" ]] || die "username and PIN are required"

# The PIN can contain shell-special chars; URL-encode it for the device URI.
encoded_pin=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$USER_PIN")
encoded_user=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$USER_NAME")
DEVICE_URI="km9100auth://${encoded_user}:${encoded_pin}@${PRINTER_HOST}:${PRINTER_PORT}"

info "checking printer reachability ($PRINTER_HOST:$PRINTER_PORT)…"
if ! nc -z -G 3 "$PRINTER_HOST" "$PRINTER_PORT" 2>/dev/null; then
    die "can't reach $PRINTER_HOST:$PRINTER_PORT — connect to the office network and retry"
fi

info "installing backend to $BACKEND_DEST (will prompt for sudo)…"
sudo install -o root -g wheel -m 0500 "$BACKEND_SRC" "$BACKEND_DEST"

# Unpack PPD to a temp file lpadmin can read.
PPD_TMP="$(mktemp /tmp/KMC250i.XXXXXX.ppd)"
trap 'rm -f "$PPD_TMP"' EXIT
gunzip -kc "$PPD_GZ" > "$PPD_TMP"

info "configuring CUPS queue '$QUEUE_NAME'…"
sudo lpadmin -p "$QUEUE_NAME" -E -v "$DEVICE_URI" -P "$PPD_TMP" \
    -o KMAuthentication=True -o UserType=Private \
    -o CertServerType=Number -o CertServerNum=Device
sudo cupsenable "$QUEUE_NAME" >/dev/null 2>&1 || true
sudo cupsaccept "$QUEUE_NAME" >/dev/null 2>&1 || true

info "queue device URI: $(lpstat -v "$QUEUE_NAME" | sed -E 's|(km9100auth://[^:]+):[^@]+@|\1:***@|')"

if [[ "$RUN_TEST" -eq 1 ]]; then
    info "sending a test print and verifying via SNMP…"
    test_ps="$(mktemp /tmp/kmtest.XXXXXX.ps)"
    cat > "$test_ps" <<EOF
%!PS-Adobe-3.0
/Helvetica findfont 18 scalefont setfont
72 720 moveto (Mac printer install test — user: $USER_NAME) show
72 700 moveto ($(date '+%Y-%m-%d %H:%M:%S')) show
showpage
EOF
    since="$(date '+%H:%M')"
    lp -d "$QUEUE_NAME" "$test_ps" >/dev/null
    rm -f "$test_ps"

    # Printer clock may drift; poll up to ~30s for a new OK entry attributed to us.
    ok=0
    for i in $(seq 1 10); do
        sleep 3
        out=$("$VERIFIER" --since "$since" 2>/dev/null || true)
        if echo "$out" | grep -qE '^[[:space:]]*[0-9]+[[:space:]].*[[:space:]]OK[[:space:]]'; then
            ok=1
            break
        fi
    done

    if [[ "$ok" -eq 1 ]]; then
        info "test print confirmed printed (SNMP log shows OK)"
    else
        echo "warning: test print did not show as OK in the SNMP log within ~30s." >&2
        echo "         check the printer physically, and re-run: $VERIFIER --since $since" >&2
        echo "         a DENIED line means the username/PIN is wrong." >&2
        exit 2
    fi
fi

cat <<EOF

Done. You can now print from any Mac app:
  - GUI:  Cmd+P, choose "$QUEUE_NAME"
  - CLI:  lp -d $QUEUE_NAME <file>

To remove the queue:           sudo lpadmin -x $QUEUE_NAME
To remove the backend:         sudo rm $BACKEND_DEST
To verify what hit the printer: $VERIFIER --since HH:MM
EOF
