//  SecretsEnvelope
//  The only way secrets leave this server, and the reason they can.
//
//  **The server password is both the gate and the key.** Exporting secrets requires typing
//  the password this server accepts, and the archive is encrypted with a key
//  derived from it. That is one decision doing two jobs on purpose:
//
//    - it proves the person exporting already has the credential that owns the server, so
//      the export grants them nothing they did not have;
//    - and it means the file is useless to whoever finds it later, which matters because a
//      ZIP is a thing people email themselves and leave in Downloads.
//
//  **A server with no password cannot export secrets at all.** Not "exports them in the
//  clear", not "asks for a different passphrase": refused. An empty password is the shipped
//  default and the state a fresh install sits in, so allowing it would mean the least
//  configured servers produce the most dangerous files. `PasswordPolicy` exempts the empty
//  string for its own good reasons; this is where that exemption stops.
//
//  The iteration count is stored in each envelope rather than assumed, so raising it does
//  not strand archives written under the old one.
//
//  PBKDF2 rather than HKDF, and this is the distinction that matters when a KEY comes from
//  a PASSWORD: HKDF is a fast extract-and-expand over material that is already
//  high-entropy, and applying it to something a person typed hands an attacker an offline
//  guessing oracle at the speed of a hash. PBKDF2's work factor is the whole point. The salt
//  is random per export, so two exports of the same server under the same password do not
//  produce the same key.

import Crypto
import Foundation
import _CryptoExtras

/// The encrypted `secrets.enc` member of an archive.
public struct SecretsEnvelope: Codable, Sendable {

  /// Bumped if the derivation or the cipher changes. An envelope from a future version is
  /// refused rather than attempted; see `open`.
  public static let currentVersion = 1

  /// Named in the file rather than implied by the version, so somebody reading an archive
  /// later can see what they are holding without this source.
  public static let algorithm = "PBKDF2-HMAC-SHA256+AES-256-GCM"

  /// 210,000, the OWASP floor for PBKDF2-HMAC-SHA256.
  ///
  /// Stored in the file rather than assumed, so raising it later does not strand archives
  /// made under the old count: `open` uses whatever the envelope says.
  public static let iterations = 210_000

  public let version: Int
  public let algorithm: String
  public let iterations: Int
  /// Base64. Random per export, so the same password over the same server twice yields two
  /// different keys.
  public let salt: Data
  public let nonce: Data
  public let ciphertext: Data
  public let tag: Data

  public enum Failure: Error, Equatable, CustomStringConvertible {
    /// This server has no password, so there is nothing to gate the export with.
    case noServerPassword
    /// The password given is not the one this server accepts.
    case wrongPassword
    /// The archive was written by a newer version of this format.
    case unsupportedVersion(Int)
    /// The password was right for the gate but the envelope will not open, which means the
    /// file has been altered or truncated.
    case corrupt

    public var description: String {
      switch self {
      case .noServerPassword:
        "This server has no password, so secrets cannot be exported. Set a server password "
          + "first: it is what the export is encrypted with."
      case .wrongPassword:
        "That is not this server's password."
      case .unsupportedVersion(let version):
        "This archive's secrets were written by a newer version of BlueBubbles (format "
          + "\(version)). Update before importing it."
      case .corrupt:
        "The password was accepted but the encrypted section could not be read. The file is "
          + "damaged or was modified after it was made."
      }
    }
  }

  /// Encrypts `payload` under a key derived from the server password.
  ///
  /// - Parameter password: the password this server accepts. Refused when empty;
  ///   see the header.
  public static func seal(_ payload: Data, withServerPassword password: String) throws
    -> SecretsEnvelope
  {
    guard !password.isEmpty else { throw Failure.noServerPassword }

    var salt = Data(count: 32)
    salt.withUnsafeMutableBytes { buffer in
      guard let base = buffer.baseAddress else { return }
      // The system generator, not `SystemRandomNumberGenerator` over a loop: this is key
      // material and the platform's CSPRNG is the thing to ask.
      _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, base)
    }

    let key = try derive(password: password, salt: salt, iterations: iterations)
    let sealed = try AES.GCM.seal(payload, using: key)
    return SecretsEnvelope(
      version: currentVersion,
      algorithm: algorithm,
      iterations: iterations,
      salt: salt,
      nonce: Data(sealed.nonce),
      ciphertext: sealed.ciphertext,
      tag: sealed.tag
    )
  }

  /// Decrypts, or says which of the three things went wrong.
  ///
  /// A wrong password and a damaged file are told apart by the CALLER having already
  /// checked the password against this server, because AES-GCM cannot distinguish them: a
  /// bad key and a bad ciphertext both fail the tag. `ServerImporter` does that check, which
  /// is what lets the message say "that is not the password" rather than "it did not work".
  public func open(withPassword password: String) throws -> Data {
    guard version <= Self.currentVersion else {
      throw Failure.unsupportedVersion(version)
    }
    let key = try Self.derive(password: password, salt: salt, iterations: iterations)
    do {
      let box = try AES.GCM.SealedBox(
        nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
      return try AES.GCM.open(box, using: key)
    } catch {
      throw Failure.corrupt
    }
  }

  private static func derive(password: String, salt: Data, iterations: Int) throws
    -> SymmetricKey
  {
    try KDF.Insecure.PBKDF2.deriveKey(
      from: Data(password.utf8),
      salt: salt,
      using: .sha256,
      outputByteCount: 32,
      rounds: iterations
    )
  }
}
