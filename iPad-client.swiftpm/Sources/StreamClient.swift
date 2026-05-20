import Foundation
import Network
import CryptoKit

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
        guard let salt = salt, let connection = connection else {
            print("[-] Cannot submit PIN: Pairing not initialized or no connection.")
            return
        }
        
        clientQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Derive session key
            let key = CryptoHelper.deriveKey(pin: pin, salt: salt)
            self.sessionKey = key
            
            do {
                // Encrypt "SUCCESS" token to prove key validity
                let token = "SUCCESS".data(using: .utf8)!
                let encryptedToken = try CryptoHelper.encrypt(data: token, key: key)
                
                // Format payload: [0x03] + [Encrypted verification token]
                var payload = Data()
                var magic: UInt8 = 0x03
                payload.append(&magic, count: 1)
                payload.append(encryptedToken)
                
                self.sendPacket(payload)
            } catch {
                print("[-] Encryption error during PIN submission: \(error.localizedDescription)")
            }
        }
    }
    
    func sendInputEvent(phase: TouchPhaseType, x: Float, y: Float, pressure: Float) {
        guard isRunning, isPaired, let key = sessionKey else { return }
        
        var rawEvent = Data()
        
        // 1. Magic identifier for Input Event: 0x01 (1 byte)
        var identifier: UInt8 = 0x01
        rawEvent.append(&identifier, count: 1)
        
        // 2. Touch Phase (1 byte)
        var rawPhase = phase.rawValue
        rawEvent.append(&rawPhase, count: 1)
        
        // 3. X (4 bytes Float bitPattern Big-Endian)
        var xBits = x.bitPattern.bigEndian
        withUnsafeBytes(of: &xBits) { rawEvent.append(contentsOf: $0) }
        
        // 4. Y (4 bytes Float bitPattern Big-Endian)
        var yBits = y.bitPattern.bigEndian
        withUnsafeBytes(of: &yBits) { rawEvent.append(contentsOf: $0) }
        
        // 5. Pressure (4 bytes Float bitPattern Big-Endian)
        var pressureBits = pressure.bitPattern.bigEndian
        withUnsafeBytes(of: &pressureBits) { rawEvent.append(contentsOf: $0) }
        
        // Encrypt the event data
        do {
            let encryptedEvent = try CryptoHelper.encrypt(data: rawEvent, key: key)
            
            // Format packet: [0x11] + [Encrypted Event Data]
            var payload = Data()
            var magic: UInt8 = 0x11
            payload.append(&magic, count: 1)
            payload.append(encryptedEvent)
            
            sendPacket(payload)
        } catch {
            print("[-] Encryption failed for input event: \(error.localizedDescription)")
        }
    }
    
    private func sendPacket(_ payload: Data) {
        guard let connection = connection else { return }
        
        var packet = Data()
        var size = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &size) { packet.append(contentsOf: $0) }
        packet.append(payload)
        
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
            
            let payloadSize = data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
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
        let magic = data[0]
        
        switch magic {
        case 0x02: // Pairing request (Mac -> iPad)
            // Payload: [0x02] + [Salt (16 bytes)]
            guard data.count >= 17 else { return }
            let saltData = data.subdata(in: 1..<17)
            self.salt = saltData
            
            print("[+] Received pairing salt. Requesting PIN from UI...")
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.streamClient(self, didRequestPINWithSalt: saltData)
            }
            
        case 0x04: // Pairing Result (Mac -> iPad)
            // Payload: [0x04] + [Status (1 byte)]
            guard data.count >= 2 else { return }
            let status = data[1]
            let success = (status == 1)
            
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
            
        case 0x10: // Encrypted video data frame (Mac -> iPad)
            guard isPaired, let key = sessionKey else {
                print("[-] Warning: Received video data before pairing completion.")
                return
            }
            
            let encryptedVideo = data.subdata(in: 1..<data.count)
            do {
                let decryptedVideo = try CryptoHelper.decrypt(combinedData: encryptedVideo, key: key)
                self.delegate?.streamClient(self, didReceiveNALUnit: decryptedVideo)
            } catch {
                print("[-] Failed to decrypt video frame: \(error.localizedDescription)")
            }
            
        default:
            print("[-] Unknown magic received from server: \(magic)")
        }
    }
}
