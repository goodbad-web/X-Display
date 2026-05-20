import Foundation
import Network

#if os(macOS)
protocol StreamServerDelegate: AnyObject {
    func streamServer(_ server: StreamServer, didReceiveInputEvent phase: UInt8, x: Float, y: Float, pressure: Float)
}

final class StreamServer: @unchecked Sendable {
    weak var delegate: StreamServerDelegate?
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
            
            // Start receiving input events from client
            self.startReceiving(connection, id: id)
        }
    }
    
    private func startReceiving(_ connection: NWConnection, id: UUID) {
        // Read 4-byte size header
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] (data, context, isComplete, error) in
            guard let self = self else { return }
            if let error = error {
                print("[-] Server receive failed for \(id): \(error.localizedDescription)")
                self.removeConnection(id: id)
                return
            }
            
            guard let data = data, data.count == 4 else {
                if isComplete {
                    self.removeConnection(id: id)
                } else {
                    self.startReceiving(connection, id: id)
                }
                return
            }
            
            let payloadSize = data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            self.receivePayload(connection, id: id, size: Int(payloadSize))
        }
    }
    
    private func receivePayload(_ connection: NWConnection, id: UUID, size: Int) {
        guard size > 0 else {
            self.startReceiving(connection, id: id)
            return
        }
        
        connection.receive(minimumIncompleteLength: size, maximumLength: size) { [weak self] (data, context, isComplete, error) in
            guard let self = self else { return }
            if let error = error {
                print("[-] Server receive payload failed: \(error.localizedDescription)")
                self.removeConnection(id: id)
                return
            }
            
            guard let data = data, data.count == size else {
                if isComplete {
                    self.removeConnection(id: id)
                } else {
                    self.startReceiving(connection, id: id)
                }
                return
            }
            
            self.parseAndDispatchInput(data)
            
            // Wait for next packet
            self.startReceiving(connection, id: id)
        }
    }
    
    private func parseAndDispatchInput(_ data: Data) {
        // Minimum payload size: magic(1) + phase(1) + X(4) + Y(4) + pressure(4) = 14 bytes
        guard data.count >= 14 else { return }
        
        let identifier = data[0]
        guard identifier == 0x01 else { return } // Not an input event
        
        let rawPhase = data[1]
        
        // Extract X, Y, Pressure (Float from bigEndian bitPattern)
        let xBits = data.subdata(in: 2..<6).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let yBits = data.subdata(in: 6..<10).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let pressureBits = data.subdata(in: 10..<14).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        
        let x = Float(bitPattern: xBits)
        let y = Float(bitPattern: yBits)
        let pressure = Float(bitPattern: pressureBits)
        
        delegate?.streamServer(self, didReceiveInputEvent: rawPhase, x: x, y: y, pressure: pressure)
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
#endif
