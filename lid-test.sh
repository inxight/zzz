#!/bin/bash
# 덮개를 닫아도 실제로 계속 돌아가는지 확인하는 테스트.
#
# 사용법
#   1) 메뉴바에서 잠자기 차단을 켠다 (아이콘이 오렌지 눈 모양)
#   2) 이 스크립트를 실행한다
#   3) 전원 어댑터를 뽑고 덮개를 닫는다
#   4) 몇 분 뒤 덮개를 연다
#   5) Ctrl+C 로 멈추고 결과를 본다
#
# 5초마다 한 줄씩 찍는다. 덮개를 닫은 동안 줄이 계속 늘어났으면 성공,
# 시각이 뚝 끊겼다가 다시 이어지면 그 구간에 잠든 것이다.

LOG="$HOME/nosleep-test.log"

echo "잠자기 차단 상태: $(pmset -g | grep -i sleepdisabled | awk '{print $2}')  (1이어야 한다)"
echo "로그 파일: $LOG"
echo "5초마다 기록합니다. Ctrl+C 로 종료."
echo "----- 시작 $(date '+%Y-%m-%d %H:%M:%S') -----" >> "$LOG"

trap 'echo; echo "----- 종료 $(date "+%H:%M:%S") -----" >> "$LOG"; echo; echo "== 마지막 40줄 =="; tail -40 "$LOG"; exit 0' INT

while true; do
  printf '%s  batt=%s%%  ac=%s\n' \
    "$(date '+%H:%M:%S')" \
    "$(pmset -g batt | grep -o '[0-9]*%' | head -1 | tr -d '%')" \
    "$(pmset -g batt | grep -q 'AC Power' && echo yes || echo no)" >> "$LOG"
  sleep 5
done
