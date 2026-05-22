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

### 2.1 CGVirtualDisplay の動的ロードパターン (Objective-C)
プライベートシンボルのリンクを避けるため、実行時に `NSClassFromString` を用いて `CGVirtualDisplay` 関連クラスをロードし、仮想ディスプレイを動的に構築する標準パターンです。

```objc
- (BOOL)createVirtualDisplayWithLogicalWidth:(uint32_t)logicalWidth
                               logicalHeight:(uint32_t)logicalHeight
                                  pixelWidth:(uint32_t)pixelWidth
                                 pixelHeight:(uint32_t)pixelHeight
                                       hiDPI:(BOOL)hiDPI
                              pixelsPerInch:(double)pixelsPerInch
                                       error:(NSError **)outError {
    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    Class displayClass = NSClassFromString(@"CGVirtualDisplay");

    if (!descriptorClass || !modeClass || !settingsClass || !displayClass) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"CVirtualDisplay" code:1 userInfo:@{NSLocalizedDescriptionKey: @"CGVirtualDisplay private classes are not available."}];
        }
        return NO;
    }

    // ディスクリプタの初期化
    id descriptor = [[descriptorClass alloc] init];
    [descriptor setValue:@"X-Display Virtual Display" forKey:@"name"];
    [descriptor setValue:@(pixelWidth) forKey:@"maxPixelsWide"];
    [descriptor setValue:@(pixelHeight) forKey:@"maxPixelsHigh"];
    [descriptor setValue:dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0) forKey:@"queue"];
    
    // 設定とモードの初期化
    id settings = [[settingsClass alloc] init];
    [settings setValue:@(hiDPI ? 1 : 0) forKey:@"hiDPI"];

    // 解像度モードの作成（1920x1080@60Hz等）
    id mode = [[modeClass alloc] performSelector:@selector(initWithWidth:height:refreshRate:)
                                      withObject:@(logicalWidth)
                                      withObject:@(logicalHeight)
                                      withObject:@(60.0)];
    [settings setValue:@[mode] forKey:@"modes"];

    // ディスプレイの生成と設定反映
    id virtualDisplay = [[displayClass alloc] performSelector:@selector(initWithDescriptor:) withObject:descriptor];
    BOOL applied = [virtualDisplay performSelector:@selector(applySettings:) withObject:settings];
    
    if (!applied) {
        return NO;
    }
    
    _virtualDisplay = virtualDisplay; // インスタンスを保持
    return YES;
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
