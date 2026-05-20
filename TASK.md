# TASK: 実装タスクチェックリスト

- [x] **Phase 1: macOS仮想ディスプレイ作成 PoC**
  - [x] Swift Package Manager による `X-display` プロジェクト初期化
  - [x] Objective-Cによる動的ローダー `CVirtualDisplayHelper` の設計
  - [x] `AppleVirtualDisplay.framework` の動的ロードと `dlopen` の検証
  - [x] `NSInvocation` を用いた `createVirtualDisplay` の実行とARC所有権エラーの修正
  - [x] Swiftメイン（`X_display.swift`）からの `shared()` 呼び出しと動作確認・ビルド成功

- [x] **Phase 2: ScreenCaptureKitによる超低遅延キャプチャ PoC**
  - [x] macOSの画面収録権限の確認およびチェックロジックの実装
  - [x] `ScreenCaptureKit` の `SCShareableContent` から、作成した仮想ディスプレイを特定するフィルタリング処理の記述
  - [x] `SCStream` の初期化とフレームキャプチャコールバックの記述
  - [x] キャプチャした `CVPixelBuffer` のサイズ、解像度、タイムスタンプのログ出力検証


- [x] **Phase 3: 有線/無線通信 & ストリーミング配信 PoC**
  - [x] iPadOSクライアントアプリのプロジェクト作成
  - [x] **無線**: `Network.framework` (Bonjour) を用いたローカルTCPソケット通信 of 構築
  - [x] **有線**: `USBMuxd` を利用したTCPポート転送経由 of 有線通信の検証（透過的なTCPで実現）
  - [x] Mac側での `VideoToolbox` H.264 ハードウェア圧縮（Bフレーム無効）パケット化処理の実装
  - [x] iPad側でのデコードと `Metal` (MTKView) へのダイレクトレンダリング実装

- [x] **Phase 4: 入力フィードバック PoC**
  - [x] iPad上でのタッチ位置、Pencil（筆圧・傾き）のイベントハンドリング
  - [x] イベントデータをUDP/TCP経由でMacに即座に逆送信する軽量プロトコル実装
  - [x] Mac側で `CGEvent` に変換し、カーソルやブラシのリアルタイム動作を検証

- [ ] **Phase 5: プロダクト化・UI・接続制御実装**
  - [ ] macOS側メニューバー常駐型UI（メニューから仮想画面の起動・切断・解像度調整を行う）の構築
  - [ ] iPadOS側のUI（デバイス検出リスト、接続中待機画面、解像度調整など）の構築
  - [ ] Wi-Fi/USB/Thunderbolt の接続メディア優先度・自動切替ロジックの実装
  - [ ] 画面切断時（タイムアウト処理）のウィンドウ配置自動復元処理の構築

- [ ] **Phase 6: リリース・セキュリティ検証**
  - [ ] Macアプリの Developer ID コード署名、公証（Notarization）プロセスの自動化
  - [ ] `Sparkle.framework` による自動アップデート機構の組み込み
  - [ ] PINコードによる初回接続ペアリングセキュリティの実装
