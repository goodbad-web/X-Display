import Foundation
import CryptoKit

enum CryptoHelper {
    // PINとSaltから32バイトの対称鍵を派生
    static func deriveKey(pin: String, salt: Data) -> SymmetricKey {
        let pinData = pin.data(using: .utf8) ?? Data()
        let combined = pinData + salt
        let hash = SHA256.hash(data: combined)
        return SymmetricKey(data: hash)
    }
    
    // ChaChaPoly による超低遅延暗号化
    static func encrypt(data: Data, key: SymmetricKey) throws -> Data {
        let sealedBox = try ChaChaPoly.seal(data, using: key)
        return sealedBox.combined
    }
    
    // ChaChaPoly による復号
    static func decrypt(combinedData: Data, key: SymmetricKey) throws -> Data {
        let sealedBox = try ChaChaPoly.SealedBox(combined: combinedData)
        return try ChaChaPoly.open(sealedBox, using: key)
    }
}
