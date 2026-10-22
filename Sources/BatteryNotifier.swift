import Cocoa
import SwiftUI
import IOKit.ps

struct BatteryReading {
    let percent: Int
    let onBattery: Bool
}

struct BatteryPolicy {
    static func shouldNotify(percent: Int, onBattery: Bool, alreadySent: Bool) -> Bool {
        percent >= 0 && percent < 10 && onBattery && !alreadySent
    }
    static func rearmed(percent: Int) -> Bool { percent >= 15 }
}

final class BatteryNotifier: ObservableObject {
    private let defaults = UserDefaults.standard
    @Published var enabled: Bool { didSet {
        defaults.set(enabled, forKey: "phoneAlerts")
        if enabled { poll() } else { awaitingConfirmation = false; generation = UUID(); task?.cancel(); task = nil; sending = false; status = "通知はオフです"; updateAttention() }
    } }
    @Published var topic: String { didSet {
        defaults.set(topic, forKey: "ntfyTopic")
        confirmedAt = nil
        defaults.removeObject(forKey: "phoneConfirmedAt")
        awaitingConfirmation = false
        generation = UUID(); task?.cancel(); task = nil; sending = false
    } }
    @Published var confirmedAt: Date?
    @Published var awaitingConfirmation = false
    @Published var confirmationRequired = true
    var onAttentionChange: (() -> Void)?
    var confirmationValid: Bool { ConfirmationPolicy.valid(confirmedAt: confirmedAt) }
    var expiryText: String {
        guard let date = confirmedAt else { return "初回の受信確認が必要です" }
        return "通知の有効期限：" + date.addingTimeInterval(ConfirmationPolicy.lifetime).formatted(date: .abbreviated, time: .shortened)
    }
    func confirmReceipt() {
        guard awaitingConfirmation, enabled else { return }
        confirmedAt = Date()
        defaults.set(confirmedAt, forKey: "phoneConfirmedAt")
        awaitingConfirmation = false
        confirmationRequired = false
        status = "受信確認済み · 7日間有効"
        onAttentionChange?()
        poll()
    }
    func updateAttention() {
        let required = enabled && !confirmationValid
        if confirmationRequired != required {
            confirmationRequired = required
            onAttentionChange?()
        }
    }
    @Published var status = "通知はオフです"
    @Published var percent: Int?
    @Published var sending = false
    private var timer: Timer?
    private let sessionDelegate = NotificationSession()
    private lazy var session = sessionDelegate.makeSession()
    private var task: URLSessionDataTask?
    private var retryAt = Date.distantPast
    private var failures = 0
    private var generation = UUID()
    private var alreadySent: Bool {
        get { defaults.bool(forKey: "lowBatterySent") }
        set { defaults.set(newValue, forKey: "lowBatterySent") }
    }
    init() {
        enabled = defaults.bool(forKey: "phoneAlerts")
        topic = defaults.string(forKey: "ntfyTopic") ?? "sleep-" + UUID().uuidString.lowercased()
        confirmedAt = defaults.object(forKey: "phoneConfirmedAt") as? Date
        defaults.set(topic, forKey: "ntfyTopic")
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }
    static func battery() -> BatteryReading? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = d[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = d[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            return BatteryReading(percent: max(0, min(100, current * 100 / maximum)),
                                  onBattery: d[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue)
        }
        return nil
    }
    func poll() {
        updateAttention()
        if enabled && !confirmationValid && !sending {
            status = "通知停止中：iPhoneでntfyを開き、テスト通知を受信して再確認してください"
        }
        guard let reading = Self.battery() else { percent = nil; if enabled { status = "バッテリー情報を取得できません" }; return }
        percent = reading.percent
        if BatteryPolicy.rearmed(percent: reading.percent) { alreadySent = false }
        guard enabled, !sending, confirmationValid else { return }
        if BatteryPolicy.shouldNotify(percent: reading.percent, onBattery: reading.onBattery, alreadySent: alreadySent), Date() >= retryAt {
            send(test: false, percent: reading.percent)
        } else if !alreadySent && Date() >= retryAt { status = "監視中 · バッテリー使用中に10%未満で通知" }
        else if alreadySent { status = "低残量通知を送信済み · 15%以上で再通知を有効化" }
    }
    var validTopic: Bool {
        NotificationSecurity.validTopic(topic)
    }
    func test() { send(test: true, percent: percent ?? 0) }
    func notifyLidClosed() {
        // A busy sender drops this event rather than replaying an old closure later.
        guard enabled, confirmationValid, !sending else { return }
        send(test: false, percent: percent ?? 0, lid: true)
    }
    private func send(test: Bool, percent: Int, lid: Bool = false) {
        guard !sending, enabled else { return }
        guard test || confirmationValid else { updateAttention(); return }
        guard validTopic else { status = "トピックは16〜100文字の半角英数字・_・-を使用してください"; return }
        if test { awaitingConfirmation = false }
        sending = true
        status = "送信中…"
        generation = UUID()
        let requestGeneration = generation
        guard let request = (lid ? NotificationSecurity.lidRequest(topic: topic) : NotificationSecurity.request(topic: topic, test: test, percent: percent)) else {
            sending = false
            status = "通知データが不正です"
            return
        }
        task = session.dataTask(with: request) { [weak self] _, response, error in
            DispatchQueue.main.async {
                guard let self, self.generation == requestGeneration else { return }
                self.sending = false
                self.task = nil
                if let error = error as? URLError, error.code == .cancelled { return }
                guard error == nil, let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
                    self.failures += 1
                    self.retryAt = Date().addingTimeInterval(min(3600, 300 * pow(2, Double(min(self.failures - 1, 4)))))
                    self.status = lid ? "ふた閉じ通知を送信できませんでした。接続を確認してください。この通知は再送しません。" : "送信できませんでした。接続を確認してください。低残量通知は5〜60分間隔で再試行します。"
                    return
                }
                self.failures = 0
                self.retryAt = .distantPast
                if !test && !lid { self.alreadySent = true }
                else if test { self.awaitingConfirmation = true }
                self.status = "サービスへの送信完了 · iPhone側で受信を確認してください"
            }
        }
        task?.resume()
    }
    func copyTopic() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(topic, forType: .string)
    }
}

struct BatteryPanel: View {
    @ObservedObject var notifier: BatteryNotifier
    @State private var showingSetup = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("iPhoneに低残量・ふた閉じを通知", isOn: $notifier.enabled).toggleStyle(.switch)
            Text("バッテリー \(notifier.percent.map { "\($0)%" } ?? "取得不可") · 10%未満で通知")
                .font(.caption).foregroundStyle(.secondary)
            if notifier.enabled {
                Text("下のQRをiPhoneのカメラで読み取ってください。")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                if notifier.confirmationRequired {
                    Label("通知停止中 · 受信確認が必要です", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.bold()).foregroundStyle(.orange)
                    Text("初回・受信確認から7日後は自動通知を送信しません。iPhoneのホーム画面からntfyを開き、「テスト通知」を押して届くことを確認してください。")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(notifier.expiryText).font(.caption).foregroundStyle(.secondary)
                }
                if let url = PhoneSetup.url(topic: notifier.topic), let qr = PhoneSetup.qr(url) {
                    Image(nsImage: qr).interpolation(.none).resizable().scaledToFit()
                        .frame(width: 170, height: 170).padding(12).background(.white, in: RoundedRectangle(cornerRadius: 12))
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("iPhone登録用QRコード")
                    Text("① iPhoneで読み取る → ② 共有からホーム画面に追加 → ③ ntfyを開いて通知を許可 → ④ Macでテスト通知")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("通知先のトピックが不正なためQRを表示できません。")
                        .font(.caption).foregroundStyle(.orange)
                }
                TextField("通知用トピック", text: $notifier.topic).textFieldStyle(.roundedBorder).disabled(notifier.sending)
                HStack {
                    Button("詳しい登録手順") { showingSetup = true }.disabled(!notifier.validTopic)
                    Button("コピー") { notifier.copyTopic() }
                    Button("テスト通知") { notifier.test() }.disabled(notifier.sending || !notifier.validTopic)
                    Link("設定方法 ↗", destination: URL(string: "https://docs.ntfy.sh/subscribe/pwa/")!)
                }.font(.caption)
                Text("トピックを知る人は受信できます。共有しないでください。通知内容は外部サービスntfy.shへ送信されます。")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if notifier.awaitingConfirmation {
                    Text("iPhoneにテスト通知が表示されたら押してください。サーバーへの送信だけでは受信確認になりません。")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                    Button("iPhoneで届いたことを確認した（7日間有効にする）") { notifier.confirmReceipt() }
                        .font(.caption).disabled(notifier.sending)
                }
                Text(notifier.status).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(isPresented: $showingSetup) { PhoneSetup(topic: notifier.topic) }
    }
}
