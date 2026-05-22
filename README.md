# X-display: macOS-iPad 超低遅延画面拡張システム

## 1. プロジェクト概要
`X-display` は、iPadをMacのセカンドディスプレイ（拡張画面）として機能させる、超低遅延画面共有システムです。
AppleのプライベートAPI（`CGVirtualDisplay`）を活用し、余計なカーネル拡張やドライバ申請を必要とせずに仮想画面を生成します。

本プロジェクトは単一のリポジトリ・コードベースに統合されており、macOSアプリ（送信・受信の双方をサポート）とiPadOSアプリ（受信専用）をシームレスに開発・ビルドできます。

---

## 2. システム要件 (Requirements)
- **macOS (Host/Client)**: macOS 14.0 (Sonoma) 以上推奨
- **Swift / Xcode**: Swift 6.0以上 / Xcode 15.0以上
- **iPadOS (Client)**: iOS/iPadOS 17.0 以上
- **ビルドシステム**: XcodeGen (2.40.0以上) 推奨

---

## 3. ディレクトリ構造 (Directory Structure)
```
X-display/
├── project.yml             # macOS用 XcodeGen設定
├── Package.swift           # Swift Package Manager設定
├── PLAN.md                 # 開発ロードマップ・設計方針
├── TASK.md                 # タスク進捗管理表
├── AGENTS.md               # AI協調・Token Economy規則
├── BUG.md                  # 不具合追跡・トラブルシューティング
├── SKILLS.md               # 必要技術スキル・コードテンプレート
├── ARCHITECTURE.md         # スレッド設計・データパケット仕様
├── Sources/
│   ├── CVirtualDisplay/    # [Objective-C] CGVirtualDisplay 動的ロードヘルパー
│   └── X-display/          # [Swift] macOSメインアプリケーション・エントリポイント
├── XDisplayShared/         # [SwiftPM] 送受信共通プロトコル・通信ユーティリティ
└── iPad-client/            # [SwiftUI] iPadクライアントアプリケーション
    ├── project.yml         # iPadOS用 XcodeGen設定
    └── Sources/            # iPadOS UI・Metal描画・H.264/HEVCデコーダー
```

---

## 4. ビルドと実行方法 (Build & Run)

### 4.1 プロジェクトファイルの生成 (XcodeGen)
本プロジェクトはXcodeGenで管理されています。ビルド前に以下のコマンドを実行してXcodeプロジェクトを生成します。

```bash
# macOSホスト用のプロジェクト生成（ルートディレクトリで実行）
xcodegen generate

# iPadOSクライアント用のプロジェクト生成
cd iPad-client
xcodegen generate
```

### 4.2 ビルド & テスト実行
生成された `X-Display.xcworkspace` または各 `.xcodeproj` ファイルをXcodeで開き、ビルドを実行します。

- **macOS アプリ**: メニューバー常駐型のHost機能（送信）に加え、受信機（Client）ウィンドウを同時に起動可能。
- **iPadOS クライアント**: メインビューが起動し、同一Wi-Fiネットワーク上のMac、またはUSB接続されたMacを自動検知して接続待ち受けになります。

---

## Current Status
- **Virtual Display (CGVirtualDisplay)**: Working (macOS 14+)
- **ScreenCaptureKit (Zero-copy capture)**: Working
- **H264/HEVC Encoder/Decoder**: Working
- **Unified App Architecture**: In Progress (Integrating Target Assets)
- **Reconnect Recovery & Hardening**: Hardening under progress (Phase 7)

---

## 5. 実行時の注意点 (Troubleshooting)
- **画面収録（Screen Recording）権限**:
  本アプリケーションは画面キャプチャを伴うため、初回実行時にmacOSより「画面収録」の権限が求められます。「システム設定 -> プライバシーとセキュリティ -> 画面収録」にて、実行元アプリまたはXcodeのチェックを有効にしてください。
- **iOS用 App Store 審査への配慮**:
  iOS/iPadOSビルド時には、プリプロセッサマクロ `#if os(macOS)` およびビルドターゲット構成により、Private API関連（`CGVirtualDisplay`等）の参照コードはバイナリに一切コンパイルされません。App Storeの自動検証プロセスも問題なく通過可能です。

