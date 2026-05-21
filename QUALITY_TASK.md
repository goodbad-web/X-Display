# QUALITY_TASK: 製品品質チェックリスト

## P0: 必須
- [ ] 30分連続接続でクラッシュなし
- [ ] iPad再接続- [ ] iPad再接続を10回連続成功
  - reconnect <= 3 sec
  - black screen なし
  - input restore 成功を10回連続で成功
- [x] iPad拡張画面の入力安定化
- [ ] Mac sleep/wake後に2秒以内で復帰
- [ ] USB抜き差し後に自動再接続
- [ ] Wi-Fi切断後に安全にIdleへ戻る
- [ ] SCStream停止時に自動restart
- [ ] 仮想ディスプレイ破棄後にウィンドウ配置を復元
- [ ] メモリ増加 10MB/hour 以下
- [ ] idle CPU 5%以下
- [ ] 画面収録権限なし時に明確な案内表示

## P1: 推奨
- [x] 解像度変更中にクラッシュしない
- [ ] iPad回転時に描画破綻しない
- [ ] エンコーダ詰まり時に復旧
- [ ] bitrate低下時にDegraded表示
- [ ] Metal描画停止時に再初期化

## P2: 後回し
- [ ] 詳細ログexport
- [ ] ユーザー診断レポート生成