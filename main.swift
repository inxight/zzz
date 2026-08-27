// NoSleepBar — 덮개를 닫아도 맥북이 잠들지 않게 하는 메뉴바 토글
//
// 동작 원리
//   pmset -a disablesleep 1/0 이 IOPMrootDomain 의 SleepDisabled 속성을 켜고 끈다.
//   이 값이 Yes 이면 덮개를 닫아 clamshell 이벤트가 발생해도 커널이 잠자기를 거부한다.
//   macOS 기본 clamshell 모드와 달리 외부 디스플레이도 전원 어댑터도 필요 없다.
//
//   (M1 / macOS 26.5.2 에서 실측 확인: SleepDisabled 0 → 1, ioreg 반영됨)
//
// 상태 표시는 앱 내부 변수가 아니라 매번 IORegistry 의 실제 값을 읽어서 그린다.
// 터미널 등 다른 경로로 값이 바뀌어도 메뉴바가 진실을 보여주게 하기 위해서다.

import Cocoa
import IOKit
import IOKit.ps

// MARK: - 커널 상태 읽기

/// IOPMrootDomain 의 SleepDisabled 실제 값
func readSleepDisabled() -> Bool {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard service != 0 else { return false }
    defer { IOObjectRelease(service) }
    guard let raw = IORegistryEntryCreateCFProperty(
        service, "SleepDisabled" as CFString, kCFAllocatorDefault, 0
    )?.takeRetainedValue() else { return false }
    return (raw as? Bool) ?? false
}

struct PowerState {
    var percent: Int   // -1 이면 읽기 실패
    var onAC: Bool

    var label: String {
        let source = onAC ? "전원 연결" : "배터리"
        return percent >= 0 ? "\(source) · \(percent)%" : source
    }
}

func readPower() -> PowerState {
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
    else { return PowerState(percent: -1, onAC: true) }

    for src in sources {
        guard let desc = IOPSGetPowerSourceDescription(blob, src)?.takeUnretainedValue()
                as? [String: Any] else { continue }
        let cur = desc[kIOPSCurrentCapacityKey as String] as? Int ?? -1
        let max = desc[kIOPSMaxCapacityKey as String] as? Int ?? 100
        let state = desc[kIOPSPowerSourceStateKey as String] as? String ?? ""
        let pct = (cur >= 0 && max > 0) ? Int((Double(cur) / Double(max) * 100).rounded()) : -1
        return PowerState(percent: pct, onAC: state == (kIOPSACPowerValue as String))
    }
    return PowerState(percent: -1, onAC: true)
}

// MARK: - 설정 적용

enum ApplyResult {
    case ok
    case failed(String)
}

/// sudoers NOPASSWD 가 깔려 있으면 프롬프트 없이, 아니면 관리자 인증 창으로 폴백한다.
@discardableResult
func applySleepDisabled(_ want: Bool) -> ApplyResult {
    let arg = want ? "1" : "0"

    // 1) 무암호 경로
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
    task.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", arg]
    task.standardOutput = Pipe()
    task.standardError = Pipe()
    if (try? task.run()) != nil {
        task.waitUntilExit()
        if task.terminationStatus == 0, readSleepDisabled() == want { return .ok }
    }

    // 2) 관리자 인증 폴백
    var errorInfo: NSDictionary?
    let source = "do shell script \"/usr/bin/pmset -a disablesleep \(arg)\" with administrator privileges"
    NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
    if let e = errorInfo {
        let code = e[NSAppleScript.errorNumber] as? Int ?? 0
        if code == -128 { return .failed("인증이 취소되었습니다.") }
        return .failed(e[NSAppleScript.errorMessage] as? String ?? "알 수 없는 오류가 났습니다.")
    }

    return readSleepDisabled() == want
        ? .ok
        : .failed("명령은 실행됐지만 SleepDisabled 값이 반영되지 않았습니다.")
}

// MARK: - 설정 저장

enum Key {
    static let batteryGuard = "batteryGuard"
    static let batteryThreshold = "batteryThreshold"
    static let releaseOnQuit = "releaseOnQuit"
}

let launchAgentLabel = "kr.co.inxight.nosleepbar"

// MARK: - 앱

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    private var autoOffTimer: Timer?
    private var autoOffDeadline: Date?
    private var watchdog: Timer?

    private var defaults: UserDefaults { .standard }

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: [
            Key.batteryGuard: true,
            Key.batteryThreshold: 20,
            Key.releaseOnQuit: true,
        ])

        menu.delegate = self
        statusItem.menu = menu
        refreshIcon()

        // 30초마다 배터리 확인 + 아이콘 갱신(외부 변경 반영)
        watchdog = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard defaults.bool(forKey: Key.releaseOnQuit), readSleepDisabled() else { return }
        applySleepDisabled(false)
    }

    // MARK: 아이콘

    private func refreshIcon() {
        let on = readSleepDisabled()
        let name = on ? "eye.fill" : "zzz"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: on ? "잠자기 차단 켜짐" : "잠자기 차단 꺼짐")

        if on {
            // 켜진 상태는 배터리를 계속 먹으므로 눈에 띄어야 한다
            image?.isTemplate = false
            statusItem.button?.image = image?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(paletteColors: [.systemOrange])
            )
        } else {
            image?.isTemplate = true
            statusItem.button?.image = image
        }
        statusItem.button?.toolTip = on
            ? "잠자기 차단 켜짐 — 덮개를 닫아도 계속 돌아갑니다"
            : "잠자기 차단 꺼짐"
    }

    private func tick() {
        defer { refreshIcon() }
        guard readSleepDisabled(), defaults.bool(forKey: Key.batteryGuard) else { return }

        let power = readPower()
        let threshold = defaults.integer(forKey: Key.batteryThreshold)
        guard !power.onAC, power.percent >= 0, power.percent <= threshold else { return }

        turnOff()
        notify(
            title: "잠자기 차단을 자동 해제했습니다",
            body: "배터리가 \(power.percent)% 로 떨어져 설정한 기준(\(threshold)%) 이하가 되었습니다."
        )
    }

    // MARK: 메뉴

    func menuWillOpen(_ menu: NSMenu) { rebuild() }

    private func rebuild() {
        menu.removeAllItems()

        let on = readSleepDisabled()
        let power = readPower()

        // 상태 헤더
        let header = NSMenuItem(title: on ? "잠자기 차단 — 켜짐" : "잠자기 차단 — 꺼짐", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let sub = NSMenuItem(title: "  \(power.label)", action: nil, keyEquivalent: "")
        sub.isEnabled = false
        menu.addItem(sub)

        if on, let deadline = autoOffDeadline {
            let left = max(0, Int(deadline.timeIntervalSinceNow / 60))
            let t = NSMenuItem(title: "  \(left)분 후 자동 해제", action: nil, keyEquivalent: "")
            t.isEnabled = false
            menu.addItem(t)
        }

        menu.addItem(.separator())

        add(on ? "끄기" : "켜기", #selector(toggle), key: "t")

        menu.addItem(.separator())

        // 자동 해제 타이머
        let timerItem = NSMenuItem(title: "자동 해제", action: nil, keyEquivalent: "")
        let timerMenu = NSMenu()
        for (label, minutes) in [("사용 안 함", 0), ("30분 후", 30), ("1시간 후", 60), ("2시간 후", 120), ("4시간 후", 240)] {
            let mi = NSMenuItem(title: label, action: #selector(setAutoOff(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = minutes
            let currentIsNone = (autoOffDeadline == nil)
            mi.state = (minutes == 0 && currentIsNone) ? .on : .off
            timerMenu.addItem(mi)
        }
        timerItem.submenu = timerMenu
        menu.addItem(timerItem)

        // 배터리 보호
        let guardItem = NSMenuItem(
            title: "배터리 \(defaults.integer(forKey: Key.batteryThreshold))% 이하면 자동 해제",
            action: #selector(toggleBatteryGuard), keyEquivalent: ""
        )
        guardItem.target = self
        guardItem.state = defaults.bool(forKey: Key.batteryGuard) ? .on : .off
        menu.addItem(guardItem)

        let thresholdItem = NSMenuItem(title: "기준 배터리", action: nil, keyEquivalent: "")
        let thresholdMenu = NSMenu()
        for pct in [10, 15, 20, 30, 50] {
            let mi = NSMenuItem(title: "\(pct)%", action: #selector(setThreshold(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = pct
            mi.state = (pct == defaults.integer(forKey: Key.batteryThreshold)) ? .on : .off
            thresholdMenu.addItem(mi)
        }
        thresholdItem.submenu = thresholdMenu
        menu.addItem(thresholdItem)

        menu.addItem(.separator())

        let quitRelease = add("종료할 때 자동 해제", #selector(toggleReleaseOnQuit))
        quitRelease.state = defaults.bool(forKey: Key.releaseOnQuit) ? .on : .off

        let login = add("로그인할 때 자동 실행", #selector(toggleLoginItem))
        login.state = isLoginItemEnabled() ? .on : .off

        menu.addItem(.separator())
        add("NoSleepBar 종료", #selector(quit), key: "q")
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    // MARK: 동작

    @objc private func toggle() {
        let want = !readSleepDisabled()
        switch applySleepDisabled(want) {
        case .ok:
            if !want { clearAutoOff() }
            refreshIcon()
        case .failed(let message):
            refreshIcon()
            notify(title: "설정을 바꾸지 못했습니다", body: message)
        }
    }

    private func turnOff() {
        if case .ok = applySleepDisabled(false) { clearAutoOff() }
        refreshIcon()
    }

    @objc private func setAutoOff(_ sender: NSMenuItem) {
        clearAutoOff()
        let minutes = sender.tag
        guard minutes > 0 else { return }

        // 타이머를 걸면 잠자기 차단도 함께 켠다
        if !readSleepDisabled() {
            guard case .ok = applySleepDisabled(true) else {
                notify(title: "설정을 바꾸지 못했습니다", body: "잠자기 차단을 켜지 못해 타이머를 걸지 않았습니다.")
                refreshIcon()
                return
            }
        }

        let deadline = Date().addingTimeInterval(TimeInterval(minutes * 60))
        autoOffDeadline = deadline
        autoOffTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
            self?.turnOff()
        }
        refreshIcon()
    }

    private func clearAutoOff() {
        autoOffTimer?.invalidate()
        autoOffTimer = nil
        autoOffDeadline = nil
    }

    @objc private func toggleBatteryGuard() {
        defaults.set(!defaults.bool(forKey: Key.batteryGuard), forKey: Key.batteryGuard)
    }

    @objc private func setThreshold(_ sender: NSMenuItem) {
        defaults.set(sender.tag, forKey: Key.batteryThreshold)
    }

    @objc private func toggleReleaseOnQuit() {
        defaults.set(!defaults.bool(forKey: Key.releaseOnQuit), forKey: Key.releaseOnQuit)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: 로그인 항목 (LaunchAgent)

    private var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
    }

    private func isLoginItemEnabled() -> Bool {
        FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    @objc private func toggleLoginItem() {
        let fm = FileManager.default
        let url = launchAgentURL

        if isLoginItemEnabled() {
            launchctl(["bootout", "gui/\(getuid())/\(launchAgentLabel)"])
            try? fm.removeItem(at: url)
            return
        }

        let plist: [String: Any] = [
            "Label": launchAgentLabel,
            "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath],
            "RunAtLoad": true,
        ]
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
              (try? data.write(to: url)) != nil else {
            notify(title: "자동 실행을 켜지 못했습니다", body: "LaunchAgent 파일을 쓰지 못했습니다.")
            return
        }
        launchctl(["bootstrap", "gui/\(getuid())", url.path])
    }

    private func launchctl(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
    }

    // MARK: 알림

    private func notify(title: String, body: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .warning
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }
}

// MARK: - 진입점

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // Dock 아이콘 없음
app.run()
