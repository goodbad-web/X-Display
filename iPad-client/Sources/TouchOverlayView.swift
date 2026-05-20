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
    var onScrollEvent: ((Float, Float) -> Void)? = nil
    var onRightClickEvent: ((Float, Float) -> Void)? = nil
    
    func makeUIView(context: Context) -> TouchCaptureUIView {
        let view = TouchCaptureUIView()
        view.onTouchEvent = onTouchEvent
        view.onScrollEvent = onScrollEvent
        view.onRightClickEvent = onRightClickEvent
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        return view
    }
    
    func updateUIView(_ uiView: TouchCaptureUIView, context: Context) {
        uiView.onTouchEvent = onTouchEvent
        uiView.onScrollEvent = onScrollEvent
        uiView.onRightClickEvent = onRightClickEvent
    }
    
    class TouchCaptureUIView: UIView, UIGestureRecognizerDelegate {
        var onTouchEvent: ((TouchEvent) -> Void)?
        var onScrollEvent: ((Float, Float) -> Void)?
        var onRightClickEvent: ((Float, Float) -> Void)?
        
        private var lastPanTranslation: CGPoint = .zero
        
        override init(frame: CGRect) {
            super.init(frame: frame)
            setupGestures()
        }
        
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setupGestures()
        }
        
        private func setupGestures() {
            // 1-finger Tap (Left Click)
            let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
            singleTap.numberOfTouchesRequired = 1
            singleTap.delegate = self
            addGestureRecognizer(singleTap)
            
            // 2-finger Tap (Right Click)
            let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
            twoFingerTap.numberOfTouchesRequired = 2
            twoFingerTap.delegate = self
            addGestureRecognizer(twoFingerTap)
            
            // 1-finger Pan (Drag / Move)
            let singlePan = UIPanGestureRecognizer(target: self, action: #selector(handleSinglePan(_:)))
            singlePan.minimumNumberOfTouches = 1
            singlePan.maximumNumberOfTouches = 1
            singlePan.delegate = self
            addGestureRecognizer(singlePan)
            
            // 2-finger Pan (Scroll)
            let twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
            twoFingerPan.minimumNumberOfTouches = 2
            twoFingerPan.maximumNumberOfTouches = 2
            twoFingerPan.delegate = self
            addGestureRecognizer(twoFingerPan)
            
            // Priority setup to avoid click actions during scrolling or context-click actions
            singleTap.require(toFail: twoFingerTap)
            singlePan.require(toFail: twoFingerPan)
        }
        
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            return true
        }
        
        @objc private func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            guard let onTouchEvent = onTouchEvent, gesture.state == .ended else { return }
            let location = gesture.location(in: self)
            let bounds = self.bounds
            guard bounds.width > 0 && bounds.height > 0 else { return }
            
            let normX = Float(max(0, min(1, location.x / bounds.width)))
            let normY = Float(max(0, min(1, location.y / bounds.height)))
            
            // Simulate mouse click on macOS side
            onTouchEvent(TouchEvent(phase: .began, x: normX, y: normY, pressure: 1.0))
            onTouchEvent(TouchEvent(phase: .ended, x: normX, y: normY, pressure: 0.0))
        }
        
        @objc private func handleTwoFingerTap(_ gesture: UITapGestureRecognizer) {
            guard let onRightClickEvent = onRightClickEvent, gesture.state == .ended else { return }
            let location = gesture.location(in: self)
            let bounds = self.bounds
            guard bounds.width > 0 && bounds.height > 0 else { return }
            
            let normX = Float(max(0, min(1, location.x / bounds.width)))
            let normY = Float(max(0, min(1, location.y / bounds.height)))
            
            onRightClickEvent(normX, normY)
        }
        
        @objc private func handleSinglePan(_ gesture: UIPanGestureRecognizer) {
            guard let onTouchEvent = onTouchEvent else { return }
            let location = gesture.location(in: self)
            let bounds = self.bounds
            guard bounds.width > 0 && bounds.height > 0 else { return }
            
            let normX = Float(max(0, min(1, location.x / bounds.width)))
            let normY = Float(max(0, min(1, location.y / bounds.height)))
            
            let phase: XDisplayTouchPhase
            var pressure: Float = 1.0
            
            switch gesture.state {
            case .began:
                phase = .began
            case .changed:
                phase = .moved
            case .ended:
                phase = .ended
                pressure = 0.0
            case .cancelled, .failed:
                phase = .cancelled
                pressure = 0.0
            default:
                return
            }
            
            onTouchEvent(TouchEvent(phase: phase, x: normX, y: normY, pressure: pressure))
        }
        
        @objc private func handleTwoFingerPan(_ gesture: UIPanGestureRecognizer) {
            guard let onScrollEvent = onScrollEvent else { return }
            
            let translation = gesture.translation(in: self)
            
            switch gesture.state {
            case .began:
                lastPanTranslation = translation
            case .changed:
                let deltaX = Float(translation.x - lastPanTranslation.x)
                let deltaY = Float(translation.y - lastPanTranslation.y)
                if abs(deltaX) > 0.1 || abs(deltaY) > 0.1 {
                    onScrollEvent(deltaX, deltaY)
                }
                lastPanTranslation = translation
            default:
                lastPanTranslation = .zero
            }
        }
    }
}


