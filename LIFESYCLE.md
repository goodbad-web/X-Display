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