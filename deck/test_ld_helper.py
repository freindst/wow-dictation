"""Tests for the platform-independent parts of ld_helper. Run: python3 -m unittest deck/test_ld_helper.py"""
import http.server
import io
import json
import os
import re
import string
import sys
import tempfile
import threading
import time
import unittest

sys.path.insert(0, os.path.dirname(__file__))
import ld_helper as h  # noqa: E402


class ParseTests(unittest.TestCase):
    def test_parse_combo(self):
        self.assertEqual(h.parse_combo("ctrl+shift+f11"), (frozenset({"ctrl", "shift"}), 87))
        self.assertEqual(h.parse_combo("Control-Shift-F6"), (frozenset({"ctrl", "shift"}), 64))
        self.assertEqual(h.parse_combo("f13"), (frozenset(), 183))
        for bad in ("", "ctrl+", "hyper+a", "ctrl+leftshift", "ctrl+nosuchkey"):
            with self.assertRaises(ValueError, msg=bad):
                h.parse_combo(bad)

    def test_combo_name_roundtrip(self):
        for text in ("ctrl+shift+f11", "alt+a", "f12"):
            self.assertEqual(h.combo_name(*h.parse_combo(text)), text)

    def test_ioctl_numbers(self):
        self.assertEqual(h.UI_DEV_CREATE, 0x5501)
        self.assertEqual(h.UI_DEV_DESTROY, 0x5502)
        self.assertEqual(h.UI_SET_EVBIT, 0x40045564)
        self.assertEqual(h.UI_SET_KEYBIT, 0x40045565)
        self.assertEqual(h.UI_DEV_SETUP, 0x405C5503)
        self.assertEqual(h.EVIOCGNAME(256), 0x81004506)
        self.assertEqual(h.INPUT_EVENT.size, 24)

    def test_default_addon_keys_match_addon(self):
        lua = open(os.path.join(os.path.dirname(__file__), "..", "LocalDictation", "LocalDictation.lua")).read()
        signals = dict(re.findall(r'(F\d+)="(RECORDING|PROCESSING|PREPARE|SEND|FAILED)"', lua))
        cfg = h.load_config("/nonexistent")
        for name, value in cfg["addon"].items():
            mods, code = h.parse_combo(value)
            self.assertEqual(mods, frozenset({"ctrl", "shift"}))
            key = h.NAME_BY_CODE[code].upper()
            self.assertEqual(signals.get(key), name.upper(), f"{value} not bound in addon")


class TranscriptTests(unittest.TestCase):
    def test_every_printable_ascii_except_pipe_is_typeable(self):
        missing = [c for c in string.printable if c not in h.CHARS and c not in "|\t\n\r\x0b\x0c"]
        self.assertEqual(missing, [])
        self.assertNotIn("|", h.CHARS)

    def test_normalize(self):
        self.assertEqual(h.normalize_transcript(" [BLANK_AUDIO] "), "")
        self.assertEqual(h.normalize_transcript(" Hello’s  team — pull now…\n"), "Hello's team - pull now...")
        self.assertEqual(h.normalize_transcript("Café résumé a|b"), "Cafe resume a/b")
        self.assertEqual(h.normalize_transcript("(music) ok"), "ok")
        self.assertEqual(len(h.normalize_transcript("word " * 200, 300)), 299)


class ChordTests(unittest.TestCase):
    def setUp(self):
        self.t = h.ChordTracker({"record": h.parse_combo("ctrl+shift+f11"), "send": h.parse_combo("ctrl+shift+f12")})
        self.C, self.S, self.F11, self.F12 = 29, 42, 87, 88

    def press(self, *codes):
        fired = []
        for c in codes:
            fired += self.t.feed(c, 1)
        return fired

    def release(self, *codes):
        for c in codes:
            self.t.feed(c, 0)

    def test_modifiers_first(self):
        self.assertEqual(self.press(self.C, self.S, self.F11), ["record"])

    def test_any_order(self):
        # Steam Input may emit the key before its modifiers.
        self.assertEqual(self.press(self.F11, self.C, self.S), ["record"])

    def test_fires_once_until_released(self):
        self.assertEqual(self.press(self.C, self.S, self.F11), ["record"])
        self.assertEqual(self.t.feed(self.F11, 2), [])  # autorepeat
        self.assertEqual(self.press(self.C), [])  # duplicate down from a second device
        self.release(self.F11)
        self.assertEqual(self.press(self.F11), ["record"])

    def test_exact_modifiers(self):
        self.assertEqual(self.press(self.F11), [])  # no modifiers
        self.assertEqual(self.press(self.C), [])  # ctrl only
        self.assertEqual(self.press(56, self.S), [])  # ctrl+alt+shift: extra modifier, no match
        self.release(56)
        # Releasing alt leaves exactly ctrl+shift+f11 held, but only a key-down can fire.
        self.assertEqual(self.t.feed(self.S, 1), ["record"])

    def test_send(self):
        self.assertEqual(self.press(self.C, self.S, self.F12), ["send"])


class InGameTests(unittest.TestCase):
    SAMPLE = 'LocalDictationDB = {\n["channel"] = "PARTY",\n["helperRecord1"] = "CTRL--",\n["helperRecord2"] = "SHIFT-PAD1",\n}\n'

    def test_parse_wow_binding(self):
        self.assertEqual(h.parse_wow_binding("ALT-CTRL-SHIFT-F9"), (frozenset({"alt", "ctrl", "shift"}), 67))
        self.assertEqual(h.parse_wow_binding("CTRL--"), (frozenset({"ctrl"}), 12))
        self.assertEqual(h.parse_wow_binding("NUMPAD7"), (frozenset(), 71))
        self.assertEqual(h.parse_wow_binding("CTRL-\\"), (frozenset({"ctrl"}), 43))
        self.assertIsNone(h.parse_wow_binding("SHIFT-PAD1"))
        self.assertIsNone(h.parse_wow_binding("CTRL-NOSUCHKEY"))

    def test_reads_saved_variables_and_refreshes(self):
        fd, path = tempfile.mkstemp(suffix=".lua")
        os.write(fd, self.SAMPLE.encode()); os.close(fd)
        try:
            self.assertEqual(h.read_ingame_record_keys(path), ["CTRL--", "SHIFT-PAD1"])
            cfg = h.load_config("/nonexistent")
            cfg["wow"]["saved_variables"] = path
            triggers = h.parse_keys(cfg["triggers"])
            ing = h.InGameTriggers(cfg, triggers, log=lambda *_: None)
            self.assertIn(("record", frozenset({"ctrl"}), 12), ing.entries())  # gamepad one skipped
            self.assertFalse(ing.refresh())  # unchanged file
            with open(path, "w") as f:
                f.write(self.SAMPLE.replace("CTRL--", "ALT-F5"))
            os.utime(path, (time.time() + 5, time.time() + 5))
            self.assertTrue(ing.refresh())
            self.assertIn(("record", frozenset({"alt"}), 63), ing.entries())
            self.assertNotIn(("record", frozenset({"ctrl"}), 12), ing.entries())
        finally:
            os.remove(path)

    def test_tracker_multiple_triggers_per_action(self):
        t = h.ChordTracker([("record", frozenset({"ctrl", "shift"}), 87), ("record", frozenset({"ctrl"}), 12)])
        self.assertEqual(t.feed(29, 1) + t.feed(12, 1), ["record"])  # ctrl + minus
        t.feed(12, 0); t.feed(29, 0)
        self.assertEqual(t.feed(29, 1) + t.feed(42, 1) + t.feed(87, 1), ["record"])


class FakeKeyboard:
    def __init__(self):
        self.events = []

    def press_combo(self, mods, code):
        self.events.append(("combo", h.combo_name(mods, code)))

    def type_text(self, text):
        self.events.append(("type", text))


class FakeRecorder:
    def __init__(self, fail_start=False):
        self.fail_start = fail_start
        self.recording = False

    def start(self):
        if self.fail_start:
            raise RuntimeError("no mic")
        self.recording = True

    def stop(self):
        self.recording = False
        fd, path = tempfile.mkstemp(suffix=".wav")
        os.close(fd)
        return path


class FakeTranscriber:
    def __init__(self, text):
        self.text = text

    def transcribe(self, path):
        return self.text


class BridgeTests(unittest.TestCase):
    def make(self, text=" Hello team. ", recorder=None):
        self.kb = FakeKeyboard()
        addon = h.parse_keys(h.load_config("/nonexistent")["addon"])
        self.queued = []
        b = h.Bridge(self.kb, recorder or FakeRecorder(), FakeTranscriber(text), addon, paste_delay=0,
                     log=lambda *_: None, spawn=lambda fn, *a: self.queued.append((fn, a)))
        return b

    def act(self, b, action):
        b.last_press = 0  # skip debounce
        b.on_action(action)

    def run_queued(self):
        while self.queued:
            fn, a = self.queued.pop(0)
            fn(*a)

    def test_full_cycle(self):
        b = self.make()
        self.act(b, "record")
        self.assertEqual(b.state, "recording")
        self.act(b, "record")
        self.assertEqual(b.state, "processing")
        self.act(b, "send")  # ignored while processing
        self.run_queued()
        self.assertEqual(b.state, "preview")
        self.act(b, "send")
        self.assertEqual(b.state, "idle")
        self.assertEqual(self.kb.events, [
            ("combo", "ctrl+shift+f6"), ("combo", "ctrl+shift+f7"), ("combo", "ctrl+shift+f8"),
            ("type", "Hello team."), ("combo", "ctrl+shift+f9")])

    def test_no_speech_reports_failure(self):
        b = self.make(text="[BLANK_AUDIO]")
        self.act(b, "record"); self.act(b, "record"); self.run_queued()
        self.assertEqual(b.state, "idle")
        self.assertEqual(self.kb.events[-1], ("combo", "ctrl+shift+f10"))

    def test_mic_failure(self):
        b = self.make(recorder=FakeRecorder(fail_start=True))
        self.act(b, "record")
        self.assertEqual(b.state, "idle")
        self.assertEqual(self.kb.events, [("combo", "ctrl+shift+f6"), ("combo", "ctrl+shift+f10")])

    def test_record_during_preview_starts_fresh(self):
        b = self.make()
        self.act(b, "record"); self.act(b, "record"); self.run_queued()
        self.act(b, "record")
        self.assertEqual(b.state, "recording")

    def test_debounce(self):
        b = self.make()
        b.on_action("record")
        b.on_action("record")  # within 0.25 s: ignored
        self.assertEqual(b.state, "recording")


class WhisperClientTests(unittest.TestCase):
    def test_posts_multipart_and_reads_text(self):
        seen = {}

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                body = self.rfile.read(int(self.headers["Content-Length"]))
                seen["path"] = self.path
                seen["ctype"] = self.headers["Content-Type"]
                seen["body"] = body
                out = json.dumps({"text": " Hi there\n"}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(out)))
                self.end_headers()
                self.wfile.write(out)

            def log_message(self, *a):
                pass

        server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        fd, path = tempfile.mkstemp(suffix=".wav")
        os.write(fd, b"RIFF....WAVEdata")
        os.close(fd)
        try:
            client = h.WhisperServer(f"http://127.0.0.1:{server.server_port}", log=lambda *_: None)
            self.assertTrue(client._port_open())
            self.assertEqual(client.transcribe(path), " Hi there\n")
        finally:
            os.remove(path)
            server.shutdown()
            server.server_close()
        self.assertEqual(seen["path"], "/inference")
        boundary = seen["ctype"].split("boundary=")[1]
        self.assertIn(f"--{boundary}--".encode(), seen["body"])
        self.assertIn(b'name="file"; filename="speech.wav"', seen["body"])
        self.assertIn(b"RIFF....WAVEdata", seen["body"])
        self.assertIn(b'name="response_format"\r\n\r\njson', seen["body"])


if __name__ == "__main__":
    unittest.main()
