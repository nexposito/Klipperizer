#!/usr/bin/env bash
# ============================================================
#  Klipperizer — Instalador
#  Uso: bash install.sh
# ============================================================
set -euo pipefail

BASEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { echo -e "\033[1;34m[Klipperizer]\033[0m $*"; }
erro() { echo -e "\033[1;31m[Erro]\033[0m $*" >&2; exit 1; }

# ---------- 1. Dependências do sistema ----------
if command -v apt-get >/dev/null; then PKG=apt
elif command -v dnf >/dev/null; then PKG=dnf
elif command -v pacman >/dev/null; then PKG=pacman
else erro "Distribuição não suportada (apt/dnf/pacman)."
fi

log "Instalando dependências do sistema (pedirá sudo)..."
case $PKG in
  apt)
    sudo apt-get update -qq
    sudo apt-get install -y git build-essential python3 python3-venv python3-pip \
      dfu-util can-utils iproute2 whiptail wget curl
    ;;
  dnf)
    sudo dnf install -y git gcc make python3 python3-pip dfu-util can-utils \
      iproute2 newt wget curl
    ;;
  pacman)
    sudo pacman -Sy --needed git base-devel python python-pip dfu-util can-utils \
      iproute2 libnewt wget curl
    ;;
esac

# yq — processa os perfis YAML das placas
if ! command -v yq >/dev/null 2>&1; then
  log "Instalando yq..."
  case $(uname -m) in
    x86_64)        YQ_ARCH=amd64 ;;
    aarch64|arm64) YQ_ARCH=arm64 ;;
    armv7*|armv6*) YQ_ARCH=arm   ;;
    *) erro "Arquitetura não suportada para yq: $(uname -m)" ;;
  esac
  sudo wget -qO /usr/local/bin/yq \
    "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${YQ_ARCH}"
  sudo chmod +x /usr/local/bin/yq
fi

# ---------- 2. Ambiente Python (ferramentas de flash + painel web) ----------
log "Criando ambiente Python..."
python3 -m venv "$BASEDIR/.venv"
"$BASEDIR/.venv/bin/pip" install --quiet --upgrade pip
"$BASEDIR/.venv/bin/pip" install --quiet python-can pyserial flask

# ---------- 3. Permissões de execução ----------
# Arquivos vindos de sincronização (Drive/GitHub Desktop) podem perder o bit +x
chmod +x "$BASEDIR/klipperizer" "$BASEDIR"/lib/*.sh \
  "$BASEDIR/install.sh" "$BASEDIR/uninstall.sh" \
  "$BASEDIR/web/kiosk.sh" 2>/dev/null || true

# ---------- 4. Regras udev (flash sem sudo) ----------
log "Instalando regras udev..."
sudo cp "$BASEDIR/udev/99-klipperizer.rules" /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo udevadm trigger

# ---------- 5. Comando global ----------
sudo ln -sf "$BASEDIR/klipperizer" /usr/local/bin/klipperizer

# ---------- 6. Painel web (opcional) ----------
if command -v systemctl >/dev/null 2>&1 && \
   whiptail --backtitle "Klipperizer" --title "Painel touch" \
   --yesno "Instalar o painel web touch (para display de 5 polegadas)?\n\nO painel fica em http://<ip-da-máquina>:8080 e abre em qualquer navegador." \
   0 0 3>&1 1>&2 2>&3; then
  log "Instalando serviço do painel web..."
  sudo cp "$BASEDIR/web/klipperizer-web.service" /etc/systemd/system/
  sudo sed -i "s/%i/$(whoami)/g" /etc/systemd/system/klipperizer-web.service
  sudo sed -i "s|/home/%i/klipperizer|$BASEDIR|g" /etc/systemd/system/klipperizer-web.service
  sudo systemctl daemon-reload
  sudo systemctl enable --now klipperizer-web
  log "Painel disponível em: http://$(hostname -I | awk '{print $1}'):8080"
fi

log "Instalação concluída!"
log "Rode 'klipperizer' para abrir o menu. Na 1ª execução o Klipper e o Katapult serão clonados."
