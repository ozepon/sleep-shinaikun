# 専用通知アプリ・遠隔オフ（開発版）

iPhoneのホーム画面に追加するWebアプリ（PWA）です。Apple Developer Programへの加入は不要です。iOS 16.4以降を対象にしています。まだ本番公開していません。実機のPush到達・ふたを閉じた状態での実行確認が必要です。

## 利用の流れ

1. 運営がCloudflareへ通知サーバーを公開し、招待するMacの接続情報を発行します。一般公開の新規登録はありません。
2. Macの「専用アプリ接続」でサーバーURLとMac接続トークンを入力し、「登録コードを発行」を押します。
3. iPhoneで同じサーバーURLを開き、共有からホーム画面に追加します。**追加したアイコンから開いてから登録**します。
4. 「MacのQRを読み取る」でMacのQRを読み、「通知を許可して登録」を押します。登録コードの貼り付けでも登録できます。QRは5分有効・1回限りです。
5. Macで「専用通知とiPhoneからのオフ操作」をオンにし、テスト通知を送ります。ntfyは移行確認まで残しています。両方オンなら両方へ送信します。
6. 遠隔オフには、Mac側の既存の「切替の認証を省略する」限定許可が必要です。設定時だけ管理者認証が必要です。遠隔操作によって認証画面を出すことはありません。
7. バッテリー使用中に10%未満になると通知します。通知からアプリを開き「スリープ防止をオフにする」を選択して確認します。選択しなければ変更しません。
8. Macは約60秒ごとに指示を確認します。受信していない指示は2分で失効します。アプリ終了中・オフライン中に後から期限切れの指示を実行しません。
9. Macは固定のpmsetコマンドでオフにし、設定を読み直してオフを確認してから結果をサーバーへ報告します。報告を受けたサーバーだけが「オフにしました」をPush送信します。

オフ直後にMacがスリープすると結果送信が止まる場合があります。結果をMacに保存し、復帰後に再試行します。自動送信は最大3回、以後は「保留した結果の報告を再試行」で手動再開します。報告がなければiPhone側は成功表示をしません。「実行結果を確認できない」状態を表示します。Push送信成功はAppleサービスが受け付けたという意味で、iPhoneに表示された保証ではありません。通信障害・通知許可・上限によって完了Pushが出ない場合もあり、アプリ画面でも確認できます。

## 制限と保護

- 有効なMac+iPhoneを50組まで。運営だけが接続情報を発行します。再ペアリングで旧iPhoneの操作トークンは無効になります。
- Mac、iPhone、登録用のトークンは役割別。すべてランダム値＋HMAC。偽造トークンはDBアクセス前に拒否します。DBにはトークンのSHA-256ハッシュだけを保存します。Macのトークンはキーチェーン、iPhoneはPWAのローカル保存です。
- QRや登録コードを共有しないでください。有効なコードを先に使った人が登録できます。Mac接続トークンが漏れると、その組の操作・再ペアリング・偽の結果報告が可能です。運営が失効させます。
- 指示はオフのみ。任意のシェルや引数は送れません。同じ指示は一度だけ取得し、二重操作を防ぎます。指示の取得後にアプリが落ちた場合も再実行しません。
- 操作指示は1組あたり直近24時間で10回、全体500回まで。通知はUTC日付で1組10回・全体500回まで。失敗した送信も上限に数えます。送信IDの再利用では再送しません。通知の同時送信は最大2件、待ち行列を作らず超過を拒否します。
- APIのエッジ制限はIPあたり60回/分、トークンあたり20回/分。Cloudflareの各拠点での概算制限であり、全世界を通した厳密な上限ではありません。
- 本文4KBまで。Push宛先はHTTPSのApple Pushドメインだけ、リダイレクト拒否、5秒タイムアウト。任意URLをサーバーから取得しません。
- APIはキャッシュ禁止、同一オリジン、HTTPS。管理トークン・Push秘密鍵はサーバーのみ。第三者CDNのスクリプトを読みません。Push本文はweb-pushの暗号化を使用します。
- 操作履歴・送信記録は7日後の定期削除対象。`DISABLED=1`でAPIを停止できます。アプリを消す前にMac側の限定許可を解除してください。

50台が常時接続すると、60秒ポーリングで約72,000リクエスト/日です。ほかに操作確認・通知等が加算されます。無料枠は大規模攻撃でも無停止を保証するものではありません。大量アクセスで無料枠が尽きればAPIは停止し、遠隔操作・通知は使えなくなります。Macのローカル切替は通知サーバーに依存しません。有料プランへ自動変更する処理はありません。

## 運営用セットアップ

Node.js 22以降、CloudflareのWorkers/D1を利用できるアカウントが必要です。以下はserverディレクトリで実行します。

```sh
npm ci
npx wrangler login
npx wrangler d1 create sleep-shinaikun
# 表示されたdatabase_idをwrangler.jsoncに設定
npx wrangler d1 migrations apply sleep-shinaikun --remote
node scripts/init.mjs
# .dev.varsの4項目を値を表示せず暗号化シークレットへ登録
node scripts/publish-secrets.mjs
npx wrangler deploy
node scripts/enroll.mjs https://YOUR.workers.dev /private/path/mac-connection.json
```

管理トークンは`.admin-token`に0600で保存します。接続情報ファイルも0600です。管理者だけがMacのトークンを本人へ渡します。失効は管理者のBearerトークンで`POST /api/admin/revoke`へ`{"id":"対象のID"}`を送ります。管理トークンは一般ユーザーへ渡しません。

## 検証

```sh
npm test
npx wrangler deploy --dry-run --outdir /tmp/sleep-shinaikun-worker-check
node tests/runtime.mjs /tmp/sleep-shinaikun-worker-check/worker.js
```

`tests/security.test.mjs`はNodeのSQLiteで実際のSQLとAPIを検証します。Pushはテスト内で差し替え、Appleや第三者へ攻撃を送りません。Macのpmset/sudo設定も変更しません。`tests/runtime.mjs`はworkerd/D1で並列登録を検証します。実際のworkerd/D1で、10件の同時クリックが1指示になること、役割分離、指示の1回取得、完了報告、暗号化Pushの復号、二重Push拒否、期限切れ指示の拒否、60件同時登録時の50組上限を確認しました。Macの実際のpmset操作とiPhone実機の到達は別途確認が必要です。

参考：[Apple Web Push](https://developer.apple.com/documentation/usernotifications/sending-web-push-notifications-in-web-apps-and-browsers)、[Cloudflare Rate Limiting](https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/)。

検証結果：[API・暗号化テスト](tests/results.txt)、[workerd/D1統合テスト](tests/runtime-results.txt)。
