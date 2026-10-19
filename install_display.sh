#!/usr/bin/env bash
# ============================================================
#  Klipperizer Display — installer
#  Usage: bash display/install_display.sh
#  Installs the GTK stack (same as KlipperScreen), the websocket
#  library and the systemd service that starts the app on the
#  DSI/HDMI display at boot.
# ============================================================
set -euo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log()  { echo -e "\033[1;34m[Klipperizer Display]\033[0m $*"; }
fail() { echo -e "\033[1;31m[Error]\033[0m $*" >&2; exit 1; }

# ---------- 1. GTK stack (KlipperScreen's stack) ----------
log "Installing GTK dependencies (will ask for sudo)..."
if command -v apt-get >/dev/null; then
  sudo apt-get update -qq
  sudo apt-get install -y python3-gi gir1.2-gtk-3.0 python3-gi-cairo \
    gir1.2-gdkpixbuf-2.0 python3-websockets
elif command -v dnf >/dev/null; then
  sudo dnf install -y python3-gobject gtk3 python3-websockets
elif command -v pacman >/dev/null; then
  sudo pacman -Sy --needed python-gobject gtk3 python-websockets
else
  fail "Unsupported distribution."
fi

# ---------- 2. Executable bit ----------
chmod +x "$BASEDIR/display/klipperizer_display.py" 2>/dev/null || true

# ---------- 3. systemd service (autostart on the display) ----------
# Runs on the graphical session (DISPLAY=:0). For Wayland sessions set
# WAYLAND_DISPLAY instead — see display/README.md.
log "Installing the systemd service..."
sudo tee /etc/systemd/system/klipperizer-display.service >/dev/null <<EOF
[Unit]
Description=Klipperizer Display (flashing + printer status)
After=graphical.target
Wants=graphical.target

[Service]
Type=simple
User=$USER
Environment=DISPLAY=:0
ExecStart=/usr/bin/python3 $BASEDIR/display/klipperizer_display.py --fullscreen
Restart=always
RestartSec=3

[Install]
WantedBy=graphical.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable klipperizer-display.service

log "Installation complete!"
log "Start it now with:  sudo systemctl start klipperizer-display"
log "Or test manually:   python3 $BASEDIR/display/klipperizer_display.py"
