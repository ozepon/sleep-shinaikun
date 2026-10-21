import Foundation

var checks = 0
func check(_ value: Bool, _ name: String) {
    guard value else { print("FAIL: \(name)"); exit(1) }
    checks += 1
    print("PASS: \(name)")
}
let normal = "sleep-0123456789abcdef"
check((normal + "\n").range(of: "^[A-Za-z0-9_-]{16,100}$", options: .regularExpression) == nil, "baseline previous sender already rejects trailing newline")
let attacks = ["", "short", normal + "\n", normal + "\r\nX-Evil: yes", normal + "/../private", normal + "?x=1", normal + "#fragment", normal + "%2fadmin", normal + "; touch /tmp/should-not-exist", normal + "$(id)", normal + "`id`", normal + "\"", normal + "\\", normal + "\u{0}", normal + "💣", String(repeating: "x", count: 101), String(repeating: "x", count: 1000000)]
for (i, attack) in attacks.enumerated() {
    check(!NotificationSecurity.validTopic(attack), "reject malicious topic \(i + 1)")
    check(NotificationSecurity.subscriptionURL(topic: attack) == nil, "reject malicious QR URL \(i + 1)")
    check(NotificationSecurity.request(topic: attack, test: true, percent: 9) == nil, "reject malicious request \(i + 1)")
}
for length in [16, 100] { check(NotificationSecurity.validTopic(String(repeating: "a", count: length)), "accept boundary \(length)") }
check(NotificationSecurity.subscriptionURL(topic: normal) == "https://ntfy.sh/" + normal, "fixed HTTPS QR host")
let request = NotificationSecurity.request(topic: normal, test: false, percent: 9)!
check(request.url?.absoluteString == "https://ntfy.sh", "fixed HTTPS publish host")
check(request.httpMethod == "POST", "POST only")
let payload = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
check(Set(payload.keys) == Set(["topic", "title", "message", "priority", "tags"]), "payload excludes device name and credentials")
check(payload["topic"] as? String == normal, "JSON topic roundtrip")
check(NotificationSecurity.request(topic: normal, test: false, percent: -1) == nil, "reject negative battery")
check(NotificationSecurity.request(topic: normal, test: false, percent: 101) == nil, "reject oversized battery")
let delegate = NotificationSession()
let session = delegate.makeSession()
check(session.configuration.httpCookieStorage == nil, "no cookie storage")
check(session.configuration.urlCredentialStorage == nil, "no credential storage")
if CommandLine.arguments.contains("--redirect-test") {
    let done = DispatchSemaphore(value: 0)
    var localRequest = request
    localRequest.url = URL(string: "http://127.0.0.1:18766/redirect")!
    session.dataTask(with: localRequest) { _, response, error in
        check(error == nil && (response as? HTTPURLResponse)?.statusCode == 307, "real HTTP redirect refused; original 307 retained")
        done.signal()
    }.resume()
    check(done.wait(timeout: .now() + 10) == .success, "redirect attack completed locally")
}
session.invalidateAndCancel()
let now = Date(timeIntervalSince1970: 2000000000)
check(!ConfirmationPolicy.valid(confirmedAt: nil, now: now), "first setup requires receipt confirmation")
check(ConfirmationPolicy.valid(confirmedAt: now, now: now), "just confirmed is valid")
check(ConfirmationPolicy.valid(confirmedAt: now.addingTimeInterval(-ConfirmationPolicy.lifetime + 1), now: now), "one second before seven days is valid")
check(!ConfirmationPolicy.valid(confirmedAt: now.addingTimeInterval(-ConfirmationPolicy.lifetime), now: now), "exactly seven days expires")
check(!ConfirmationPolicy.valid(confirmedAt: now.addingTimeInterval(-ConfirmationPolicy.lifetime - 1), now: now), "after seven days expires")
check(!ConfirmationPolicy.valid(confirmedAt: now.addingTimeInterval(1), now: now), "clock rollback requires recheck")
print("Security checks passed: \(checks)")
