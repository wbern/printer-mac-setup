# One-shot office-printer installer for Windows, designed to run straight from
# the web with nothing to download by hand:
#
#   irm https://pages.bernting.se/room-business-center-skrivare/install.ps1 | iex
#
# It installs the Olivetti d-Copia MF224 / Konica Minolta bizhub C250i
# (192.168.9.15) with per-user authentication that actually works. Windows
# auth to this printer needs THREE things together (any one alone fails
# silently with "Radering av fel" / the job is deleted at the spooler):
#
#   1. Registry fix  RpcAuthnLevelPrivacyEnabled = 0  (undo Microsoft's 2021
#      PrintNightmare hardening that breaks auth to non-Microsoft printers).
#   2. A Windows Credential Manager entry for 192.168.9.15 (so the spooler can
#      answer the printer's auth challenge) — the #1 missing piece.
#   3. The official Olivetti Universal PostScript driver (NOT Generic/PCL).
#
# This script self-elevates (UAC), downloads the driver, prompts for the
# user's initials + PIN, then does all three. Mirrors the field-tested
# auto_install_printer.ps1.

[CmdletBinding()]
param(
    [string]$Username,
    [string]$Password,
    [string]$PrinterIP   = "192.168.9.15",
    [int]   $PrinterPort = 9100,
    [string]$PrinterName = "Room_Business_Center_Olivetti_MF224",
    [switch]$NoTest
)

# ---- CONFIG (edit to match where the files are hosted) ----------------------
$Site      = if ($env:PRINTER_SITE)       { $env:PRINTER_SITE }       else { "https://pages.bernting.se/room-business-center-skrivare" }
$ScriptUrl = if ($env:PRINTER_SCRIPT_URL) { $env:PRINTER_SCRIPT_URL } else { "$Site/install.ps1" }
$DriverUrl = if ($env:PRINTER_DRIVER_URL) { $env:PRINTER_DRIVER_URL } else { "$Site/printer-driver-win-x64.zip" }
$DriverInf = "KOAWNAA_.inf"                       # INF at the root of the zip
$DriverName = "Generic Universal PS v3.9.12"      # name the Olivetti PS driver registers as
# -----------------------------------------------------------------------------

$ErrorActionPreference = "Stop"

function Info($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  $([char]0x2713) $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  ! $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "X $m" -ForegroundColor Red; Read-Host "`nPress Enter to close"; exit 1 }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# --- Self-elevate ------------------------------------------------------------
# Under `irm | iex` there's no script file on disk, so to relaunch elevated we
# re-download ourselves to a temp file and run that as Administrator. Any
# credentials already supplied are forwarded to the elevated session.
if (-not (Test-Admin)) {
    Write-Host ""
    Write-Host "  Office Printer Setup" -ForegroundColor White
    Write-Host ""
    Info "asking for administrator access (Windows will pop up a 'Yes/No' prompt)..."
    $tmp = Join-Path $env:TEMP "printer-setup.ps1"
    try {
        Invoke-WebRequest -Uri $ScriptUrl -OutFile $tmp -UseBasicParsing
    } catch {
        Die "couldn't download the installer from $ScriptUrl. Check your internet connection and try again."
    }
    $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$tmp`"")
    if ($Username) { $argList += @("-Username", $Username) }
    if ($Password) { $argList += @("-Password", $Password) }
    if ($NoTest)   { $argList += "-NoTest" }
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
    } catch {
        Die "administrator access was declined. The printer can't be installed without it. Re-run and click 'Yes' on the prompt."
    }
    return
}

# ===== From here on we are elevated ==========================================
Write-Host ""
Write-Host "  Office Printer Setup  -  Olivetti MF224" -ForegroundColor White
Write-Host ""

# 1) Reachability — fail early, before any changes, if off-network.
Info "checking the printer is reachable ($PrinterIP`:$PrinterPort)..."
$reachable = $false
try {
    $client = New-Object System.Net.Sockets.TcpClient
    $iar = $client.BeginConnect($PrinterIP, $PrinterPort, $null, $null)
    if ($iar.AsyncWaitHandle.WaitOne(3000, $false) -and $client.Connected) { $reachable = $true }
    $client.Close()
} catch { $reachable = $false }
if (-not $reachable) {
    Die "can't reach the printer at $PrinterIP. Connect to the office Wi-Fi/network and run this again. (Nothing has been changed.)"
}
Ok "printer is reachable"

# 2) Credentials — from params, else prompt.
if (-not $Username) {
    Write-Host ""
    Write-Host "Enter your printer login (the initials + 4-digit PIN registered at the printer):" -ForegroundColor White
    $Username = (Read-Host "  Initials (e.g. abc)").Trim()
}
if (-not $Password) {
    $Password = (Read-Host "  PIN (e.g. 1234)").Trim()
}
if (-not $Username -or -not $Password) { Die "initials and PIN are both required." }

# 3) Registry fix (undo PrintNightmare strict RPC auth).
Info "applying the print-auth registry fix..."
$regPath = "HKLM:\System\CurrentControlSet\Control\Print"
if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
Set-ItemProperty -Path $regPath -Name "RpcAuthnLevelPrivacyEnabled" -Value 0 -Type DWord
Ok "registry fix applied (RpcAuthnLevelPrivacyEnabled = 0)"

# 4) Store credentials in Windows Credential Manager.
Info "storing your printer login..."
# Call cmdkey.exe directly (not via cmd /c "...") so PowerShell handles argument
# quoting — a username/PIN with a space or special char won't corrupt the entry.
cmdkey /delete:$PrinterIP 2>$null | Out-Null
$null = cmdkey /add:$PrinterIP /user:$Username /pass:$Password
if ($LASTEXITCODE -ne 0) { Die "couldn't store the credentials (cmdkey failed)." }
Ok "login stored for $PrinterIP (user: $Username)"

# 5) Restart the Print Spooler so it picks up the changes.
Info "restarting the Print Spooler..."
Restart-Service -Name Spooler -Force
Start-Sleep -Seconds 2
Ok "spooler restarted"

# 6) Download + extract the driver.
Info "downloading the printer driver (one-time, ~52 MB)..."
$work = Join-Path $env:TEMP ("kmdriver_" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$zip = Join-Path $work "driver.zip"
try {
    Invoke-WebRequest -Uri $DriverUrl -OutFile $zip -UseBasicParsing
} catch {
    Die "couldn't download the driver from $DriverUrl. Check your connection and try again."
}
Expand-Archive -Path $zip -DestinationPath $work -Force
$inf = Join-Path $work $DriverInf
if (-not (Test-Path $inf)) { Die "driver download looks corrupt ($DriverInf missing). Try again." }
Ok "driver downloaded"

# 7) Install the driver into the Windows driver store.
Info "installing the Olivetti Universal PS driver..."
$pnp = & pnputil.exe /add-driver "$inf" /install 2>&1
# pnputil returns 0 (added), 259 (no new driver / already present), or 3010
# (added, reboot required) on success-ish paths; anything else is worth flagging,
# though Add-Printer below is the real gate.
if ($LASTEXITCODE -notin 0, 259, 3010) {
    Warn "pnputil returned $LASTEXITCODE while adding the driver; continuing."
}
Ok "driver installed in the driver store"

# 8) Remove any existing queue/port with our name so we start clean.
$existing = Get-Printer -Name $PrinterName -ErrorAction SilentlyContinue
if ($existing) { Remove-Printer -Name $PrinterName -Confirm:$false; Ok "removed an old copy of the printer" }

# 9) Create the TCP/IP (RAW 9100) port.
Info "creating the printer port..."
$portName = "IP_$PrinterIP"
$existingPort = Get-PrinterPort -Name $portName -ErrorAction SilentlyContinue
if ($existingPort) { Remove-PrinterPort -Name $portName -Confirm:$false -ErrorAction SilentlyContinue }
Add-PrinterPort -Name $portName -PrinterHostAddress $PrinterIP
Ok "port created ($portName)"

# 10) Add the printer queue.
Info "adding the printer..."
try {
    Add-Printer -Name $PrinterName -DriverName $DriverName -PortName $portName
} catch {
    Write-Host "  Available PostScript drivers:" -ForegroundColor Yellow
    Get-PrinterDriver | Where-Object { $_.Name -like "*PS*" -or $_.Name -like "*Generic*" } |
        Select-Object -ExpandProperty Name | ForEach-Object { Write-Host "    $_" }
    Die "couldn't add the printer with driver '$DriverName'. See the list above."
}
Ok "printer added: $PrinterName"

# 11) Enable bidirectional + SNMP (MFP auth feature detection).
try {
    Set-Printer -Name $PrinterName -EnableBidirectional $true
    Set-PrinterPort -Name $portName -SNMP 1 -SNMPCommunity "public" -ErrorAction SilentlyContinue
    Ok "bidirectional / SNMP enabled"
} catch {
    Warn "couldn't enable bidirectional/SNMP (not fatal) — $_"
}

# 12) Confirmation print.
if (-not $NoTest) {
    Info "sending a test page..."
    try {
        $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        @(
            "Printer setup complete - user: $Username",
            $stamp,
            "",
            "If you can read this, $PrinterName is working."
        ) | Out-Printer -Name $PrinterName
        Ok "test page sent"
    } catch {
        Warn "couldn't send the test page automatically — try Ctrl+P in any app."
    }
}

# Cleanup
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host " All set!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Print from any app with Ctrl+P and choose:" -ForegroundColor White
Write-Host "  $PrinterName" -ForegroundColor Cyan
Write-Host ""
Read-Host "Press Enter to close"
