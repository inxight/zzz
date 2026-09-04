# NoSleepBar

화면 자동 꺼짐과 덮개를 닫을 때의 잠자기를 함께 차단하는 macOS 메뉴바 토글.

Swift 한 파일(`main.swift`)과 셸 스크립트 몇 개가 전부다. Xcode 프로젝트는 없다.

---

## 동작 원리

토글을 켜면 서로 다른 두 계층을 함께 적용한다.

1. 사용자 LaunchAgent가 `/usr/bin/caffeinate -dimsu` 를 계속 실행한다. 화면 자동 꺼짐,
   유휴 시스템 잠자기, 디스크 유휴 상태 등을 `caffeinate` 와 같은 방식으로 차단한다.
2. `pmset -a disablesleep 1` 로 `IOPMrootDomain` 의 `SleepDisabled` 를 켜 덮개 닫힘
   잠자기를 별도로 차단한다. 이 설정은 관리자 권한이 필요하다.

앱을 종료해도 설정을 유지하도록 선택한 경우 `caffeinate` LaunchAgent와 `SleepDisabled`가
모두 남는다. LaunchAgent는 프로세스가 예기치 않게 종료되면 다시 실행한다.

메뉴는 `caffeinate` 프로세스와 `SleepDisabled`의 실제 상태를 각각 표시한다. 두 항목이
모두 켜져 있을 때만 전체 상태를 **켜짐**으로 표시한다.

---

## 요구 사항

| 항목 | 값 |
|---|---|
| macOS | 13.0 이상 (`LSMinimumSystemVersion`) |
| 아키텍처 | Apple Silicon — `build.sh` 가 `arm64-apple-macos13.0` 으로만 컴파일한다 |
| 빌드 도구 | `swiftc` (Xcode 또는 Command Line Tools) |

Intel 맥에서 쓰려면 `build.sh` 의 `-target` 을 바꾸거나 universal 로 빌드해야 한다.

---

## 설치

```bash
./build.sh            # ~/Applications/NoSleepBar.app 생성 + ad-hoc 서명
sudo ./install-sudoers.sh   # (선택) 비밀번호 프롬프트 없애기
open -a ~/Applications/NoSleepBar.app
```

`build.sh` 는 임시 위치에서 새 번들의 컴파일·서명 검증을 마친 뒤 기존 NoSleepBar를 교체한다.

### sudoers 항목은 왜 선택인가

`pmset -a disablesleep` 은 root 권한이 필요하다. 앱은 두 경로를 순서대로 시도한다.

1. `sudo -n /usr/bin/pmset -a disablesleep 0|1` — 무암호 경로
2. 실패하면 AppleScript `with administrator privileges` 로 관리자 인증 창

`install-sudoers.sh` 를 돌리지 않아도 2번 폴백으로 동작한다. 다만 토글할 때마다 인증 창이 뜬다.

설치되는 내용은 아래 두 줄이 전부다. **인자까지 정확히 일치할 때만** 통과하므로
`pmset sleep`, `displaysleep`, `hibernatemode` 등 다른 명령은 여전히 비밀번호를 요구한다.

```
<사용자> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1
<사용자> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0
```

스크립트는 `visudo -c` 로 문법을 먼저 검증한 뒤에만 `/etc/sudoers.d/nosleepbar` 에 설치하고,
설치 후 대상 사용자의 켜기·끄기 명령이 무암호로 허용되는지 설정값 변경 없이 확인한다.

되돌리기: `sudo rm /etc/sudoers.d/nosleepbar`

---

## 메뉴

| 항목 | 설명 |
|---|---|
| 상태 헤더 | 전체 상태와 화면 자동 꺼짐 차단/덮개 닫힘 차단의 개별 상태 |
| 켜기 / 끄기 (`⌘T`) | 두 차단 기능을 함께 켜거나 끈다 |
| 자동 해제 | 사용 안 함 / 30분 / 1시간 / 2시간 / 4시간 뒤 자동으로 끈다 |
| 배터리 N% 이하면 자동 해제 | 기본 켜짐 |
| 기준 배터리 | 10 / 15 / 20 / 30 / 50% (기본 20%) |
| 종료할 때 자동 해제 | 기본 켜짐 |
| 로그인할 때 자동 실행 | LaunchAgent 등록/해제 |
| NoSleepBar 종료 (`⌘Q`) | |

아이콘은 꺼졌을 때 `zzz`, 완전히 켜졌을 때 오렌지색 `eye.fill`, 두 기능 중 하나만
켜진 비정상 상태일 때 빨간색 경고 삼각형이다.

### 배터리 보호

30초마다 도는 워치독이 배터리 상태를 확인한다.
**어댑터를 뽑은 상태**에서 잔량이 기준 이하로 떨어지면 잠자기 차단을 자동으로 해제하고 알림을 띄운다.
어댑터가 꽂혀 있으면 발동하지 않는다.

### 자동 해제 타이머

타이머를 걸면 잠자기 차단이 꺼져 있던 경우 **함께 켜진다.**
켜는 데 실패하면 타이머를 걸지 않고 알림을 띄운다.

### 로그인 항목

`~/Library/LaunchAgents/kr.co.inxight.nosleepbar.plist` 를 만들고 `launchctl bootstrap` 한다.
끄면 `bootout` 후 파일을 지운다.

화면 자동 꺼짐 차단 프로세스는 별도
`~/Library/LaunchAgents/kr.co.inxight.nosleepbar.caffeinate.plist` 로 관리한다. 이 파일은
전체 차단 기능을 끄거나, `종료할 때 자동 해제`가 켜진 상태로 앱을 종료하면 제거된다.

---

## 파일

| 파일 | 용도 |
|---|---|
| [main.swift](main.swift) | 앱 전체 |
| [Info.plist](Info.plist) | 번들 정보. `LSUIElement` 로 Dock 아이콘 없음 |
| [build.sh](build.sh) | `swiftc` 로 `.app` 번들 생성 + ad-hoc 서명 + 검증 |
| [install-sudoers.sh](install-sudoers.sh) | 무암호 sudoers 항목 설치 |
| [uninstall.sh](uninstall.sh) | 앱·LaunchAgent·설정값·sudoers 항목 전부 제거 |
| [lid-test.sh](lid-test.sh) | 덮개를 닫은 동안 실제로 안 잤는지 확인 |

---

## 덮개 테스트

```bash
./lid-test.sh
```

5초마다 `~/nosleep-test.log` 에 시각·배터리·AC 여부를 한 줄씩 남긴다.

1. 메뉴바에서 잠자기 차단을 켠다 (아이콘이 오렌지 눈 모양)
2. 스크립트를 실행한다
3. 전원 어댑터를 뽑고 덮개를 닫는다
4. 몇 분 뒤 덮개를 연다
5. `Ctrl+C` 로 멈추고 마지막 40줄을 본다

덮개를 닫은 동안 줄이 끊기지 않고 이어졌으면 성공이다.
시각이 뚝 끊겼다가 다시 이어지면 그 구간에 잠든 것이다.

---

## 제거

```bash
./uninstall.sh
```

잠자기 차단 해제 → 앱 종료 → `caffeinate` 및 로그인 LaunchAgent 제거 → 번들 삭제 →
`defaults` 설정값 삭제 → sudoers 항목 삭제 → `visudo -c` 재검증 순으로 돈다.

---

## 확인된 범위

`caffeinate` 실행 여부는 `launchctl print`로, 덮개 차단은 IORegistry의 `SleepDisabled`로
각각 확인한다. `caffeinate -s` assertion은 macOS 자체 동작에 따라 전원 연결 중에만 유효하다.

`pmset disablesleep`은 `pmset(1)` 매뉴얼에 공개된 설정이 아니다. macOS 또는 기기 모델에
따라 덮개 닫힘 동작이 달라질 수 있으므로 실제 기기에서 덮개를 닫은 동안 로그가 계속
기록되는지 확인해야 한다. 로컬 `lid-test.sh`는 CPU가 계속 실행됐는지만 확인하며,
특정 SSH·VPN·원격 제어 연결의 지속 여부까지 검증하지는 않는다.
