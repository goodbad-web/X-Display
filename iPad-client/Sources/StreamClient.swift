import Foundation
import Network
import CryptoKit
import XDisplayShared

protocol StreamClientDelegate: AnyObject {
    func streamClient(_ client: StreamClient, didReceiveNALUnit data: Data)
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
    
    func connect(endpoint: NWEndpoint) {
        let parameters = NWParameters.tcp
        
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
                self.startReceiving()
            case .failed(let error):
                print("[-] Connection error: \(error.localizedDescription)")
                self.disconnect()
            case .cancelled:
                print("[*] Connection cancelled.")
                self.disconnect()
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
    
    func disconnect() {
        guard isRunning else { return }
        isRunning = false
        isPaired = false
        sessionKey = nil
        salt = nil
        connection?.cancel()
        connection = nil
        print("[*] StreamClient disconnected.")
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
                
                let payload = XDisplayPacketCodec.makePairingVerification(encryptedToken: encryptedToken)
                
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

    func sendScrollEvent(deltaX: Float, deltaY: Float) {
        guard isRunning, isPaired, let key = sessionKey else { return }
        
        let rawEvent = XDisplayScrollEvent(deltaX: deltaX, deltaY: deltaY).encodeRawPayload()
        
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
                self.disconnect()
                return
            }
            
            guard let data = data, data.count == 4 else {
                if isComplete {
                    self.disconnect()
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
                self.disconnect()
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
                self.disconnect()
                return
            }
            
            guard let data = data, data.count == size else {
                if isComplete {
                    self.disconnect()
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
            do {
                saltData = try XDisplayPacketCodec.decodePairingRequestSalt(data)
            } catch {
                print("[-] Invalid pairing request payload: \(error)")
                return
            }
            self.salt = saltData
            
            print("[+] Received pairing salt. Requesting PIN from UI...")
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.streamClient(self, didRequestPINWithSalt: saltData)
            }
            
        case .pairingResult:
            let success: Bool
            do {
                success = try XDisplayPacketCodec.decodePairingResult(data)
            } catch {
                print("[-] Invalid pairing result payload: \(error)")
                return
            }
            
            if success {
                print("[+] Pairing verified by host! Communication is now secure.")
                self.isPaired = true
            } else {
                print("[-] Pairing rejected by host.")
                self.disconnect()
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
                self.delegate?.streamClient(self, didReceiveNALUnit: decryptedVideo)
            } catch {
                print("[-] Failed to decrypt video frame: \(error.localizedDescription)")
            }
            
        case .pairingVerify, .inputEvent:
            print("[-] Unexpected magic received from server: \(magic.rawValue)")
        }
    }
}
