/// Integrity hashing — SHA-256 over canonical UTF-8 bytes.
///
/// Objects recorded under protocol 0.1 were hashed with the Python
/// reference implementation's legacy serialization, which this Swift
/// port deliberately does NOT reimplement: 0.1-era objects are reported
/// as `.legacyUnverifiable` and must be verified with the reference
/// implementation. Nothing is ever re-hashed — that would be later
/// knowledge rewriting earlier evidence.
///
/// Hashes provide tamper *evidence* for a local store, not cryptographic
/// proof against an adversary who controls the device.

import CryptoKit
import Foundation

public let genesisHash = String(repeating: "0", count: 64)

public enum HashEra: Equatable {
    /// Protocol >= 0.2: RFC 8785 canonicalization, verifiable here.
    case jcs
    /// Protocol 0.1 or unstamped rows: verifiable only by the Python
    /// reference implementation's frozen legacy serializer.
    case legacyUnverifiable
}

public func hashEra(forProtocol version: String?) -> HashEra {
    (version == nil || version == "0.1") ? .legacyUnverifiable : .jcs
}

public func integrityHash(_ value: JSONValue) throws -> String {
    let canonical = try JCS.canonicalJSON(value)
    let digest = SHA256.hash(data: Data(canonical.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}
