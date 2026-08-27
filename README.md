# NoSleepBar

덮개를 닫아도 맥북이 잠들지 않게 하는 macOS 메뉴바 토글.

외부 디스플레이도, 전원 어댑터도 필요 없다. macOS 기본 clamshell 모드와 달리
배터리로만 돌아가는 상태에서도 덮개를 닫은 채 작업을 계속 돌릴 수 있다.

Swift 한 파일(`main.swift`)과 셸 스크립트 몇 개가 전부다. Xcode 프로젝트는 없다.

---

## 동작 원리

`pmset -a disablesleep 1` 이 커널의 `IOPMrootDomain` 속성 `SleepDisabled` 를 켠다.
이 값이 `Yes` 면 덮개를 닫아 clamshell 이벤트가 발생해도 커널이 잠자기를 거부한다.

메뉴바 아이콘과 메뉴는 앱 내부 변수가 아니라 **매번 IORegistry 의 실제 값을 읽어서** 그린다.
터미널에서 `pmset` 을 직접 쳐서 값을 바꿔도 메뉴바가 진실을 보여준다.

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

`build.sh` 는 기존에 떠 있던 NoSleepBar 를 종료하고 번들을 다시 만든다.

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
설치 후 대상 사용자로 실제 무암호 실행이 되는지까지 확인한다.

되돌리기: `sudo rm /etc/sudoers.d/nosleepbar`

---

## 메뉴

| 항목 | 설명 |
|---|---|
| 상태 헤더 | 켜짐/꺼짐, 전원 연결 여부와 배터리 잔량 |
| 켜기 / 끄기 (`⌘T`) | 토글 |
| 자동 해제 | 사용 안 함 / 30분 / 1시간 / 2시간 / 4시간 뒤 자동으로 끈다 |
| 배터리 N% 이하면 자동 해제 | 기본 켜짐 |
| 기준 배터리 | 10 / 15 / 20 / 30 / 50% (기본 20%) |
| 종료할 때 자동 해제 | 기본 켜짐 |
| 로그인할 때 자동 실행 | LaunchAgent 등록/해제 |
| NoSleepBar 종료 (`⌘Q`) | |

아이콘은 꺼졌을 때 `zzz` 템플릿 심볼, 켜졌을 때 오렌지색 `eye.fill` 이다.
켜진 상태는 배터리를 계속 먹으므로 눈에 띄게 만들어 뒀다.

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

잠자기 차단 해제 → 앱 종료 → LaunchAgent 제거 → 번들 삭제 → `defaults` 설정값 삭제 →
sudoers 항목 삭제 → `visudo -c` 재검증 순으로 돈다. 소스는 그대로 남는다.

---

## 확인된 범위

`main.swift` 주석 기준 — M1 / macOS 26.5.2 에서 `SleepDisabled` 값이 0 → 1 로 바뀌고
`ioreg` 에 반영되는 것까지 실측했다.

Intel 맥, 다른 macOS 버전, 장시간 덮개 유지 동작은 확인하지 않았다.
