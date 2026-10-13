import CryptoKit
import Foundation

// Input is consumed in CI through stdin. Only the public key is emitted.
let encoded = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
guard let secret = Data(base64Encoded: encoded), [32, 96].contains(secret.count), secret.contains(where: { $0 != 0 }) else {
    fputs("Invalid Sparkle exported key format.\n", stderr)
    exit(1)
}
do {
    let publicKey: Data
    if secret.count == 32 {
        publicKey = try Curve25519.Signing.PrivateKey(rawRepresentation: secret).publicKey.rawRepresentation
    } else {
        // Sparkle's legacy export is the expanded private key followed by the public key.
        publicKey = Data(secret.suffix(32))
        _ = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
    }
    guard publicKey.contains(where: { $0 != 0 }) else { exit(1) }
    print(publicKey.base64EncodedString())
} catch {
    fputs("Could not derive the Sparkle public key.\n", stderr)
    exit(1)
}
