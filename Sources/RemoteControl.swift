import Cocoa
import Security
import SwiftUI
import UniformTypeIdentifiers

final class RemoteControl: ObservableObject {
  @Published var origin =
    UserDefaults.standard.string(forKey: "remoteOrigin")
    ?? "https://sleep-shinaikun-notify.ozepon-d.workers.dev"
  @Published var credentialInput = ""
  @Published var pairCode = ""
  @Published var status = "専用通知サーバーは未接続です"
  @Published var enabled = UserDefaults.standard.bool(forKey: "remoteEnabled") {
    didSet { UserDefaults.standard.set(enabled, forKey: "remoteEnabled") }
  }
  private var lowSent = false
  private let delegate = NotificationSession()
  private lazy var session = delegate.makeSession()
  private var inFlight = false
  private var lastPoll = Date.distantPast
  private var pendingResult: (String, String)? {
    didSet {
      if let (id, state) = pendingResult {
        UserDefaults.standard.set([id, state], forKey: "remotePendingResult")
      } else {
        UserDefaults.standard.removeObject(forKey: "remotePendingResult")
      }
    }
  }
  init() {
    if let saved = UserDefaults.standard.stringArray(forKey: "remotePendingResult"),
      saved.count == 2
    {
      pendingResult = (saved[0], saved[1])
    }
  }
  private var resultAttempts = 0
  private var connection: [String: String]? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "local.lidawake.remote", kSecAttrAccount as String: "mac",
      kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
  }
  private var token: String? { connection?["token"] }
  private var base: URL? { connection?["origin"].flatMap(Self.validOrigin) }
  private static func validOrigin(_ origin: String) -> URL? {
    guard let u = URL(string: origin), u.scheme == "https", u.user == nil, u.password == nil,
      u.port == nil, u.path.isEmpty || u.path == "/", u.query == nil, u.fragment == nil,
      u.host?.hasSuffix(".workers.dev") == true
    else { return nil }
    return u
  }
  func connect() {
    if credentialInput.isEmpty {
      guard base != nil, token != nil, origin == connection?["origin"] else {
        status = "接続ファイルを読み込むか、接続トークンを入力してください"
        return
      }
      issuePair()
      return
    }
    guard Self.validOrigin(origin) != nil,
      credentialInput.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
    else {
      status = "HTTPSのworkers.dev URLと接続トークンを確認してください"
      return
    }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "local.lidawake.remote", kSecAttrAccount as String: "mac",
    ]
    SecItemDelete(query as CFDictionary)
    var item = query
    item[kSecValueData as String] = try? JSONSerialization.data(withJSONObject: [
      "origin": origin, "token": credentialInput,
    ])
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
      status = "接続情報をキーチェーンに保存できません"
      return
    }
    UserDefaults.standard.set(origin, forKey: "remoteOrigin")
    credentialInput = ""
    issuePair()
  }
  private func issuePair() {
    pairCode = ""
    call("pair") { [weak self] d in
      guard let self else { return }
      if let t = d?["pairToken"] as? String, let k = d?["publicKey"] as? String {
        self.pairCode = t + "." + k
        self.status = "専用アプリでQRを読み取ってください（5分有効）"
      } else {
        self.status = "登録コードを発行できません。接続情報・通信を確認してください"
      }
    }
  }
  func importConnection() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    panel.message = "運営から受け取った接続ファイルを選んでください。他人へ共有しないでください。"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4096,
      let data = try? Data(contentsOf: url),
      let values = (try? JSONSerialization.jsonObject(with: data)) as? [String: String],
      let address = values["origin"], Self.validOrigin(address) != nil,
      let credential = values["macToken"],
      credential.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
    else {
      status = "接続ファイルの形式が正しくありません"
      return
    }
    origin = address
    credentialInput = credential
    connect()
  }
  private func call(
    _ path: String, data: [String: Any] = [:], completion: @escaping ([String: Any]?) -> Void
  ) {
    guard let base, let token else {
      completion(nil)
      return
    }
    var request = URLRequest(url: base.appendingPathComponent("api/" + path))
    request.httpMethod = "POST"
    request.timeoutInterval = 10
    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: data)
    session.dataTask(with: request) { body, response, error in
      let value: [String: Any]? =
        error == nil && (response as? HTTPURLResponse)?.statusCode == 200
        ? body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } : nil
      DispatchQueue.main.async { completion(value) }
    }.resume()
  }
  func retryReport() {
    resultAttempts = 0
    lastPoll = .distantPast
  }
  func notify(_ kind: String) {
    call("notify", data: ["id": UUID().uuidString, "kind": kind]) { [weak self] d in
      self?.status =
        d?["delivery"] as? String == "accepted" ? "通知サービスへ送信しました" : "通知を送信できませんでした（未登録・上限・通信を確認）"
    }
  }
  func poll(control: SleepControl) {
    guard enabled, !inFlight, Date().timeIntervalSince(lastPoll) >= 60, base != nil, token != nil
    else { return }
    if pendingResult != nil && resultAttempts >= 3 {
      status = "結果の報告が保留中です。通信を確認し、報告を再試行してください"
      return
    }
    lastPoll = Date()
    inFlight = true
    if let reading = BatteryNotifier.battery() {
      if reading.percent >= 15 { lowSent = false }
      if reading.onBattery && reading.percent < 10 && !lowSent {
        lowSent = true
        notify("low")
      }
    }
    if let (id, state) = pendingResult {
      resultAttempts += 1
      call("result", data: ["id": id, "state": state]) { [weak self] d in
        guard let self else { return }
        self.inFlight = false
        if d != nil { self.pendingResult = nil }
      }
      return
    }
    guard !control.busy else {
      inFlight = false
      return
    }
    call("poll") { [weak self, weak control] d in
      guard let self, let control else { return }
      guard self.enabled else {
        self.inFlight = false
        return
      }
      guard let c = d?["command"] as? [String: Any], let id = c["id"] as? String,
        let expiry = c["expires"] as? Double
      else {
        self.inFlight = false
        return
      }
      guard expiry > Date().timeIntervalSince1970 else {
        self.inFlight = false
        return
      }
      func finish(_ ok: Bool) {
        let state = ok ? "off" : "failed"
        self.pendingResult = (id, state)
        self.resultAttempts = 1
        self.status = ok ? "iPhoneの指示でオフを確認しました" : "iPhoneの指示を実行できませんでした"
        self.call("result", data: ["id": id, "state": state]) { d in
          self.inFlight = false
          if d != nil { self.pendingResult = nil }
        }
      }
      control.refresh()
      if control.available && !control.enabled {
        finish(true)
        return
      }
      guard !control.busy, LimitedPermission.isInstalled() else {
        finish(false)
        return
      }
      control.setEnabled(false) { ok in finish(ok) }
    }
  }
}
struct RemotePanel: View {
  @ObservedObject var remote: RemoteControl
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("専用アプリ接続（準備版）").bold()
      Toggle("専用通知とiPhoneからのオフ操作", isOn: $remote.enabled)
      Button("接続ファイルを読み込む…") { remote.importConnection() }
      TextField("通知サーバー https://…workers.dev", text: $remote.origin)
      SecureField("Mac接続トークン", text: $remote.credentialInput)
      Text("① iPhoneで上のURLを開き、ホーム画面に追加します。② 追加したアプリから、下のQRを読み取ります。").font(.caption).fixedSize(
        horizontal: false, vertical: true)
      Button("登録コードを発行") { remote.connect() }
      if !remote.pairCode.isEmpty {
        if let qr = PhoneSetup.qr(remote.pairCode) {
          Image(nsImage: qr).interpolation(.none).resizable().scaledToFit().frame(
            width: 170, height: 170
          ).padding(10).background(.white)
        }
        Text("専用アプリ内の「MacのQRを読み取る」で読み取ってください（5分有効）。").font(.caption).fixedSize(
          horizontal: false, vertical: true)
        TextField("iPhone登録コード", text: $remote.pairCode)
        Button("登録コードをコピー") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(remote.pairCode, forType: .string)
        }
      }
      Button("専用アプリへテスト通知") { remote.notify("test") }
      Text(remote.status).font(.caption)
      Button("保留した結果の報告を再試行") { remote.retryReport() }
      Text("iPhoneからのオフ操作には、Macのスリープ切替の限定許可が必要です。").font(.caption)
    }.textFieldStyle(.roundedBorder)
  }
}
