# Controller Speech + Local Dictation addon

> **Steam Deck / Linux:** a prototype helper for WoW under Proton is in [`deck/`](deck/README.md). The addon is shared; it also accepts the Deck helper's Ctrl-Shift-F6…F10 signal keys.

Prototype for **WoW Forever on Apple Silicon / macOS 26+**. Uses the English Apple SpeechAnalyzer engine already tested in Local Speech Demo. No TypeWhisper, API key, or cloud transcription.

## Install and run

1. Install the included `LocalDictation` folder in `/Applications/World of Warcraft/_forever_/Interface/AddOns/`. `install-addon.command` performs this copy and refuses to overwrite an existing folder.
2. Enable **Local Dictation** in WoW's AddOns list. Enable loading out-of-date addons if necessary, then `/reload`. The TOC targets Forever interface 16001; a later client can require updating this number.
3. Open **Controller Speech.app**, click **Prepare English Model**, and wait for ready.
4. **Set Record / Stop in game:** `/ld keys` → **Record / Stop** slot, then press a key combination (or a WoW gamepad button or combo). Then `/reload`. WoW saves the addon's settings on reload or logout, and the helper reads the binding from `WTF/Account/*/SavedVariables/LocalDictation.lua`. The app shows it under **In-game Record / Stop**. Plain typing keys are refused, because they would start recording while you chat. **Send** is an ordinary addon hotkey (**Send message**) that WoW handles directly, so the helper doesn't need it.
   - If your controller reaches WoW as keyboard keys through a mapper, bind whatever combination it sends. If you use WoW's own gamepad mode, combos like `SHIFT-PAD1` are converted using WoW's gamepad modifier settings (for example L2 + A).
   - If you press Record and nothing happens within 1.5 s, the addon says why: a `/reload` is still needed, or the helper isn't running.

   Optional extra triggers in the helper app, for Record / Stop and Send. Each can have a keyboard combination, a controller combination, or both:
   - **Keyboard** defaults to Control-Option-R (Record / Stop) and Control-Option-S (Send). Click **Change…** and press a new combination (it needs a modifier, or use an F-key). While the bridge is on, the helper takes these keys system-wide, so WoW never sees them and they need no WoW binding.
   - **Controller:** click **Set combo…**, hold the buttons together (for example L1 + R1 + A), then release them all. The combination fires when its last button goes down. The helper only *observes* controller input, so WoW still gets the buttons: pick a combination WoW doesn't use. A single button works but also runs its normal WoW action.
5. Why the triggers live in the helper: the addon can't start the microphone or call the app (no sockets), so the helper catches the presses itself. It records and transcribes, then drives the addon with the keys below.
6. Click **Accessibility…**, then allow **Controller Speech** in System Settings → Privacy & Security → Accessibility. This lets the helper send key combinations and paste into WoW. This is a new app identity, so its microphone permission is also separate from Local Speech Demo.
7. Enable the **bridge** and put WoW in front. Keep the helper running in the background.

## Closing the app

Closing the main window quits the app. Quit also stops microphone recording, cancels transcription and pending paste tasks, and removes controller listeners. The controller bridge starts disabled whenever the app launches.

## Workflow

- Press Record (keyboard or controller combination): helper captures the mic and sends an addon recording notification. The addon opens, clears the previous draft, and displays Recording.
- Press Record again: helper stops capture, transcribes locally and tells the addon to show Transcribing.
- Once text exists, helper opens/focuses the addon preview, waits the **Preview → paste delay** (default 1 second), replaces the system clipboard with the transcript and issues Command-V.
- Review the preview and destination, then press the helper's Send combination (keyboard or controller). Enter in the preview, the panel's **Send** button, or the addon's own Send hotkey work too. The addon submits the message, clears the preview and closes the panel.
- Press Record while a preview exists: cancels any pending paste, starts a fresh recording and clears the draft. Presses during transcription are ignored with a status in the helper.

The delay is a focus/paste settling delay **after the result is available**. It never guesses that recognition has finished. Total stop-to-preview time is recognition latency plus this delay. The measurement list reports recognition only.

## Addon panel

- **Status line:** a colored dot shows idle, recording, transcribing, ready or error.
- **Channel row:** Say, Party, Raid, Instance, Guild or Whisper. The selected channel is highlighted, and channels you can't use right now (no party or guild) are greyed out, with a tooltip explaining why.
- **Whisper target:** type Name or Name-Realm, or click **Friends…** to pick from your character friends, Battle.net friends (sent with a Battle.net whisper) and recent whispers. It has search, shows online friends first with class colors, and offline friends are disabled.
- **Message preview:** an editable text box with a 255-byte counter that turns orange, then red. Enter sends and Esc closes.
- **Controller navigation (WoW gamepad mode):** while the panel is open, the D-pad, A, B and Y act on the panel. D-pad left/right changes channel; up/down changes the whisper target, or moves through the open friend list. A sends (or picks the highlighted friend), B closes (or leaves the list), X clears the message, Y opens or closes the friend list. Esc and the list's own close button also close only the friend list. These are temporary override bindings: they apply only while the panel is shown, and they're released as combat starts, so the buttons keep their normal game actions in a fight. Turn it off with `/ld pad off`.
- **Hotkeys:** opens an editor with two key slots per action. Click a slot and press a keyboard key, mouse button 3–5 or gamepad button; right-click a slot to clear it. Bindings are saved to WoW's binding set and also appear under Key Bindings → AddOns → Local Dictation. Control-Shift-F13…F17 are reserved for the helper.

| Hotkey action | Effect |
|---|---|
| Open / close panel | Toggle the panel for typing or checking the destination |
| Send message | Submit the preview |
| Next / Previous channel | Cycle channels (works with the panel closed) |
| Next whisper target | Cycle online friends and recent whispers |
| Pick from friends | Open the panel with the friend picker |
| Clear message | Empty the preview |
| Cancel / close | Close and clear |

Hotkeys with a modifier, or keys like F-keys, also work while the preview has text focus. Plain letter keys stay normal typing there.

Preset commands:

- `/ld channel party` (also say, raid, instance, guild, whisper)
- `/ld whisper FriendName-Realm`
- `/ld friends` (friend picker), `/ld keys` (hotkey editor), `/ld freekeys` (lists free keyboard keys and controller combos; flags combos whose plain key has a game action, because WoW falls back to the plain key when a combo is unbound)
- `/ld status`
- `/ld close`
- `/ld` opens an empty preview for a manual paste test.

Channel, whisper target, recent whispers and panel position are stored in normal SavedVariables, subject to the client's persistence behavior. Reapply the preset if the beta client resets settings.

Messages are limited to 255 bytes. Oversize messages remain in preview with an error so they can be edited; there is no automatic splitting.

## Bridge implementation

The addon never launches or calls the backend. The Mac helper independently receives native controller events while WoW is foreground, controls recording/transcription, then sends these key combinations:

| Combination | Addon action |
|---|---|
| Control-Shift-F13 | Clear draft and show Recording |
| Control-Shift-F14 | Show Transcribing |
| Control-Shift-F15 | Open/focus empty preview |
| Command-V | Paste transcript |
| Control-Shift-F16 | Submit preview |
| Control-Shift-F17 | Show failure/retry state |

The addon installs session-only override bindings for those combinations. A focused edit box also handles the helper's function keys. Text crosses through macOS clipboard and WoW's normal edit-box paste. No sockets, memory access or reload-per-message mechanism is used.

The helper does not receive an acknowledgement from the addon. It reports **Paste issued** or **Send key delivered**, not confirmed delivery. If focus was wrong, inspect the addon and retry. Only use the bridge while the composer can safely take input; avoid mouse/keyboard interaction during the paste delay. The foreground check happens again immediately before paste.

The addon clears/closes after the send API returns without a Lua error. This is submission, not server acknowledgement; chat restrictions or invalid recipients may still produce game errors. No test message is sent automatically.

## Troubleshooting and validation

- **No controller listed:** connect via Bluetooth/USB, click Refresh controller, and check Last input. A controller visible only through a remapping tool might not be exposed to Apple's GameController API; this needs a live hardware check.
- **No addon panel:** ensure the addon is loaded, the bridge is enabled, WoW is foreground, Accessibility is allowed, and the selected controller button is registered in Last input. Try `/ld` manually.
- **Panel opens but no text:** increase the delay, avoid clicking other fields, and test Command-V manually into `/ld`. The transcript remains visible in the helper and on the clipboard after attempted delivery.
- **No mic activity:** allow this app under Privacy & Security → Microphone; check Sound → Input.
- **Send does nothing:** check the helper phase/status, addon destination, whisper recipient, message length and game errors. Never assume the helper's Send-key message means server delivery.
- **Panel blocks gameplay:** close it with Escape, its X button, `/ld close`, or a custom Cancel binding.

Native app compilation and bundle validation are checked during build. Actual controller coexistence, synthetic key receipt, addon focus and chat submission require a live Forever test. These are integration assumptions to verify, not claims of Blizzard approval or full in-game compatibility.

## Data and source

Local recognition uses Apple's system-managed English model. Initial model downloads can use Apple's network services. Microphone clips are temporary and removed after processing. The app replaces the clipboard with the transcript and keeps text/measurements in memory; JSON export includes transcript text. It does not read game memory or automatically send chat after transcription. Send is a separate controller action.

Swift source is separated into app lifecycle (`App.swift`), speech capture/recognition (`LocalSpeech.swift`), controller and keyboard bridge (`ControllerBridge.swift`, `GlobalHotKey.swift`), and views (`ContentView.swift`, `BridgeView.swift`). Lua/XML source is in `LocalDictation/`. `build.command` rebuilds and ad-hoc signs the helper. The application is not notarized for redistribution.
