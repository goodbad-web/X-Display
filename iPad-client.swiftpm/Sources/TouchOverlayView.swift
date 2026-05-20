import SwiftUI
import UIKit
import XDisplayShared

struct TouchEvent {
    let phase: XDisplayTouchPhase
    let x: Float // Normalized 0.0 ~ 1.0
    let y: Float // Normalized 0.0 ~ 1.0
    let pressure: Float // 0.0 ~ 1.0 (or force)
}

struct TouchOverlayView: UIViewRepresentable {
    var onTouchEvent: (TouchEvent) -> Void
    
    func makeUIView(context: Context) -> TouchCaptureUIView {
        let view = TouchCaptureUIView()
        view.onTouchEvent = onTouchEvent
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = false // Start with single-touch PoC
        return view
    }
    
    func updateUIView(_ uiView: TouchCaptureUIView, context: Context) {
        uiView.onTouchEvent = onTouchEvent
    }
    
    class TouchCaptureUIView: UIView {
        var onTouchEvent: ((TouchEvent) -> Void)?
        
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            handleTouches(touches, phase: .began)
        }
        
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            handleTouches(touches, phase: .moved)
        }
        
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            handleTouches(touches, phase: .ended)
        }
        
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            handleTouches(touches, phase: .cancelled)
        }
        
        private func handleTouches(_ touches: Set<UITouch>, phase: XDisplayTouchPhase) {
            guard let touch = touches.first, let onTouchEvent = onTouchEvent else { return }
            
            let location = touch.location(in: self)
            let bounds = self.bounds
            
            // Avoid division by zero
            guard bounds.width > 0 && bounds.height > 0 else { return }
            
            // Normalize coordinates between 0.0 and 1.0
            let normX = Float(max(0, min(1, location.x / bounds.width)))
            let normY = Float(max(0, min(1, location.y / bounds.height)))
            
            // Retrieve pressure (Pencil has high precision force, finger has 0.0/1.0)
            var pressure: Float = 1.0
            if touch.type == .pencil {
                // Maximum possible force is touch.maximumPossibleForce
                let maxForce = touch.maximumPossibleForce > 0 ? touch.maximumPossibleForce : 1.0
                pressure = Float(touch.force / maxForce)
            } else {
                pressure = phase == .ended || phase == .cancelled ? 0.0 : 1.0
            }
            
            let event = TouchEvent(phase: phase, x: normX, y: normY, pressure: pressure)
            onTouchEvent(event)
        }
    }
}
