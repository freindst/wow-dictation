#!/bin/zsh
set -eu
cd "${0:A:h}"
build_cache="${TMPDIR:-/tmp/}ControllerSpeechModuleCache"
mkdir -p "$build_cache" 'Controller Speech.app/Contents/MacOS'
cp Resources/Info.plist 'Controller Speech.app/Contents/Info.plist'
xcrun swiftc -module-cache-path "$build_cache" -parse-as-library -O -target arm64-apple-macosx26.0 Source/*.swift -o 'Controller Speech.app/Contents/MacOS/ControllerSpeech'
codesign --force --sign - 'Controller Speech.app'
echo 'Built Controller Speech.app'
