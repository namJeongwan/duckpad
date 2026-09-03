import CryptoKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4 || arguments.count == 5 else { exit(64) }
let inventory = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
var signedPayload = Data("duckpad-extension-signature-v1\n".utf8)
signedPayload.append(inventory)
let signatureText = try String(contentsOfFile: arguments[2], encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines)
guard let publicBytes = Data(base64Encoded: arguments[3]),
      let signature = Data(base64Encoded: signatureText) else { exit(65) }
let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicBytes)
guard publicKey.isValidSignature(signature, for: signedPayload) else { exit(66) }
if arguments.count == 5 {
    let privateBytes = try Data(contentsOf: URL(fileURLWithPath: arguments[4]))
    let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateBytes)
    guard privateKey.publicKey.rawRepresentation == publicBytes else { exit(68) }
    guard try privateKey.signature(for: signedPayload) == signature else { exit(69) }
}
