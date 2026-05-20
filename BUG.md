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

### ⚠️ Issue 04: macOSメジャーアップデート時のPrivate APIシグネチャ変更リスク
- **ステータス**: 警戒中（将来のOSアップデート時に想定）
- **現象**: 新しいmacOSバージョン（macOS 15/16など）で動的ロードが失敗する、または作成メソッド呼び出し時にアプリがクラッシュする。
- **原因**: AppleがPrivate Framework（`AppleVirtualDisplay.framework`）の内部構造や引数を変更する可能性。
- **対策方針**:
  - `respondsToSelector:` の検証を徹底し、メソッドが存在しない場合は仮想ディスプレイの生成をスキップして安全に処理をフォールバックする。
