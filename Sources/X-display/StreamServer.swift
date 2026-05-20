import Foundation
import Network

final class StreamServer: @unchecked Sendable {
    private var listener: NWListener?
    private var activeConnections: [UUID: NWConnection] = [:]
    private let connectionQueue = DispatchQueue(label: "com.xdisplay.server.connection-queue", qos: .userInteractive)
    
    func start(port: UInt16) throws {
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let parameters = NWParameters.tcp
        
        // Disable Nagle's algorithm to enforce ultra-low latency
        if let tcpOpt = parameters.defaultProtocolStack.applicationProtocols.first as? NWProtocolTCP.Options {
            tcpOpt.noDelay = true // Enable TCP_NODELAY
        }
        
        listener = try NWListener(using: parameters, on: nwPort)
        
        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[+] StreamServer is ready on port \(port)")
            case .failed(let error):
                print("[-] StreamServer failed: \(error.localizedDescription)")
            default:
                break
            }
        }
        
        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }
        
        listener?.start(queue: connectionQueue)
    }
    
    func stop() {
        listener?.cancel()
        listener = nil
        
        connectionQueue.async { [weak self] in
            guard let self = self else { return }
            for connection in self.activeConnections.values {
                connection.cancel()
            }
            self.activeConnections.removeAll()
            print("[+] StreamServer stopped.")
        }
    }
    
    private func handleNewConnection(_ connection: NWConnection) {
        let id = UUID()
        connectionQueue.async { [weak self] in
            guard let self = self else { return }
            self.activeConnections[id] = connection
            print("[+] Client connected! Total clients: \(self.activeConnections.count)")
            
            connection.stateUpdateHandler = { state in
                switch state {
                case .failed(let error):
                    print("[-] Connection failed: \(error.localizedDescription)")
                    self.removeConnection(id: id)
                case .cancelled:
                    print("[*] Connection cancelled.")
                    self.removeConnection(id: id)
                default:
                    break
                }
            }
            connection.start(queue: self.connectionQueue)
        }
    }
    
    private func removeConnection(id: UUID) {
        connectionQueue.async { [weak self] in
            guard let self = self else { return }
            if let connection = self.activeConnections.removeValue(forKey: id) {
                connection.cancel()
                print("[-] Client disconnected. Total clients: \(self.activeConnections.count)")
            }
        }
    }
    
    func broadcast(data: Data) {
        connectionQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.activeConnections.isEmpty else { return }
            
            // Format packet: [4-Byte Payload Size] + [Data]
            var packet = Data()
            var size = UInt32(data.count).bigEndian
            withUnsafeBytes(of: &size) { packet.append(contentsOf: $0) }
            packet.append(data)
            
            for (id, connection) in self.activeConnections {
                connection.send(content: packet, completion: .contentProcessed({ error in
                    if let error = error {
                        print("[-] Send failed to \(id): \(error.localizedDescription)")
                    }
                }))
            }
        }
    }
}
