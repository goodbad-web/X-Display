import Foundation
import Network
import CryptoKit

#if os(macOS)
protocol StreamServerDelegate: AnyObject {
    func streamServer(_ server: StreamServer, didReceiveInputEvent phase: UInt8, x: Float, y: Float, pressure: Float)
}

final class ClientSession: @unchecked Sendable {
    let id: UUID
    let connection: NWConnection
    var isPaired = false
    var sessionKey: SymmetricKey?
    let salt: Data
    let pin: String
    
    init(id: UUID, connection: NWConnection) {
        self.id = id
        self.connection = connection
        
        // Generate 4-digit PIN
        self.pin = String(format: "%04d", Int.random(in: 0...9999))
        
        // Generate random 16-byte salt
        var saltBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &saltBytes)
        self.salt = Data(saltBytes)
    }
}

final class StreamServer: @unchecked Sendable {
    weak var delegate: StreamServerDelegate?
    private var listener: NWListener?
    private var activeConnections: [UUID: ClientSession] = [:]
    private let connectionQueue = DispatchQueue(label: "com.xdisplay.server.connection-queue", qos: .userInteractive)
    private let timingLock = NSLock()
    private var broadcastCount = 0
    private var broadcastTotalNs: UInt64 = 0
    
    func start(port: UInt16) throws {
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let parameters = NWParameters.tcp
        
        // Disable Nagle's algorithm to enforce ultra-low latency
        if let tcpOpt = parameters.defaultProtocolStack.applicationProtocols.first as? NWProtocolTCP.Options {
            tcpOpt.noDelay = true // Enable TCP_NODELAY
        }
        
        listener = try NWListener(using: parameters, on: nwPort)
        
        // Broadcast via Bonjour
        listener?.service = NWListener.Service(name: "X-Display Host", type: "_xdisplay._tcp")
        
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
            for session in self.activeConnections.values {
                session.connection.cancel()
            }
            self.activeConnections.removeAll()
            print("[+] StreamServer stopped.")
        }
    }
    
    private func handleNewConnection(_ connection: NWConnection) {
        let id = UUID()
        connectionQueue.async { [weak self] in
            guard let self = self else { return }
            
            let session = ClientSession(id: id, connection: connection)
            self.activeConnections[id] = session
            
            print("\n" + String(repeating: "*", count: 40))
            print("[***] NEW CLIENT PENDING PAIRING!")
            print("[***] ENTER THIS PIN ON YOUR IPAD: \(session.pin)")
            print(String(repeating: "*", count: 40) + "\n")
            
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
            
            // Send pairing request immediately (0x02 + 16-byte Salt)
            var authRequest = Data()
            var magic: UInt8 = 0x02
            authRequest.append(&magic, count: 1)
            authRequest.append(session.salt)
            self.sendPacket(authRequest, to: connection)
            
            // Start receiving packets
            self.startReceiving(session)
        }
    }
    
    private func sendPacket(_ payload: Data, to connection: NWConnection) {
        var packet = Data()
        var size = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &size) { packet.append(contentsOf: $0) }
        packet.append(payload)
        
        connection.send(content: packet, completion: .contentProcessed({ error in
            if let error = error {
                print("[-] Server failed to send packet: \(error.localizedDescription)")
            }
        }))
    }
    
    private func startReceiving(_ session: ClientSession) {
        // Read 4-byte size header
        session.connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] (data, context, isComplete, error) in
            guard let self = self else { return }
            if let error = error {
                print("[-] Server receive failed for \(session.id): \(error.localizedDescription)")
                self.removeConnection(id: session.id)
                return
            }
            
            guard let data = data, data.count == 4 else {
                if isComplete {
                    self.removeConnection(id: session.id)
                } else {
                    self.startReceiving(session)
                }
                return
            }
            
            let payloadSize = data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            self.receivePayload(session, size: Int(payloadSize))
        }
    }
    
    private func receivePayload(_ session: ClientSession, size: Int) {
        guard size > 0 else {
            self.startReceiving(session)
            return
        }
        
        session.connection.receive(minimumIncompleteLength: size, maximumLength: size) { [weak self] (data, context, isComplete, error) in
            guard let self = self else { return }
            if let error = error {
                print("[-] Server receive payload failed: \(error.localizedDescription)")
                self.removeConnection(id: session.id)
                return
            }
            
            guard let data = data, data.count == size else {
                if isComplete {
                    self.removeConnection(id: session.id)
                } else {
                    self.startReceiving(session)
                }
                return
            }
            
            self.handleIncomingPayload(data, session: session)
            
            // Wait for next packet
            self.startReceiving(session)
        }
    }
    
    private func handleIncomingPayload(_ data: Data, session: ClientSession) {
        guard data.count > 0 else { return }
        let magic = data[0]
        
        switch magic {
        case 0x03: // Verification Attempt (iPad -> Mac)
            // Payload: [0x03] + [Encrypted verification token]
            let encryptedToken = data.subdata(in: 1..<data.count)
            let derivedKey = CryptoHelper.deriveKey(pin: session.pin, salt: session.salt)
            
            do {
                let decryptedData = try CryptoHelper.decrypt(combinedData: encryptedToken, key: derivedKey)
                if let decryptedString = String(data: decryptedData, encoding: .utf8), decryptedString == "SUCCESS" {
                    print("[+] PIN Pairing Successful! Session is now encrypted.")
                    session.isPaired = true
                    session.sessionKey = derivedKey
                    
                    // Reply with success status: [0x04] + [1]
                    let reply = Data([0x04, 1])
                    self.sendPacket(reply, to: session.connection)
                } else {
                    throw NSError(domain: "AuthError", code: -1, userInfo: nil)
                }
            } catch {
                print("[-] PIN Pairing Failed. Invalid PIN submitted by client.")
                // Reply with failure status: [0x04] + [0]
                let reply = Data([0x04, 0])
                self.sendPacket(reply, to: session.connection)
                self.removeConnection(id: session.id)
            }
            
        case 0x11: // Encrypted input event (iPad -> Mac)
            guard session.isPaired, let key = session.sessionKey else {
                print("[-] Warning: Received input event from unauthenticated client.")
                return
            }
            
            let encryptedEvent = data.subdata(in: 1..<data.count)
            do {
                let decryptedEvent = try CryptoHelper.decrypt(combinedData: encryptedEvent, key: key)
                self.parseAndDispatchInput(decryptedEvent)
            } catch {
                print("[-] Error decrypting client input event: \(error.localizedDescription)")
            }
            
        default:
            print("[-] Unknown package magic received: \(magic)")
        }
    }
    
    private func parseAndDispatchInput(_ data: Data) {
        // Minimum payload size: magic(1) + phase(1) + X(4) + Y(4) + pressure(4) = 14 bytes
        guard data.count >= 14 else { return }
        
        let identifier = data[0]
        guard identifier == 0x01 else { return } // Not a valid touch input event
        
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
            if let session = self.activeConnections.removeValue(forKey: id) {
                session.connection.cancel()
                print("[-] Client disconnected. Total clients: \(self.activeConnections.count)")
            }
        }
    }
    
    func broadcast(data: Data) {
        connectionQueue.async { [weak self] in
            guard let self = self else { return }
            let start = DispatchTime.now().uptimeNanoseconds
            let pairedSessions = self.activeConnections.values.filter { $0.isPaired && $0.sessionKey != nil }
            guard !pairedSessions.isEmpty else { return }
            
            for session in pairedSessions {
                guard let key = session.sessionKey else { continue }
                
                do {
                    // Encrypt NAL unit video data
                    let encryptedData = try CryptoHelper.encrypt(data: data, key: key)
                    
                    // Format packet: [0x10] + [Encrypted Data]
                    var payload = Data()
                    var magic: UInt8 = 0x10
                    payload.append(&magic, count: 1)
                    payload.append(encryptedData)
                    
                    self.sendPacket(payload, to: session.connection)
                } catch {
                    print("[-] Failed to encrypt video frame: \(error.localizedDescription)")
                }
            }

            let elapsedNs = DispatchTime.now().uptimeNanoseconds - start
            self.timingLock.lock()
            self.broadcastCount += 1
            self.broadcastTotalNs += elapsedNs
            let shouldLog = self.broadcastCount % 60 == 0
            let averageMs = Double(self.broadcastTotalNs) / Double(self.broadcastCount) / 1_000_000.0
            self.timingLock.unlock()
            if shouldLog {
                let elapsedMs = Double(elapsedNs) / 1_000_000.0
                print(String(format: "[Timing] broadcast: %.2f ms (avg %.2f ms)", elapsedMs, averageMs))
            }
        }
    }
}
#endif
