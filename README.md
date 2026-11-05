# Controller Speech + Local Dictation addon

Prototype for **WoW Forever on Apple Silicon / macOS 26+**. Uses the English Apple SpeechAnalyzer engine already tested in Local Speech Demo. No TypeWhisper, API key, or cloud transcription.

## Install and run

1. Install the included `LocalDictation` folder in `/Applications/World of Warcraft/_forever_/Interface/AddOns/`. `install-addon.command` performs this copy and refuses to overwrite an existing folder.
2. Enable **Local Dictation** in WoW's AddOns list. Enable loading out-of-date addons if necessary, then `/reload`. The TOC targets Forever interface 16001; a later client can require updating this number.
3. Open **Controller Speech.app**, click **Prepare English Model**, and wait for ready.
4. Connect the controller by Bluetooth/USB. Check the controller name and **Last input** field by pressing buttons while the bridge is disabled. The app uses Apple's native GameController framework.
5. Choose different **Record / Stop** and **Send** buttons. Defaults are L3 (left stick click) and R3 (right stick click). In WoW, remove other actions from those two buttons. The helper observes input; it cannot prevent the game from also executing an existing binding.
6. Click **Accessibility…**, then allow **Controller Speech** in System Settings → Privacy & Security → Accessibility. This lets the helper send key combinations and paste into WoW. This is a new app identity, so its microphone permission is also separate from Local Speech Demo.
7. Enable **controller bridge** and put WoW in front. Keep the helper running in the background.

## Closing the app

Closing the main window quits the app. Quit also stops microphone recording, cancels transcription and pending paste tasks, and removes controller listeners. The controller bridge starts disabled whenever the app launches.

## Workflow

- Press Record: helper captures the mic and sends an addon recording notification. The addon opens, clears the previous draft, and displays Recording.
- Press Record again: helper stops capture, transcribes locally and tells the addon to show Transcribing.
- Once text exists, helper opens/focuses the addon preview, waits the **Preview → paste delay** (default 1 second), replaces the system clipboard with the transcript and issues Command-V.
- Review the preview and destination. Press the separate Send button: the helper sends the addon Send binding; the addon submits the message, clears the preview and closes the panel.
- Press Record while a preview exists: cancels any pending paste, starts a fresh recording and clears the draft. Presses during transcription are ignored with a status in the helper.

The delay is a focus/paste settling delay **after the result is available**. It never guesses that recognition has finished. Total stop-to-preview time is recognition latency plus this delay. The measurement list reports recognition only.

## Channel and whisper recipient

Default channel is Party. Click the channel button in the addon to cycle Say → Party → Raid → Instance → Guild → Whisper. For controller-only channel cycling, bind **Next dictation channel** under Key Bindings → Local Dictation to a spare controller button. Bind **Cancel / close dictation preview** similarly if desired.

Preset commands:

- `/ld channel party` (also say, raid, instance, guild, whisper)
- `/ld whisper FriendName-Realm`
- `/ld status`
- `/ld close`
- `/ld` opens an empty preview for a manual paste test.

The whisper recipient field can be edited in the addon; set it once before a controller session. This prototype does not yet provide a controller friend-picker. Channel and target are stored in normal SavedVariables, subject to the client's persistence behavior. Reapply the preset if the beta client resets settings.

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

Swift source is separated into app lifecycle (`App.swift`), speech capture/recognition (`LocalSpeech.swift`), controller bridge (`ControllerBridge.swift`), and views (`ContentView.swift`, `BridgeView.swift`). Lua/XML source is in `LocalDictation/`. `build.command` rebuilds and ad-hoc signs the helper. The application is not notarized for redistribution.
