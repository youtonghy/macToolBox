import CryptoKit
import Foundation

guard CommandLine.arguments.count == 4 else {
    fputs("usage: sign_ocr_catalog.swift <private-key> <catalog> <signature>\n", stderr)
    exit(2)
}

let keyURL = URL(fileURLWithPath: CommandLine.arguments[1])
let catalogURL = URL(fileURLWithPath: CommandLine.arguments[2])
let signatureURL = URL(fileURLWithPath: CommandLine.arguments[3])
let keyText = try String(contentsOf: keyURL, encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines)
guard let keyData = Data(base64Encoded: keyText) else {
    fputs("error: catalog signing key is not base64\n", stderr)
    exit(1)
}
let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
let signature = try privateKey.signature(for: Data(contentsOf: catalogURL))
try Data((signature.base64EncodedString() + "\n").utf8).write(
    to: signatureURL,
    options: .atomic
)
print(privateKey.publicKey.rawRepresentation.base64EncodedString())
