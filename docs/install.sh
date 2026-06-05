#!/usr/bin/env bash
# One-shot office-printer installer for macOS, designed to run straight from the
# web with no prerequisites:
#
#   curl -fsSL https://pages.bernting.se/printer-mac-setup/install.sh | bash
#   curl -fsSL https://pages.bernting.se/printer-mac-setup/install.sh | bash -s -- -u abc -p 1234
#
# It installs the Olivetti MF224 / Konica Minolta bizhub C250i (192.168.9.15)
# with per-user authentication baked in, so the printer never prompts at the
# panel. Dependency-free: uses only tools present on a stock Mac (bash, perl,
# lpadmin, curl) — no python3, no Homebrew, no Xcode tools required.
#
# What it does:
#   1. Asks for the user's printer username + PIN (or takes -u/-p).
#   2. Installs the Konica Minolta C250i driver if its PPD isn't present.
#   3. Installs the km9100auth CUPS backend (Perl) that injects the PJL auth
#      header — and strips the KMCOETYPE line that otherwise makes GUI prints
#      fail with "Login Error".
#   4. Creates the Olivetti_MF224 queue with those credentials, makes it the
#      default, and removes any no-auth duplicate macOS auto-created.
#   5. Prints a confirmation page.

set -euo pipefail

# ---- CONFIG (edit these to match where you host the files) -------------------
SITE="${PRINTER_SITE:-https://pages.bernting.se/printer-mac-setup}"   # GitHub Pages origin
BACKEND_URL="${PRINTER_BACKEND_URL:-$SITE/km9100auth}" # the Perl backend
DRIVER_URL="${PRINTER_DRIVER_URL:-$SITE/km-c250i-driver.pkg}" # KM driver pkg/dmg
PRINTER_HOST="${PRINTER_HOST:-192.168.9.15}"
PRINTER_PORT="${PRINTER_PORT:-9100}"
QUEUE_NAME="${PRINTER_QUEUE:-Olivetti_MF224}"
# -----------------------------------------------------------------------------

PPD_GZ="/Library/Printers/PPDs/Contents/Resources/KONICAMINOLTAC250i.gz"
BACKEND_DEST="/usr/libexec/cups/backend/km9100auth"

USER_NAME=""
USER_PIN=""
RUN_TEST=1

c_bold=$'\033[1m'; c_green=$'\033[32m'; c_red=$'\033[31m'; c_yellow=$'\033[33m'; c_off=$'\033[0m'
info() { printf '%s==>%s %s\n' "$c_bold" "$c_off" "$*"; }
ok()   { printf '%s✓%s %s\n' "$c_green" "$c_off" "$*"; }
warn() { printf '%s!%s %s\n' "$c_yellow" "$c_off" "$*" >&2; }
die()  { printf '%s✗ error:%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -u|--user)     USER_NAME="${2:-}"; shift 2 ;;
        -p|--pin|--password) USER_PIN="${2:-}"; shift 2 ;;
        --no-test)     RUN_TEST=0; shift ;;
        -h|--help)     sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[[ "$(uname)" == "Darwin" ]] || die "this installer is macOS-only"
command -v perl >/dev/null 2>&1 || die "perl not found (unexpected on macOS)"

printf '\n%s  Office printer setup — Olivetti MF224%s\n\n' "$c_bold" "$c_off"

# --- Prerequisites first, so we never collect a PIN we can't use -------------

# 1) Reachability — fail early (no side effects) if off-network.
info "checking the printer is reachable ($PRINTER_HOST:$PRINTER_PORT)…"
if ! /usr/bin/nc -z -G 3 "$PRINTER_HOST" "$PRINTER_PORT" 2>/dev/null; then
    die "can't reach the printer at $PRINTER_HOST. Connect to the office Wi-Fi/network and run this again."
fi
ok "printer is reachable"

# 2) Administrator access (needed for the driver, backend, and queue).
info "this step needs administrator access — you'll be asked for your Mac password."
sudo -v || die "administrator access is required to install a printer"

# 3) Driver / PPD — settle this BEFORE asking for credentials.
if [[ ! -f "$PPD_GZ" ]]; then
    info "the Konica Minolta C250i driver isn't installed yet — fetching it (one-time)…"
    tmp_pkg="$(mktemp -t kmdriver).pkg"
    if curl -fsSL "$DRIVER_URL" -o "$tmp_pkg" 2>/dev/null && [[ -s "$tmp_pkg" ]]; then
        info "installing driver…"
        sudo installer -pkg "$tmp_pkg" -target / >/dev/null || die "driver install failed"
        rm -f "$tmp_pkg"
    else
        rm -f "$tmp_pkg"
        die "couldn't download the printer driver from:
    $DRIVER_URL
The Konica Minolta C250i driver isn't installed on this Mac and I couldn't fetch
it. Either ask IT to install the 'bizhub C250i' Mac driver and re-run this, or
host the driver .pkg at the URL above. (Nothing else has been changed.)"
    fi
    [[ -f "$PPD_GZ" ]] || die "driver installed but the C250i PPD is still missing"
    ok "driver installed"
else
    ok "Konica Minolta driver already present"
fi

# 4) Credentials — only now that the prerequisites are satisfied. From flags,
# else prompt on the real terminal (works under `curl | bash`, where stdin is
# the script, by reading /dev/tty).
if [[ -z "$USER_NAME" || -z "$USER_PIN" ]]; then
    [[ -e /dev/tty ]] || die "no credentials given and no terminal to prompt on; re-run with -u <user> -p <pin>"
    if [[ -z "$USER_NAME" ]]; then
        printf 'Printer username (e.g. abc): ' > /dev/tty
        read -r USER_NAME < /dev/tty
    fi
    if [[ -z "$USER_PIN" ]]; then
        printf 'Printer PIN: ' > /dev/tty
        read -rs USER_PIN < /dev/tty
        printf '\n' > /dev/tty
    fi
fi
[[ -n "$USER_NAME" && -n "$USER_PIN" ]] || die "username and PIN are required"

# Backend.
info "installing the print backend…"
tmp_be="$(mktemp -t km9100auth)"
curl -fsSL "$BACKEND_URL" -o "$tmp_be" || die "couldn't download the backend from $BACKEND_URL"
perl -c "$tmp_be" >/dev/null 2>&1 || die "downloaded backend failed its self-check"
sudo install -o root -g wheel -m 0500 "$tmp_be" "$BACKEND_DEST"
rm -f "$tmp_be"
ok "backend installed"

# Remove any no-auth duplicate queues macOS auto-created for the same printer
# (these hijack the default and print without credentials -> denied).
while read -r line; do
    q="${line#device for }"; q="${q%%:*}"
    uri="${line#*: }"
    [[ "$q" == "$QUEUE_NAME" ]] && continue
    if [[ "$uri" == *"$PRINTER_HOST"* && ( "$uri" == ipp* || "$uri" == dnssd* || "$uri" == ipps* ) ]]; then
        info "removing no-auth duplicate queue '$q'…"
        sudo lpadmin -x "$q" 2>/dev/null || true
    fi
done < <(lpstat -v 2>/dev/null)

# Configure the queue with the user's credentials.
info "configuring the printer queue '$QUEUE_NAME'…"
enc() { perl -MURI::Escape -e 'print uri_escape($ARGV[0], "^A-Za-z0-9")' "$1" 2>/dev/null \
        || perl -e 'my $s=$ARGV[0]; $s=~s/([^A-Za-z0-9])/sprintf("%%%02X",ord($1))/ge; print $s' "$1"; }
DEVICE_URI="km9100auth://$(enc "$USER_NAME"):$(enc "$USER_PIN")@${PRINTER_HOST}:${PRINTER_PORT}"

PPD_TMP="$(mktemp -t KMC250i).ppd"
trap 'rm -f "$PPD_TMP"' EXIT
gunzip -kc "$PPD_GZ" > "$PPD_TMP"

sudo lpadmin -p "$QUEUE_NAME" -E -v "$DEVICE_URI" -P "$PPD_TMP" \
    -D "Olivetti MF224" -L "Office" \
    -o KMAuthentication=True -o UserType=Private \
    -o CertServerType=Number -o CertServerNum=Device
sudo cupsenable "$QUEUE_NAME" >/dev/null 2>&1 || true
sudo cupsaccept "$QUEUE_NAME" >/dev/null 2>&1 || true
lpoptions -d "$QUEUE_NAME" >/dev/null 2>&1 || true
ok "queue configured and set as your default printer"

# Confirmation print (dependency-free; no SNMP).
if [[ "$RUN_TEST" -eq 1 ]]; then
    info "sending a test page…"
    test_ps="$(mktemp -t kmtest).ps"
    cat > "$test_ps" <<EOF
%!PS-Adobe-3.0
/Helvetica findfont 18 scalefont setfont
72 720 moveto (Printer setup complete — user: $USER_NAME) show
72 700 moveto ($(date '+%Y-%m-%d %H:%M:%S')) show
showpage
EOF
    lp -d "$QUEUE_NAME" "$test_ps" >/dev/null 2>&1 || warn "couldn't send the test page"
    rm -f "$test_ps"
fi

printf '\n%s%s All set!%s A test page is printing now.\n' "$c_bold" "$c_green" "$c_off"
printf 'Print from any app with %sCmd+P%s and choose %s%s%s.\n\n' \
       "$c_bold" "$c_off" "$c_bold" "$QUEUE_NAME" "$c_off"
