#!/bin/bash
# NoSleepBar 를 완전히 제거한다.
set -euo pipefail

LABEL="kr.co.inxight.nosleepbar"
CAFFEINATE_LABEL="kr.co.inxight.nosleepbar.caffeinate"
APP="$HOME/Applications/NoSleepBar.app"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
CAFFEINATE_AGENT="$HOME/Library/LaunchAgents/$CAFFEINATE_LABEL.plist"

service_is_loaded() {
  local target="$1"
  local output
  if output="$(launchctl print "$target" 2>&1)"; then
    return 0
  fi
  if [[ "$output" == *"Could not find service"* ]]; then
    return 1
  fi
  echo "    실패 — launchctl 상태를 확인하지 못했습니다: $output" >&2
  return 2
}

echo "==> 앱 종료"
if pkill -x NoSleepBar 2>/dev/null; then
  sleep 1
  echo "    종료함"
else
  echo "    떠 있지 않음"
fi

echo "==> 덮개 닫힘 잠자기 차단 해제"
sudo -n /usr/bin/pmset -a disablesleep 0 2>/dev/null \
  || sudo /usr/bin/pmset -a disablesleep 0
if [ "$(pmset -g | awk 'tolower($1) == "sleepdisabled" { print $2; exit }')" != "0" ]; then
  echo "    실패 — SleepDisabled 값이 0이 아닙니다." >&2
  exit 1
fi
echo "    SleepDisabled 0"

echo "==> caffeinate 절전 차단 제거"
CAFFEINATE_TARGET="gui/$(id -u)/$CAFFEINATE_LABEL"
if service_is_loaded "$CAFFEINATE_TARGET"; then
  if ! launchctl bootout "$CAFFEINATE_TARGET"; then
    echo "    실패 — caffeinate 서비스를 종료하지 못했습니다." >&2
    exit 1
  fi
else
  SERVICE_STATUS=$?
  if [ "$SERVICE_STATUS" -ne 1 ]; then exit 1; fi
fi
if service_is_loaded "$CAFFEINATE_TARGET"; then
  echo "    실패 — caffeinate 서비스가 아직 등록돼 있습니다." >&2
  exit 1
else
  SERVICE_STATUS=$?
  if [ "$SERVICE_STATUS" -ne 1 ]; then exit 1; fi
fi
if [ -f "$CAFFEINATE_AGENT" ]; then
  rm -f "$CAFFEINATE_AGENT"
  echo "    제거함"
else
  echo "    없음"
fi

echo "==> 로그인 항목 제거"
if [ -f "$AGENT" ]; then
  LOGIN_TARGET="gui/$(id -u)/$LABEL"
  if service_is_loaded "$LOGIN_TARGET"; then
    launchctl bootout "$LOGIN_TARGET"
  else
    SERVICE_STATUS=$?
    if [ "$SERVICE_STATUS" -ne 1 ]; then exit 1; fi
  fi
  rm -f "$AGENT"
  echo "    제거함"
else
  echo "    없음"
fi

echo "==> 앱 번들 제거"
if ! rm -rf "$APP"; then
  echo "    실패 — 앱 번들을 제거하지 못했습니다." >&2
  exit 1
fi
echo "    $APP"

echo "==> 설정값 제거"
if defaults read "$LABEL" >/dev/null 2>&1; then
  if ! defaults delete "$LABEL"; then
    echo "    실패 — 설정값을 제거하지 못했습니다." >&2
    exit 1
  fi
  echo "    제거함"
else
  echo "    없음"
fi

echo "==> sudoers 항목 제거 (관리자 권한 필요)"
if ! sudo rm -f /etc/sudoers.d/nosleepbar; then
  echo "    실패 — sudoers 항목을 제거하지 못했습니다." >&2
  exit 1
fi
echo "    제거함"
sudo visudo -c

echo
echo "제거 완료. 소스는 $(cd "$(dirname "$0")" && pwd) 에 남아 있습니다."
