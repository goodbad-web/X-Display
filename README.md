# X-display: macOS-iPad 超低遅延画面拡張システム

## 1. プロジェクト概要
`X-display` は、iPadをMacのセカンドディスプレイ（拡張画面）として機能させる、超低遅延画面共有システムです。
AppleのプライベートAPI（`AppleVirtualDisplay.framework`）を活用し、余計なカーネル拡張やドライバ申請を必要とせずに仮想画面を生成します。

---

## 2. システム要件 (Requirements)
- **macOS (Host)**: macOS 12.0 (Monterey) 以上（macOS 14 Sonoma 以上を強く推奨）
- **Swift / Xcode**: Swift 6.0以上 / Xcode 15.0以上
- **iPadOS (Client)**: iOS/iPadOS 15.0 以上

---

## 3. ディレクトリ構造 (Directory Structure)
```
X-display/
├── Package.swift         # Swift Package Manager設定
├── PLAN.md               # 開発ロードマップ・設計方針
├── TASK.md               # タスク進捗管理表
├── AGENTS.md             # AI協調・Token Economy規則
├── BUG.md                # 不具合追跡・トラブルシューティング
├── SKILLS.md             # 必要技術スキル・コードテンプレート
├── ARCHITECTURE.md       # スレッド設計・データパケット仕様
├── Sources/
│   ├── CVirtualDisplay/  # [Objective-C] AppleVirtualDisplay 動的ロードヘルパー
│   └── X-display/        # [Swift] メインアプリケーション・エントリポイント
└── Tests/                # ユニットテスト
```

---

## 4. ビルドと実行方法 (Build & Run)

### 4.1 ビルド
リポジトリのルートディレクトリで以下のコマンドを実行し、プロジェクトをコンパイルします。
```bash
swift build
```

### 4.2 テスト実行 (Phase 1 PoC)
ビルド完了後、以下のコマンドでテスト起動できます。
```bash
.build/debug/X-display
```
実行すると、システム環境に 1920x1080 の仮想ディスプレイが追加されます。**「システム設定 -> ディスプレイ」** を開いてディスプレイが正しく追加されていることを確認してください。
検証終了後、ターミナルで `[ENTER]` キーを押すことで仮想ディスプレイが安全に破棄され、プログラムが終了します。

---

## Current Status

- Virtual Display: Working
- ScreenCaptureKit: Working
- H264 Streaming: Working
- Reconnect Recovery: Partial
- Production Hardening: In Progress

## 5. 実行時の注意点 (Troubleshooting)
- **画面収録（Screen Recording）権限**:
  本アプリケーションは画面キャプチャを伴うため、初回実行時にmacOSより「画面収録」の権限が求められます。拒否した場合は「システム設定 -> プライバシーとセキュリティ -> 画面収録」にて、実行元のターミナルアプリまたはXcodeのチェックを有効にしてください。
- **デバッグログの確認**:
  動的ロードの失敗や仮想ディスプレイ生成のエラーは、ターミナルの標準出力および `BUG.md` に記載のトラブルシューティング例を参照してください。
