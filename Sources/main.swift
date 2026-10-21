import Cocoa
import SwiftUI
import Vision

final class SleepControl: ObservableObject {
    @Published var enabled = false
    @Published var busy = false
    @Published var message = "状態を確認しています…"
    @Published var available = false
    var onChange: (() -> Void)?

    func refresh() {
        guard !busy else { return }
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
        message = "macOSの認証を待っています…"
        DispatchQueue.global(qos: .userInitiated).async {
            // Only a fixed command and a boolean are passed to the privileged shell.
            let script = NSAppleScript(source: "do shell script \"/usr/bin/pmset -a disablesleep \(value ? 1 : 0)\" with administrator privileges")
            var error: NSDictionary?
            script?.executeAndReturnError(&error)
            let failure = error?[NSAppleScript.errorNumber] as? Int
            let detail = error?[NSAppleScript.errorMessage] as? String
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
}

struct Panel: View {
    @ObservedObject var control: SleepControl
    @ObservedObject var notifier: BatteryNotifier
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                Image(systemName: control.enabled ? "sun.max.fill" : "moon.zzz.fill")
                    .font(.system(size: 32)).foregroundStyle(control.enabled ? .orange : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("スリープしない君").font(.title2.bold())
                    Text("Macを、閉じたまま。 ").foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("スリープ防止").font(.headline)
                    Text(control.enabled ? "オン · 起動を維持" : "オフ · 通常のスリープ").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("スリープ防止", isOn: Binding(get: { control.enabled }, set: { control.setEnabled($0) }))
                    .labelsHidden().toggleStyle(.switch).disabled(control.busy || !control.available)
            }
            Text(control.message).font(.callout).fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 38, alignment: .topLeading)
            Divider()
            BatteryPanel(notifier: notifier)
            Divider()
            Text("オンの間は、バッテリー使用中もシステム全体のスリープを無効にします。通気のよい場所で使用し、バッグに入れる前にはオフにしてください。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("設定変更には管理者認証が必要です").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("終了") { NSApp.terminate(nil) }.disabled(control.busy)
            }
        }.padding(24)
        }.frame(width: 420, height: 650)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let control = SleepControl()
    lazy var notifier = BatteryNotifier()
    var item: NSStatusItem!
    let popover = NSPopover()
    var timer: Timer?
    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(show)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: Panel(control: control, notifier: notifier))
        control.onChange = { [weak self] in
            guard let self else { return }
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
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.control.refresh() }
        show()
    }
    @objc func show() {
        guard let button = item.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            control.refresh()
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
