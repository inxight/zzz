#!/bin/bash
# NoSleepBar 빌드 — main.swift 한 파일을 .app 번들로 만든다.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/NoSleepBar.app"

echo "==> 기존 앱이 떠 있으면 종료"
pkill -x NoSleepBar 2>/dev/null && sleep 1 || true

echo "==> 번들 구조 생성: $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$SRC_DIR/Info.plist" "$APP/Contents/Info.plist"

echo "==> 컴파일"
swiftc -O \
  -target arm64-apple-macos13.0 \
  -framework Cocoa -framework IOKit \
  -o "$APP/Contents/MacOS/NoSleepBar" \
  "$SRC_DIR/main.swift"

echo "==> ad-hoc 코드 서명"
codesign --force --sign - "$APP"

echo "==> 검증"
codesign --verify --verbose "$APP" 2>&1 | sed 's/^/    /'
file "$APP/Contents/MacOS/NoSleepBar" | sed 's/^/    /'

echo
echo "빌드 완료: $APP"
echo "실행: open -a \"$APP\""
