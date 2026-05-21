import Foundation
import Network
import CryptoKit
import XDisplayShared

protocol StreamClientDelegate: AnyObject {
    func streamClient(_ client: StreamClient, didReceiveVideoFrame data: Data, codec: XDisplayVideoCodec)
    func streamClient(_ client: StreamClient, connectionStateDidChange state: NWConnection.State)
    func streamClient(_ client: StreamClient, didRequestPINWithSalt salt: Data)
    func streamClient(_ client: StreamClient, didFinishPairingWithResult success: Bool)
}

class StreamClient {
    weak var delegate: StreamClientDelegate?
    private var connection: NWConnection?
    private let clientQueue = DispatchQueue(label: "com.xdisplay.client.network-queue", qos: .userInteractive)
    private var isRunning = false
    
    // Security / Pairing State
    private var isPaired = false
    private var sessionKey: SymmetricKey?
    private var salt: Data?
    private var serverID: UUID?
    
    private let clientID: UUID = {
        if let uuidString = UserDefaults.standard.string(forKey: "XDisplayClientID"),
           let uuid = UUID(uuidString: uuidString) {
            return uuid
        }
        let newUUID = UUID()
        UserDefaults.standard.set(newUUID.uuidString, forKey: "XDisplayClientID")
        return newUUID
    }()
    
    func connect(endpoint: NWEndpoint, type: ConnectionType? = nil) {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        
        // Disable Nagle's algorithm for ultra-low latency
        if let tcpOpt = parameters.defaultProtocolStack.applicationProtocols.first as? NWProtocolTCP.Options {
            tcpOpt.noDelay = true
        }
        
        connection = NWConnection(to: endpoint, using: parameters)
        
        connection?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            self.delegate?.streamClient(self, connectionStateDidChange: state)
            
            switch state {
            case .ready:
                print("[+] Connected to Mac host! Awaiting security pairing salt...")
                self.isPaired = false
                self.sessionKey = nil
                self.salt = nil
                self.serverID = nil
                self.startReceiving()
            case .failed(let error):
                print("[-] Connection error: \(error.localizedDescription)")
                self.disconnect(reason: "Connection state failed: \(error.localizedDescription)")
            case .cancelled:
                print("[*] Connection cancelled.")
                self.disconnect(reason: "Connection state cancelled")
            default:
                break
            }
        }
        
        isRunning = true
        connection?.start(queue: clientQueue)
    }

    func connect(host: String, port: UInt16) {
        let endpointHost = NWEndpoint.Host(host)
        let endpointPort = NWEndpoint.Port(rawValue: port)!
        connect(endpoint: .hostPort(host: endpointHost, port: endpointPort))
    }
    
    func disconnect(reason: String = "Unknown") {
        guard isRunning else { return }
        isRunning = false
        isPaired = false
        sessionKey = nil
        salt = nil
        serverID = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        print("[*] StreamClient disconnected. Reason: \(reason)")
    }
    
    // Submit PIN from User Input View
    func submitPIN(_ pin: String) {
        guard let salt = salt, connection != nil else {
            print("[-] Cannot submit PIN: Pairing not initialized or no connection.")
            return
        }
        
        clientQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Derive session key
            let key = CryptoHelper.deriveKey(pin: pin, salt: salt)
            self.sessionKey = key
            
            do {
                let token = Data(XDisplayProtocol.pairingVerificationToken.utf8)
                let encryptedToken = try CryptoHelper.encrypt(data: token, key: key)
                
                let payload = XDisplayPacketCodec.makePairingVerification(clientID: self.clientID, isTokenAuth: false, encryptedToken: encryptedToken)
                
                self.sendPacket(payload)
            } catch {
                print("[-] Encryption error during PIN submission: \(error.localizedDescription)")
            }
        }
    }
    
    func sendInputEvent(phase: XDisplayTouchPhase, x: Float, y: Float, pressure: Float) {
        guard isRunning, isPaired, let key = sessionKey else { return }
        
        let rawEvent = XDisplayTouchEvent(phase: phase, x: x, y: y, pressure: pressure).encodeRawPayload()
        
        // Encrypt the event data
        do {
            let encryptedEvent = try CryptoHelper.encrypt(data: rawEvent, key: key)
            let payload = XDisplayPacketCodec.makeEncryptedInputEvent(encryptedEvent)
            
            sendPacket(payload)
        } catch {
            print("[-] Encryption failed for input event: \(error.localizedDescription)")
        }
    }

    func sendScrollEvent(deltaX: Float, deltaY: Float, x: Float, y: Float) {
        guard isRunning, isPaired, let key = sessionKey else { return }
        
        let rawEvent = XDisplayScrollEvent(deltaX: deltaX, deltaY: deltaY, x: x, y: y).encodeRawPayload()
        
        do {
            let encryptedEvent = try CryptoHelper.encrypt(data: rawEvent, key: key)
            let payload = XDisplayPacketCodec.makeEncryptedInputEvent(encryptedEvent)
            
            sendPacket(payload)
        } catch {
            print("[-] Encryption failed for scroll event: \(error.localizedDescription)")
        }
    }

    func sendRightClickEvent(x: Float, y: Float) {
        guard isRunning, isPaired, let key = sessionKey else { return }
        
        let rawEvent = XDisplayRightClickEvent(x: x, y: y).encodeRawPayload()
        
        do {
            let encryptedEvent = try CryptoHelper.encrypt(data: rawEvent, key: key)
            let payload = XDisplayPacketCodec.makeEncryptedInputEvent(encryptedEvent)
            
            sendPacket(payload)
        } catch {
            print("[-] Encryption failed for right-click event: \(error.localizedDescription)")
        }
    }

    func sendPencilEvent(_ event: XDisplayPencilEvent) {
        guard isRunning, isPaired, let key = sessionKey else { return }
        
        let rawEvent = event.encodeRawPayload()
        
        do {
            let encryptedEvent = try CryptoHelper.encrypt(data: rawEvent, key: key)
            let payload = XDisplayPacketCodec.makeEncryptedInputEvent(encryptedEvent)
            
            sendPacket(payload)
        } catch {
            print("[-] Encryption failed for pencil event: \(error.localizedDescription)")
        }
    }

    func sendPencilInteractionEvent(_ event: XDisplayPencilInteractionEvent) {
        guard isRunning, isPaired, let key = sessionKey else { return }
        
        let rawEvent = event.encodeRawPayload()
        
        do {
            let encryptedEvent = try CryptoHelper.encrypt(data: rawEvent, key: key)
            let payload = XDisplayPacketCodec.makeEncryptedInputEvent(encryptedEvent)
            
            sendPacket(payload)
        } catch {
            print("[-] Encryption failed for pencil interaction event: \(error.localizedDescription)")
        }
    }


    
    func sendClientInfo(isPortrait: Bool, preferredCodec: XDisplayVideoCodec, maxFrameRate: UInt8) {
        guard isRunning, isPaired, let key = sessionKey else { return }
        
        let rawEvent = XDisplayClientInfoEvent(
            isPortrait: isPortrait,
            preferredCodec: preferredCodec,
            maxFrameRate: maxFrameRate
        ).encodeRawPayload()
        
        do {
            let encryptedEvent = try CryptoHelper.encrypt(data: rawEvent, key: key)
            let payload = XDisplayPacketCodec.makeEncryptedClientInfo(encryptedEvent)
            
            sendPacket(payload)
        } catch {
            print("[-] Encryption failed for client info event: \(error.localizedDescription)")
        }
    }

    private func sendPacket(_ payload: Data) {
        guard let connection = connection else { return }
        
        let packet = XDisplayPacketCodec.encodePacket(payload: payload)
        
        clientQueue.async {
            connection.send(content: packet, completion: .contentProcessed({ error in
                if let error = error {
                    print("[-] Failed to send client packet: \(error.localizedDescription)")
                }
            }))
        }
    }
    
    private func startReceiving() {
        guard isRunning else { return }
        // Read 4-byte size header
        connection?.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] (data, context, isComplete, error) in
            guard let self = self else { return }
            
            if let error = error {
                print("[-] Receive length failed: \(error.localizedDescription)")
                self.disconnect(reason: "Receive length error: \(error.localizedDescription)")
                return
            }
            
            guard let data = data, data.count == 4 else {
                if isComplete {
                    self.disconnect(reason: "Receive length EOF")
                } else {
                    self.startReceiving()
                }
                return
            }
            
            let payloadSize: Int
            do {
                payloadSize = try XDisplayPacketCodec.decodeLengthHeader(data)
            } catch {
                print("[-] Invalid client packet length header: \(error)")
                self.disconnect(reason: "Invalid length header: \(error)")
                return
            }
            self.receivePayload(size: Int(payloadSize))
        }
    }
    
    private func receivePayload(size: Int) {
        guard isRunning, size > 0 else {
            self.startReceiving()
            return
        }
        
        connection?.receive(minimumIncompleteLength: size, maximumLength: size) { [weak self] (data, context, isComplete, error) in
            guard let self = self else { return }
            
            if let error = error {
                print("[-] Receive payload failed: \(error.localizedDescription)")
                self.disconnect(reason: "Receive payload error: \(error.localizedDescription)")
                return
            }
            
            guard let data = data, data.count == size else {
                if isComplete {
                    self.disconnect(reason: "Receive payload EOF")
                } else {
                    self.startReceiving()
                }
                return
            }
            
            self.handleIncomingPayload(data)
            
            // Listen for next package
            self.startReceiving()
        }
    }
    
    private func handleIncomingPayload(_ data: Data) {
        guard data.count > 0 else { return }
        let magic: XDisplayPayloadMagic
        do {
            magic = try XDisplayPacketCodec.payloadMagic(in: data)
        } catch {
            print("[-] Unknown magic received from server: \(data[0])")
            return
        }
        
        switch magic {
        case .pairingRequest:
            let saltData: Data
            let serverUUID: UUID
            do {
                (saltData, serverUUID) = try XDisplayPacketCodec.decodePairingRequest(data)
            } catch {
                print("[-] Invalid pairing request payload: \(error)")
                return
            }
            self.salt = saltData
            self.serverID = serverUUID
            
            if let token = KeychainManager.getToken(for: serverUUID.uuidString) {
                print("[+] Found persistent token for server. Attempting automatic connection...")
                clientQueue.async { [weak self] in
                    guard let self = self else { return }
                    let key = CryptoHelper.deriveKey(keyData: token, salt: saltData)
                    self.sessionKey = key
                    do {
                        let tokenData = Data(XDisplayProtocol.pairingVerificationToken.utf8)
                        let encryptedToken = try CryptoHelper.encrypt(data: tokenData, key: key)
                        let payload = XDisplayPacketCodec.makePairingVerification(clientID: self.clientID, isTokenAuth: true, encryptedToken: encryptedToken)
                        self.sendPacket(payload)
                    } catch {
                        print("[-] Encryption error during auto-connect: \(error)")
                    }
                }
            } else {
                print("[+] Received pairing salt. Requesting PIN from UI...")
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.delegate?.streamClient(self, didRequestPINWithSalt: saltData)
                }
            }
            
        case .pairingResult:
            let success: Bool
            let encryptedPersistentToken: Data?
            do {
                (success, encryptedPersistentToken) = try XDisplayPacketCodec.decodePairingResult(data)
            } catch {
                print("[-] Invalid pairing result payload: \(error)")
                return
            }
            
            if success {
                print("[+] Pairing verified by host! Communication is now secure.")
                self.isPaired = true
                
                if let encryptedPersistentToken = encryptedPersistentToken,
                   let key = self.sessionKey,
                   let serverID = self.serverID {
                    do {
                        let decryptedToken = try CryptoHelper.decrypt(combinedData: encryptedPersistentToken, key: key)
                        if KeychainManager.saveToken(decryptedToken, for: serverID.uuidString) {
                            print("[+] Saved persistent token to Keychain.")
                        }
                    } catch {
                        print("[-] Failed to decrypt persistent token: \(error)")
                    }
                }
            } else {
                print("[-] Pairing rejected by host.")
                if let serverID = self.serverID {
                    _ = KeychainManager.deleteToken(for: serverID.uuidString)
                    print("[*] Deleted invalid persistent token for server: \(serverID.uuidString)")
                }
                self.disconnect(reason: "Pairing rejected by host")
            }
            
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.streamClient(self, didFinishPairingWithResult: success)
            }
            
        case .videoFrame:
            guard isPaired, let key = sessionKey else {
                print("[-] Warning: Received video data before pairing completion.")
                return
            }
            
            let encryptedVideo: Data
            do {
                encryptedVideo = try XDisplayPacketCodec.decodeEncryptedVideoFrame(data)
            } catch {
                print("[-] Invalid video frame payload: \(error)")
                return
            }
            do {
                let decryptedVideo = try CryptoHelper.decrypt(combinedData: encryptedVideo, key: key)
                let framePayload = try XDisplayVideoFramePayload.decodeRawPayload(decryptedVideo)
                self.delegate?.streamClient(self, didReceiveVideoFrame: framePayload.data, codec: framePayload.codec)
            } catch {
                print("[-] Failed to decrypt video frame: \(error.localizedDescription)")
            }
            
        case .pairingVerify, .inputEvent, .clientInfo:
            print("[-] Unexpected magic received from server: \(magic.rawValue)")
        }
    }
}
