//  EntitlementClient
//  One POST: a license key and a machine fingerprint, in; a signed token, out.
//
//  This is the whole of what the server knows about the vendor. Which payment processor sits
//  behind the endpoint, how a product maps onto a tier, what a subscription costs — none of it
//  is expressible here, and that is the point. Changing processor is a change to the issuing
//  function; this file, the token format, the settings keys and every test above them are
//  untouched.
//
//  The KEY leaves the machine here and nowhere else. It goes to our issuer over HTTPS and is
//  never written to a log, an alert or a response body.
//
//  A failure is a normal outcome, not an exception: a Mac asleep, a rebooted router, our
//  endpoint restarting. Every one of them lands as a thrown error that the caller counts and
//  otherwise ignores, because the token already in hand stays valid for its window.

import BBLicense
import Foundation

public enum EntitlementClientError: Error, Equatable, Sendable {
  case badEndpoint(String)
  case transport(String)
  /// The issuer answered, and said no. Distinguished from a transport failure because it is
  /// the only failure that means anything about the LICENSE rather than about the network.
  case rejected(status: Int, reason: String?)
  case malformedResponse(String)
}

/// What the issuer answers.
public struct EntitlementResponse: Sendable, Equatable {
  /// The signed token, compact form.
  public let token: String
  /// Set when the issuer wants this license treated as disabled. Separate from an HTTP error
  /// because it is a durable fact to persist, not a request that failed.
  public let isRevoked: Bool

  public init(token: String, isRevoked: Bool) {
    self.token = token
    self.isRevoked = isRevoked
  }
}

public struct EntitlementClient: Sendable {

  /// Injected so tests never reach the network and so the transport stays swappable.
  public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

  private let endpoint: String
  private let transport: Transport
  private let serverVersion: String

  public init(
    endpoint: String,
    serverVersion: String,
    transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }
  ) {
    self.endpoint = endpoint
    self.serverVersion = serverVersion
    self.transport = transport
  }

  public func exchange(key: String, machine: String) async throws -> EntitlementResponse {
    guard let url = URL(string: endpoint), url.scheme?.hasPrefix("http") == true else {
      throw EntitlementClientError.badEndpoint(endpoint)
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    // Short, and off the request path by construction: this only ever runs on the refresh
    // timer, so nothing is waiting on it. Long enough to survive a slow cold start at the
    // other end.
    request.timeoutInterval = 20
    // A cached entitlement is a stale entitlement; the whole purpose of the call is to learn
    // something new.
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      // `key`, not `license_key`: this is the issuer's request field, and spelling it the
      // same as the settings key would make two unrelated things read as one.
      "key": key,
      "machine_id": machine,
      "server_version": serverVersion,
    ])

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await transport(request)
    } catch {
      // Deliberately not `error.localizedDescription` into anything user-facing: this is
      // counted and logged, and the sentence a person reads comes from `LicenseRefusal`.
      throw EntitlementClientError.transport(String(describing: error))
    }

    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["reason"]
      throw EntitlementClientError.rejected(status: status, reason: reason as? String)
    }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw EntitlementClientError.malformedResponse("response is not a JSON object")
    }
    let isRevoked = object["revoked"] as? Bool ?? false
    let token = object["token"] as? String ?? ""

    // A REVOCATION LEGITIMATELY CARRIES NO TOKEN. There is no entitlement to describe, so the
    // issuer sends `{"token": null, "revoked": true}` and there is nothing for it to put
    // there. Requiring a token here made a refund unreportable: the guard threw
    // `malformedResponse`, `refresh()` recorded it as `.failed`, `markRevoked()` never ran,
    // and the customer kept paid features until the token aged out — at which point they were
    // told their subscription "could not be confirmed" rather than that it had been revoked.
    guard !isRevoked else {
      return EntitlementResponse(token: "", isRevoked: true)
    }

    // On a SUCCESS a missing token is still malformed. That is a broken issuer, not a
    // revocation, and quietly treating it as one would disable a paying customer.
    guard !token.isEmpty else {
      throw EntitlementClientError.malformedResponse("no token in response")
    }
    return EntitlementResponse(token: token, isRevoked: false)
  }
}
