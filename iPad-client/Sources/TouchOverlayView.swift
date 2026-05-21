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
    var onScrollEvent: ((Float, Float, Float, Float) -> Void)? = nil
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
        var onScrollEvent: ((Float, Float, Float, Float) -> Void)?
        var onRightClickEvent: ((Float, Float) -> Void)?
        var onPencilEvent: ((XDisplayPencilEvent) -> Void)?
        var onPencilInteractionEvent: ((XDisplayPencilInteractionEvent) -> Void)?
        
        private var lastPanTranslation: CGPoint = .zero
        private var activePencilTouch: UITouch?
        /// 1本指が最初に接地した正規化座標（pan .began 時の mouseDown 位置補正用）
        private var fingerDownNormalized: CGPoint?
        
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

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesBegan(touches, with: event)
            if let touch = touches.first(where: { $0.type == .pencil }) {
                activePencilTouch = touch
            }
            // 既存の指を含めて複数本の指が接触している場合はクリア
            let allTouches = event?.allTouches ?? []
            let fingerTouches = allTouches.filter { $0.type != .pencil && ($0.phase == .began || $0.phase == .moved || $0.phase == .stationary) }
            
            if fingerTouches.count == 1,
               let touch = fingerTouches.first {
                let loc = touch.location(in: self)
                let b = bounds
                if b.width > 0 && b.height > 0 {
                    fingerDownNormalized = CGPoint(
                        x: max(0, min(1, loc.x / b.width)),
                        y: max(0, min(1, loc.y / b.height))
                    )
                }
            } else {
                fingerDownNormalized = nil
            }
        }
        
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesMoved(touches, with: event)
            if let touch = touches.first(where: { $0.type == .pencil }) {
                activePencilTouch = touch
            }
        }
        
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesEnded(touches, with: event)
            if touches.contains(where: { $0.type == .pencil }) {
                activePencilTouch = nil
            }
            fingerDownNormalized = nil
        }
        
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesCancelled(touches, with: event)
            if touches.contains(where: { $0.type == .pencil }) {
                activePencilTouch = nil
            }
            fingerDownNormalized = nil
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
            let pencilInteraction: UIPencilInteraction
            if #available(iOS 17.5, *) {
                pencilInteraction = UIPencilInteraction(delegate: self)
            } else {
                pencilInteraction = UIPencilInteraction()
                pencilInteraction.delegate = self
            }
            addInteraction(pencilInteraction)
        }
        
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // hoverGestureはPencilホバー専用。通常タッチ系ジェスチャとの同時認識は不要。
            if gestureRecognizer is UIHoverGestureRecognizer || otherGestureRecognizer is UIHoverGestureRecognizer {
                return false
            }
            return true
        }
        
        private func getPencilEvent(from gesture: UIGestureRecognizer, phase: XDisplayTouchPhase) -> XDisplayPencilEvent? {
            guard let touch = activePencilTouch else {
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

            let normX: Float
            let normY: Float

            if gesture.state == .began, let down = fingerDownNormalized {
                // pan 判定完了前の真の接地点を mouseDown 位置として使う
                normX = Float(down.x)
                normY = Float(down.y)
                fingerDownNormalized = nil
            } else {
                let location = gesture.location(in: self)
                let b = bounds
                guard b.width > 0 && b.height > 0 else { return }
                normX = Float(max(0, min(1, location.x / b.width)))
                normY = Float(max(0, min(1, location.y / b.height)))
            }

            let pressure: Float = (gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed) ? 0.0 : 1.0
            onTouchEvent(TouchEvent(phase: phase, x: normX, y: normY, pressure: pressure))
        }
        
        @objc private func handleTwoFingerPan(_ gesture: UIPanGestureRecognizer) {
            fingerDownNormalized = nil
            
            guard let onScrollEvent = onScrollEvent else { return }

            let translation = gesture.translation(in: self)
            let location = gesture.location(in: self)
            let b = bounds

            switch gesture.state {
            case .began:
                lastPanTranslation = translation
            case .changed:
                let deltaX = Float(translation.x - lastPanTranslation.x)
                let deltaY = Float(translation.y - lastPanTranslation.y)
                if abs(deltaX) > 0.1 || abs(deltaY) > 0.1 {
                    let normX = b.width  > 0 ? Float(max(0, min(1, location.x / b.width)))  : 0.5
                    let normY = b.height > 0 ? Float(max(0, min(1, location.y / b.height))) : 0.5
                    onScrollEvent(deltaX, deltaY, normX, normY)
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
        
        @available(iOS 17.5, *)
        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
            guard let onPencilInteractionEvent = onPencilInteractionEvent else { return }
            onPencilInteractionEvent(XDisplayPencilInteractionEvent(type: .doubleTap))
        }
        
        @available(iOS 17.5, *)
        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
            guard let onPencilInteractionEvent = onPencilInteractionEvent else { return }
            onPencilInteractionEvent(XDisplayPencilInteractionEvent(type: .squeeze))
        }

        // Fallback double-tap support for iOS 17.0 ~ 17.4
        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            guard let onPencilInteractionEvent = onPencilInteractionEvent else { return }
            onPencilInteractionEvent(XDisplayPencilInteractionEvent(type: .doubleTap))
        }
    }
}



