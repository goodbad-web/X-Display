import Foundation
import Network

struct DiscoveredDevice: Identifiable, Hashable {
    let id: String // Device unique identifier
    let name: String
    let endpoint: NWEndpoint
}

class DeviceBrowser: ObservableObject {
    @Published var discoveredDevices: [DiscoveredDevice] = []
    private var browser: NWBrowser?
    private let browserQueue = DispatchQueue(label: "com.xdisplay.client.browser-queue", qos: .utility)
    
    func startBrowsing() {
        let parameters = NWParameters()
        let serviceType = NWBrowser.Descriptor.bonjour(type: "_xdisplay._tcp", domain: "local.")
        
        browser = NWBrowser(for: serviceType, using: parameters)
        
        browser?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[+] Bonjour Browser is active and scanning...")
            case .failed(let error):
                print("[-] Bonjour Browser failed: \(error.localizedDescription)")
            default:
                break
            }
        }
        
        browser?.browseResultsChangedHandler = { [weak self] (results, changes) in
            guard let self = self else { return }
            
            var devices: [DiscoveredDevice] = []
            for result in results {
                if case let .service(name, type, domain, _) = result.endpoint {
                    let deviceId = "\(name).\(type).\(domain)"
                    devices.append(DiscoveredDevice(id: deviceId, name: name, endpoint: result.endpoint))
                }
            }
            
            DispatchQueue.main.async {
                self.discoveredDevices = devices
            }
        }
        
        browser?.start(queue: browserQueue)
    }
    
    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        DispatchQueue.main.async {
            self.discoveredDevices = []
        }
    }
}
