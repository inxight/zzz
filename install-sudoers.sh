#!/bin/bash
# NoSleepBar 가 비밀번호 없이 잠자기 차단을 켜고 끌 수 있게 sudoers 항목을 설치한다.
#
# 허용 범위는 아래 두 줄이 전부다. 인자까지 정확히 일치할 때만 통과하므로
# 다른 pmset 명령(sleep, displaysleep, hibernatemode 등)은 여전히 비밀번호를 요구한다.
#
# 되돌리기: sudo rm /etc/sudoers.d/nosleepbar

set -euo pipefail

# 대상 사용자 결정.
#   osascript 의 "with administrator privileges" 로 실행되면 SUDO_USER 가 없고 whoami 가 root 다.
#   그 상태로 설치하면 root 에게 권한을 줘서 정작 앱(사용자 권한)이 쓰지 못한다.
#   그래서 GUI 로그인 사용자(/dev/console 소유자)를 우선으로 본다. 인자로 덮어쓸 수 있다.
TARGET_USER="${1:-${SUDO_USER:-$(stat -f%Su /dev/console)}}"
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
  echo "대상 사용자를 정하지 못했습니다. 사용법: sudo $0 <사용자명>" >&2
  exit 1
fi
DEST="/etc/sudoers.d/nosleepbar"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

if [ "$(id -u)" -ne 0 ]; then
  echo "root 권한이 필요합니다:  sudo $0" >&2
  exit 1
fi

cat > "$TMP" <<EOF
# NoSleepBar — 메뉴바 잠자기 차단 토글 전용
# 아래 두 명령만 무암호로 허용한다. 다른 pmset 명령은 해당되지 않는다.
$TARGET_USER ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1
$TARGET_USER ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0
EOF

echo "==> 설치할 내용"
sed 's/^/    /' "$TMP"

echo
echo "==> 문법 검증 (visudo -c)"
# 문법이 깨진 파일을 넣으면 sudo 전체가 망가지므로 반드시 먼저 검사한다.
if ! visudo -c -f "$TMP"; then
  echo "문법 오류 — 설치를 중단합니다." >&2
  exit 1
fi

echo
echo "==> 설치"
install -o root -g wheel -m 0440 "$TMP" "$DEST"
ls -l "$DEST"

echo
echo "==> 전체 sudoers 재검증"
visudo -c

echo
echo "==> 무암호 권한 확인 ($TARGET_USER 기준, 설정값은 변경하지 않음)"
if sudo -u "$TARGET_USER" sudo -n -l /usr/bin/pmset -a disablesleep 0 >/dev/null 2>&1 \
  && sudo -u "$TARGET_USER" sudo -n -l /usr/bin/pmset -a disablesleep 1 >/dev/null 2>&1; then
  echo "    OK — 켜기와 끄기 명령이 모두 비밀번호 없이 허용됩니다."
else
  echo "    실패 — 무암호 권한을 확인하지 못했습니다." >&2
  exit 1
fi

echo
echo "완료. 되돌리려면: sudo rm $DEST"
