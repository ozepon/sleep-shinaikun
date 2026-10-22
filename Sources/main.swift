import Cocoa
import SwiftUI
import Vision

final class SleepControl: ObservableObject {
    @Published var enabled = false
    @Published var busy = false
    @Published var message = "状態を確認しています…"
    @Published var available = false
    @Published var limitedPermission = LimitedPermission.isInstalled()
    var onChange: (() -> Void)?

    func refresh() {
        guard !busy else { return }
        limitedPermission = LimitedPermission.isInstalled()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self)
            let parts = output.components(separatedBy: .newlines).first { $0.contains("SleepDisabled") }?.split(whereSeparator: { $0.isWhitespace })
            guard process.terminationStatus == 0, let value = parts?.last, value == "0" || value == "1" else {
                available = false
                message = "このMacのスリープ設定を取得できませんでした。"
                onChange?()
                return
            }
            available = true
            enabled = value == "1"
            message = enabled ? "ふたを閉じても、Macを起動したままにします。" : "ふたを閉じると、通常どおりスリープします。"
            onChange?()
        } catch {
            available = false
            message = error.localizedDescription
        }
    }

    func setEnabled(_ value: Bool, completion: ((Bool) -> Void)? = nil) {
        guard !busy else { return }
        busy = true
        message = limitedPermission ? "スリープ設定を変更しています…" : "macOSの認証を待っています…"
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: Int?
            var detail: String?
            if LimitedPermission.isInstalled() {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
                process.arguments = LimitedPermission.arguments(enabled: value)
                process.standardInput = FileHandle.nullDevice
                let pipe = Pipe()
                process.standardError = pipe
                do {
                    try process.run()
                    _ = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    if process.terminationStatus != 0 {
                        failure = Int(process.terminationStatus)
                        detail = "限定許可が使えません。認証省略の設定を解除するか、管理者に設定を確認してください。"
                    }
                } catch { failure = -1; detail = error.localizedDescription }
            } else {
                let script = NSAppleScript(source: "do shell script \"/usr/bin/pmset -a disablesleep \(value ? 1 : 0)\" with administrator privileges")
                var error: NSDictionary?
                if script == nil { failure = -1; detail = "認証処理を作成できません" }
                else {
                    script?.executeAndReturnError(&error)
                    failure = error?[NSAppleScript.errorNumber] as? Int
                    detail = error?[NSAppleScript.errorMessage] as? String
                }
            }
            DispatchQueue.main.async {
                self.busy = false
                self.refresh()
                if let failure {
                    self.message = failure == -128 ? "変更をキャンセルしました。" : "設定を変更できませんでした：\(detail ?? String(failure))"
                }
                completion?(failure == nil && self.available && self.enabled == value)
            }
        }
    }
    func configureLimitedPermission(remove: Bool) {
        guard !busy, let shell = LimitedPermission.script(uid: getuid(), remove: remove) else { return }
        let alert = NSAlert()
        alert.messageText = remove ? "認証の省略を解除しますか？" : "スリープ切替だけ、認証を省略しますか？"
        alert.informativeText = remove
            ? "このユーザー用に追加した限定許可を削除します。解除にも管理者認証が必要です。スリープ防止がオンなら、先にオフにしてください。"
            : "このMacの現在のユーザーに、pmsetのスリープ切替（0と1）だけを許可します。同じユーザーで動く他のアプリもこの2操作を実行できるようになります。任意の管理者コマンドや他の電源設定は許可しません。アプリを削除する前にここから解除してください。"
        alert.addButton(withTitle: remove ? "認証して解除" : "認証して有効にする")
        alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard !remove || !enabled else { message = "先にスリープ防止をオフにしてから解除してください。"; return }
        busy = true
        message = "限定許可の変更には、今回だけ管理者認証が必要です…"
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            let script = NSAppleScript(source: LimitedPermission.appleScript(shell))
            if script != nil { script?.executeAndReturnError(&error) }
            DispatchQueue.main.async {
                self.busy = false
                self.refresh()
                if script == nil || error != nil {
                    self.message = "限定許可を変更できませんでした。キャンセル、またはMacの管理設定をご確認ください。"
                } else if self.limitedPermission == !remove {
                    self.message = remove ? "限定許可を解除しました。次回から通常の管理者認証を使います。" : "スリープ切替だけ認証を省略します。"
                } else { self.message = "設定を確認できません。通常の認証を使ってください。" }
            }
        }
    }

}

struct Panel: View {
    @ObservedObject var control: SleepControl
    @ObservedObject var notifier: BatteryNotifier
    @ObservedObject var remote: RemoteControl
    var panelHeight: CGFloat = 560
    private let ink = Color(red: 0.15, green: 0.22, blue: 0.17)
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png"), let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().scaledToFit().frame(width: 76, height: 70)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("スリープしない君").font(.system(size: 20, weight: .bold, design: .rounded))
                    Text(control.enabled ? "起きてるよ。まかせてね。" : "おやすみの準備、できてるよ。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 18).padding(.vertical, 10)
                .background(Color(red: 0.90, green: 0.94, blue: 0.77))
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("スリープ防止").font(.headline)
                                Text(control.enabled ? "オン · ふたを閉じても起動を維持" : "オフ · いつもどおりスリープ")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Toggle("スリープ防止", isOn: Binding(get: { control.enabled }, set: { control.setEnabled($0) }))
                                .labelsHidden().toggleStyle(.switch).disabled(control.busy || !control.available)
                        }
                        Text(control.message).font(.caption).fixedSize(horizontal: false, vertical: true)
                        Divider()
                        Label(control.limitedPermission ? "このユーザーのスリープ切替は認証省略中" : "切り替えごとに管理者認証", systemImage: "lock.shield")
                            .font(.caption).fixedSize(horizontal: false, vertical: true)
                        Button(control.limitedPermission ? "認証省略を解除…" : "切替の認証を省略する…") {
                            control.configureLimitedPermission(remove: control.limitedPermission)
                        }.font(.caption).disabled(control.busy)
                        Text("初回設定・解除には管理者認証が必要です。同じユーザーの他アプリにもスリープ切替だけを許可します。")
                            .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(16).background(.white, in: RoundedRectangle(cornerRadius: 18))
                    VStack(alignment: .leading, spacing: 12) {
                        Label("iPhoneにお知らせ", systemImage: "iphone.radiowaves.left.and.right")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                        BatteryPanel(notifier: notifier)
                    }.padding(16).background(.white, in: RoundedRectangle(cornerRadius: 18))
                    RemotePanel(remote: remote).padding(16).background(.white, in: RoundedRectangle(cornerRadius: 18))
                    Label {
                        Text("オンの間はMac全体のスリープを止めます。通気のよい場所で使い、バッグにしまう前にはオフにしてください。")
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: { Image(systemName: "leaf") }
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4)
                }.padding(14)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Text(control.limitedPermission ? "限定許可：スリープの切替のみ" : "設定変更には管理者認証が必要です").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Button("終了") { NSApp.terminate(nil) }.disabled(control.busy)
            }.padding(.horizontal, 18).padding(.vertical, 10).background(.white.opacity(0.8))
        }.frame(width: 390, height: panelHeight)
            .background(Color(red: 0.97, green: 0.96, blue: 0.92))
            .foregroundStyle(ink).tint(ink).preferredColorScheme(.light)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let control = SleepControl()
    let lidMonitor = LidMonitor()
    let remote = RemoteControl()
    lazy var notifier = BatteryNotifier()
    var item: NSStatusItem!
    let popover = NSPopover()
    var timer: Timer?
    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(show)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: Panel(control: control, notifier: notifier, remote: remote))
        control.onChange = { [weak self] in
            guard let self else { return }
            if !self.control.enabled { _ = self.lidMonitor.poll(enabled: false) }
            if let url = Bundle.main.url(forResource: "MenuIcon", withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                image.size = NSSize(width: 22, height: 22)
                image.isTemplate = false
                image.accessibilityDescription = "スリープしない君"
                self.item.button?.image = image
            } else {
                self.item.button?.image = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: "スリープしない君")
            }
            self.item.button?.title = (self.notifier.enabled && self.notifier.confirmationRequired ? " ⚠︎" : "") + (self.control.enabled ? " ON" : "")
            self.item.button?.toolTip = "スリープしない君：スリープ防止 \(self.control.enabled ? "オン" : "オフ")"
        }
        notifier.onAttentionChange = { [weak self] in self?.control.onChange?() }
        control.refresh()
        _ = lidMonitor.poll(enabled: control.available && control.enabled)
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in guard let self else { return }
            self.control.refresh()
            self.remote.poll(control: self.control)
            if self.lidMonitor.poll(enabled: self.control.available && self.control.enabled) {
                self.notifier.notifyLidClosed()
                if self.remote.enabled { self.remote.notify("lid") }
            }
        }
        show()
    }
    @objc func show() {
        guard let button = item.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            control.refresh()
            let screenHeight = button.window?.screen?.visibleFrame.height ?? 700
            let height = min(560, max(240, screenHeight - 80))
            popover.contentViewController = NSHostingController(rootView: Panel(control: control, notifier: notifier, remote: remote, panelHeight: height))
            popover.contentSize = NSSize(width: 390, height: height)
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if control.busy { return .terminateCancel }
        control.refresh()
        guard control.enabled else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "スリープ防止をオフにして終了しますか？"
        alert.informativeText = "オンのまま終了すると、スリープ防止の設定が残ります。"
        alert.addButton(withTitle: "オフにして終了")
        alert.addButton(withTitle: "キャンセル")
        alert.addButton(withTitle: "オンのまま終了")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            control.setEnabled(false) { success in NSApp.reply(toApplicationShouldTerminate: success) }
            return .terminateLater
        case .alertThirdButtonReturn: return .terminateNow
        default: return .terminateCancel
        }
    }
}

if CommandLine.arguments.contains("--check") {
    let control = SleepControl()
    control.refresh()
    print("SleepDisabled=\(control.enabled ? 1 : 0); readable=\(control.available)")
    exit(control.available ? 0 : 1)
}
if CommandLine.arguments.contains("--self-test") {
    precondition(!BatteryPolicy.shouldNotify(percent: 10, onBattery: true, alreadySent: false))
    precondition(BatteryPolicy.shouldNotify(percent: 9, onBattery: true, alreadySent: false))
    precondition(!BatteryPolicy.shouldNotify(percent: 9, onBattery: false, alreadySent: false))
    precondition(!BatteryPolicy.shouldNotify(percent: 9, onBattery: true, alreadySent: true))
    precondition(!BatteryPolicy.rearmed(percent: 14))
    precondition(BatteryPolicy.rearmed(percent: 15))
    print("Battery policy: 6 checks passed")
    exit(0)
}
if CommandLine.arguments.contains("--battery-check") {
    if let reading = BatteryNotifier.battery() {
        print("Battery=\(reading.percent)%; onBattery=\(reading.onBattery)")
    } else { print("No battery information") }
    exit(0)
}
if CommandLine.arguments.contains("--qr-self-test") {
    let value = PhoneSetup.url(topic: "sleep-qr-validation-only")!
    guard let image = PhoneSetup.qr(value), let data = image.tiffRepresentation else { fatalError("QR generation failed") }
    let request = VNDetectBarcodesRequest()
    try VNImageRequestHandler(data: data).perform([request])
    guard request.results?.first?.payloadStringValue == value else { fatalError("QR payload mismatch") }
    print("QR generation and independent Vision decoding: passed")
    exit(0)
}
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
