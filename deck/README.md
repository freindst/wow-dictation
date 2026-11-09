# Local Dictation on Steam Deck (prototype)

Linux counterpart of the macOS **Controller Speech** helper, for WoW running on a Steam Deck through Proton. The **LocalDictation addon is the same** on both platforms: install it into the WoW client's `Interface/AddOns` folder as usual.

> **Status: untested on real hardware.** The logic is unit-tested (`test_ld_helper.py`), but the parts below marked *verify* need a live check on a Deck.

## How it works

```
Steam Input chord ──► Ctrl+Shift+F11 ──► ld_helper sees the key (reads /dev/input, does not block it)
                                         │
                                         ├─ Ctrl+Shift+F6 ──► addon: "Recording"
                                         ├─ pw-record captures the mic
Steam Input chord ──► Ctrl+Shift+F11 ──► ├─ Ctrl+Shift+F7 ──► addon: "Transcribing"
                                         ├─ whisper.cpp (local server) transcribes
                                         ├─ Ctrl+Shift+F8 ──► addon opens the preview
                                         └─ types the text into the preview (virtual keyboard)
Steam Input chord ──► Ctrl+Shift+F12 ──► Ctrl+Shift+F9 ──► addon sends the message
```

| Piece | Mac helper | Deck helper |
|---|---|---|
| Speech | Apple SpeechAnalyzer | whisper.cpp `whisper-server`, English model (`base.en` by default) |
| Triggers | Keyboard hotkeys / controller combos in the app | Steam Input chord → trigger key, watched by the helper |
| Mic | AVAudioRecorder | `pw-record` (PipeWire) |
| Addon signals | Ctrl-Shift-F13…F17 | Ctrl-Shift-F6…F10 (avoids Linux Ctrl+Alt+Fn console switching, and F13+ which Xwayland/Wine may not pass through) |
| Text delivery | Clipboard + ⌘V | Typed by a `uinput` virtual keyboard (US layout; accents are simplified and `\|` becomes `/`) |
| Runs as | App window | `systemd --user` service, so it keeps running in Game Mode |

The helper is plain Python 3 with no extra packages, because SteamOS has no compiler for pip packages.

## Install yourself in Desktop Mode

The setup wizard installs the helper, English model, WoW addon, background service and a **Local Dictation Controls** desktop/application-menu launcher. A code agent is not required. Initial setup needs internet access, a sudo password and Distrobox (or an existing native C++ compiler). Whisper is compiled automatically during setup. This installer has shell validation and helper unit tests, but still needs a real Steam Deck installation test.

1. On the Deck, switch to Desktop Mode and open Firefox.
2. Download the [installer branch ZIP](https://github.com/freindst/wow-dictation/archive/refs/heads/deck-self-service-install.zip) and extract the entire archive using the file manager.
3. Open the extracted **deck** folder. Right-click inside the folder and choose **Open Terminal Here**. Run this one command in Konsole.

   ```bash
   bash setup.sh
   ```

4. Select your WoW client folder in the folder picker. This is the folder containing **Interface** and **WTF**, such as `_forever_`. If no picker is available, the terminal asks for the full path. Confirm installation, then supply your sudo password when input access is requested. If no sudo password is configured, run `passwd` first and rerun setup.
5. Wait for the Whisper build and model download. The wizard installs the addon, backs up an existing LocalDictation addon, and creates **Local Dictation Controls** on the Desktop and application menu. It reports dependency failures in the terminal. Rerun the installer after addressing the error.
6. Reboot if the wizard requests it. The service is enabled for login. Open **Local Dictation Controls** and choose **Status** or **Diagnostics** to check it.
7. In WoW, enable **Local Dictation**, reload the UI, and map your two Steam Input buttons as described below. Return to Gaming Mode and launch WoW.

The addon folder is installed automatically. You still choose Steam Input bindings yourself because the installer does not edit your existing controller layout.

Use **Local Dictation Controls** to start, stop, inspect logs, run diagnostics or disable start at login. Exiting the controls window leaves the background service running. Choose **Stop helper** or **Disable start at login and stop** to stop dictation.

For a terminal check in either Desktop Mode or SSH, run the following commands.

```bash
systemctl --user status local-dictation --no-pager
python3 ~/.local/share/local-dictation/ld_helper.py --check
```

### Lower-level installation

`install.sh` still supports scripted installation. `--permissions` grants the current user input/uinput access and needs a reboot or full logout. `--model tiny.en`, `--model base.en` and `--model small.en` control which model is downloaded for a fresh configuration. Existing configuration is preserved. The wizard uses Base English by default.

Everything except the input udev rule and group membership is installed in your home folder. The rule uses group permissions for input events and the virtual keyboard. It requires sudo. No changes to Steam's read-only system image are part of the installer.

## Record / Stop key from the addon

As on the Mac, you can set **Record / Stop** in game (`/ld keys`, then `/reload`). The helper finds the addon's saved file inside the Proton prefix (Steam `compatdata`, SD card, Lutris or Heroic prefixes) and watches that key too, re-reading it every few seconds. Set `[wow] saved_variables` to the full path if it isn't found; `--check` shows which file it uses. Only keyboard bindings work here: on the Deck the controller reaches WoW as keyboard keys through Steam Input, so bind the key combination your Steam Input chord sends.

## Steam Input setup (Game Mode)

Open WoW's controller settings (the **Steam** button with the game running → Controller settings → edit the layout). Pick a button combination you don't use in WoW. The four back buttons (L4, L5, R4, R5) are good candidates:

- **Record / Stop:** on the chosen button, add a command. Set it to a chord with your modifier button (for example hold R4 + press A), or use a back button directly. Bind it to the keyboard keys **Left Ctrl + Left Shift + F11**, either one command with all three keys or three commands on the same activator.
- **Send:** the same idea with another button (for example R4 + B) → **Left Ctrl + Left Shift + F12**.

Steam Input menu names change between client versions; look for options like *Add Chord*, *Add extra command* or *Mode shift*. The helper accepts the keys in any order, as long as Ctrl+Shift+F11 is held together with no other modifier.

To change the trigger keys, edit `[triggers]` in `~/.config/local-dictation/config.ini` and restart the service.

## Checking each piece

| Command | What it checks |
|---|---|
| `python3 ~/.local/share/local-dictation/ld_helper.py --check` | Permissions, recorder, whisper server/binary, config |
| `… --list-devices` | Which input devices exist, including Steam's virtual keyboard |
| `… --watch` | Prints each key press and `>>> trigger: record` when a trigger matches. Run it (with the service stopped) and press your Steam Input chord |
| `… --transcribe file.wav` | Speech recognition alone |
| `… --type "hello there"` | Types into whatever has focus after 3 s; use it on WoW's `/ld` preview |

## To verify on a real Deck

- [ ] **Steam Input → helper:** `--watch` shows the chord's keys arriving from a Steam virtual input device, in both Desktop Mode and Game Mode.
- [ ] **Signal keys → WoW:** Ctrl-Shift-F6…F10 from the virtual keyboard reach WoW through gamescope, Xwayland and Proton (`/ld` panel reacts).
- [ ] **Typing:** `--type` lands correctly in the preview; raise `key_delay_ms` if letters go missing.
- [ ] **Speed:** time from stop to preview with `base.en`. If it's too slow, try `tiny.en`, or run `whisper-server` on a PC (`--host 0.0.0.0`) and point `server_url` at it.
- [ ] **Microphone:** the built-in mic or a headset is the default PipeWire source (Steam → Settings → Audio).

## Known limits

- No check that WoW is the focused app (the Mac helper has one); triggers fire whatever is in front.
- The helper only watches the trigger keys, so WoW receives them too. Keep them unbound in WoW.
- Typing assumes a US keyboard layout in WoW/Proton.
- Same caveats as the Mac version: synthetic input, no delivery acknowledgement, and Send is a separate action you take after reviewing the text.

## Development

```bash
python3 -m unittest deck/test_ld_helper.py
```
