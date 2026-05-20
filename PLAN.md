# PLAN: macOS-iPad 画面拡張アプリケーション 開発計画書

## 1. プロジェクト目標
macOSの画面をiPadにセカンドディスプレイ（拡張画面）として拡張する、超低遅延（1フレーム以下・約16ms遅延）の商用アプリケーションを開発する。

## 2. マイルストーン
```mermaid
gantt
    title 開発ロードマップ (PoCからリリースまで)
    dateFormat  YYYY-MM-DD
    section 実証実験 (PoC)
    仮想ディスプレイ作成検証           :active, poc1, 2026-05-20, 2d
    ScreenCaptureKitキャプチャ検証    :   poc2, after poc1, 3d
    USBMuxd/Wi-Fi通信検証           :   poc3, after poc2, 4d
    デコード・Metal描画検証           :   poc4, after poc3, 3d
    入力逆送信（タッチ・Pencil）検証   :   poc5, after poc4, 3d
    section クライアント開発
    macOSホストアプリ UI・接続制御     :   host1, after poc5, 7d
    iPadOSクライアントアプリ UI・描画  :   client1, after poc5, 7d
    section リリース準備
    Developer IDコード署名・公証     :   rel1, after host1, 3d
    Stripe決済・ライセンス認証基盤    :   rel2, after host1, 5d
```

---

## 3. 技術的設計アプローチ（コア仕様）

### ① 仮想ディスプレイ制御（macOS）
- `AppleVirtualDisplay.framework` (Private API) を `dlopen` による動的ロード。
- `AVDVirtualDisplayController` と `AVDVirtualDisplay` を用いて、システム設定に 1920x1080 (HiDPI) などの画面を即座に追加する。

### ② ビデオ伝送パイプライン（ゼロレイテンシ）
- **キャプチャ**: `ScreenCaptureKit` によるゼロコピーVRAMキャプチャ。
- **エンコード**: `VideoToolbox` (H.264/HEVC) で `RealTime = true` および **Bフレーム無効化（MaxFrameDelayCount = 0）** による遅延の完全排除。
- **転送**: Wi-Fi (Bonjour/TCP) および USB/Thunderbolt (USBMuxd/TCP)。ソケットに `TCP_NODELAY = true` を設定し、送信遅延を極小化。
- **デコード・描画**: iPad側 `VideoToolbox` でハードウェアデコードし、生成されたピクセルバッファを直接 `Metal` (MTKView) にバインドして超低遅延描画。

### ③ 機能スコープ
- **初期フェーズ**: 画面拡張および入力制御（タッチ、Apple Pencil対応）のみ。
- **音声転送**: 実装の複雑化と遅延を避けるため、初期フェーズでは「非対応」とする。

---

## 4. 配布・ライセンス設計
- **macOSホスト**: Mac App Store非対応のため、独自Webサイトからの直販。Developer IDでコード署名およびAppleの公証（Notarization）を必須とする。
- **iPadOSクライアント**: App Storeにて公式配布。
- **アップデート通知**: macOSホストアプリに `Sparkle.framework` を組み込み、OSアップデート等の追従に伴う強制/推奨アップデート導線を確保する。
