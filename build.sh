#!/bin/bash
# NoSleepBar 빌드 — main.swift 한 파일을 .app 번들로 만든다.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_ROOT="$HOME/Applications"
APP="$APP_ROOT/NoSleepBar.app"
mkdir -p "$APP_ROOT"

# 기존 설치본은 새 번들의 컴파일·서명 검증이 모두 끝난 뒤에만 교체한다.
STAGING_ROOT="$(mktemp -d "$APP_ROOT/.nosleepbar-build.XXXXXX")"
BUILD_APP="$STAGING_ROOT/NoSleepBar.app"
PREVIOUS_APP="$STAGING_ROOT/previous.app"
trap 'rm -rf "$STAGING_ROOT"' EXIT

echo "==> 임시 번들 구조 생성"
mkdir -p "$BUILD_APP/Contents/MacOS"
cp "$SRC_DIR/Info.plist" "$BUILD_APP/Contents/Info.plist"

echo "==> 컴파일"
swiftc -O \
  -target arm64-apple-macos13.0 \
  -framework Cocoa -framework IOKit \
  -o "$BUILD_APP/Contents/MacOS/NoSleepBar" \
  "$SRC_DIR/main.swift"

echo "==> ad-hoc 코드 서명"
codesign --force --sign - "$BUILD_APP"

echo "==> 새 번들 검증"
codesign --verify --verbose "$BUILD_APP" 2>&1 | sed 's/^/    /'
file "$BUILD_APP/Contents/MacOS/NoSleepBar" | sed 's/^/    /'

echo "==> 기존 앱이 떠 있으면 종료"
pkill -x NoSleepBar 2>/dev/null && sleep 1 || true

echo "==> 검증된 번들 설치: $APP"
if [ -e "$APP" ]; then
  mv "$APP" "$PREVIOUS_APP"
fi
if ! mv "$BUILD_APP" "$APP"; then
  if [ -e "$PREVIOUS_APP" ]; then mv "$PREVIOUS_APP" "$APP"; fi
  echo "설치 실패 — 기존 앱을 복구했습니다." >&2
  exit 1
fi
rm -rf "$PREVIOUS_APP"

echo "==> 설치본 재검증"
codesign --verify --verbose "$APP" 2>&1 | sed 's/^/    /'
file "$APP/Contents/MacOS/NoSleepBar" | sed 's/^/    /'

echo
echo "빌드 완료: $APP"
echo "실행: open -a \"$APP\""
