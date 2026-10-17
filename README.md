# Klipperizer

Automated Klipper firmware flashing system for 3D printer boards — with **CAN bus** and **USB** support.

Pick the board type in the menu, pick the board, pick the communication mode, and Klipperizer does the rest: generates the menuconfig `.config` automatically, builds, detects the board, warns when DFU mode is needed and flashes the firmware.

## Installation

```bash
git clone https://github.com/nexposito/Klipperizer.git
cd Klipperizer
bash install.sh
```

**One single install, everything ready.** The installer handles:

- System dependencies (git, build-essential, python3, dfu-util, can-utils, whiptail, yq)
- Python environment (python-can, pyserial)
- **Klipper and Katapult clones** (or updates, if they already exist)
- udev rules (flash without sudo)
- Executable permissions and the global `klipperizer` command

Running `bash install.sh` again updates Klipper and Katapult to the latest version — it is also the system update path.

## Usage

From inside the repository folder:

```bash
./klipperizer
```

> **Important:** run it as `./klipperizer` (with the leading `./`). The bare `klipperizer` command only works when the symlink created by the installer (`/usr/local/bin/klipperizer`) is reachable — `./klipperizer` always works.

1. Choose the **board type**: Toolhead, Mainboard, Filament changer, Inductive probe, Expansion board or USB-CAN adapter
2. Choose the **board** from the list (names only)
3. Choose the communication: **CAN** or **USB**
4. Follow the on-screen instructions — the system warns when to put the board in DFU mode (first flash only)
5. On later updates, flashing goes straight through Katapult, no DFU needed

### Command line (scripts and automation)

```bash
./klipperizer --list                              # list boards as JSON
./klipperizer --flash boards/toolhead/btt_ebb36_v12.yaml can
```

## How it works

- **YAML profiles** in `boards/` describe each board: category, MCU, menuconfig options, flashing method, USB IDs and hardware warnings
- The system generates the `.config` from the profile, builds **Katapult** (bootloader) and **Klipper**, and flashes the board
- First flash: DFU/BOOT → Katapult → Klipper
- Updates: straight through Katapult (USB serial or CAN), no DFU
- USB-CAN adapters (U2C, UTOC, UTC) receive firmware directly via dfu-util

## Supported boards (60 profiles, 6 categories)

### Toolhead (16)

BTT EBB36 Gen2, BTT EBB36 V1.2, BTT EBB42 Gen2, BTT EBB42 V1.2, BTT SB2209 (RP2040), BTT SB2209/SB2240 (STM32), Fysetc H36, Fysetc H36 v2.0, Fysetc SB Combo V2, Fysetc SB-CAN-TH, MKS THR36 V1.0, Mellow Fly SB2040 v1/v2, Mellow Fly SB2040 v3, Mellow Fly SHT36 and SHT42, Mellow Fly SHT36 v2, Mellow Fly SHT36 v3

### Mainboard (30)

BTT Kraken, BTT Manta E3EZ, BTT Manta M5P V1.0, BTT Manta M8P V1.1, BTT Manta M8P V2.0, BTT Octopus (STM32F407), BTT Octopus (STM32F446), BTT Octopus (STM32H723), BTT Octopus Max EZ, BTT Octopus Pro v1.1, BTT Octopus X7 (Troodon), BTT SKR Pico, BTT SKR-3, BTT SKR-3 EZ (STM32H723), BTT SKR-3 EZ (STM32H743), BTT SKRat v1.0, Fysetc Spider King, Fysetc Spider Pro, Fysetc Spider v1.0, Fysetc Spider v2.2, Fysetc Spider v2.3, Fysetc Spider v3.0, Fysetc Spider v3.0 H7, LDO Leviathan v1.2, LDO Leviathan v1.3, MKS Monster8 v2, Mellow FLY-D5P, Mellow FLY-Micro4, Mellow Fly-Super8, Mellow Fly-Super8 Pro H723

### Filament changer (6)

AFC-Lite (Boxturtle), AFC-Pro, BTT MMB CAN v1.0/v1.1, BTT MMB CAN v2.0, Fysetc Hexa Distro Fusion, Mellow Fly ERCF

### Inductive probe (1)

BTT Eddy Duo

### Expansion board (3)

DragonDinghy, Fysetc PITB V1.0, Fysetc PITB V2.0

### USB-CAN adapter (3)

BTT U2C v2.1, Makerbase UTC 1.0, Mellow Fly UTOC-1/UTOC-3

Reference database: [canbus.esoterical.online](https://canbus.esoterical.online)

## Profile status

- ✅ **Verified**: flashing method, VID:PID, MCU and hardware warnings
- ⚠️ **Marked with `# VERIFY`**: CAN pins and crystals of some boards — the build validates every symbol against the Kconfig and fails with a clear message if a name is wrong; pins must be checked against the guide

## Adding a board

See [CONTRIBUTING.md](CONTRIBUTING.md). Summary:

1. Copy `schema/boards.template.yaml` to `boards/<category>/<name>.yaml`
2. Fill in the menuconfig options (the Esoterical guide has screenshots for every board; or use `tools/extract_board_configs.py`)
3. Open a Pull Request — CI validates the YAML automatically

## Structure

```
Klipperizer/
├── klipperizer        # main menu (type → board → mode) + orchestration
├── install.sh         # full installer (deps + Klipper + Katapult + udev)
├── uninstall.sh       # uninstaller
├── lib/               # build, detection, flash and notifications
├── boards/            # board profiles (YAML)
├── schema/            # profile template
├── udev/              # USB access rules
├── tools/             # config extractor for the Esoterical guide
└── .github/workflows/ # CI (validates profiles and scripts)
```

## Roadmap

- Native display interface (KlipperScreen-style, running directly on a 5" touch display)

## License

GPL-3.0 — see [LICENSE](LICENSE).
