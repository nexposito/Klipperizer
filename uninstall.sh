#!/usr/bin/env bash
# Klipperizer — uninstaller
set -euo pipefail
BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

sudo rm -f /usr/local/bin/klipperizer
sudo rm -f /etc/udev/rules.d/99-klipperizer.rules
sudo udevadm control --reload-rules

echo "Klipperizer removed."
echo "The $BASEDIR folder (including klipper/, katapult/ and .venv/) can be deleted manually."
