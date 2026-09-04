// NoSleepBar — 화면 자동 꺼짐과 덮개 닫힘 잠자기를 함께 차단하는 메뉴바 토글
//
// 동작 원리
//   1) 사용자 LaunchAgent 로 /usr/bin/caffeinate -dimsu 를 계속 실행해 화면 및 유휴 잠자기를 막는다.
//   2) pmset -a disablesleep 1/0 으로 IOPMrootDomain 의 SleepDisabled 속성을 켜고 꺼
//      덮개를 닫을 때 발생하는 잠자기를 별도로 막는다.
//
// 두 계층이 모두 실제로 켜져 있을 때만 메뉴바에 "켜짐"으로 표시한다.

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

struct CommandResult {
    let status: Int32
    let output: String
}

@discardableResult
func runCommand(_ executable: String, _ arguments: [String]) -> CommandResult? {
    let task = Process()
    let output = Pipe()
    task.executableURL = URL(fileURLWithPath: executable)
    task.arguments = arguments
    task.standardOutput = output
    task.standardError = output

    do {
        try task.run()
        // 프로세스가 쓰는 동안 함께 읽어 pipe 버퍼가 차서 멈추는 일을 피한다.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return CommandResult(
            status: task.terminationStatus,
            output: String(data: data, encoding: .utf8) ?? ""
        )
    } catch {
        return nil
    }
}

func applySleepDisabledWithoutPrompt(_ want: Bool) -> Bool {
    let arg = want ? "1" : "0"
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
    task.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", arg]
    task.standardOutput = Pipe()
    task.standardError = Pipe()
    if (try? task.run()) != nil {
        task.waitUntilExit()
        return task.terminationStatus == 0 && readSleepDisabled() == want
    }
    return false
}

/// sudoers NOPASSWD 가 깔려 있으면 프롬프트 없이, 아니면 관리자 인증 창으로 폴백한다.
@discardableResult
func applySleepDisabled(_ want: Bool) -> ApplyResult {
    let arg = want ? "1" : "0"

    // 1) 무암호 경로
    if applySleepDisabledWithoutPrompt(want) { return .ok }

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
    static let protectionEnabled = "protectionEnabled"
}

let launchAgentLabel = "kr.co.inxight.nosleepbar"
let caffeinateAgentLabel = "kr.co.inxight.nosleepbar.caffeinate"

struct ProtectionState {
    let screenStateKnown: Bool
    let screenSleepBlocked: Bool
    let lidSleepBlocked: Bool

    var isFullyEnabled: Bool { screenStateKnown && screenSleepBlocked && lidSleepBlocked }
    var isFullyDisabled: Bool { screenStateKnown && !screenSleepBlocked && !lidSleepBlocked }
}

// MARK: - 앱

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    private var autoOffTimer: Timer?
    private var autoOffDeadline: Date?
    private var watchdog: Timer?
    private var lastCaffeinateRecoveryError: String?

    private var defaults: UserDefaults { .standard }

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: [
            Key.batteryGuard: true,
            Key.batteryThreshold: 20,
            Key.releaseOnQuit: true,
        ])

        // 기존 버전에는 이 설정 키가 없었다. 당시 실제 커널 상태를 한 번만 가져와
        // 기존 사용자의 켜짐 상태를 그대로 마이그레이션한다.
        if defaults.object(forKey: Key.protectionEnabled) == nil {
            defaults.set(
                readSleepDisabled() || readProtectionState().screenSleepBlocked,
                forKey: Key.protectionEnabled
            )
        }

        menu.delegate = self
        statusItem.menu = menu

        if defaults.bool(forKey: Key.protectionEnabled) {
            if case .failed(let message) = applyProtection(true) {
                notify(title: "절전 차단을 완전히 켜지 못했습니다", body: message)
            }
        } else if isCaffeinateAgentConfigured() {
            // 비정상 종료 중 남은 helper 가 있으면 저장된 꺼짐 상태에 맞춘다.
            _ = stopCaffeinateAgent()
        }
        refreshIcon()

        // 30초마다 helper 상태 복구 + 배터리 확인 + 아이콘 갱신
        watchdog = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard defaults.bool(forKey: Key.releaseOnQuit) else { return }
        // 종료 시에는 한 계층의 해제가 실패해도 다른 계층까지 반드시 해제를 시도한다.
        if readSleepDisabled() { _ = applySleepDisabled(false) }
        _ = stopCaffeinateAgent()
        if readProtectionState().isFullyDisabled {
            defaults.set(false, forKey: Key.protectionEnabled)
        }
    }

    // MARK: 아이콘

    private func refreshIcon() {
        let state = readProtectionState()
        let name: String
        let description: String
        let color: NSColor?

        if state.isFullyEnabled {
            name = "eye.fill"
            description = "화면 자동 꺼짐 및 덮개 잠자기 차단 켜짐"
            color = .systemOrange
        } else if state.isFullyDisabled {
            name = "zzz"
            description = "화면 자동 꺼짐 및 덮개 잠자기 차단 꺼짐"
            color = nil
        } else {
            name = "exclamationmark.triangle.fill"
            description = "잠자기 차단 일부만 켜짐"
            color = .systemRed
        }

        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
        if let color {
            image?.isTemplate = false
            statusItem.button?.image = image?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(paletteColors: [color])
            )
        } else {
            image?.isTemplate = true
            statusItem.button?.image = image
        }
        statusItem.button?.toolTip = description
    }

    private func tick() {
        defer { refreshIcon() }

        let wanted = defaults.bool(forKey: Key.protectionEnabled)
        let state = readProtectionState()

        // launchd 자체 KeepAlive 에 더해 두 계층의 부분 상태를 비대화식으로 복구한다.
        if wanted {
            if !state.lidSleepBlocked {
                _ = applySleepDisabledWithoutPrompt(true)
            }
            if !state.screenSleepBlocked {
                switch startCaffeinateAgent() {
                case .ok:
                    lastCaffeinateRecoveryError = nil
                case .failed(let message):
                    if lastCaffeinateRecoveryError != message {
                        lastCaffeinateRecoveryError = message
                        notify(title: "화면 자동 꺼짐 차단을 복구하지 못했습니다", body: message)
                    }
                }
            }
        } else {
            if state.lidSleepBlocked {
                _ = applySleepDisabledWithoutPrompt(false)
            }
            if state.screenSleepBlocked || isCaffeinateAgentConfigured() {
                _ = stopCaffeinateAgent()
            }
        }

        guard wanted, defaults.bool(forKey: Key.batteryGuard) else { return }

        let power = readPower()
        let threshold = defaults.integer(forKey: Key.batteryThreshold)
        guard !power.onAC, power.percent >= 0, power.percent <= threshold else { return }

        if turnOff() {
            notify(
                title: "잠자기 차단을 자동 해제했습니다",
                body: "배터리가 \(power.percent)% 로 떨어져 설정한 기준(\(threshold)%) 이하가 되었습니다."
            )
        }
    }

    // MARK: 메뉴

    func menuWillOpen(_ menu: NSMenu) { rebuild() }

    private func rebuild() {
        menu.removeAllItems()

        let state = readProtectionState()
        let wanted = defaults.bool(forKey: Key.protectionEnabled)
        let power = readPower()

        // 상태 헤더
        let stateTitle: String
        if state.isFullyEnabled {
            stateTitle = "잠자기 차단 — 켜짐"
        } else if state.isFullyDisabled {
            stateTitle = "잠자기 차단 — 꺼짐"
        } else {
            stateTitle = "잠자기 차단 — 일부만 켜짐"
        }
        let header = NSMenuItem(title: stateTitle, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        addStatusLine(
            "화면 자동 꺼짐 차단",
            isOn: state.screenSleepBlocked,
            isKnown: state.screenStateKnown
        )
        addStatusLine("덮개 닫힘 잠자기 차단", isOn: state.lidSleepBlocked)

        let powerItem = NSMenuItem(title: "  \(power.label)", action: nil, keyEquivalent: "")
        powerItem.isEnabled = false
        menu.addItem(powerItem)

        if wanted, let deadline = autoOffDeadline {
            let left = max(0, Int(deadline.timeIntervalSinceNow / 60))
            let t = NSMenuItem(title: "  \(left)분 후 자동 해제", action: nil, keyEquivalent: "")
            t.isEnabled = false
            menu.addItem(t)
        }

        menu.addItem(.separator())

        add(wanted ? "끄기" : "켜기", #selector(toggle), key: "t")

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

    private func addStatusLine(_ title: String, isOn: Bool, isKnown: Bool = true) {
        let status = isKnown ? (isOn ? "켜짐" : "꺼짐") : "확인 실패"
        let item = NSMenuItem(
            title: "  \(title) · \(status)",
            action: nil,
            keyEquivalent: ""
        )
        item.isEnabled = false
        menu.addItem(item)
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
        let want = !defaults.bool(forKey: Key.protectionEnabled)
        switch applyProtection(want) {
        case .ok:
            defaults.set(want, forKey: Key.protectionEnabled)
            if !want { clearAutoOff() }
            refreshIcon()
        case .failed(let message):
            refreshIcon()
            notify(title: "절전 차단 설정을 바꾸지 못했습니다", body: message)
        }
    }

    @discardableResult
    private func turnOff() -> Bool {
        switch applyProtection(false) {
        case .ok:
            defaults.set(false, forKey: Key.protectionEnabled)
            clearAutoOff()
            refreshIcon()
            return true
        case .failed(let message):
            refreshIcon()
            notify(title: "잠자기 차단을 해제하지 못했습니다", body: message)
            return false
        }
    }

    @objc private func setAutoOff(_ sender: NSMenuItem) {
        clearAutoOff()
        let minutes = sender.tag
        guard minutes > 0 else { return }

        // 타이머를 걸면 두 절전 차단 기능도 함께 켠다.
        if !defaults.bool(forKey: Key.protectionEnabled) || !readProtectionState().isFullyEnabled {
            switch applyProtection(true) {
            case .ok:
                defaults.set(true, forKey: Key.protectionEnabled)
            case .failed(let message):
                notify(title: "설정을 바꾸지 못했습니다", body: "잠자기 차단을 켜지 못했습니다. \(message)")
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

    // MARK: 화면 자동 꺼짐·덮개 절전 차단

    private var caffeinateAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(caffeinateAgentLabel).plist")
    }

    private var caffeinateServiceTarget: String {
        "gui/\(getuid())/\(caffeinateAgentLabel)"
    }

    private struct CaffeinateAgentStatus {
        let isKnown: Bool
        let loaded: Bool
        let running: Bool
        let commandMatches: Bool
        let error: String
    }

    private func caffeinateAgentStatus() -> CaffeinateAgentStatus {
        guard let result = runCommand("/bin/launchctl", ["print", caffeinateServiceTarget]) else {
            return CaffeinateAgentStatus(
                isKnown: false,
                loaded: false,
                running: false,
                commandMatches: false,
                error: "launchctl 을 실행하지 못했습니다."
            )
        }

        if result.status == 0 {
            return CaffeinateAgentStatus(
                isKnown: true,
                loaded: true,
                running: result.output.contains("state = running"),
                commandMatches: result.output.contains("/usr/bin/caffeinate")
                    && result.output.contains("-dimsu"),
                error: ""
            )
        }

        let notFound = result.output.contains("Could not find service")
        return CaffeinateAgentStatus(
            isKnown: notFound,
            loaded: false,
            running: false,
            commandMatches: false,
            error: result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func isCaffeinateAgentConfigured() -> Bool {
        if FileManager.default.fileExists(atPath: caffeinateAgentURL.path) { return true }
        let status = caffeinateAgentStatus()
        return status.isKnown && status.loaded
    }

    private func readProtectionState() -> ProtectionState {
        let status = caffeinateAgentStatus()
        return ProtectionState(
            screenStateKnown: status.isKnown,
            screenSleepBlocked: status.running && status.commandMatches,
            lidSleepBlocked: readSleepDisabled()
        )
    }

    private func commandError(_ result: CommandResult?, fallback: String) -> String {
        guard let result else { return fallback }
        let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? fallback : message
    }

    /// 앱이 종료되어도 설정을 유지할 수 있도록 caffeinate 를 별도 사용자 LaunchAgent 로 관리한다.
    private func startCaffeinateAgent() -> ApplyResult {
        let fm = FileManager.default
        let url = caffeinateAgentURL
        let plist: [String: Any] = [
            "Label": caffeinateAgentLabel,
            "ProgramArguments": ["/usr/bin/caffeinate", "-dimsu"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 3,
            "StandardOutPath": "/dev/null",
            "StandardErrorPath": "/dev/null",
        ]

        let initialStatus = caffeinateAgentStatus()
        guard initialStatus.isKnown else {
            return .failed(initialStatus.error.isEmpty
                ? "caffeinate 상태를 확인하지 못했습니다."
                : initialStatus.error)
        }

        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist,
                format: .xml,
                options: 0
            )
            try data.write(to: url, options: .atomic)
        } catch {
            return .failed("caffeinate 실행 설정을 저장하지 못했습니다: \(error.localizedDescription)")
        }

        var status = caffeinateAgentStatus()
        if status.loaded, !status.commandMatches {
            let result = runCommand("/bin/launchctl", ["bootout", caffeinateServiceTarget])
            guard result?.status == 0 else {
                return .failed(commandError(result, fallback: "기존 caffeinate 설정을 교체하지 못했습니다."))
            }
            status = caffeinateAgentStatus()
            guard status.isKnown, !status.loaded else {
                return .failed("기존 caffeinate 설정이 종료됐는지 확인하지 못했습니다.")
            }
        }

        if !status.running {
            let result: CommandResult?
            if status.loaded {
                result = runCommand("/bin/launchctl", ["kickstart", "-k", caffeinateServiceTarget])
            } else {
                result = runCommand(
                    "/bin/launchctl",
                    ["bootstrap", "gui/\(getuid())", url.path]
                )
            }

            guard result?.status == 0 else {
                let message = commandError(result, fallback: "caffeinate 를 시작하지 못했습니다.")
                _ = stopCaffeinateAgent()
                return .failed(message)
            }

            // launchctl 명령 직후 실제 프로세스가 running 상태가 될 때까지 짧게 확인한다.
            for _ in 0..<10 {
                status = caffeinateAgentStatus()
                if status.running, status.commandMatches { return .ok }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }

        if status.running, status.commandMatches { return .ok }
        _ = stopCaffeinateAgent()
        return .failed("caffeinate 실행 요청은 성공했지만 프로세스가 시작되지 않았습니다.")
    }

    private func stopCaffeinateAgent() -> ApplyResult {
        let fm = FileManager.default
        let url = caffeinateAgentURL
        let status = caffeinateAgentStatus()

        guard status.isKnown else {
            return .failed(status.error.isEmpty
                ? "caffeinate 상태를 확인하지 못했습니다."
                : status.error)
        }

        if status.loaded {
            let result = runCommand("/bin/launchctl", ["bootout", caffeinateServiceTarget])
            let afterBootout = caffeinateAgentStatus()
            guard afterBootout.isKnown else {
                return .failed(afterBootout.error.isEmpty
                    ? "caffeinate 종료 상태를 확인하지 못했습니다."
                    : afterBootout.error)
            }
            if result?.status != 0, afterBootout.loaded {
                return .failed(commandError(result, fallback: "caffeinate 를 종료하지 못했습니다."))
            }
            if afterBootout.loaded {
                return .failed("caffeinate 서비스가 종료되지 않았습니다.")
            }
        }

        if fm.fileExists(atPath: url.path) {
            do {
                try fm.removeItem(at: url)
            } catch {
                return .failed("caffeinate 실행 설정을 지우지 못했습니다: \(error.localizedDescription)")
            }
        }

        let finalStatus = caffeinateAgentStatus()
        guard finalStatus.isKnown else {
            return .failed(finalStatus.error.isEmpty
                ? "caffeinate 종료 상태를 확인하지 못했습니다."
                : finalStatus.error)
        }
        return finalStatus.loaded
            ? .failed("caffeinate 서비스가 종료되지 않았습니다.")
            : .ok
    }

    private func failureMessage(_ primary: String, rollback: String?) -> String {
        guard let rollback else { return primary }
        return "\(primary) 이전 상태 복구도 완료하지 못했습니다: \(rollback)"
    }

    /// 적용 중 실패했을 때 변경 전의 두 상태로 되돌린다.
    private func restoreProtectionState(_ original: ProtectionState) -> String? {
        var errors: [String] = []
        let current = readProtectionState()

        if current.screenSleepBlocked != original.screenSleepBlocked {
            let result = original.screenSleepBlocked
                ? startCaffeinateAgent()
                : stopCaffeinateAgent()
            if case .failed(let message) = result { errors.append(message) }
        } else if !original.screenSleepBlocked, isCaffeinateAgentConfigured() {
            if case .failed(let message) = stopCaffeinateAgent() { errors.append(message) }
        }

        if readSleepDisabled() != original.lidSleepBlocked {
            if case .failed(let message) = applySleepDisabled(original.lidSleepBlocked) {
                errors.append(message)
            }
        }

        let restored = readProtectionState()
        if !restored.screenStateKnown
            || restored.screenSleepBlocked != original.screenSleepBlocked
            || restored.lidSleepBlocked != original.lidSleepBlocked {
            errors.append("실제 절전 차단 상태가 변경 전 값과 다릅니다.")
        }
        return errors.isEmpty ? nil : errors.joined(separator: " ")
    }

    /// 화면 자동 꺼짐 차단과 덮개 닫힘 차단을 함께 적용한다.
    private func applyProtection(_ want: Bool) -> ApplyResult {
        let original = readProtectionState()
        guard original.screenStateKnown else {
            return .failed("현재 caffeinate 상태를 확인하지 못해 설정을 바꾸지 않았습니다.")
        }

        if want {
            if !original.lidSleepBlocked {
                switch applySleepDisabled(true) {
                case .ok:
                    break
                case .failed(let message):
                    return .failed(failureMessage(message, rollback: restoreProtectionState(original)))
                }
            }

            switch startCaffeinateAgent() {
            case .ok:
                if readProtectionState().isFullyEnabled { return .ok }
                let message = "두 절전 차단 상태를 모두 확인하지 못했습니다."
                return .failed(failureMessage(message, rollback: restoreProtectionState(original)))
            case .failed(let message):
                return .failed(failureMessage(message, rollback: restoreProtectionState(original)))
            }
        }

        if original.lidSleepBlocked {
            switch applySleepDisabled(false) {
            case .ok:
                break
            case .failed(let message):
                return .failed(failureMessage(message, rollback: restoreProtectionState(original)))
            }
        }

        switch stopCaffeinateAgent() {
        case .ok:
            if readProtectionState().isFullyDisabled { return .ok }
            let message = "두 절전 차단 상태가 모두 해제됐는지 확인하지 못했습니다."
            return .failed(failureMessage(message, rollback: restoreProtectionState(original)))
        case .failed(let message):
            return .failed(failureMessage(message, rollback: restoreProtectionState(original)))
        }
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
