# Contributing to Klipperizer

Thanks for wanting to add a board! The process is simple and CI validates everything automatically.

## Adding a new board

1. **Copy the template**:
   ```bash
   cp schema/boards.template.yaml boards/toolhead/my_board.yaml
   ```
   (use `mainboard/` or `adapter/` as appropriate)

2. **Fill in the fields** — the main reference is the
   [canbus.esoterical.online](https://canbus.esoterical.online) guide, which has
   menuconfig screenshots for every board:
   - `name` and `category`: exactly as in the guide
   - `mcu`: the board's real chip (check the silkscreen or the manual)
   - `bootloader.vid_pid`: run `lsusb` with the board in DFU/BOOT mode
   - `bootloader.instructions`: copy the steps from the guide
   - `katapult` and `klipper`: transcribe the options from the screenshots
     (alternative: use `python3 tools/extract_board_configs.py --board "Name"`)

3. **Mark uncertainties**: any value you have not confirmed with a real board,
   leave a `# VERIFY` comment on the line. This helps other users know what to check.

4. **Open a Pull Request** — CI validates the YAML (name and VID:PID required)
   and runs shellcheck on the scripts.

## Important rules

- **Invalid CONFIG_* symbols never pass silently**: the build validates every
  symbol against the real Kconfig and fails with a clear message. Even so,
  validate offsets and pins with a real board when possible.
- **USB-CAN adapters** (U2C, UTOC, UTC) do not run Katapult/Klipper —
  use the `adapter` section with `firmware` (binary URL) and `command`
  (dfu-util with `{vidpid}` and `{file}`).
- **Boards with MCU variants** (Octopus, SKR-3 EZ): create one profile per
  variant, with the suffix in the name.
- **Test before approving**: if you tested the profile with a real board,
  remove the `# VERIFY` comments and mention it in the PR.

## Reporting issues

Open an issue with:
- Board and MCU variant
- Mode (CAN/USB) and the step where it failed
- Full log output
- `lsusb` and `ls /dev/serial/by-id/` output at the moment of the failure

## License

Every contribution is licensed under GPL-3.0 along with the project.
