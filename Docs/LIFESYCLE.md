# Object Ownership Rules

## SCStream
- owner: CaptureManager
- create: startCapture()
- destroy: stopCapture()
- restart: recreate only on capture queue

## VTCompressionSession
- owner: Encoder
- invalidate before release
- never recreate on frame callback thread

## CVPixelBuffer
- retain only across async boundaries
- release immediately after encode

## Dual-Mode Loopback (Port & Resource Isolation)
- **Port Conflict Avoidance**: macOS上で送信側(Host)と受信側(Client)を同時起動する際、TCPリスナーポートと接続ポートが衝突しないよう、送信側はデフォルトポートを使用し、受信側は動的/選択型ポートにてバインドを完全に分離する。
- **Shared Memory Safety**: 同一プロセスで送受信双方が動く場合、同一の `CVPixelBuffer` に対する競合（書き込み中の読み出し等）を防ぐため、必ずコピーを作成するか別々のバッファプールでメモリを完全に独立させる。