#!/usr/bin/env python3
# ============================================================
#  Klipperizer Display — native GTK app (same stack as KlipperScreen)
#  Two pages in one app:
#    STATUS — live printer data from Moonraker (temps, progress,
#             print control buttons)
#    FLASH  — the Klipperizer flashing workflow (board type →
#             board → mode) with the flash log on screen
#  The flash page reuses the tested CLI core:
#    ./klipperizer --flash <profile.yaml> <can|usb>
#  It runs non-interactively (stdin closed): the ENTER confirmations
#  in the flash flow fall back to short delays automatically.
#  Requires: python3-gi, gir1.2-gtk-3.0, python3-websockets
#  (installed by display/install_display.sh)
# ============================================================

import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, GLib, Gdk

import asyncio
import json
import os
import re
import subprocess
import sys
import threading
import urllib.request

# ---------- Paths ----------
APP_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.dirname(APP_DIR)
BOARDS_DIR = os.path.join(REPO_DIR, "boards")
KLIPPERIZER = os.path.join(REPO_DIR, "klipperizer")

MOONRAKER_WS = os.environ.get("MOONRAKER_WS", "ws://127.0.0.1:7125/websocket")
MOONRAKER_HTTP = os.environ.get("MOONRAKER_HTTP", "http://127.0.0.1:7125")


# ---------- Board profile helpers (dependency-free YAML scan) ----------

def list_categories():
    cats = []
    if os.path.isdir(BOARDS_DIR):
        for d in sorted(os.listdir(BOARDS_DIR)):
            if os.path.isdir(os.path.join(BOARDS_DIR, d)) and not d.startswith("."):
                cats.append(d)
    return cats


def parse_profile(path):
    """Extract name and category from a profile YAML (regex, no deps)."""
    name = cat = None
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                if name is None:
                    m = re.match(r'^name:\s*"?(.+?)"?\s*(#.*)?$', line)
                    if m:
                        name = m.group(1).strip()
                if cat is None:
                    m = re.match(r'^category:\s*(\S+)', line)
                    if m:
                        cat = m.group(1).strip()
                if name and cat:
                    break
    except OSError:
        pass
    return name, cat


def list_boards(category):
    boards = []
    d = os.path.join(BOARDS_DIR, category)
    if os.path.isdir(d):
        for f in sorted(os.listdir(d)):
            if f.endswith((".yaml", ".yml")):
                path = os.path.join(d, f)
                name, _cat = parse_profile(path)
                boards.append((name or f, path))
    return boards


# ---------- Moonraker client (status subscription) ----------

class Moonraker:
    """Background websocket client. Pushes status dicts to the UI thread
    via GLib.idle_add. Reconnects every 3s on failure."""

    def __init__(self, url, on_status, on_conn):
        self.url = url
        self.on_status = on_status
        self.on_conn = on_conn
        self.connected = False

    def start(self):
        threading.Thread(target=self._thread, daemon=True).start()

    def _thread(self):
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        loop.run_until_complete(self._run())

    async def _run(self):
        try:
            import websockets
        except ImportError:
            GLib.idle_add(self.on_conn, None)  # None = websockets missing
            return
        while True:
            try:
                async with websockets.connect(self.url, max_size=2 ** 23) as ws:
                    self.connected = True
                    GLib.idle_add(self.on_conn, True)
                    await ws.send(json.dumps({
                        "jsonrpc": "2.0", "method": "printer.objects.subscribe",
                        "params": {"objects": {
                            "extruder": None, "heater_bed": None,
                            "print_stats": None, "display_status": None,
                            "toolhead": None}}, "id": 1}))
                    async for raw in ws:
                        msg = json.loads(raw)
                        params = msg.get("params")
                        if params and isinstance(params, list) and "status" in params[0]:
                            GLib.idle_add(self.on_status, params[0]["status"])
            except asyncio.CancelledError:
                return
            except Exception:
                if self.connected:
                    self.connected = False
                    GLib.idle_add(self.on_conn, False)
                await asyncio.sleep(3)


def moonraker_command(path):
    """POST a printer command to Moonraker's HTTP API (dependency-free)."""
    req = urllib.request.Request(
        MOONRAKER_HTTP + path, data=b"{}",
        headers={"Content-Type": "application/json"}, method="POST")
    try:
        urllib.request.urlopen(req, timeout=5)
        return True
    except Exception:
        return False


# ---------- CSS (touch-friendly sizes) ----------

def apply_css():
    css = b"""
    button { min-height: 48px; min-width: 64px; font-size: 15px; }
    .temp-label { font-size: 26px; font-weight: bold; }
    .temp-title { font-size: 14px; opacity: 0.75; }
    .state-label { font-size: 20px; font-weight: bold; }
    .log-view { font-family: monospace; font-size: 12px; }
    """
    provider = Gtk.CssProvider()
    provider.load_from_data(css)
    Gtk.StyleContext.add_provider_for_screen(
        Gdk.Screen.get_default(), provider,
        Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)


# ---------- Main window ----------

class KlipperizerDisplay(Gtk.Window):
    def __init__(self):
        super().__init__(title="Klipperizer Display")
        self.set_default_size(800, 480)
        self.flash_proc = None
        self.flash_running = False

        apply_css()

        # ----- Header bar with page switcher + connection dot -----
        header = Gtk.HeaderBar()
        header.set_show_close_button(True)
        header.set_title("Klipperizer Display")
        self.set_titlebar(header)

        self.stack = Gtk.Stack()
        self.stack.set_transition_type(Gtk.StackTransitionType.SLIDE_LEFT_RIGHT)
        switcher = Gtk.StackSwitcher()
        switcher.set_stack(self.stack)
        header.set_custom_title(switcher)

        self.conn_dot = Gtk.Label(label="●")
        header.pack_end(self.conn_dot)

        self.stack.add_titled(self._build_status_page(), "status", "Status")
        self.stack.add_titled(self._build_flash_page(), "flash", "Flash")

        self.add(self.stack)

        if "--fullscreen" in sys.argv:
            self.fullscreen()

        self.moonraker = Moonraker(MOONRAKER_WS, self.update_status, self.update_conn)
        self.moonraker.start()

    # ==================== STATUS PAGE ====================

    def _build_status_page(self):
        page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        page.set_margin_top(16)
        page.set_margin_bottom(16)
        page.set_margin_start(16)
        page.set_margin_end(16)

        temps = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=24)
        temps.set_halign(Gtk.Align.CENTER)

        self.nozzle_title = Gtk.Label(label="Nozzle")
        self.nozzle_title.get_style_context().add_class("temp-title")
        self.lbl_nozzle = Gtk.Label(label="-- / --")
        self.lbl_nozzle.get_style_context().add_class("temp-label")
        nz = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        nz.pack_start(self.nozzle_title, False, False, 0)
        nz.pack_start(self.lbl_nozzle, False, False, 0)

        self.bed_title = Gtk.Label(label="Bed")
        self.bed_title.get_style_context().add_class("temp-title")
        self.lbl_bed = Gtk.Label(label="-- / --")
        self.lbl_bed.get_style_context().add_class("temp-label")
        bd = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        bd.pack_start(self.bed_title, False, False, 0)
        bd.pack_start(self.lbl_bed, False, False, 0)

        temps.pack_start(nz, False, False, 0)
        temps.pack_start(bd, False, False, 0)
        page.pack_start(temps, False, False, 0)

        self.lbl_state = Gtk.Label(label="Moonraker: connecting...")
        self.lbl_state.get_style_context().add_class("state-label")
        page.pack_start(self.lbl_state, False, False, 0)

        self.lbl_file = Gtk.Label(label="")
        page.pack_start(self.lbl_file, False, False, 0)

        self.progress = Gtk.ProgressBar()
        self.progress.set_text("0%")
        self.progress.set_show_text(True)
        page.pack_start(self.progress, False, False, 0)

        btns = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        btns.set_halign(Gtk.Align.CENTER)
        self.btn_pause = self._cmd_button("⏸ Pause", "/printer/print/pause")
        self.btn_resume = self._cmd_button("▶ Resume", "/printer/print/resume")
        self.btn_cancel = self._cmd_button("⏹ Cancel", "/printer/print/cancel")
        self.btn_estop = self._cmd_button("⏻ E-Stop", "/printer/emergency_stop")
        self.btn_estop.get_style_context().add_class("destructive-action")
        for b in (self.btn_pause, self.btn_resume, self.btn_cancel, self.btn_estop):
            btns.pack_start(b, False, False, 0)
        page.pack_start(btns, False, False, 0)

        return page

    def _cmd_button(self, label, path):
        btn = Gtk.Button(label=label)
        btn.connect("clicked", self._on_command, path)
        return btn

    def _on_command(self, _btn, path):
        ok = moonraker_command(path)
        if not ok:
            self.lbl_state.set_text("Command failed — is Moonraker up?")

    def update_conn(self, state):
        # state: True (connected), False (down), None (websockets missing)
        if state is None:
            self.conn_dot.set_text("●")
            self.conn_dot.set_opacity(0.3)
            self.lbl_state.set_text("python3-websockets not installed — status offline")
        elif state:
            self.conn_dot.set_opacity(1.0)
        else:
            self.conn_dot.set_opacity(0.3)
            self.lbl_state.set_text("Moonraker: offline — retrying...")
        return False

    def update_status(self, status):
        ex = status.get("extruder", {})
        bed = status.get("heater_bed", {})
        self.lbl_nozzle.set_text("%.1f / %.0f °C" % (
            ex.get("temperature", 0.0), ex.get("target", 0.0)))
        self.lbl_bed.set_text("%.1f / %.0f °C" % (
            bed.get("temperature", 0.0), bed.get("target", 0.0)))

        ps = status.get("print_stats", {})
        state = ps.get("state", "unknown")
        filename = ps.get("filename", "")
        ds = status.get("display_status", {})
        progress = float(ps.get("progress") or ds.get("progress") or 0.0)

        self.progress.set_fraction(min(progress, 1.0))
        self.progress.set_text("%d%%" % round(progress * 100))
        self.lbl_file.set_text(filename)
        self.lbl_state.set_text("State: %s" % state)
        return False

    # ==================== FLASH PAGE ====================

    def _build_flash_page(self):
        page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        page.set_margin_top(12)
        page.set_margin_bottom(12)
        page.set_margin_start(12)
        page.set_margin_end(12)

        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)

        row.pack_start(Gtk.Label(label="Board type:"), False, False, 0)
        self.combo_cat = Gtk.ComboBoxText()
        for c in list_categories():
            self.combo_cat.append_text(c)
        row.pack_start(self.combo_cat, True, True, 0)

        row.pack_start(Gtk.Label(label="Board:"), False, False, 0)
        self.combo_board = Gtk.ComboBoxText()
        row.pack_start(self.combo_board, True, True, 0)

        row.pack_start(Gtk.Label(label="Mode:"), False, False, 0)
        self.combo_mode = Gtk.ComboBoxText()
        self.combo_mode.append("can", "CAN")
        self.combo_mode.append("usb", "USB")
        self.combo_mode.set_active(0)
        row.pack_start(self.combo_mode, False, False, 0)

        page.pack_start(row, False, False, 0)

        actions = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        actions.set_halign(Gtk.Align.CENTER)
        self.btn_flash = Gtk.Button(label="⚡ Start Flash")
        self.btn_flash.get_style_context().add_class("suggested-action")
        self.btn_flash.connect("clicked", self._on_start_flash)
        actions.pack_start(self.btn_flash, False, False, 0)
        page.pack_start(actions, False, False, 0)

        self.lbl_flash_state = Gtk.Label(label="Pick a board type, a board and the mode.")
        page.pack_start(self.lbl_flash_state, False, False, 0)

        scroll = Gtk.ScrolledWindow()
        scroll.set_vexpand(True)
        self.log_view = Gtk.TextView()
        self.log_view.set_editable(False)
        self.log_view.set_cursor_visible(False)
        self.log_view.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        self.log_view.get_style_context().add_class("log-view")
        scroll.add(self.log_view)
        page.pack_start(scroll, True, True, 0)

        self.combo_cat.connect("changed", self._on_category_changed)
        if self.combo_cat.get_active() == -1 and self.combo_cat.get_model().get_iter_first():
            self.combo_cat.set_active(0)
        return page

    def _on_category_changed(self, _combo):
        self.combo_board.remove_all()
        cat = self.combo_cat.get_active_text()
        if not cat:
            return
        for name, _path in list_boards(cat):
            self.combo_board.append_text(name)
        if self.combo_board.get_model().get_iter_first():
            self.combo_board.set_active(0)

    def _selected_profile(self):
        cat = self.combo_cat.get_active_text()
        board = self.combo_board.get_active_text()
        if not cat or not board:
            return None
        for name, path in list_boards(cat):
            if name == board:
                return path
        return None

    def _log(self, text):
        buf = self.log_view.get_buffer()
        buf.insert(buf.get_end_iter(), text)
        # auto-scroll to the bottom
        mark = buf.create_mark(None, buf.get_end_iter(), False)
        self.log_view.scroll_to_mark(mark, 0.0, True, 0.0, 1.0)
        return False

    def _on_start_flash(self, _btn):
        if self.flash_running:
            return
        profile = self._selected_profile()
        if not profile:
            self.lbl_flash_state.set_text("Select a board first.")
            return
        mode = self.combo_mode.get_active_id() or "can"

        self.log_view.get_buffer().set_text("")
        self.lbl_flash_state.set_text("Flashing... follow the log below.")
        self.btn_flash.set_sensitive(False)
        self.flash_running = True

        try:
            self.flash_proc = subprocess.Popen(
                [KLIPPERIZER, "--flash", profile, mode],
                cwd=REPO_DIR,
                stdin=subprocess.DEVNULL,   # non-interactive: ENTER prompts fall back to delays
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True, bufsize=1)
        except OSError as e:
            GLib.idle_add(self._log, "Failed to start the flash process: %s\n" % e)
            self._flash_finished(False)
            return

        threading.Thread(target=self._read_flash_output, daemon=True).start()

    def _read_flash_output(self):
        proc = self.flash_proc
        for line in proc.stdout:
            GLib.idle_add(self._log, line)
        code = proc.wait()
        GLib.idle_add(self._flash_finished, code == 0)

    def _flash_finished(self, ok):
        self.flash_running = False
        self.btn_flash.set_sensitive(True)
        if ok:
            self.lbl_flash_state.set_text("✅ Flash finished successfully!")
        else:
            self.lbl_flash_state.set_text("❌ Flash failed — check the log.")
        return False


# ---------- Entry point ----------

def main():
    win = KlipperizerDisplay()
    win.connect("destroy", Gtk.main_quit)
    win.show_all()
    Gtk.main()


if __name__ == "__main__":
    main()
