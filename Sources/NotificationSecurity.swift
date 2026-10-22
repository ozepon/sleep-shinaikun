import Foundation

struct NotificationSecurity {
    static func validTopic(_ topic: String) -> Bool {
        let bytes = Array(topic.utf8)
        return (16...100).contains(bytes.count) && bytes.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }
    static func subscriptionURL(topic: String) -> String? {
        guard validTopic(topic) else { return nil }
        return "https://ntfy.sh/\(topic)"
    }
    static func request(topic: String, test: Bool, percent: Int) -> URLRequest? {
        guard validTopic(topic), (0...100).contains(percent) else { return nil }
        var request = URLRequest(url: URL(string: "https://ntfy.sh")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "topic": topic, "title": "スリープしない君",
            "message": test ? "接続テストです。このiPhoneでMacのバッテリー通知を受け取れます。" : "Macのバッテリー残量が\(percent)%になりました。充電してください。",
            "priority": test ? 3 : 4, "tags": [test ? "white_check_mark" : "battery"]
        ])
        return request
    }
    static func lidRequest(topic: String) -> URLRequest? {
        guard var request = request(topic: topic, test: true, percent: 0) else { return nil }
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "topic": topic, "title": "スリープしない君",
            "message": "Macのふたを閉じました。スリープ防止はオンです。",
            "priority": 3, "tags": ["computer"]
        ])
        return request
    }

}

// A redirect must never forward a private topic or notification body elsewhere.
final class NotificationSession: NSObject, URLSessionTaskDelegate {
    func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct ConfirmationPolicy {
    static let lifetime: TimeInterval = 7 * 24 * 60 * 60
    static func valid(confirmedAt: Date?, now: Date = Date()) -> Bool {
        guard let date = confirmedAt else { return false }
        let age = now.timeIntervalSince(date)
        return age >= 0 && age < lifetime
    }
}
