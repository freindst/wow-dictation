#!/usr/bin/env bash
# Installed alongside ld_helper.py. Intended for a Desktop Mode Konsole window.
set -uo pipefail
data="$HOME/.local/share/local-dictation"
while true; do
  echo
  echo 'Local Dictation Controls'
  echo '1  Start / restart helper'
  echo '2  Stop helper'
  echo '3  Show status'
  echo '4  Show recent logs'
  echo '5  Run diagnostics'
  echo '6  Enable start at login'
  echo '7  Disable start at login and stop'
  echo '0  Exit controls'
  read -r -p 'Choose an action: ' choice || exit 0
  case "$choice" in
    1) systemctl --user restart local-dictation.service ;;
    2) systemctl --user stop local-dictation.service ;;
    3) systemctl --user --no-pager status local-dictation.service ;;
    4) journalctl --user -u local-dictation.service --no-pager -n 60 ;;
    5) python3 "$data/ld_helper.py" --check ;;
    6) systemctl --user enable local-dictation.service ;;
    7) systemctl --user disable --now local-dictation.service ;;
    0) exit 0 ;;
    *) echo 'Choose one of the numbered actions.' ;;
  esac
done
