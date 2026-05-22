#if os(macOS)
import Foundation
import Cocoa
import CoreGraphics
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
@discardableResult
func _AXUIElementGetWindow(_ element: AXUIElement, _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError

final class WindowLayoutRestorer: @unchecked Sendable {
    private struct SavedWindow {
        let windowID: CGWindowID
        let ownerPID: pid_t
        let originalFrame: CGRect
    }
    
    private let lock = NSLock()
    private var savedWindows: [SavedWindow] = []
    
    /// 仮想ディスプレイ上にあるウィンドウの位置情報を保存する
    func saveLayout(forDisplayID displayID: CGDirectDisplayID) {
        lock.lock()
        defer { lock.unlock() }
        
        savedWindows.removeAll()
        let displayBounds = CGDisplayBounds(displayID)
        guard displayBounds.width > 0 && displayBounds.height > 0 else { return }
        
        // 画面上にある全てのウィンドウ情報を取得
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return
        }
        
        for info in windowList {
            guard let windowID = info[kCGWindowNumber as String] as? CGWindowID,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
                continue
            }
            
            // 仮想ディスプレイの領域と交差しているウィンドウを対象とする
            if frame.intersects(displayBounds) {
                savedWindows.append(SavedWindow(windowID: windowID, ownerPID: ownerPID, originalFrame: frame))
                print("[WindowRestorer] Saved window ID: \(windowID) from PID: \(ownerPID) frame: \(frame)")
            }
        }
    }
    
    /// 保存したウィンドウをメインディスプレイに安全に退避する
    func restoreLayoutToMainDisplay() {
        lock.lock()
        let windowsToRestore = savedWindows
        savedWindows.removeAll()
        lock.unlock()
        
        guard !windowsToRestore.isEmpty else { return }
        let mainBounds = CGDisplayBounds(CGMainDisplayID())
        guard mainBounds.width > 0 && mainBounds.height > 0 else { return }
        
        for saved in windowsToRestore {
            moveWindowToMainDisplay(saved, mainBounds: mainBounds)
        }
    }
    
    private func moveWindowToMainDisplay(_ saved: SavedWindow, mainBounds: CGRect) {
        let appRef = AXUIElementCreateApplication(saved.ownerPID)
        var windowListRef: CFTypeRef?
        
        guard AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowListRef) == .success,
              let windows = windowListRef as? [AXUIElement] else {
            return
        }
        
        for window in windows {
            var id: CGWindowID = 0
            let err = _AXUIElementGetWindow(window, &id)
            if err == .success && id == saved.windowID {
                // メイン画面の安全な領域（中央）に移動
                let newWidth = min(saved.originalFrame.width, mainBounds.width * 0.8)
                let newHeight = min(saved.originalFrame.height, mainBounds.height * 0.8)
                let newX = mainBounds.origin.x + (mainBounds.width - newWidth) / 2
                let newY = mainBounds.origin.y + (mainBounds.height - newHeight) / 2
                
                var position = CGPoint(x: newX, y: newY)
                var size = CGSize(width: newWidth, height: newHeight)
                
                if let posVal = AXValueCreate(.cgPoint, &position),
                   let sizeVal = AXValueCreate(.cgSize, &size) {
                    AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posVal)
                    AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeVal)
                    print("[WindowRestorer] Restored window ID: \(id) to main display.")
                }
                break
            }
        }
    }
}
#endif
