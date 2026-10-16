# Klipperizer

Sistema automatizado de flash de firmware [Klipper](https://www.klipper3d.org/) para placas de impressoras 3D — com suporte a **CAN bus** e **USB**.

Escolha a placa no menu, escolha a comunicação e o Klipperizer faz o resto: gera o `.config` do menuconfig automaticamente, compila, detecta a placa, avisa quando for preciso entrar em modo DFU e grava o firmware.

## Instalação

```bash
git clone https://github.com/nexposito/Klipperizer
cd Klipperizer
bash install.sh
```

O instalador cuida de tudo: dependências (git, build-essential, python3, dfu-util, can-utils, whiptail, yq), ambiente Python, regras udev (flash sem sudo), comando global `klipperizer` e — opcionalmente — o **painel web touch** para display de 5 polegadas.

## Uso

### Terminal (menu interativo)

```bash
klipperizer
```

1. Escolha a placa no menu
2. Escolha a comunicação: **CAN** ou **USB**
3. Siga as instruções na tela — o sistema avisa quando colocar a placa em modo DFU (apenas no primeiro flash)
4. Nas atualizações seguintes, o flash é direto via Katapult, sem DFU

### Painel touch (display de 5 polegadas)

Se instalado, o painel fica em `http://<ip-da-máquina>:8080` — acessível pelo display touch e por qualquer navegador na rede (celular, PC). Cards grandes de placas, seletor de modo e log ao vivo.

Para abrir automaticamente em tela cheia no display no boot:

```bash
# adicione ao autostart do desktop (ex.: /etc/xdg/lxsession/LXDE-pi/autostart no Raspberry Pi OS)
@bash /caminho/para/Klipperizer/web/kiosk.sh
```

### Linha de comando (scripts e automação)

```bash
klipperizer --list                          # lista placas em JSON
klipperizer --flash boards/toolhead/btt_ebb36_v12.yaml can
```

## Como funciona

- **Perfis YAML** em `boards/` descrevem cada placa: MCU, opções de menuconfig, método de gravação, IDs USB e avisos de hardware
- O sistema gera o `.config` a partir do perfil, compila **Katapult** (bootloader) e **Klipper**, e grava na placa
- Primeiro flash: DFU/BOOT → Katapult → Klipper
- Atualizações: direto via Katapult (USB serial ou CAN), sem DFU
- Adaptadores USB-CAN (U2C, UTOC, UTC) recebem firmware direto via dfu-util

## Placas suportadas (56 perfis)

### Toolheads (25)

AFC-Lite (Boxturtle), AFC-Pro, BTT EBB36 Gen2, BTT EBB36 V1.2, BTT EBB42 Gen2, BTT EBB42 V1.2, BTT Eddy Duo, BTT MMB v1.0/v1.1, BTT MMB v2.0, BTT SB2209 (RP2040), BTT SB2209/SB2240 (STM32), DragonDinghy, Fysetc H36, Fysetc H36 v2.0, Fysetc PITB V1.0, Fysetc PITB V2.0, Fysetc SB Combo V2, Fysetc SB-CAN-TH, MKS THR36 V1.0, Mellow Fly ERCF, Mellow Fly SB2040 v1/v2, Mellow Fly SB2040 v3, Mellow Fly SHT36/SHT42, Mellow Fly SHT36 v2, Mellow Fly SHT36 v3

### Mainboards (28)

BTT Kraken, BTT Manta E3EZ, BTT Manta M5P V1.0, BTT Manta M8P V1.1, BTT Manta M8P V2.0, BTT Octopus (F446/F429/F407/H723), BTT Octopus Max EZ, BTT Octopus Pro v1.1, BTT Octopus X7 (Troodon), BTT SKR Pico, BTT SKR-3, BTT SKR-3 EZ (H723/H743), BTT SKRat v1.0, Fysetc Hexa Distro Fusion, Fysetc Spider King, Fysetc Spider Pro, Fysetc Spider v1.0, Fysetc Spider v2.2, Fysetc Spider v2.3, Fysetc Spider v3.0, Fysetc Spider v3.0 H7, LDO Leviathan v1.2, LDO Leviathan v1.3, MKS Monster8 v2, Mellow FLY-D5P, Mellow FLY-Micro4, Mellow Fly-Super8, Mellow Fly-Super8 Pro H723

### Adaptadores USB-CAN (3)

BTT U2C v2.1, Makerbase UTC 1.0, Mellow Fly UTOC-1/UTOC-3

Base de referência: [canbus.esoterical.online](https://canbus.esoterical.online)

## Estado dos perfis

- ✅ **Validados no guia**: modo de gravação, VID:PID, MCU e avisos de hardware
- ⚠️ **Marcados com `# VALIDAR`**: offsets de bootloader e pinos CAN de algumas placas — o build valida os símbolos contra o Kconfig e falha com mensagem clara se algo estiver errado

## Adicionando uma placa

Veja [CONTRIBUTING.md](CONTRIBUTING.md). Resumo:

1. Copie `schema/boards.template.yaml` para `boards/<categoria>/<nome>.yaml`
2. Preencha as opções de menuconfig (o guia do Esoterical tem os screenshots de cada placa; ou use `tools/extract_board_configs.py`)
3. Abra um Pull Request — a CI valida o YAML automaticamente

## Estrutura

```
Klipperizer/
├── klipperizer        # menu principal + orquestração (CLI + modos --list/--flash)
├── install.sh         # instalador
├── uninstall.sh       # desinstalador
├── lib/               # build, detecção, flash e avisos
├── boards/            # perfis das placas (YAML)
├── schema/            # template de perfil
├── udev/              # regras de acesso USB
├── web/               # painel touch (Flask) + kiosk para display 5"
├── tools/             # extrator de configs do guia Esoterical
└── .github/workflows/ # CI (valida perfis e scripts)
```

## Licença

GPL-3.0 — veja [LICENSE](LICENSE).
