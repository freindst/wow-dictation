#!/usr/bin/env bash
# Interactive Desktop Mode setup. Run from an extracted repository ZIP.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
data="$HOME/.local/share/local-dictation"

if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 ]]; then
  echo 'This installer requires an x86_64 Linux Steam Deck. Run it in Desktop Mode.'
  exit 1
fi
if [[ $EUID -eq 0 ]]; then
  echo 'Run this installer as your normal Deck user. It asks for sudo only for input permissions.'
  exit 1
fi
for tool in python3 git curl pw-record systemctl konsole; do
  if ! command -v "$tool" >/dev/null; then
    echo "Missing dependency: $tool. Setup has stopped before making changes."
    exit 1
  fi
done
if ! { command -v cmake >/dev/null && command -v c++ >/dev/null; } && ! command -v distrobox >/dev/null; then
  echo 'Distrobox is required to build Whisper on a Deck without a compiler.'
  echo 'Install Distrobox using its official instructions, then run this installer again.'
  echo 'https://distrobox.it/'
  exit 1
fi

echo 'Local Dictation — Steam Deck setup'
echo 'This installs the helper and English model in your home folder.'
echo 'It also copies the addon into your chosen WoW client and enables a background service.'
echo 'First setup downloads and compiles Whisper automatically. This can take several minutes.'
echo
if command -v kdialog >/dev/null; then
  wow_dir="$(kdialog --title 'Local Dictation — select WoW client' --getexistingdirectory "$HOME" 2>/dev/null)" || exit 1
else
  read -r -p 'Full WoW client path (for example .../World of Warcraft/_forever_): ' wow_dir
fi
if [[ ! -d "$wow_dir/Interface" || ! -d "$wow_dir/WTF" ]]; then
  echo 'Select the WoW client folder containing both Interface and WTF. Log into WoW once if needed.'
  exit 1
fi
if [[ ! -f "$here/../LocalDictation/LocalDictation.toc" ]]; then
  echo 'The addon is missing. Extract the entire repository ZIP before running deck/setup.sh.'
  exit 1
fi
read -r -p 'Continue with installation? [y/N] ' answer
[[ "$answer" == y || "$answer" == Y ]] || exit 0

# Access to event devices and uinput is needed in Gaming Mode.
# Group membership becomes effective for systemd after a full logout or reboot.
needs_reboot=0
if [[ ! -w /dev/uinput ]] || ! python3 -c 'import glob, os, sys; sys.exit(not any(os.access(p, os.R_OK) for p in glob.glob("/dev/input/event*")))'; then
  echo 'Input setup lets the helper read keyboard events and create a virtual keyboard.'
  echo 'Enter your Deck sudo password when requested. If none is set, run passwd in Konsole first.'
  bash "$here/install.sh" --permissions
  needs_reboot=1
fi

# The lower-level installer checks/builds the local speech engine and downloads Base English.
# A permission check may still need a reboot, which this wizard handles below.
if bash "$here/install.sh"; then
  install_status=0
else
  install_status=$?
fi
if [[ $install_status -ne 0 && $install_status -ne 3 ]]; then
  echo 'Helper installation failed. Review the error above and rerun setup after correcting it.'
  exit "$install_status"
fi

addon="$wow_dir/Interface/AddOns/LocalDictation"
if [[ -e "$addon" ]]; then
  backup="$data/backups/LocalDictation-$(date +%Y%m%d-%H%M%S)-$$"
  mkdir -p "$(dirname "$backup")"
  cp -a "$addon" "$backup"
  echo "Previous addon backed up to $backup"
fi
mkdir -p "$addon"
install -m 644 "$here/../LocalDictation/LocalDictation.toc" "$here/../LocalDictation/LocalDictation.lua" "$here/../LocalDictation/Bindings.xml" "$addon/"
install -m 755 "$here/manage.sh" "$data/manage.sh"

# Install launchers with fully quoted paths, usable without opening an agent or editor.
python3 - "$data/manage.sh" <<'PY'
from pathlib import Path
import subprocess
import sys

def quote(value):
    value = value.replace('\\', '\\\\').replace('"', '\\"').replace('`', '\\`').replace('$', '\\$').replace('%', '%%')
    return '"' + value + '"'

text = ('[Desktop Entry]\nType=Application\nName=Local Dictation Controls\n'
        'Comment=Start, stop and diagnose the Steam Deck dictation helper\n'
        'Exec=konsole --noclose -e /bin/bash ' + quote(sys.argv[1]) + '\n'
        'Icon=audio-input-microphone\nTerminal=false\nCategories=Utility;\n')
apps = Path.home() / '.local/share/applications'
apps.mkdir(parents=True, exist_ok=True)
(apps / 'local-dictation.desktop').write_text(text)
try:
    desktop = Path(subprocess.check_output(['xdg-user-dir', 'DESKTOP'], text=True).strip())
except (OSError, subprocess.CalledProcessError):
    desktop = Path.home() / 'Desktop'
desktop.mkdir(parents=True, exist_ok=True)
launcher = desktop / 'Local Dictation Controls.desktop'
launcher.write_text(text)
launcher.chmod(0o755)
PY

if [[ $needs_reboot -eq 1 || $install_status -eq 3 ]]; then
  echo
  echo 'Files installed. Reboot the Deck to apply input permissions.'
  echo 'After reboot, open Local Dictation Controls and choose Status or Diagnostics.'
else
  systemctl --user restart local-dictation.service
  echo 'Background helper started. Check Status in Local Dictation Controls.'
fi
echo
echo 'In WoW, enable Local Dictation and reload the UI.'
echo 'Map a spare Steam Input button to Ctrl+Shift+F11 for Record/Stop.'
echo 'Map another button to Ctrl+Shift+F12 for Send.'
echo 'Return to Gaming Mode and launch WoW. The service runs in the background.'
echo 'Use the installed Local Dictation Controls launcher whenever you need to stop it.'
