# NFR: 非機能要件

## Latency
- 目標: glass-to-glass latency <= 16ms
- 許容: <= 33ms
- NG: > 50ms が3秒以上継続

## Stability
- 連続接続: 30分以上
- 再接続成功率: 95%以上
- クラッシュ: P0操作中 0件

## Recovery
- SCStream停止検知: 500ms以内
- SCStream再生成: 2秒以内
- USB/Wi-Fi切替: 3秒以内
- sleep/wake復帰: 2秒以内

## Resource
- idle CPU: 5%以下
- streaming CPU: 25%以下
- memory leak: 10MB/hour 以下
- thermal warning時: bitrateまたはfpsを下げる

## UX
- 権限不足時はアプリを落とさない
- 復旧中は状態表示する
- Fatal時は原因と次操作を表示する

## Benchmark Environment

- Host: M3 Max
- Client: iPad Pro M4
- Resolution: 1920x1080
- Codec: H264
- Transport: USB
- Refresh Rate: 60fps