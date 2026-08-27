#!/bin/bash
# NoSleepBar 를 완전히 제거한다.
set -uo pipefail

LABEL="kr.co.inxight.nosleepbar"
APP="$HOME/Applications/NoSleepBar.app"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "==> 잠자기 차단 해제"
sudo -n /usr/bin/pmset -a disablesleep 0 2>/dev/null \
  || sudo /usr/bin/pmset -a disablesleep 0
echo "    $(pmset -g | grep -i sleepdisabled)"

echo "==> 앱 종료"
pkill -x NoSleepBar 2>/dev/null && echo "    종료함" || echo "    떠 있지 않음"

echo "==> 로그인 항목 제거"
if [ -f "$AGENT" ]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$AGENT"
  echo "    제거함"
else
  echo "    없음"
fi

echo "==> 앱 번들 제거"
rm -rf "$APP" && echo "    $APP"

echo "==> 설정값 제거"
defaults delete "$LABEL" 2>/dev/null && echo "    제거함" || echo "    없음"

echo "==> sudoers 항목 제거 (관리자 권한 필요)"
sudo rm -f /etc/sudoers.d/nosleepbar && echo "    제거함"
sudo visudo -c

echo
echo "제거 완료. 소스는 $(cd "$(dirname "$0")" && pwd) 에 남아 있습니다."
