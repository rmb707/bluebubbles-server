//  TokenVerifier
//  Ed25519 over a compact, JWS-shaped token. Pure, synchronous, and total.
//
//  `base64url(header).base64url(claims).base64url(signature)`, signed over the first two
//  segments joined by the dot, exactly as JWS does. Not a JWT library: nothing here reads
//  `alg` from the header, because a verifier that lets the token choose its own algorithm is
//  how `alg: none` happened. The algorithm is Ed25519 because this file says so.
//
//  The same shape `AppcastSigning` already verifies release artifacts with
//  (`Sources/BBUpdates/AppcastSigning.swift`). The key-parsing is deliberately duplicated
//  rather than shared: lifting fifteen lines into BBCore would drag `Crypto` into the module
//  every target depends on, and a dependency from licensing onto the UPDATER to borrow a
//  base64 decode is worse than the duplication. If a third copy ever appears, lift it then.
//
//  FAILS CLOSED, ALWAYS. Every error path returns nil or throws; there is no branch that
//  treats a malformed token as permissive. That includes the unconfigured build: with no
//  public key compiled in, nothing verifies and nothing is entitled.

import Crypto
import Foundation

public enum TokenVerificationError: Error, Equatable, Sendable {
  /// No public key in this build. See `LicensePublicKey`.
  case notConfigured
  case malformedToken(String)
  case badSignature
  case malformedClaims(String)
  /// A token from a newer claim format than this build understands.
  case unsupportedVersion(Int)
}

/// The signing service's public key, as base64.
///
/// The private half never exists on any machine that runs this server; it lives only in the
/// issuing function. Replacing this constant is how the key is rotated, which means rotation
/// requires a release — acceptable, because the alternative is fetching the trust anchor over
/// the network, and a trust anchor you can be talked out of is not one.
public enum LicensePublicKey {

  /// Empty until a keypair is generated and the issuing service exists.
  ///
  /// Empty is the SAFE value and the build is fully functional with it: `TokenVerifier`
  /// answers `notConfigured`, every license evaluates to `.none`, and every ungated route —
  /// which is all of them until one declares a tier — is untouched. A placeholder that
  /// verified anything would be the dangerous choice, so there is not one.
  public static let base64 = "HzGEqany62//wdr3EGCtCBlpy7TgDu1yFIMsKGUJ8H0="

  /// Whether this build can verify anything at all.
  ///
  /// The switch that decides whether the subscription gate is composed. A build with no trust
  /// anchor cannot evaluate a license, so it must not refuse anyone for failing to have one:
  /// enforcement would mean gated routes answering 402 to every caller, with no possible way
  /// to satisfy them. Unconfigured therefore gates NOTHING, and dropping a key in is what
  /// turns enforcement on.
  public static var isConfigured: Bool {
    !base64.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// Parses a raw 32-byte key from base64.
  ///
  /// Raw bytes, not DER: swift-crypto wants the 32 bytes and WebCrypto wants PKCS8, so the
  /// two sides agree on the only representation neither has to unwrap. Public so the
  /// cross-language fixture test can point the verifier at a throwaway key.
  public static func parse(base64: String) throws -> Curve25519.Signing.PublicKey {
    let trimmed = base64.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw TokenVerificationError.notConfigured }
    guard let data = Data(base64Encoded: trimmed), data.count == 32 else {
      throw TokenVerificationError.malformedToken("public key is not 32 base64-encoded bytes")
    }
    do {
      return try Curve25519.Signing.PublicKey(rawRepresentation: data)
    } catch {
      throw TokenVerificationError.malformedToken("public key rejected: \(error)")
    }
  }

  static func key() throws -> Curve25519.Signing.PublicKey { try parse(base64: base64) }
}

public enum TokenVerifier {

  /// The newest claim format this build can read.
  public static let supportedVersion = 1

  /// Verifies a compact token and decodes its claims.
  ///
  /// Signature FIRST, claims second. Decoding attacker-controlled JSON before establishing
  /// that we signed it would widen the attack surface to the decoder for no reason.
  public static func verify(
    _ token: String,
    publicKey: Curve25519.Signing.PublicKey? = nil
  ) throws -> EntitlementToken {
    let key = try publicKey ?? LicensePublicKey.key()

    let segments = token.split(separator: ".", omittingEmptySubsequences: false)
    guard segments.count == 3 else {
      throw TokenVerificationError.malformedToken("expected 3 segments, got \(segments.count)")
    }
    guard let signature = decode(base64URL: String(segments[2])) else {
      throw TokenVerificationError.malformedToken("signature is not base64url")
    }
    guard let signed = "\(segments[0]).\(segments[1])".data(using: .utf8) else {
      throw TokenVerificationError.malformedToken("token is not UTF-8")
    }
    guard key.isValidSignature(signature, for: signed) else {
      throw TokenVerificationError.badSignature
    }
    guard let payload = decode(base64URL: String(segments[1])) else {
      throw TokenVerificationError.malformedToken("claims are not base64url")
    }

    let claims: EntitlementToken.Claims
    do {
      claims = try JSONDecoder().decode(EntitlementToken.Claims.self, from: payload)
    } catch {
      throw TokenVerificationError.malformedClaims(String(describing: error))
    }
    guard claims.v <= supportedVersion else {
      throw TokenVerificationError.unsupportedVersion(claims.v)
    }
    return EntitlementToken(claims: claims)
  }

  /// base64url, padding optional.
  ///
  /// JWS omits the padding and `Data(base64Encoded:)` requires it, so it is restored here
  /// rather than the token format being bent to suit Foundation.
  static func decode(base64URL text: String) -> Data? {
    var working = text.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let remainder = working.count % 4
    if remainder != 0 { working += String(repeating: "=", count: 4 - remainder) }
    return Data(base64Encoded: working)
  }

  /// The encoder half, for tests and for the issuing service's own fixtures. Not used by the
  /// server at runtime — nothing here ever creates a token.
  public static func encode(base64URL data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
