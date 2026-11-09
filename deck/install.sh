#!/usr/bin/env bash
# Install the Local Dictation helper on a Steam Deck (run in Desktop Mode, in Konsole).
#
#   ./install.sh                 install helper, build whisper.cpp, download model, add service
#   ./install.sh --permissions   one-time sudo step: input group + uinput access (needs a sudo password)
#   ./install.sh --model small.en  use a different English model (tiny.en, base.en, small.en)
#
# Everything lives in your home folder, so SteamOS updates do not remove it.
# The --permissions step writes to /etc, which SteamOS keeps across updates.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
data="$HOME/.local/share/local-dictation"
conf="$HOME/.config/local-dictation"
units="$HOME/.config/systemd/user"
whisper_ref="${WHISPER_REF:-v1.7.5}"
model="base.en"
do_permissions=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --permissions) do_permissions=1 ;;
    --model) [[ $# -ge 2 ]] || { echo "--model needs tiny.en, base.en, or small.en"; exit 2; }; model="$2"; shift ;;
    *) echo "unknown option: $1"; exit 2 ;;
  esac
  shift
done

case "$model" in tiny.en|base.en|small.en) ;; *) echo "Unsupported model: $model"; exit 2 ;; esac
if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 ]]; then
  echo 'This installer requires x86_64 Linux.'
  exit 1
fi

if [[ $do_permissions -eq 1 ]]; then
  echo "Granting $USER read access to input devices and write access to /dev/uinput (sudo)…"
  sudo tee /etc/udev/rules.d/60-local-dictation-uinput.rules >/dev/null <<'RULE'
KERNEL=="uinput", SUBSYSTEM=="misc", GROUP="input", MODE="0660", OPTIONS+="static_node=uinput"
RULE
  sudo modprobe uinput
  sudo usermod -aG input "$USER"
  sudo udevadm control --reload-rules
  sudo udevadm trigger --name-match=uinput || true
  echo "Done. Log out and back in (or reboot) so the 'input' group applies."
  exit 0
fi

mkdir -p "$data/models" "$conf" "$units"
install -m 755 "$here/ld_helper.py" "$data/ld_helper.py"
if [[ ! -f "$conf/config.ini" ]]; then
  sed "s/ggml-base.en.bin/ggml-$model.bin/" "$here/config.example.ini" > "$conf/config.ini"
  echo "Wrote $conf/config.ini"
else
  echo "Keeping existing $conf/config.ini"
fi

# --- whisper.cpp ---------------------------------------------------------
server_bin="$data/whisper.cpp/build/bin/whisper-server"
if [[ ! -x "$server_bin" ]]; then
  if [[ ! -d "$data/whisper.cpp" ]]; then
    git clone --depth 1 --branch "$whisper_ref" https://github.com/ggml-org/whisper.cpp.git "$data/whisper.cpp"
  fi
  build_cmd="cd '$data/whisper.cpp' && cmake -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_TESTS=OFF -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF '-DCMAKE_EXE_LINKER_FLAGS=-static-libstdc++ -static-libgcc' && cmake --build build -j 4 --target whisper-server"
  if command -v cmake >/dev/null && command -v c++ >/dev/null; then
    bash -c "$build_cmd"
  elif command -v distrobox >/dev/null; then
    # SteamOS has no compiler; build inside a throwaway container (static binary runs on the host).
    if ! distrobox list --no-color | awk -F '|' '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' | grep -qx ld-build; then
      distrobox create --yes --name ld-build --image docker.io/library/ubuntu:22.04
    fi
    distrobox enter ld-build -- bash -c "sudo apt-get update -qq && sudo apt-get install -y -qq build-essential cmake git >/dev/null && $build_cmd"
  else
    echo "Need cmake + a C++ compiler, or distrobox, to build whisper.cpp."
    echo "Alternatively run whisper-server on another PC and set server_url in $conf/config.ini."
    exit 1
  fi
fi

# Verify the compiled executable can load its runtime libraries on the host.
"$server_bin" --help >/dev/null

# --- model ---------------------------------------------------------------
model_file="$data/models/ggml-$model.bin"
if [[ ! -f "$model_file" ]]; then
  echo "Downloading ggml-$model.bin…"
  curl -L --fail -o "$model_file.part" "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$model.bin"
  mv "$model_file.part" "$model_file"
fi

# --- service -------------------------------------------------------------
install -m 644 "$here/local-dictation.service" "$units/local-dictation.service"
systemctl --user daemon-reload
systemctl --user enable local-dictation.service

echo
if ! python3 "$data/ld_helper.py" --check; then
  echo
  echo "Files installed, but diagnostics failed. Resolve the reported issue before starting the service."
  exit 3
fi
echo
echo "Start now:      systemctl --user restart local-dictation"
echo "Follow the log: journalctl --user -u local-dictation -f"
