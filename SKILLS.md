# SKILLS: プロジェクト技術ナレッジ・スキル集

本プロジェクトの開発およびメンテナンスに必要な主要スキル、コアAPIテンプレート、および設計ナレッジをまとめます。

---

## 1. 必須開発スキル (Required Engineering Skills)

| スキルカテゴリ | 主な利用フレームワーク・API | 重要コンセプト |
| :--- | :--- | :--- |
| **macOS システムプログラミング** | `AppleVirtualDisplay.framework` (Private API), `dlopen`, `NSInvocation`, Objective-C Runtime | プライベートフレームワークの安全な動的ロード、ARC所有権管理、メソッドシグネチャの動的解析。 |
| **超低遅延ストリーミング** | `ScreenCaptureKit`, `VideoToolbox`, `Metal`, `CVPixelBuffer` | ゼロコピーによるVRAM描画（CPUコピー回避）、H.264/HEVCリアルタイム圧縮、Bフレーム無効化（0フレーム遅延）。 |
| **デバイス間通信** | `Network.framework` (Bonjour/TCP), `USBMuxd` (有線TCPポート転送) | ローカル通信ソケット設計、`TCP_NODELAY`によるバッファ最小化、パケット輻輳制御。 |

---

## 2. API 実装テンプレート (Core API Code Patterns)

### 2.1 AppleVirtualDisplay の動的ロードパターン (Objective-C)
プライベートシンボルのリンクを避けるため、実行時に `dlopen` と `NSInvocation` を用いて仮想ディスプレイを動的に構築する標準パターンです。

```objc
// Dynamic creation helper
- (id)createDisplayWithWidth:(uint32_t)w height:(uint32_t)h error:(NSError **)err {
    Class controllerClass = NSClassFromString(@"AVDVirtualDisplayController");
    Class settingsClass = NSClassFromString(@"AVDVirtualDisplaySettings");
    if (!controllerClass || !settingsClass) return nil;

    id controller = [[controllerClass alloc] init];
    id settings = [[settingsClass alloc] init];
    [settings setValue:@(w) forKey:@"width"];
    [settings setValue:@(h) forKey:@"height"];

    SEL createSelector = NSSelectorFromString(@"createVirtualDisplayWithSettings:queue:error:");
    NSMethodSignature *sig = [controller methodSignatureForSelector:createSelector];
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:controller];
    [inv setSelector:createSelector];

    dispatch_queue_t queue = dispatch_get_main_queue();
    __autoreleasing NSError *creationError = nil;
    NSError *__autoreleasing *errPtr = &creationError;

    [inv setArgument:&settings atIndex:2];
    [inv setArgument:&queue atIndex:3];
    [inv setArgument:&errPtr atIndex:4];

    [inv invoke];
    __unsafe_unretained id displayResult = nil;
    [inv getReturnValue:&displayResult];
    
    if (err) *err = creationError;
    return displayResult;
}
```

### 2.2 ScreenCaptureKit ゼロコピーキャプチャ設定テンプレート (Swift)
`ScreenCaptureKit` を用いて、GPUメモリ（VRAM）に最適化したキャプチャを行う標準的な設定パラメータです。

```swift
import ScreenCaptureKit

func configureZeroCopyStream(display: SCDisplay) -> SCStreamConfiguration {
    let config = SCStreamConfiguration()
    
    // VRAM直接キャプチャ設定
    config.width = Int(display.width)
    config.height = Int(display.height)
    
    // ピクセルフォーマット（BGRA等、GPUに最適化したフォーマットを選択）
    config.pixelFormat = kCVPixelFormatType_32BGRA
    
    // 超低遅延オプション
    config.queueDepth = 3 // キュー深度を極小に（遅延を避ける）
    config.minimumFrameInterval = CMTime(value: 1, timescale: 60) // 60fpsターゲット
    
    return config
}
```

### 2.3 VideoToolbox ゼロレイテンシ圧縮設定テンプレート (Swift)
`VideoToolbox` でエンコード遅延を1ms以下に抑えるための最速エンコードプロパティの定義です。

```swift
import VideoToolbox

func configureZeroLatencyEncoder(session: VTCompressionSession) {
    // リアルタイムエンコードをONにする
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    
    // Bフレームを完全に無効化（遅延をなくす）
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 0 as CFNumber)
    
    // H.264 Baseline Profile などの低遅延向けのプロファイルを選択
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
}
```
