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

### ⚠️ Issue 03: TCC / 画面記録（Screen Recording）権限の取得問題
- **ステータス**: 未発生（Phase 2実行時に想定される課題）
- **現象**: `ScreenCaptureKit` でキャプチャを開始しようとすると、権限エラーまたは黒画面しか取得できない。
- **原因**: macOSのセキュリティ制限（TCC）により、アプリが「システム設定 -> プライバシーとセキュリティ -> 画面記録」で許可を得ていないと画面取得がブロックされる。
- **対策方針**:
  - `SCShareableContent` 取得前に、APIが提供するアクセス権取得ロジック（`CGRequestScreenCaptureAccess()`等）をコールする。
  - 権限が却下された場合、ユーザーへシステム設定を促すUIポップアップを表示する。

### ⚠️ Issue 04: macOSメジャーアップデート時のPrivate APIシグネチャ変更リスク
- **ステータス**: 警戒中（将来のOSアップデート時に想定）
- **現象**: 新しいmacOSバージョン（macOS 15/16など）で動的ロードが失敗する、または作成メソッド呼び出し時にアプリがクラッシュする。
- **原因**: AppleがPrivate Framework（`AppleVirtualDisplay.framework`）の内部構造や引数を変更する可能性。
- **対策方針**:
  - `respondsToSelector:` の検証を徹底し、メソッドが存在しない場合は仮想ディスプレイの生成をスキップして安全に処理をフォールバックする。
