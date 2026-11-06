#!/usr/bin/env python3
"""Local Dictation helper for Steam Deck / Linux.

Linux counterpart of the macOS Controller Speech app. It uses only the Python
standard library, because SteamOS has no compiler for pip packages.

Flow:
  Steam Input chord -> trigger key (e.g. Ctrl+Shift+F11) -> this helper sees it
  -> records the mic (pw-record) -> whisper.cpp server transcribes
  -> a virtual keyboard (uinput) sends the addon's notify keys and types the text.

The addon never talks to this helper. The helper watches the keyboard devices
(read-only, it does not grab them) and drives the addon with key presses.
"""
from __future__ import annotations

import argparse
import configparser
import glob
import json
import os
import re
import select
import shlex
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
import uuid

try:
    import fcntl  # Linux/Unix only; imported lazily-safe so the logic can be unit-tested anywhere.
except ImportError:  # pragma: no cover
    fcntl = None

VERSION = "0.1.0"
CONFIG_PATH = os.path.expanduser("~/.config/local-dictation/config.ini")

# ---------------------------------------------------------------------------
# Linux key codes (linux/input-event-codes.h)
# ---------------------------------------------------------------------------
KEY: dict[str, int] = {}
for _i, _c in enumerate("1234567890"):
    KEY[_c] = 2 + _i
for _i, _c in enumerate("qwertyuiop"):
    KEY[_c] = 16 + _i
for _i, _c in enumerate("asdfghjkl"):
    KEY[_c] = 30 + _i
for _i, _c in enumerate("zxcvbnm"):
    KEY[_c] = 44 + _i
KEY.update(esc=1, minus=12, equal=13, backspace=14, tab=15, leftbrace=26, rightbrace=27, enter=28,
           semicolon=39, apostrophe=40, grave=41, backslash=43, comma=51, dot=52, slash=53, space=57,
           leftctrl=29, rightctrl=97, leftshift=42, rightshift=54, leftalt=56, rightalt=100,
           leftmeta=125, rightmeta=126, pause=119, scrolllock=70, insert=110, home=102, end=107,
           pageup=104, pagedown=109, delete=111, up=103, left=105, right=106, down=108,
           kp0=82, kp1=79, kp2=80, kp3=81, kp4=75, kp5=76, kp6=77, kp7=71, kp8=72, kp9=73,
           kpminus=74, kpplus=78, kpdot=83, kpasterisk=55, kpslash=98, kpenter=96)
for _i in range(10):
    KEY[f"f{_i + 1}"] = 59 + _i
KEY["f11"], KEY["f12"] = 87, 88
for _i in range(12):
    KEY[f"f{_i + 13}"] = 183 + _i
NAME_BY_CODE = {v: k for k, v in KEY.items()}

MODIFIERS = {"ctrl": (29, 97), "shift": (42, 54), "alt": (56, 100), "meta": (125, 126)}
MOD_BY_CODE = {code: name for name, codes in MODIFIERS.items() for code in codes}
MOD_ALIASES = {"control": "ctrl", "ctl": "ctrl", "option": "alt", "super": "meta", "win": "meta", "cmd": "meta"}

# US layout: character -> (key code, needs shift)
CHARS: dict[str, tuple[int, bool]] = {" ": (KEY["space"], False)}
for _c in "abcdefghijklmnopqrstuvwxyz":
    CHARS[_c] = (KEY[_c], False)
    CHARS[_c.upper()] = (KEY[_c], True)
for _d, _s in zip("1234567890", "!@#$%^&*()"):
    CHARS[_d] = (KEY[_d], False)
    CHARS[_s] = (KEY[_d], True)
for _plain, _shifted, _name in [("-", "_", "minus"), ("=", "+", "equal"), ("[", "{", "leftbrace"),
                                ("]", "}", "rightbrace"), (";", ":", "semicolon"), ("'", '"', "apostrophe"),
                                ("`", "~", "grave"), ("\\", None, "backslash"), (",", "<", "comma"),
                                (".", ">", "dot"), ("/", "?", "slash")]:
    CHARS[_plain] = (KEY[_name], False)
    if _shifted:
        CHARS[_shifted] = (KEY[_name], True)
# "|" is deliberately missing: it is WoW's chat escape character.

PUNCTUATION_FIXES = {"‘": "'", "’": "'", "“": '"', "”": '"', "—": " - ",
                     "–": "-", "…": "...", " ": " ", "|": "/"}


def parse_combo(text: str) -> tuple[frozenset[str], int]:
    """Parse 'ctrl+shift+f11' into ({'ctrl','shift'}, KEY_F11)."""
    parts = [p.strip().lower() for p in text.replace("-", "+").split("+") if p.strip()]
    if not parts:
        raise ValueError("empty key combination")
    mods = set()
    for p in parts[:-1]:
        p = MOD_ALIASES.get(p, p)
        if p not in MODIFIERS:
            raise ValueError(f"unknown modifier {p!r} in {text!r}")
        mods.add(p)
    key = parts[-1]
    if key not in KEY or key in MOD_BY_CODE.values() or KEY[key] in MOD_BY_CODE:
        raise ValueError(f"unknown or modifier-only key {key!r} in {text!r}")
    return frozenset(mods), KEY[key]


def combo_name(mods: frozenset[str], code: int) -> str:
    order = [m for m in ("ctrl", "alt", "shift", "meta") if m in mods]
    return "+".join(order + [NAME_BY_CODE.get(code, str(code))])


# WoW binding key names -> KEY names (letters/digits/F-keys map by lower-casing)
WOW_KEY_NAMES = {"-": "minus", "=": "equal", "[": "leftbrace", "]": "rightbrace", "\\": "backslash",
                 ";": "semicolon", "'": "apostrophe", ",": "comma", ".": "dot", "/": "slash", "`": "grave",
                 "NUMPADMINUS": "kpminus", "NUMPADPLUS": "kpplus", "NUMPADDECIMAL": "kpdot",
                 "NUMPADMULTIPLY": "kpasterisk", "NUMPADDIVIDE": "kpslash", "ESCAPE": "esc"}
for _i in range(10):
    WOW_KEY_NAMES[f"NUMPAD{_i}"] = f"kp{_i}"


def parse_wow_binding(binding: str) -> tuple[frozenset[str], int] | None:
    """'ALT-CTRL-SHIFT-F9' or 'CTRL--' -> (mods, code). Gamepad (PAD*) bindings return None:
    on the Deck the controller reaches WoW as keyboard keys through Steam Input."""
    rest, mods = binding, set()
    changed = True
    while changed:
        changed = False
        for mod in ("ALT", "CTRL", "SHIFT", "META"):
            if rest.startswith(mod + "-") and len(rest) > len(mod) + 1:
                mods.add(mod.lower()); rest = rest[len(mod) + 1:]; changed = True
    name = WOW_KEY_NAMES.get(rest, rest.lower())
    if name not in KEY or KEY[name] in MOD_BY_CODE:
        return None
    return frozenset(mods), KEY[name]


SAVED_VARIABLES_GLOBS = [
    "~/.local/share/Steam/steamapps/compatdata/*/pfx/drive_c/Program Files*/World of Warcraft/_*_/WTF/Account/*/SavedVariables/LocalDictation.lua",
    "/run/media/*/*/steamapps/compatdata/*/pfx/drive_c/Program Files*/World of Warcraft/_*_/WTF/Account/*/SavedVariables/LocalDictation.lua",
    "~/Games/*/drive_c/Program Files*/World of Warcraft/_*_/WTF/Account/*/SavedVariables/LocalDictation.lua",
    "~/Games/Heroic/Prefixes/*/*/drive_c/Program Files*/World of Warcraft/_*_/WTF/Account/*/SavedVariables/LocalDictation.lua",
]


def find_saved_variables(configured: str = "auto") -> str | None:
    """Newest LocalDictation.lua written by the addon (WoW writes it on /reload or logout)."""
    patterns = SAVED_VARIABLES_GLOBS if configured.strip().lower() in ("", "auto") else [configured]
    files = [f for pat in patterns for f in glob.glob(os.path.expanduser(pat))]
    return max(files, key=os.path.getmtime) if files else None


def read_ingame_record_keys(path: str) -> list[str]:
    with open(path, encoding="utf-8", errors="replace") as f:
        text = f.read()
    keys = []
    for field in ("helperRecord1", "helperRecord2"):
        m = re.search(r'\["%s"\]\s*=\s*"([^"]*)"' % field, text)
        if m and m.group(1):
            keys.append(m.group(1))
    return keys


def normalize_transcript(text: str, max_chars: int = 300) -> str:
    """Clean whisper output into something typeable on a US layout."""
    text = re.sub(r"\[[^\]]*\]|\([^)]*(music|silence|blank|inaudible|noise)[^)]*\)", " ", text, flags=re.I)
    for bad, good in PUNCTUATION_FIXES.items():
        text = text.replace(bad, good)
    out = []
    for ch in unicodedata.normalize("NFKD", text):
        if ch in CHARS:
            out.append(ch)
        elif ch in "\r\n\t":
            out.append(" ")
        # other characters (accents after NFKD, emoji, ...) are dropped
    text = re.sub(r"\s+", " ", "".join(out)).strip()
    return text[:max_chars].rstrip()


# ---------------------------------------------------------------------------
# evdev / uinput via ioctl (no python-evdev needed)
# ---------------------------------------------------------------------------
EV_SYN, EV_KEY, SYN_REPORT = 0, 1, 0
INPUT_EVENT = struct.Struct("llHHi")  # struct input_event on 64-bit Linux


def _ioc(direction: int, kind: str, nr: int, size: int) -> int:
    return (direction << 30) | (size << 16) | (ord(kind) << 8) | nr


def EVIOCGNAME(length: int) -> int:
    return _ioc(2, "E", 0x06, length)


def EVIOCGBIT(ev: int, length: int) -> int:
    return _ioc(2, "E", 0x20 + ev, length)


UI_SET_EVBIT = _ioc(1, "U", 100, 4)
UI_SET_KEYBIT = _ioc(1, "U", 101, 4)
UI_DEV_SETUP = _ioc(1, "U", 3, 92)  # struct uinput_setup: input_id(8) + name[80] + ff_effects_max(4)
UI_DEV_CREATE = _ioc(0, "U", 1, 0)
UI_DEV_DESTROY = _ioc(0, "U", 2, 0)
VIRTUAL_NAME = "local-dictation virtual keyboard"


class VirtualKeyboard:
    """A uinput keyboard. Works in Desktop Mode and in Game Mode (gamescope)."""

    def __init__(self, key_delay: float = 0.006, path: str = "/dev/uinput"):
        if fcntl is None:
            raise RuntimeError("uinput needs Linux")
        self.key_delay = key_delay
        self.lock = threading.Lock()
        self.fd = os.open(path, os.O_WRONLY | os.O_NONBLOCK)
        fcntl.ioctl(self.fd, UI_SET_EVBIT, EV_KEY)
        fcntl.ioctl(self.fd, UI_SET_EVBIT, EV_SYN)
        for code in sorted(set(KEY.values())):
            fcntl.ioctl(self.fd, UI_SET_KEYBIT, code)
        setup = struct.pack("HHHH80sI", 0x06, 0x1209, 0x4C44, 1, VIRTUAL_NAME.encode(), 0)  # BUS_VIRTUAL
        fcntl.ioctl(self.fd, UI_DEV_SETUP, setup)
        fcntl.ioctl(self.fd, UI_DEV_CREATE)
        time.sleep(0.5)  # give the compositor / Xwayland time to pick up the new device

    def _emit(self, ev_type: int, code: int, value: int) -> None:
        os.write(self.fd, INPUT_EVENT.pack(0, 0, ev_type, code, value))

    def _key(self, code: int, down: bool) -> None:
        self._emit(EV_KEY, code, 1 if down else 0)
        self._emit(EV_SYN, SYN_REPORT, 0)
        time.sleep(self.key_delay)

    def press_combo(self, mods: frozenset[str], code: int) -> None:
        mod_codes = [MODIFIERS[m][0] for m in ("ctrl", "alt", "shift", "meta") if m in mods]
        with self.lock:
            for m in mod_codes:
                self._key(m, True)
            self._key(code, True)
            self._key(code, False)
            for m in reversed(mod_codes):
                self._key(m, False)

    def type_text(self, text: str) -> None:
        shift = KEY["leftshift"]
        with self.lock:
            for ch in text:
                mapped = CHARS.get(ch)
                if not mapped:
                    continue
                code, shifted = mapped
                if shifted:
                    self._key(shift, True)
                self._key(code, True)
                self._key(code, False)
                if shifted:
                    self._key(shift, False)

    def close(self) -> None:
        try:
            fcntl.ioctl(self.fd, UI_DEV_DESTROY)
        finally:
            os.close(self.fd)


def device_name(fd: int) -> str:
    buf = fcntl.ioctl(fd, EVIOCGNAME(256), bytes(256))
    return buf.split(b"\0", 1)[0].decode(errors="replace")


def device_supports(fd: int, codes: set[int]) -> bool:
    size = (max(KEY.values()) // 8) + 1
    bits = fcntl.ioctl(fd, EVIOCGBIT(EV_KEY, size), bytes(size))
    return all(bits[c // 8] & (1 << (c % 8)) for c in codes)


class ChordTracker:
    """Fires an action when its exact modifiers + key become held, in any press order.

    triggers: {action: (mods, key)} or a list of (action, mods, key); an action may have several."""

    def __init__(self, triggers):
        self.held: set[int] = set()
        self.set_triggers(triggers)

    def set_triggers(self, triggers) -> None:
        if isinstance(triggers, dict):
            triggers = [(a, m, k) for a, (m, k) in triggers.items()]
        self.entries: list[tuple[str, frozenset[str], int]] = list(triggers)
        self.latched: set[int] = set()

    def held_mods(self) -> frozenset[str]:
        return frozenset(MOD_BY_CODE[c] for c in self.held if c in MOD_BY_CODE)

    def feed(self, code: int, value: int) -> list[str]:
        if value == 2:  # autorepeat
            return []
        fired = []
        if value == 1:
            self.held.add(code)
            mods = self.held_mods()
            for i, (action, want_mods, key) in enumerate(self.entries):
                if i in self.latched or key not in self.held or mods != want_mods:
                    continue
                if code == key or code in MOD_BY_CODE:
                    self.latched.add(i)
                    if action not in fired:
                        fired.append(action)
        else:
            self.held.discard(code)
            for i, (_, _, key) in enumerate(self.entries):
                if code == key:
                    self.latched.discard(i)
        return fired


class KeyListener:
    """Reads every keyboard-like /dev/input device without grabbing it."""

    def __init__(self, triggers, log=print):
        self.tracker = ChordTracker(triggers)
        self.needed = {KEY["a"]}  # any keyboard-like device (Steam's virtual keyboard has every key)
        self.devices: dict[int, tuple[str, str]] = {}  # fd -> (path, name)
        self.log = log
        self.last_scan = 0.0

    def scan(self) -> None:
        self.last_scan = time.monotonic()
        open_paths = {path for path, _ in self.devices.values()}
        for path in sorted(glob.glob("/dev/input/event*")):
            if path in open_paths:
                continue
            try:
                fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
            except OSError:
                continue
            try:
                name = device_name(fd)
                if name == VIRTUAL_NAME or not device_supports(fd, self.needed):
                    os.close(fd)
                    continue
            except OSError:
                os.close(fd)
                continue
            self.devices[fd] = (path, name)
            self.log(f"watching {path}: {name}")

    def close(self) -> None:
        for fd in list(self.devices):
            os.close(fd)
        self.devices.clear()

    def run(self, on_action, stop: threading.Event, on_key=None, every_5s=None) -> None:
        self.scan()
        if not self.devices:
            self.log("no readable keyboard devices yet; is this user in the 'input' group?")
        while not stop.is_set():
            if time.monotonic() - self.last_scan > 5:
                self.scan()
                if every_5s:
                    every_5s()
            fds = list(self.devices)
            if not fds:
                stop.wait(1)
                continue
            readable, _, _ = select.select(fds, [], [], 1.0)
            for fd in readable:
                try:
                    data = os.read(fd, INPUT_EVENT.size * 64)
                except BlockingIOError:
                    continue
                except OSError:
                    path, name = self.devices.pop(fd)
                    os.close(fd)
                    self.log(f"device gone: {path} ({name})")
                    continue
                for off in range(0, len(data) - INPUT_EVENT.size + 1, INPUT_EVENT.size):
                    _, _, ev_type, code, value = INPUT_EVENT.unpack_from(data, off)
                    if ev_type != EV_KEY:
                        continue
                    if on_key:
                        on_key(self.devices.get(fd, ("?", "?"))[1], code, value)
                    for action in self.tracker.feed(code, value):
                        on_action(action)


# ---------------------------------------------------------------------------
# Microphone and speech recognition
# ---------------------------------------------------------------------------
class Recorder:
    def __init__(self, command: str):
        self.command = command
        self.proc: subprocess.Popen | None = None
        self.path: str | None = None

    def start(self) -> None:
        fd, self.path = tempfile.mkstemp(prefix="ld-", suffix=".wav")
        os.close(fd)
        argv = [a.replace("{file}", self.path) for a in shlex.split(self.command)]
        self.proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        time.sleep(0.05)
        if self.proc.poll() is not None:
            err = self.proc.stderr.read().decode(errors="replace").strip() if self.proc.stderr else ""
            self.proc = None
            raise RuntimeError(f"recorder exited immediately: {err or argv[0]}")

    def stop(self) -> str:
        proc, path = self.proc, self.path
        self.proc = None
        if proc is None or path is None:
            raise RuntimeError("not recording")
        proc.send_signal(signal.SIGINT)  # lets pw-record finish the WAV header
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        if not os.path.exists(path) or os.path.getsize(path) < 1000:
            raise RuntimeError("recording is empty; check the microphone")
        return path

    def cancel(self) -> None:
        if self.proc:
            self.proc.kill()
            self.proc.wait()
            self.proc = None
        if self.path and os.path.exists(self.path):
            os.remove(self.path)


def multipart(fields: dict[str, str], file_field: str, filename: str, payload: bytes) -> tuple[bytes, str]:
    boundary = "ld" + uuid.uuid4().hex
    lines = []
    for k, v in fields.items():
        lines.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode())
    lines.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{file_field}"; filename="{filename}"\r\n'
                 f"Content-Type: audio/wav\r\n\r\n".encode() + payload + b"\r\n")
    lines.append(f"--{boundary}--\r\n".encode())
    return b"".join(lines), f"multipart/form-data; boundary={boundary}"


class WhisperServer:
    """Client for whisper.cpp's whisper-server (POST /inference). Optionally starts it."""

    def __init__(self, url: str, command: str = "", log=print):
        self.url = url.rstrip("/")
        self.command = command
        self.proc: subprocess.Popen | None = None
        self.log = log

    def _port_open(self) -> bool:
        u = urllib.parse.urlparse(self.url)
        try:
            with socket.create_connection((u.hostname or "127.0.0.1", u.port or 80), timeout=0.5):
                return True
        except OSError:
            return False

    def start(self, wait: float = 60) -> None:
        if self._port_open():
            self.log(f"using whisper server at {self.url}")
            return
        if not self.command:
            self.log(f"warning: no whisper server at {self.url} and no server_command configured")
            return
        argv = [os.path.expanduser(a) for a in shlex.split(self.command)]
        self.log("starting whisper server: " + " ".join(argv))
        self.proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + wait
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                raise RuntimeError("whisper server exited; run it by hand to see the error")
            if self._port_open():
                self.log("whisper server ready")
                return
            time.sleep(0.5)
        raise RuntimeError("whisper server did not start in time")

    def transcribe(self, wav_path: str) -> str:
        with open(wav_path, "rb") as f:
            body, ctype = multipart({"temperature": "0.0", "response_format": "json"}, "file", "speech.wav", f.read())
        req = urllib.request.Request(self.url + "/inference", data=body, headers={"Content-Type": ctype})
        with urllib.request.urlopen(req, timeout=60) as resp:
            data = json.loads(resp.read().decode())
        if "error" in data:
            raise RuntimeError(str(data["error"]))
        return str(data.get("text", ""))

    def stop(self) -> None:
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()


# ---------------------------------------------------------------------------
# Bridge state machine (same protocol as the macOS helper)
# ---------------------------------------------------------------------------
ADDON_SIGNALS = ("recording", "processing", "prepare", "send", "failed")


class Bridge:
    def __init__(self, keyboard, recorder, transcriber, addon_keys: dict[str, tuple[frozenset[str], int]],
                 paste_delay: float = 0.6, max_chars: int = 300, log=print, spawn=None):
        self.keyboard = keyboard
        self.recorder = recorder
        self.transcriber = transcriber
        self.addon_keys = addon_keys
        self.paste_delay = paste_delay
        self.max_chars = max_chars
        self.log = log
        self.spawn = spawn or (lambda fn, *a: threading.Thread(target=fn, args=a, daemon=True).start())
        self.state = "idle"
        self.lock = threading.Lock()
        self.last_press = 0.0

    def notify(self, signal_name: str) -> None:
        mods, code = self.addon_keys[signal_name]
        self.keyboard.press_combo(mods, code)

    def on_action(self, action: str) -> None:
        with self.lock:
            now = time.monotonic()
            if now - self.last_press < 0.25:
                return
            self.last_press = now
            if action == "record":
                self._record()
            elif action == "send":
                self._send()

    def _record(self) -> None:
        if self.state == "recording":
            try:
                path = self.recorder.stop()
            except Exception as e:  # noqa: BLE001
                self.log(f"recording failed: {e}")
                self.state = "idle"
                self.notify("failed")
                return
            self.state = "processing"
            self.notify("processing")
            self.log("transcribing...")
            self.spawn(self._transcribe, path)
        elif self.state in ("processing", "delivering"):
            self.log("busy; wait for the preview")
        else:
            self.notify("recording")
            try:
                self.recorder.start()
            except Exception as e:  # noqa: BLE001
                self.log(f"could not start recording: {e}")
                self.notify("failed")
                return
            self.state = "recording"
            self.log("recording...")

    def _send(self) -> None:
        if self.state in ("recording", "processing", "delivering"):
            self.log("nothing ready to send yet")
            return
        self.notify("send")
        self.state = "idle"
        self.log("send key delivered to the addon")

    def _transcribe(self, path: str) -> None:
        started = time.monotonic()
        try:
            text = normalize_transcript(self.transcriber.transcribe(path), self.max_chars)
        except Exception as e:  # noqa: BLE001
            self.log(f"transcription failed: {e}")
            text = ""
        finally:
            try:
                os.remove(path)
            except OSError:
                pass
        with self.lock:
            if self.state != "processing":
                return
            if not text:
                self.state = "idle"
                self.notify("failed")
                self.log("no speech recognized")
                return
            self.state = "delivering"
            self.log(f"recognized in {time.monotonic() - started:.2f}s: {text}")
            self.notify("prepare")
        time.sleep(self.paste_delay)
        self.keyboard.type_text(text)
        with self.lock:
            if self.state == "delivering":
                self.state = "preview"
        self.log("typed into preview; press Send to submit")


# ---------------------------------------------------------------------------
# Config and entry point
# ---------------------------------------------------------------------------
DEFAULTS = {
    "triggers": {"record": "ctrl+shift+f11", "send": "ctrl+shift+f12"},
    "speech": {
        "server_url": "http://127.0.0.1:8178",
        "server_command": "~/.local/share/local-dictation/whisper.cpp/build/bin/whisper-server "
                          "-m ~/.local/share/local-dictation/models/ggml-base.en.bin "
                          "--host 127.0.0.1 --port 8178 -t 4",
        "record_command": "pw-record --rate 16000 --channels 1 --format s16 {file}",
    },
    "delivery": {"paste_delay": "0.6", "key_delay_ms": "6", "max_chars": "300"},
    # Record / Stop keys set in the addon's Hotkeys panel are read from its saved file.
    "wow": {"saved_variables": "auto", "use_ingame_record": "yes"},
    # Keys the addon listens for. Ctrl+Shift+F6-F10 avoid Linux's Ctrl+Alt+Fn console switching and
    # the F13+ keys, which Xwayland/Wine may not pass through as F13.
    "addon": {"recording": "ctrl+shift+f6", "processing": "ctrl+shift+f7", "prepare": "ctrl+shift+f8",
              "send": "ctrl+shift+f9", "failed": "ctrl+shift+f10"},
}


def load_config(path: str) -> configparser.ConfigParser:
    cfg = configparser.ConfigParser(interpolation=None)
    cfg.read_dict(DEFAULTS)
    if os.path.exists(path):
        cfg.read(path)
    return cfg


def parse_keys(section) -> dict[str, tuple[frozenset[str], int]]:
    return {name: parse_combo(value) for name, value in section.items()}


class InGameTriggers:
    """Config triggers plus the Record / Stop keys bound in the addon (re-read when the file changes)."""

    def __init__(self, cfg, triggers, log=print):
        self.base = [(a, m, k) for a, (m, k) in triggers.items()]
        self.enabled = cfg["wow"].get("use_ingame_record", "yes").lower() in ("yes", "true", "1", "on")
        self.setting = cfg["wow"].get("saved_variables", "auto")
        self.log = log
        self.path, self.mtime, self.extra = None, None, []
        self.refresh()

    def refresh(self) -> bool:
        if not self.enabled:
            return False
        path = find_saved_variables(self.setting)
        mtime = os.path.getmtime(path) if path else None
        if (path, mtime) == (self.path, self.mtime):
            return False
        self.path, self.mtime = path, mtime
        extra = []
        if path:
            for binding in read_ingame_record_keys(path):
                parsed = parse_wow_binding(binding)
                if parsed:
                    extra.append(("record",) + parsed)
                    self.log(f"in-game Record / Stop: {binding}")
                else:
                    self.log(f"in-game Record / Stop {binding!r} can't be watched on Linux (gamepad or unknown key)")
        changed = extra != self.extra
        self.extra = extra
        return changed

    def entries(self):
        return self.base + self.extra


def check(cfg) -> int:
    ok = True

    def report(good: bool, text: str):
        nonlocal ok
        ok = ok and good
        print(("ok   " if good else "FAIL ") + text)

    report(sys.platform.startswith("linux"), f"running on Linux ({sys.platform})")
    report(os.access("/dev/uinput", os.W_OK), "/dev/uinput is writable (virtual keyboard)")
    readable = [p for p in glob.glob("/dev/input/event*") if os.access(p, os.R_OK)]
    report(bool(readable), f"{len(readable)} input devices readable (needs the 'input' group)")
    rec = shlex.split(cfg["speech"]["record_command"])[0]
    report(any(os.access(os.path.join(d, rec), os.X_OK) for d in os.environ.get("PATH", "").split(":")),
           f"recorder '{rec}' found")
    server = WhisperServer(cfg["speech"]["server_url"], "")
    if server._port_open():
        report(True, f"whisper server reachable at {server.url}")
    else:
        binary = os.path.expanduser(shlex.split(cfg["speech"]["server_command"] or "none")[0])
        report(os.access(binary, os.X_OK), f"whisper server binary {binary}")
    sv = find_saved_variables(cfg["wow"]["saved_variables"])
    if sv:
        keys = read_ingame_record_keys(sv)
        print(("ok   " if keys else "note ") + f"addon settings {sv}: in-game Record / Stop = {', '.join(keys) or 'not set'}")
    else:
        print("note addon settings file not found (log in once with the addon, or set [wow] saved_variables)")
    try:
        parse_keys(cfg["triggers"]); parse_keys(cfg["addon"])
        report(True, "key combinations parse")
    except ValueError as e:
        report(False, str(e))
    return 0 if ok else 1


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Local Dictation helper for Steam Deck / Linux")
    ap.add_argument("--config", default=CONFIG_PATH)
    ap.add_argument("--check", action="store_true", help="check permissions and dependencies")
    ap.add_argument("--list-devices", action="store_true", help="list input devices")
    ap.add_argument("--watch", action="store_true", help="print key presses (to verify Steam Input output)")
    ap.add_argument("--type", metavar="TEXT", help="type TEXT through the virtual keyboard after 3 s")
    ap.add_argument("--transcribe", metavar="WAV", help="transcribe a WAV file and print the result")
    ap.add_argument("--version", action="version", version=VERSION)
    args = ap.parse_args(argv)
    cfg = load_config(args.config)

    def log(msg: str) -> None:
        print(time.strftime("%H:%M:%S ") + msg, flush=True)

    if args.check:
        return check(cfg)
    if args.list_devices:
        for path in sorted(glob.glob("/dev/input/event*")):
            try:
                fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
                print(path, device_name(fd), "(keyboard keys)" if device_supports(fd, {KEY["a"]}) else "")
                os.close(fd)
            except OSError as e:
                print(path, f"<{e.strerror}>")
        return 0
    if args.transcribe:
        server = WhisperServer(cfg["speech"]["server_url"], cfg["speech"]["server_command"], log)
        server.start()
        try:
            print(normalize_transcript(server.transcribe(args.transcribe)))
        finally:
            server.stop()
        return 0
    if args.type:
        kb = VirtualKeyboard(int(cfg["delivery"]["key_delay_ms"]) / 1000)
        time.sleep(3)
        kb.type_text(normalize_transcript(args.type))
        kb.close()
        return 0

    triggers = parse_keys(cfg["triggers"])
    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())

    if args.watch:
        listener = KeyListener(InGameTriggers(cfg, triggers, log).entries(), log)
        tracker_names = {a: combo_name(*t) for a, t in triggers.items()}
        log("press keys; triggers: " + ", ".join(f"{a}={n}" for a, n in tracker_names.items()))
        listener.run(lambda a: log(f">>> trigger: {a}"), stop,
                     on_key=lambda dev, code, value: value != 2 and log(
                         f"{dev}: {NAME_BY_CODE.get(code, code)} {'down' if value else 'up'}"))
        listener.close()
        return 0

    ingame = InGameTriggers(cfg, triggers, log)
    addon_keys = parse_keys(cfg["addon"])
    missing = [s for s in ADDON_SIGNALS if s not in addon_keys]
    if missing:
        log("config [addon] is missing: " + ", ".join(missing))
        return 1
    server = WhisperServer(cfg["speech"]["server_url"], cfg["speech"]["server_command"], log)
    server.start()
    kb = VirtualKeyboard(int(cfg["delivery"]["key_delay_ms"]) / 1000)
    recorder = Recorder(cfg["speech"]["record_command"])
    bridge = Bridge(kb, recorder, server, addon_keys, float(cfg["delivery"]["paste_delay"]),
                    int(cfg["delivery"]["max_chars"]), log)
    listener = KeyListener(ingame.entries(), log)
    log("ready: record=" + combo_name(*triggers["record"]) + ", send=" + combo_name(*triggers["send"]))

    def refresh_ingame():
        if ingame.refresh():
            listener.tracker.set_triggers(ingame.entries())

    try:
        listener.run(bridge.on_action, stop, every_5s=refresh_ingame)
    finally:
        recorder.cancel()
        listener.close()
        kb.close()
        server.stop()
        log("stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
