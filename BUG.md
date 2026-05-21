# BUG: 既知の不具合・トラブルシューティング

本ドキュメントでは、開発中に遭遇したエラーとその解決策、および確認されている課題について記録・追跡します。

---

## 1. 解決済みのエラー (Resolved Issues)

### 🐛 Issue 01: NSErrorポインタのARC所有権エラー (Pointer ownership mismatch)
- **現象**: `CVirtualDisplay.m` のビルド時に以下のエラーが発生。
  ```
  error: pointer to non-const type 'NSError *' with no explicit ownership
  NSError **errPtr = &creationError;
  ```
- **原因**: Objective-CのARC環境において、`NSError **` は暗黙的に `NSError * __autoreleasing *` と解釈されるが、ローカル変数 `creationError` は暗黙的に `__strong` 所有権を持つため、所有権の不一致が起きた。
- **解決策**: 以下のように明示的な `__autoreleasing` 識別子を付与してポインタ変数を宣言するよう修正。
  ```objc
  __autoreleasing NSError *creationError = nil;
  NSError *__autoreleasing *errPtr = &creationError;
  ```

### 🐛 Issue 02: Swift自動リネーム規則エラー (sharedHelper obsoleted in Swift 3)
- **現象**: `X_display.swift` のビルド時に以下のエラーが発生。
  ```
  error: 'sharedHelper()' has been renamed to 'shared()'
  note: 'sharedHelper()' was obsoleted in Swift 3
  ```
- **原因**: SwiftのClang ImporterがObjective-Cクラスのクラスメソッド `sharedHelper` をSwift 3以降の自動API簡略化規則に従い `shared()` に自動リネームしたため、Swiftから元の名称で呼ぶとリジェクトされた。
- **解決策**: Swift側での呼び出しを `CVirtualDisplayHelper.shared()` に変更。

---

## 2. 既知の課題・調査中 (Active & Pending Issues)

### ✅ Issue 03: TCC / 画面記録（Screen Recording）権限の取得問題
- **ステータス**: 解決済み
- **現象**: `Screen & System Audio Recording` を許可して再起動しても、`SCShareableContent` が `The user declined TCCs for application, window, display capture` で失敗する。
- **原因**: TCC に古い code requirement が残り、現在の `X-Display.app` の署名条件と一致しなかった。ログでは `Failed to match existing code requirement for subject com.goodbad-web.X-Display` が出る。
- **解決策**:
  - Debug ビルドで `ENABLE_DEBUG_DYLIB = NO` を明示し、`X-Display.debug.dylib` 分離による署名条件の揺れを避ける。
  - `CGPreflightScreenCaptureAccess()` の結果だけで起動を止めず、実際の可否は `SCShareableContent` / `SCStream` に委ねる。
  - 音声権限要求を混ぜないため、`SCStreamConfiguration.capturesAudio = false` を明示する。
  - 既存の stale TCC 登録は `tccutil reset ScreenCapture` で全消しし、現在の署名済み app で許可を取り直す。

### ⚠️ Issue 05: iPad再接続時の画面ブラックアウトおよび即時切断ループ
- **ステータス**: 黒画面・初回フリーズは対策済み。`SCStream` 継続更新停止は health monitor + restart で対応。
- **現象**: 接続完了後、または再接続時にiPadの画面が黒いままになり、ペアリング成功（`Pairing verified by host!`）の直後に `StreamClient` が即時切断（`StreamClient disconnected`）され無限再接続ループに陥る。
- **原因の仮説と対応策**:
  - **仮説1**: Mac側の `NSAlert.runModal()` がメインスレッドをブロックし、ペアリング成功後のストリーム配信やソケット通信にデッドロックやタイムアウトを引き起こしている。
    - **対応策**: `X_display.swift` 内の `alert.runModal()` を非ブロックのフローティングウィンドウ表示（`window.makeKeyAndOrderFront`）へ変更し、メインスレッドのブロッキングリスクを完全に排除。
  - **仮説2**: SwiftUIのシート破棄の副作用、またはソケット切断（EOF）による自動クローズ。
    - **対応策**: `StreamClient.swift` の切断ロジックおよび `AppViewModel.disconnect()` に詳細なスタックトレースと切断理由（Reason）ログを組み込み、実行時ログからトリガーを特定できるようにした。
  - **確認済み原因**: ペアリング前の `SCStream` フレーム破棄により、接続直後に送る初回IDR/SPS/PPSが欠けるケースがあった。また仮想ディスプレイ環境では `SCStream` が初回1フレーム後に継続更新しないケースを確認。
    - **対応策**: ペアリング前から最新 `CVPixelBuffer` を保持し、ペアリング完了時に即時keyframe送信する。`SCStream` health monitor + restart を追加し、停止・詰まり時は `SCStream` のみ再生成する。fallback capture は再起動失敗時の最終手段に限定する。
