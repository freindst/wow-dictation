#!/bin/zsh
set -eu
cd "${0:A:h}"
addon_target='/Applications/World of Warcraft/_forever_/Interface/AddOns/LocalDictation'
if [[ -e "$addon_target" ]]; then
  echo 'LocalDictation already exists. Rename or remove that folder before installing this demo.'
  exit 1
fi
mkdir -p "$addon_target"
cp LocalDictation/LocalDictation.toc LocalDictation/LocalDictation.lua LocalDictation/Bindings.xml "$addon_target/"
echo 'Installed LocalDictation for WoW Forever. Enable it in AddOns and /reload.'
