import Foundation
import Network
import CryptoKit
import XDisplayShared

#if os(macOS)
protocol StreamServerDelegate: AnyObject {
    func streamServer(_ server: StreamServer, didReceiveInputEvent phase: UInt8, x: Float, y: Float, pressure: Float)
    func streamServer(_ server: StreamServer, didReceiveScrollEvent deltaX: Float, deltaY: Float, x: Float, y: Float)
    func streamServer(_ server: StreamServer, didReceiveRightClickEvent x: Float, y: Float)
    func streamServer(_ server: StreamServer, didReceivePencilEvent event: XDisplayPencilEvent)
    func streamServer(_ server: StreamServer, didReceivePencilInteractionEvent event: XDisplayPencilInteractionEvent)
    func streamServer(_ server: StreamServer, didReceiveKeyboardEvent event: XDisplayKeyboardEvent)
    func streamServer(_ server: StreamServer, didReceiveMouseEvent event: XDisplayMouseEvent)
    func streamServerDidCompletePairing(_ server: StreamServer)
    func streamServer(_ server: StreamServer, didGeneratePIN pin: String)
    func streamServer(_ server: StreamServer, didReceiveClientInfo event: XDisplayClientInfoEvent)
    func streamServer(_ server: StreamServer, didDiscoverDevices devices: [NWEndpoint])
    func streamServer(_ server: StreamServer, didRequestPINForSession sessionID: UUID)
}

final class ClientSession: @unchecked Sendable {
    let id: UUID
    let connection: NWConnection
    var isPaired = false
    var sessionKey: SymmetricKey?
    var salt: Data?
    let pin: String?
    let isInitiator: Bool
    var remoteServerID: UUID?
    
    init(id: UUID, connection: NWConnection, isInitiator: Bool = false) {
        self.id = id
        self.connection = connection
        self.isInitiator = isInitiator
        
        if isInitiator {
            self.pin = nil
            self.salt = nil
        } else {
            self.pin = String(format: "%04d", Int.random(in: 0...9999))
            var saltBytes = [UInt8](repeating: 0, count: XDisplayProtocol.saltLength)
            _ = SecRandomCopyBytes(kSecRandomDefault, XDisplayProtocol.saltLength, &saltBytes)
            self.salt = Data(saltBytes)
        }
    }
}

final class StreamServer: @unchecked Sendable {
    weak var delegate: StreamServerDelegate?
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var discoveredEndpoints: [NWEndpoint] = []
    private var activeConnections: [UUID: ClientSession] = [:]
    private let connectionQueue = DispatchQueue(label: "com.xdisplay.server.connection-queue", qos: .userInteractive)
    private let timingLock = NSLock()
    private var broadcastCount = 0
    private var broadcastTotalNs: UInt64 = 0
    private var broadcastMaxNs: UInt64 = 0
    private var lastBroadcastLogTime = Date()
    private var lastBroadcastCount = 0
    
    private let statusLock = NSLock()
    private var _hasActivePairedConnections = false
    private var _currentSentFPS: Double = 0.0
    
    private let serverID: UUID = {
        if let uuidString = UserDefaults.standard.string(forKey: "XDisplayServerID"),
           let uuid = UUID(uuidString: uuidString) {
            return uuid
        }
        let newUUID = UUID()
        UserDefaults.standard.set(newUUID.uuidString, forKey: "XDisplayServerID")
        return newUUID
    }()
    
    var hasActivePairedConnections: Bool {
        statusLock.lock()
        defer { statusLock.unlock() }
        return _hasActivePairedConnections
    }
    
    var currentSentFPS: Double {
        statusLock.lock()
        defer { statusLock.unlock() }
        return _currentSentFPS
    }
    
    func start(port: UInt16) throws {
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        
        // Disable Nagle's algorithm to enforce ultra-low latency
        if let tcpOpt = parameters.defaultProtocolStack.applicationProtocols.first as? NWProtocolTCP.Options {
            tcpOpt.noDelay = true // Enable TCP_NODELAY
        }
        
        listener = try NWListener(using: parameters, on: nwPort)
        
        // Broadcast via Bonjour
        listener?.service = NWListener.Service(name: "X-Display Host", type: XDisplayProtocol.bonjourServiceType)
        
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
            self.updateActiveConnectionsStatus()
            print("[+] StreamServer stopped.")
        }
    }
    
    func startBrowsing() {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        browser = NWBrowser(for: .bonjour(type: "_xdisplay-client._tcp", domain: "local."), using: parameters)
        
        browser?.browseResultsChangedHandler = { [weak self] results, changes in
            guard let self = self else { return }
            self.discoveredEndpoints = results.map { $0.endpoint }
            DispatchQueue.main.async {
                self.delegate?.streamServer(self, didDiscoverDevices: self.discoveredEndpoints)
            }
        }
        browser?.start(queue: connectionQueue)
    }
    
    func stopBrowsing() {
        browser?.cancel()
        browser = nil
    }
    
    func connect(to endpoint: NWEndpoint) {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        if let tcpOpt = parameters.defaultProtocolStack.applicationProtocols.first as? NWProtocolTCP.Options {
            tcpOpt.noDelay = true
        }
        
        let connection = NWConnection(to: endpoint, using: parameters)
        let id = UUID()
        
        connectionQueue.async { [weak self] in
            guard let self = self else { return }
            let session = ClientSession(id: id, connection: connection, isInitiator: true)
            self.activeConnections[id] = session
            self.updateActiveConnectionsStatus()
            
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("[+] Mac Initiator connected to iPad!")
                    self.startReceiving(session)
                case .failed(let error):
                    print("[-] Mac Initiator connection failed: \(error)")
                    self.removeConnection(id: id)
                case .cancelled:
                    self.removeConnection(id: id)
                default:
                    break
                }
            }
            connection.start(queue: self.connectionQueue)
        }
    }
    
    func submitPIN(_ pin: String, forSession id: UUID) {
        connectionQueue.async { [weak self] in
            guard let self = self, let session = self.activeConnections[id], session.isInitiator, let salt = session.salt else { return }
            
            let key = CryptoHelper.deriveKey(pin: pin, salt: salt)
            session.sessionKey = key
            
            do {
                let token = Data(XDisplayProtocol.pairingVerificationToken.utf8)
                let encryptedToken = try CryptoHelper.encrypt(data: token, key: key)
                let payload = XDisplayPacketCodec.makePairingVerification(clientID: self.serverID, isTokenAuth: false, encryptedToken: encryptedToken)
                self.sendPacket(payload, to: session.connection)
            } catch {
                print("[-] Encryption error during PIN submission: \(error)")
            }
        }
    }
    
    private func handleNewConnection(_ connection: NWConnection) {
        let id = UUID()
        connectionQueue.async { [weak self] in
            guard let self = self else { return }
            
            let session = ClientSession(id: id, connection: connection)
            self.activeConnections[id] = session
            self.updateActiveConnectionsStatus()
            
            let pinStr = session.pin ?? ""
            print("\n" + String(repeating: "*", count: 40))
            print("[***] NEW CLIENT PENDING PAIRING!")
            print("[***] ENTER THIS PIN ON YOUR IPAD: \(pinStr)")
            print(String(repeating: "*", count: 40) + "\n")

            // Notify delegate so UI can show the PIN to the user
            let pin = session.pin ?? ""
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.streamServer(self, didGeneratePIN: pin)
            }
            
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
            
            if let salt = session.salt {
                let authRequest = XDisplayPacketCodec.makePairingRequest(salt: salt, serverID: self.serverID)
                self.sendPacket(authRequest, to: connection)
            }
            
            // Start receiving packets
            self.startReceiving(session)
        }
    }
    
    private func sendPacket(_ payload: Data, to connection: NWConnection, completion: (@Sendable () -> Void)? = nil) {
        let packet = XDisplayPacketCodec.encodePacket(payload: payload)
        
        connection.send(content: packet, completion: .contentProcessed({ error in
            if let error = error {
                print("[-] Server failed to send packet: \(error.localizedDescription)")
            }
            completion?()
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
            
            let payloadSize: Int
            do {
                payloadSize = try XDisplayPacketCodec.decodeLengthHeader(data)
            } catch {
                print("[-] Invalid server packet length header: \(error)")
                self.removeConnection(id: session.id)
                return
            }
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
        let magic: XDisplayPayloadMagic
        do {
            magic = try XDisplayPacketCodec.payloadMagic(in: data)
        } catch {
            print("[-] Unknown package magic received: \(data[0])")
            return
        }
        
        switch magic {
        case .pairingVerify:
            guard !session.isInitiator else {
                print("[-] Unexpected pairingVerify received by initiator")
                return
            }
            let clientID: UUID
            let isTokenAuth: Bool
            let encryptedToken: Data
            do {
                (clientID, isTokenAuth, encryptedToken) = try XDisplayPacketCodec.decodePairingVerification(data)
            } catch {
                print("[-] Invalid pairing verification payload: \(error)")
                return
            }
            
            var derivedKey: SymmetricKey?
            var usedTokenAuth = false
            
            if isTokenAuth {
                if let persistentToken = KeychainManager.getToken(for: clientID.uuidString), let salt = session.salt {
                    derivedKey = CryptoHelper.deriveKey(keyData: persistentToken, salt: salt)
                    usedTokenAuth = true
                } else {
                    print("[-] Token auth requested but no token found for client: \(clientID.uuidString)")
                }
            }
            
            if derivedKey == nil, let pin = session.pin, let salt = session.salt {
                derivedKey = CryptoHelper.deriveKey(pin: pin, salt: salt)
                usedTokenAuth = false
            }
            
            guard let key = derivedKey else { return }
            
            do {
                let decryptedData = try CryptoHelper.decrypt(combinedData: encryptedToken, key: key)
                if let decryptedString = String(data: decryptedData, encoding: .utf8), decryptedString == XDisplayProtocol.pairingVerificationToken {
                    print("[+] PIN/Token Pairing Successful! Session is now encrypted.")
                    session.isPaired = true
                    session.sessionKey = key
                    self.updateActiveConnectionsStatus()
                    
                    var newEncryptedToken: Data? = nil
                    if !usedTokenAuth {
                        var tokenBytes = [UInt8](repeating: 0, count: 32)
                        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &tokenBytes)
                        let persistentToken = Data(tokenBytes)
                        
                        _ = KeychainManager.saveToken(persistentToken, for: clientID.uuidString)
                        newEncryptedToken = try? CryptoHelper.encrypt(data: persistentToken, key: key)
                    }
                    
                    let reply = XDisplayPacketCodec.makePairingResult(success: true, encryptedToken: newEncryptedToken)
                    self.sendPacket(reply, to: session.connection)
                    self.delegate?.streamServerDidCompletePairing(self)
                } else {
                    throw NSError(domain: "AuthError", code: -1, userInfo: nil)
                }
            } catch {
                print("[-] Pairing Failed. Invalid PIN or Token submitted by client.")
                let reply = XDisplayPacketCodec.makePairingResult(success: false, encryptedToken: nil)
                self.sendPacket(reply, to: session.connection) { [weak self] in
                    self?.removeConnection(id: session.id)
                }
            }
            
        case .inputEvent:
            guard session.isPaired, let key = session.sessionKey else {
                print("[-] Warning: Received input event from unauthenticated client.")
                return
            }
            
            let encryptedEvent: Data
            do {
                encryptedEvent = try XDisplayPacketCodec.decodeEncryptedInputEvent(data)
            } catch {
                print("[-] Invalid input event payload: \(error)")
                return
            }
            do {
                let decryptedEvent = try CryptoHelper.decrypt(combinedData: encryptedEvent, key: key)
                self.parseAndDispatchInput(decryptedEvent)
            } catch {
                print("[-] Error decrypting client input event: \(error.localizedDescription)")
            }
            
        case .clientInfo:
            guard session.isPaired, let key = session.sessionKey else { return }
            
            let encryptedEvent: Data
            do {
                encryptedEvent = try XDisplayPacketCodec.decodeEncryptedClientInfo(data)
            } catch {
                print("[-] Invalid client info payload: \(error)")
                return
            }
            do {
                let decryptedEvent = try CryptoHelper.decrypt(combinedData: encryptedEvent, key: key)
                let event = try XDisplayClientInfoEvent.decodeRawPayload(decryptedEvent)
                delegate?.streamServer(self, didReceiveClientInfo: event)
            } catch {
                print("[-] Error decrypting client info event: \(error.localizedDescription)")
            }
            
        case .pairingRequest:
            guard session.isInitiator else {
                print("[-] Unexpected pairingRequest received by listener")
                return
            }
            let saltData: Data
            let serverUUID: UUID
            do {
                (saltData, serverUUID) = try XDisplayPacketCodec.decodePairingRequest(data)
            } catch {
                print("[-] Invalid pairing request payload")
                return
            }
            session.salt = saltData
            session.remoteServerID = serverUUID
            
            if let token = KeychainManager.getToken(for: serverUUID.uuidString) {
                print("[+] Found persistent token for iPad. Attempting automatic connection...")
                connectionQueue.async { [weak self] in
                    guard let self = self else { return }
                    let key = CryptoHelper.deriveKey(keyData: token, salt: saltData)
                    session.sessionKey = key
                    do {
                        let tokenData = Data(XDisplayProtocol.pairingVerificationToken.utf8)
                        let encryptedToken = try CryptoHelper.encrypt(data: tokenData, key: key)
                        let payload = XDisplayPacketCodec.makePairingVerification(clientID: self.serverID, isTokenAuth: true, encryptedToken: encryptedToken)
                        self.sendPacket(payload, to: session.connection)
                    } catch {
                        print("[-] Encryption error during auto-connect: \(error)")
                    }
                }
            } else {
                print("[+] Received pairing salt. Requesting PIN from UI...")
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.streamServer(self, didRequestPINForSession: session.id)
                }
            }
            
        case .pairingResult:
            guard session.isInitiator else {
                print("[-] Unexpected pairingResult received by listener")
                return
            }
            let success: Bool
            let encryptedPersistentToken: Data?
            do {
                (success, encryptedPersistentToken) = try XDisplayPacketCodec.decodePairingResult(data)
            } catch {
                print("[-] Invalid pairing result payload")
                return
            }
            
            if success {
                print("[+] Pairing verified by iPad! Communication is now secure.")
                session.isPaired = true
                self.updateActiveConnectionsStatus()
                
                if let encryptedPersistentToken = encryptedPersistentToken,
                   let key = session.sessionKey,
                   let serverID = session.remoteServerID {
                    do {
                        let decryptedToken = try CryptoHelper.decrypt(combinedData: encryptedPersistentToken, key: key)
                        if KeychainManager.saveToken(decryptedToken, for: serverID.uuidString) {
                            print("[+] Saved persistent token to Keychain.")
                        }
                    } catch {
                        print("[-] Failed to decrypt persistent token")
                    }
                }
                
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.streamServerDidCompletePairing(self)
                }
            } else {
                print("[-] Pairing rejected by iPad.")
                if let serverID = session.remoteServerID {
                    _ = KeychainManager.deleteToken(for: serverID.uuidString)
                }
                self.removeConnection(id: session.id)
            }

        case .videoFrame:
            print("[-] Unexpected package magic received: \(magic.rawValue)")
        }
    }
    
    private func parseAndDispatchInput(_ data: Data) {
        guard data.count > 0 else { return }
        let identifier = data[0]
        
        do {
            if identifier == 0x01 {
                let event = try XDisplayTouchEvent.decodeRawPayload(data)
                delegate?.streamServer(self, didReceiveInputEvent: event.phase.rawValue, x: event.x, y: event.y, pressure: event.pressure)
            } else if identifier == 0x02 {
                let event = try XDisplayScrollEvent.decodeRawPayload(data)
                delegate?.streamServer(self, didReceiveScrollEvent: event.deltaX, deltaY: event.deltaY, x: event.x, y: event.y)
            } else if identifier == 0x03 {
                let event = try XDisplayRightClickEvent.decodeRawPayload(data)
                delegate?.streamServer(self, didReceiveRightClickEvent: event.x, y: event.y)
            } else if identifier == 0x04 {
                let event = try XDisplayPencilEvent.decodeRawPayload(data)
                delegate?.streamServer(self, didReceivePencilEvent: event)
            } else if identifier == 0x05 {
                let event = try XDisplayPencilInteractionEvent.decodeRawPayload(data)
                delegate?.streamServer(self, didReceivePencilInteractionEvent: event)
            } else if identifier == 0x06 {
                let event = try XDisplayKeyboardEvent.decodeRawPayload(data)
                delegate?.streamServer(self, didReceiveKeyboardEvent: event)
            } else if identifier == 0x07 {
                let event = try XDisplayMouseEvent.decodeRawPayload(data)
                delegate?.streamServer(self, didReceiveMouseEvent: event)
            } else {
                print("[-] Unknown input event identifier: \(identifier)")
            }
        } catch {
            print("[-] Invalid input event (id: \(identifier)): \(error)")
        }
    }

    
    private func removeConnection(id: UUID) {
        connectionQueue.async { [weak self] in
            guard let self = self else { return }
            if let session = self.activeConnections.removeValue(forKey: id) {
                session.connection.cancel()
                self.updateActiveConnectionsStatus()
                print("[-] Client disconnected. Total clients: \(self.activeConnections.count)")
            }
        }
    }
    
    func broadcast(data: Data, codec: XDisplayVideoCodec) {
        connectionQueue.async { [weak self] in
            guard let self = self else { return }
            let start = DispatchTime.now().uptimeNanoseconds
            let pairedSessions = self.activeConnections.values.filter { $0.isPaired && $0.sessionKey != nil }
            guard !pairedSessions.isEmpty else { return }
            
            for session in pairedSessions {
                guard let key = session.sessionKey else { continue }
                
                do {
                    let framePayload = XDisplayVideoFramePayload(codec: codec, data: data).encodeRawPayload()
                    let encryptedData = try CryptoHelper.encrypt(data: framePayload, key: key)
                    
                    let payload = XDisplayPacketCodec.makeEncryptedVideoFrame(encryptedData)
                    
                    self.sendPacket(payload, to: session.connection)
                } catch {
                    print("[-] Failed to encrypt video frame: \(error.localizedDescription)")
                }
            }

            let elapsedNs = DispatchTime.now().uptimeNanoseconds - start
            self.timingLock.lock()
            self.broadcastCount += 1
            self.broadcastTotalNs += elapsedNs
            self.broadcastMaxNs = max(self.broadcastMaxNs, elapsedNs)
            let shouldLog = self.broadcastCount % 60 == 0
            let averageMs = Double(self.broadcastTotalNs) / Double(self.broadcastCount) / 1_000_000.0
            let maxMs = Double(self.broadcastMaxNs) / 1_000_000.0
            let now = Date()
            let interval = now.timeIntervalSince(self.lastBroadcastLogTime)
            let sentDelta = self.broadcastCount - self.lastBroadcastCount
            if shouldLog {
                self.lastBroadcastLogTime = now
                self.lastBroadcastCount = self.broadcastCount
            }
            self.timingLock.unlock()
            if shouldLog {
                let elapsedMs = Double(elapsedNs) / 1_000_000.0
                let sentFPS = interval > 0 ? Double(sentDelta) / interval : 0
                self.statusLock.lock()
                self._currentSentFPS = sentFPS
                self.statusLock.unlock()
                print(String(format: "[Timing] broadcast: %.2f ms (avg %.2f ms, max %.2f ms) | sent FPS: %.1f", elapsedMs, averageMs, maxMs, sentFPS))
            }
        }
    }
    
    private func updateActiveConnectionsStatus() {
        statusLock.lock()
        let hasPaired = activeConnections.values.contains { $0.isPaired && $0.sessionKey != nil }
        _hasActivePairedConnections = hasPaired
        statusLock.unlock()
    }
}
#endif
