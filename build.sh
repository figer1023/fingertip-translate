#!/bin/zsh
set -eu
cd "${0:A:h}"
app_path=${1:?请指定新应用的完整路径}
if [[ -e "$app_path" ]]; then echo '目标已存在，请使用新路径。' >&2; exit 1; fi
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp Info.plist "$app_path/Contents/Info.plist"
cp Resources/* "$app_path/Contents/Resources/"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos26.0 Core.swift Reader.swift Interface.swift App.swift main.swift -o "$app_path/Contents/MacOS/FingertipTranslate"
codesign --force --sign - --identifier local.figer.fingertiptranslate "$app_path"
codesign --verify --strict "$app_path"
