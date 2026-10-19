# Klipperizer Display

Native GTK app (Python 3 + GTK 3 — the same stack as KlipperScreen) that turns a DSI/MIPI or HDMI touchscreen connected to the Rock Pi into a **flashing tool + printer status panel** in one app.

## Pages

**Status** — live printer data from Moonraker:
- Nozzle and bed temperatures (current / target)
- Print state, filename and progress bar
- Pause / Resume / Cancel / Emergency Stop buttons
- Connection dot in the header (bright = connected, dim = offline)

**Flash** — the full Klipperizer flashing workflow:
- Board type → board → CAN/USB selection (reads the `boards/` profiles directly)
- Runs the tested CLI core (`./klipperizer --flash <profile> <mode>`) as a subprocess
- Streams the complete flash log on screen (all the steps, warnings and UUID output)

The flash runs non-interactively: the ENTER confirmations in the flash flow fall back to short delays automatically (stdin is closed by design).

## Install

```bash
cd ~/Klipperizer
bash display/install_display.sh
sudo systemctl start klipperizer-display
```

The service starts the app fullscreen on the display at every boot (`Restart=always` keeps it alive).

## Manual test (no service)

```bash
python3 display/klipperizer_display.py
```

## Configuration

Environment variables (set them in the service file or your shell):

| Variable | Default | Purpose |
|---|---|---|
| `MOONRAKER_WS` | `ws://127.0.0.1:7125/websocket` | Moonraker websocket for the status page |
| `MOONRAKER_HTTP` | `http://127.0.0.1:7125` | Moonraker HTTP API for the control buttons |

## DSI/MIPI display notes (Rock Pi)

- The app renders on any display the graphical session uses. On Rock Pi boards with a DSI panel, make sure the panel is active in the desktop session (`DISPLAY=:0` under X11 — the default for most Rock Pi images).
- Under a Wayland session, replace `Environment=DISPLAY=:0` with `Environment=WAYLAND_DISPLAY=wayland-0` in `/etc/systemd/system/klipperizer-display.service`.
- Touch works out of the box with the standard evdev/libinput stack — no extra config needed for most panels.

## Files

```
display/
├── klipperizer_display.py   # the GTK app (status + flash pages)
├── install_display.sh       # deps + systemd autostart service
└── README.md                # this file
```
