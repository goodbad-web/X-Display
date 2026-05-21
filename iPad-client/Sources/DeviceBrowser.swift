import Foundation
import Network
import XDisplayShared

enum ConnectionType: String {
    case wired = "Wired"
    case wireless = "Wireless"
}

struct DiscoveredDevice: Identifiable, Hashable {
    let id: String // Device unique identifier
    let name: String
    let endpoint: NWEndpoint
    let type: ConnectionType
}

class DeviceBrowser: ObservableObject {
    @Published var discoveredDevices: [DiscoveredDevice] = []
    private var browser: NWBrowser?
    private let browserQueue = DispatchQueue(label: "com.xdisplay.client.browser-queue", qos: .utility)
    
    func startBrowsing() {
        browserQueue.async { [weak self] in
            guard let self = self else { return }
            let parameters = NWParameters()
            let serviceType = NWBrowser.Descriptor.bonjour(type: XDisplayProtocol.bonjourServiceType, domain: "local.")
            
            let newBrowser = NWBrowser(for: serviceType, using: parameters)
            
            newBrowser.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("[+] Bonjour Browser is active and scanning...")
                case .failed(let error):
                    print("[-] Bonjour Browser failed: \(error.localizedDescription)")
                default:
                    break
                }
            }
            
            newBrowser.browseResultsChangedHandler = { [weak self] (results, changes) in
                guard let self = self else { return }
                
                var devices: [DiscoveredDevice] = []
                for result in results {
                    if case let .service(name, type, domain, _) = result.endpoint {
                        let isWired = result.interfaces.contains { $0.type == .wiredEthernet }
                        let connType: ConnectionType = isWired ? .wired : .wireless
                        let deviceId = "\(name).\(type).\(domain).\(connType.rawValue)"
                        devices.append(DiscoveredDevice(id: deviceId, name: name, endpoint: result.endpoint, type: connType))
                    }
                }
                
                DispatchQueue.main.async {
                    self.discoveredDevices = devices
                }
            }
            
            newBrowser.start(queue: self.browserQueue)
            self.browser = newBrowser
        }
    }
    
    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        DispatchQueue.main.async {
            self.discoveredDevices = []
        }
    }
}
