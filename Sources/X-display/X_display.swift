import Foundation
import CVirtualDisplay

@main
struct X_display {
    static func main() {
        print("==================================================")
        print("  macOS Virtual Display Creator PoC (Private API) ")
        print("==================================================")
        
        let helper = CVirtualDisplayHelper.shared()
        
        do {
            print("[*] Creating 1920x1080 virtual display...")
            
            // Objective-C methods mapped to throwing swift functions
            try helper.createVirtualDisplay(withWidth: 1920, height: 1080)
            
            print("[+] Virtual display created successfully!")
            print("[!] Please check: macOS System Settings -> Displays")
            print("[*] Press [ENTER] key to destroy the display and exit...")
            
            _ = readLine()
            
        } catch {
            print("[-] Error occurred: \(error.localizedDescription)")
        }
        
        print("[*] Destroying virtual display and releasing resources...")
        helper.destroyVirtualDisplay()
        print("[+] Terminated successfully.")
    }
}
