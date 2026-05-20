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
    var onPencilEvent: ((XDisplayPencilEvent) -> Void)? = nil
    var onPencilInteractionEvent: ((XDisplayPencilInteractionEvent) -> Void)? = nil
    
    func makeUIView(context: Context) -> TouchCaptureUIView {
        let view = TouchCaptureUIView()
        view.onTouchEvent = onTouchEvent
        view.onScrollEvent = onScrollEvent
        view.onRightClickEvent = onRightClickEvent
        view.onPencilEvent = onPencilEvent
        view.onPencilInteractionEvent = onPencilInteractionEvent
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        return view
    }
    
    func updateUIView(_ uiView: TouchCaptureUIView, context: Context) {
        uiView.onTouchEvent = onTouchEvent
        uiView.onScrollEvent = onScrollEvent
        uiView.onRightClickEvent = onRightClickEvent
        uiView.onPencilEvent = onPencilEvent
        uiView.onPencilInteractionEvent = onPencilInteractionEvent
    }
    
    class TouchCaptureUIView: UIView, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
        var onTouchEvent: ((TouchEvent) -> Void)?
        var onScrollEvent: ((Float, Float) -> Void)?
        var onRightClickEvent: ((Float, Float) -> Void)?
        var onPencilEvent: ((XDisplayPencilEvent) -> Void)?
        var onPencilInteractionEvent: ((XDisplayPencilInteractionEvent) -> Void)?
        
        private var lastPanTranslation: CGPoint = .zero
        
        override init(frame: CGRect) {
            super.init(frame: frame)
            setupGestures()
            setupPencilInteraction()
        }
        
        required init?(coder: NSCoder) {
            super.init(coder: coder)
            setupGestures()
            setupPencilInteraction()
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
            
            // Pencil Hover Gesture
            let hoverGesture = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
            hoverGesture.delegate = self
            addGestureRecognizer(hoverGesture)
            
            // Priority setup to avoid click actions during scrolling or context-click actions
            singleTap.require(toFail: twoFingerTap)
            singlePan.require(toFail: twoFingerPan)
        }
        
        private func setupPencilInteraction() {
            let pencilInteraction = UIPencilInteraction(delegate: self)
            addInteraction(pencilInteraction)
        }
        
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            return true
        }
        
        private func getPencilEvent(from gesture: UIGestureRecognizer, phase: XDisplayTouchPhase) -> XDisplayPencilEvent? {
            guard let touch = gesture.touches(byTargeting: self)?.first, touch.type == .pencil else {
                return nil
            }
            
            let location = touch.location(in: self)
            let bounds = self.bounds
            guard bounds.width > 0 && bounds.height > 0 else { return nil }
            
            let normX = Float(max(0, min(1, location.x / bounds.width)))
            let normY = Float(max(0, min(1, location.y / bounds.height)))
            
            let pressure = Float(touch.maximumPossibleForce > 0 ? touch.force / touch.maximumPossibleForce : 1.0)
            
            let azimuth = touch.azimuthAngle(in: self)
            let altitude = touch.altitudeAngle
            let tiltX = Float(cos(azimuth) * cos(altitude))
            let tiltY = Float(sin(azimuth) * cos(altitude))
            
            let roll: Float
            if #available(iOS 17.5, *) {
                roll = Float(touch.rollAngle)
            } else {
                roll = 0.0
            }
            
            return XDisplayPencilEvent(
                phase: phase,
                x: normX,
                y: normY,
                pressure: pressure,
                tiltX: tiltX,
                tiltY: tiltY,
                roll: roll,
                isHover: false
            )
        }
        
        @objc private func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            
            if let onPencilEvent = onPencilEvent, let pencilEvent = getPencilEvent(from: gesture, phase: .ended) {
                // Began + Ended for tap
                let beganEvent = XDisplayPencilEvent(
                    phase: .began,
                    x: pencilEvent.x,
                    y: pencilEvent.y,
                    pressure: pencilEvent.pressure,
                    tiltX: pencilEvent.tiltX,
                    tiltY: pencilEvent.tiltY,
                    roll: pencilEvent.roll,
                    isHover: false
                )
                onPencilEvent(beganEvent)
                onPencilEvent(pencilEvent)
                return
            }
            
            guard let onTouchEvent = onTouchEvent else { return }
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
            let phase: XDisplayTouchPhase
            switch gesture.state {
            case .began: phase = .began
            case .changed: phase = .moved
            case .ended: phase = .ended
            case .cancelled, .failed: phase = .cancelled
            default: return
            }
            
            if let onPencilEvent = onPencilEvent, let pencilEvent = getPencilEvent(from: gesture, phase: phase) {
                onPencilEvent(pencilEvent)
                return
            }
            
            guard let onTouchEvent = onTouchEvent else { return }
            let location = gesture.location(in: self)
            let bounds = self.bounds
            guard bounds.width > 0 && bounds.height > 0 else { return }
            
            let normX = Float(max(0, min(1, location.x / bounds.width)))
            let normY = Float(max(0, min(1, location.y / bounds.height)))
            
            var pressure: Float = 1.0
            if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
                pressure = 0.0
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
        
        @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
            guard let onPencilEvent = onPencilEvent else { return }
            let location = gesture.location(in: self)
            let bounds = self.bounds
            guard bounds.width > 0 && bounds.height > 0 else { return }
            
            let normX = Float(max(0, min(1, location.x / bounds.width)))
            let normY = Float(max(0, min(1, location.y / bounds.height)))
            
            let phase: XDisplayTouchPhase
            switch gesture.state {
            case .began: phase = .began
            case .changed: phase = .moved
            case .ended, .cancelled, .failed: phase = .ended
            default: return
            }
            
            let event = XDisplayPencilEvent(
                phase: phase,
                x: normX,
                y: normY,
                pressure: 0.0,
                tiltX: 0.0,
                tiltY: 0.0,
                roll: 0.0,
                isHover: true
            )
            onPencilEvent(event)
        }
        
        // MARK: - UIPencilInteractionDelegate
        
        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
            guard let onPencilInteractionEvent = onPencilInteractionEvent else { return }
            onPencilInteractionEvent(XDisplayPencilInteractionEvent(type: .doubleTap))
        }
        
        @available(iOS 17.5, *)
        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
            guard let onPencilInteractionEvent = onPencilInteractionEvent else { return }
            onPencilInteractionEvent(XDisplayPencilInteractionEvent(type: .squeeze))
        }
    }
}



