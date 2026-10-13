#!/usr/bin/env bash
# Klipperizer — desinstalador
set -euo pipefail
BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

sudo rm -f /usr/local/bin/klipperizer
sudo rm -f /etc/udev/rules.d/99-klipperizer.rules
sudo udevadm control --reload-rules

echo "Klipperizer removido."
echo "A pasta $BASEDIR (incluindo klipper/, katapult/ e .venv/) pode ser apagada manualmente."
