import Cocoa
import SwiftUI
import CoreImage.CIFilterBuiltins

struct PhoneSetup: View {
    let topic: String
    @Environment(\.dismiss) private var dismiss
    static func url(topic: String) -> String? { NotificationSecurity.subscriptionURL(topic: topic) }
    static func qr(_ value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("iPhoneで通知を受け取る").font(.title3.bold())
                Spacer()
                Button("閉じる") { dismiss() }
            }
            if let url = Self.url(topic: topic), let qr = Self.qr(url) {
                Image(nsImage: qr).interpolation(.none).resizable().scaledToFit()
                    .frame(width: 190, height: 190).padding(14).background(.white)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("iPhoneのカメラで読み取る通知受信ページのQRコード")
            }
            Text("1. iPhoneのカメラでQRを読み、SafariまたはChromeで開く\n2. 共有 →「ホーム画面に追加」\n3. 追加したntfyを開き、通知を許可\n4. このトピックの購読を確認\n5. Macで「テスト通知」を押す\n6. iPhoneで受信後、Macで「届いたことを確認した」を押す")
                .font(.callout).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
            Text("購読が表示されない場合は、ntfyの「Subscribe」で次のトピックを登録してください。")
                .font(.caption).foregroundStyle(.secondary)
            Text(topic).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text("iOS 16.4以降・インターネット接続が必要です。QRを読むだけでは通知は有効になりません。通知は受信確認から7日間有効です。期限後はMacのメニューバーに⚠︎を表示して自動通知を停止します。再開時はiPhoneでntfyを開き、再びテスト受信を確認してください。QRとトピックは共有しないでください。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(22).frame(width: 380)
    }
}
