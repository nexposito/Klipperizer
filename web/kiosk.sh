#!/usr/bin/env bash
# ============================================================
#  Klipperizer — modo kiosk para display touch de 5 polegadas
#  Abre o Chromium em tela cheia apontando para o painel local.
#  Chame no autostart do desktop (ex.: ~/.config/autostart/ ou
#  /etc/xdg/lxsession/LXDE-pi/autostart no Raspberry Pi OS).
# ============================================================
set -euo pipefail

# Aguarda o servidor web subir (até 60s)
for i in $(seq 1 60); do
  if curl -sf http://127.0.0.1:8080/api/status >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

# Esconde o cursor e desliga o protetor de tela
command -v unclutter >/dev/null 2>&1 && unclutter -idle 0 &
xset s off -dpms 2>/dev/null || true

exec chromium-browser --kiosk --noerrdialogs \
  --disable-infobars --check-for-update-interval=31536000 \
  --overscroll-history-navigation=0 \
  http://127.0.0.1:8080 2>/dev/null \
  || exec chromium --kiosk --noerrdialogs \
  --disable-infobars --check-for-update-interval=31536000 \
  --overscroll-history-navigation=0 \
  http://127.0.0.1:8080 2>/dev/null
