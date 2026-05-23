# AGENTS: AI 開発エージェント協調定義書

## 1. エージェント定義と役割分担
本プロジェクトの開発に関わるAIエージェントの役割分担を定義します。

| エージェント | 役割 | 担当スコープ | 関連ドキュメント |
| :--- | :--- | :--- | :--- |
| **Antigravity (メイン)** | 設計統括・Swiftメイン実装 | システム設計、ホスト・クライアントのソースコード実装、トラブルシューティング。 | [PLAN.md](file:///Users/hiroshi/Developer/X-display/Docs/PLAN.md), [ARCHITECTURE.md](file:///Users/hiroshi/Developer/X-display/Docs/ARCHITECTURE.md) |
| **Research (サブ)** | 技術調査・ドキュメント要約 | macOS/iOSプライベートAPIの仕様調査、不具合情報の解析。 | [SKILLS.md](file:///Users/hiroshi/Developer/X-display/Docs/SKILLS.md) |
| **Self (サブ)** | コンテキスト分岐実行 | 大規模リファクタリングの試行や局所的なプロトタイプ記述など、独立したタスク実行。 | [TASK.md](file:///Users/hiroshi/Developer/X-display/Docs/TASK.md) |
| **BUILD_AGENT (サブ)** | ビルド自動化・環境構築 | コンパイル可能性の維持、XcodeGen設定管理、エラー自動修復。 | [BUILD_AGENT.md](file:///Users/hiroshi/Developer/X-display/Docs/BUILD_AGENT.md) |
| **TEST_AGENT (サブ)** | テスト自動化・品質保証 | テストコード生成・実行、回帰バグ防止、非機能要件のベンチマーク検証。 | [TEST_AGENT.md](file:///Users/hiroshi/Developer/X-display/Docs/TEST_AGENT.md), [BUG.md](file:///Users/hiroshi/Developer/X-display/Docs/BUG.md) |

---

## 2. 協調と情報同期ルール
- **コンテキスト共有**: 開発の状況、バグトラッキング、今後の計画は常に [PLAN.md](file:///Users/hiroshi/Developer/X-display/Docs/PLAN.md), [BUG.md](file:///Users/hiroshi/Developer/X-display/Docs/BUG.md), [TASK.md](file:///Users/hiroshi/Developer/X-display/Docs/TASK.md) に最新化し、エージェント間で「これらのドキュメントを真っ先に読み込む」ことでコンテキストを同期する。
- **品質・ビルドのガードレール**: 
  - コード変更時は必ず [BUILD_AGENT.md](file:///Users/hiroshi/Developer/X-display/Docs/BUILD_AGENT.md) のフローに基づきビルド適合性を確認。
  - リリースやマージ前には [TEST_AGENT.md](file:///Users/hiroshi/Developer/X-display/Docs/TEST_AGENT.md) にてテストパスおよび [NFR.md](file:///Users/hiroshi/Developer/X-display/Docs/NFR.md) (非機能要件) の基準を満たしているかチェックする。
- **ドキュメントの整合性**: コード内のドキュメントコメント、および設計書や仕様書（[UI_SPEC.md](file:///Users/hiroshi/Developer/X-display/Docs/UI_SPEC.md) 等）との齟齬を発生させない。
- **マルチプラットフォームターゲット同期**: 送受信の一本化ターゲット開発時には、iOSターゲットでのPrivate API混入を防ぐための境界（`#if os(macOS)` 等）の維持に全エージェントが細心の注意を払う。

---

## 3. 管理ドキュメント一覧 (Docs/ 内)
本プロジェクトで活用する各種仕様・管理ドキュメントは `Docs/` フォルダ配下に整理されています。各エージェントは変更や調査の際、これらのファイルを優先的に読み込みます。

### 仕様・設計・規則
- [UI_SPEC.md](file:///Users/hiroshi/Developer/X-display/Docs/UI_SPEC.md): UI画面仕様、インタラクション設計、デザインシステム
- [ARCHITECTURE.md](file:///Users/hiroshi/Developer/X-display/Docs/ARCHITECTURE.md): システム構造、Dual-Modeアーキテクチャ、コンポーネント設計
- [LIFESYCLE.md](file:///Users/hiroshi/Developer/X-display/Docs/LIFESYCLE.md): オブジェクト所有権、CVPixelBufferなどのメモリ解放規則

### エージェント仕様・スキル
- [BUILD_AGENT.md](file:///Users/hiroshi/Developer/X-display/Docs/BUILD_AGENT.md): ビルド自動化、環境構築エージェント仕様
- [TEST_AGENT.md](file:///Users/hiroshi/Developer/X-display/Docs/TEST_AGENT.md): 自動テスト、カバレッジ、品質保証エージェント仕様
- [SKILLS.md](file:///Users/hiroshi/Developer/X-display/Docs/SKILLS.md): メイン・サブエージェントが備えるべきスキルとコマンド仕様

### タスク・計画・バグ追跡
- [PLAN.md](file:///Users/hiroshi/Developer/X-display/Docs/PLAN.md): 開発ロードマップ、機能追加ロードプラン
- [TASK.md](file:///Users/hiroshi/Developer/X-display/Docs/TASK.md): 実装タスク、作業進捗、およびTODOリスト
- [BUG.md](file:///Users/hiroshi/Developer/X-display/Docs/BUG.md): 既知のバグトラッキング、問題分析、解決状況
- [QUALITY_TASK.md](file:///Users/hiroshi/Developer/X-display/Docs/QUALITY_TASK.md): 品質改善、リファクタリング、技術負債解消タスク

### 非機能要件・計測方針
- [NFR.md](file:///Users/hiroshi/Developer/X-display/Docs/NFR.md): 非機能要件（遅延目標、CPU/メモリ制限値、ベンチマーク環境）
- [OBSERVABILITY.md](file:///Users/hiroshi/Developer/X-display/Docs/OBSERVABILITY.md): オブザーバビリティ、パフォーマンスメトリクス計測、ロギング方針

---
