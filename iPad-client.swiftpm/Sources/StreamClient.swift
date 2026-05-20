import Foundation
import Network

protocol StreamClientDelegate: AnyObject {
    func streamClient(_ client: StreamClient, didReceiveNALUnit data: Data)
    func streamClient(_ client: StreamClient, connectionStateDidChange state: NWConnection.State)
}

class StreamClient {
    weak var delegate: StreamClientDelegate?
    private var connection: NWConnection?
    private let clientQueue = DispatchQueue(label: "com.xdisplay.client.network-queue", qos: .userInteractive)
    private var isRunning = false
    
    func connect(host: String, port: UInt16) {
        let endpointHost = NWEndpoint.Host(host)
        let endpointPort = NWEndpoint.Port(rawValue: port)!
        let parameters = NWParameters.tcp
        
        // Disable Nagle's algorithm for ultra-low latency
        if let tcpOpt = parameters.defaultProtocolStack.applicationProtocols.first as? NWProtocolTCP.Options {
            tcpOpt.noDelay = true
        }
        
        connection = NWConnection(to: .hostPort(host: endpointHost, port: endpointPort), using: parameters)
        
        connection?.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            self.delegate?.streamClient(self, connectionStateDidChange: state)
            
            switch state {
            case .ready:
                print("[+] Connected to Mac host!")
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
    
    func disconnect() {
        guard isRunning else { return }
        isRunning = false
        connection?.cancel()
        connection = nil
        print("[*] StreamClient disconnected.")
    }
    
    func sendInputEvent(phase: TouchPhaseType, x: Float, y: Float, pressure: Float) {
        guard isRunning, let connection = connection else { return }
        
        var payload = Data()
        
        // 1. Magic identifier for Input Event: 0x01 (1 byte)
        var identifier: UInt8 = 0x01
        payload.append(&identifier, count: 1)
        
        // 2. Touch Phase (1 byte)
        var rawPhase = phase.rawValue
        payload.append(&rawPhase, count: 1)
        
        // 3. X (4 bytes Float bitPattern Big-Endian)
        var xBits = x.bitPattern.bigEndian
        withUnsafeBytes(of: &xBits) { payload.append(contentsOf: $0) }
        
        // 4. Y (4 bytes Float bitPattern Big-Endian)
        var yBits = y.bitPattern.bigEndian
        withUnsafeBytes(of: &yBits) { payload.append(contentsOf: $0) }
        
        // 5. Pressure (4 bytes Float bitPattern Big-Endian)
        var pressureBits = pressure.bitPattern.bigEndian
        withUnsafeBytes(of: &pressureBits) { payload.append(contentsOf: $0) }
        
        // Frame packet: [4-Byte Payload Size] + [Payload]
        var payloadSize = UInt32(payload.count).bigEndian
        var packet = Data()
        withUnsafeBytes(of: &payloadSize) { packet.append(contentsOf: $0) }
        packet.append(payload)
        
        // Send on network queue
        clientQueue.async {
            connection.send(content: packet, completion: .contentProcessed({ error in
                if let error = error {
                    print("[-] Failed to send input event: \(error.localizedDescription)")
                }
            }))
        }
    }
    
    private func startReceiving() {
        guard isRunning else { return }
        // Read 4-byte big-endian payload size first
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
            
            // Extract big-endian UInt32 size
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
            
            // Dispatch NAL Unit to delegate for decoding
            self.delegate?.streamClient(self, didReceiveNALUnit: data)
            
            // Read next frame packet
            self.startReceiving()
        }
    }
}
