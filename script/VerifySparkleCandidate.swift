// Public-only Ed25519 verifier. No keychain, private key or network access.
import Foundation
import CryptoKit
import Darwin

let approvedPublicKey = "txWavHI0vv7xM5j0CrtW8pkoRWmChw8hHjUxa1BL1So="

func verifies(_ data: Data, signature: Data, key: Data) throws -> Bool {
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: key)
    return publicKey.isValidSignature(signature, for: data)
}

func hex(_ value: String) -> Data {
    let bytes = Array(value.utf8)
    return Data(stride(from: 0, to: bytes.count, by: 2).map {
        UInt8(String(bytes: bytes[$0..<$0 + 2], encoding: .utf8)!, radix: 16)!
    })
}

do {
    if CommandLine.arguments == [CommandLine.arguments[0], "--self-test"] {
        // Published RFC 8032 test 1; no private test key is needed or generated.
        let key = hex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
        let signature = hex("e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b")
        guard try verifies(Data(), signature: signature, key: key),
              try !verifies(Data([1]), signature: signature, key: key) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        print("PASS: public-only Ed25519 known-answer and tamper tests")
    } else {
        guard CommandLine.arguments.count == 3,
              let key = Data(base64Encoded: approvedPublicKey),
              let signature = Data(base64Encoded: CommandLine.arguments[2]),
              signature.count == 64 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]), options: .mappedIfSafe)
        guard try verifies(data, signature: signature, key: key) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        print("PASS: Ed25519 signature matches the approved public key")
    }
} catch {
    fputs("Candidate signature verification failed.\n", stderr)
    exit(1)
}
