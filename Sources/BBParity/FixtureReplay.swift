//  FixtureReplay
//  Issues a recorded request against a running server and diffs the answer.
//
//  ONE caller: `Tests/CompatibilityTests/FixtureReplayTests`, which mounts the real router
//  in-process over a synthetic `chat.db` and runs the whole corpus on every CI build. It
//  compares SHAPE, because the fixtures were recorded against a real Mac's messages and this
//  one has seven.
//
//  This header used to open with "Two callers, deliberately" and name
//  `bb-parity replay --candidate …` as the second, reading the corpus against a server with
//  real data so the comparison could be strict. **There is no such subcommand and never was.**
//  `bb-parity` takes `--reference` and `--candidate` and asks two LIVE servers the same
//  questions through `SideBySideRunner`; it reads no fixtures and does not touch this type.
//  The claim was load-bearing enough to be copied into CONTRIBUTING.md before anyone opened
//  `Sources/ParityTool` to check, which is rule 8 in the root CLAUDE.md doing exactly what it
//  warns about.
//
//  The `mode` parameter is still real and still worth having: `.strict` is what
//  `SideBySideRunner` gets from `ResponseDiff.compare`'s own default, and a future caller
//  holding one database could pass it here.

import Foundation

/// What one replayed fixture produced.
public struct ReplayResult: Sendable {
  public let fixture: String
  public let method: String
  public let path: String
  public let expectedStatus: Int
  public let actualStatus: Int
  public let differences: [Difference]
  /// Why this fixture was not compared at all, if it was not.
  public let skipped: SkipReason?
  public let error: String?

  public enum SkipReason: String, Sendable {
    /// The fixture's own reference is this server. Replaying it compares the candidate
    /// with a photograph of the candidate, which cannot fail and proves nothing.
    case selfRecorded = "recorded from this server, not the reference"
    /// The recorder stored a digest instead of the bytes.
    case binaryBody = "binary response body"
    /// The recorder round-tripped a multipart body through UTF-8, which is lossy.
    case lossyRequestBody = "multipart body was not recorded byte-exactly"
    /// Not JSON on one side or the other, so there is no object to diff.
    case nonJSONBody = "response is not JSON"
    /// The route does something to the machine, and a replay would do it for real.
    case destructive = "the route acts on this Mac and is never replayed"
    /// The route reaches only the Private API double, and this run did not ask for that
    /// tier. Distinct from `.destructive` because it is a SETTING, not a refusal: the
    /// fixture is replayable and simply was not asked for. Reporting both as "destructive"
    /// would make a run that could have covered sixty more routes look as though it had
    /// been protected from them.
    case aboveTier = "above the tier this run was asked for (see BB_PARITY_TIER)"
  }

  /// Whether the two agree. A skipped fixture is not a match: it is an absence of one.
  ///
  /// **`.notCompared` is not a match either**, and this used to say it was:
  /// `differences.allSatisfy { $0.kind == .notCompared }` is true of an empty list AND of a
  /// list made entirely of "I could not check this". `ResponseDiff` raises that kind
  /// precisely so a replay can count what it could not see instead of scoring it as a pass —
  /// its own comment says the failure this harness exists to prevent is a check that
  /// silently stops checking — and then the scorer counted it as a pass.
  ///
  /// It was not theoretical: six of the forty-four fixtures the corpus called matching were
  /// matching only on unverified arrays, `data.properties` and a whole `data` among them.
  /// Those are now failures with a baseline entry each, which is the difference between a
  /// gap you can read and a gap that reads as a pass.
  public var isMatch: Bool {
    skipped == nil && error == nil && expectedStatus == actualStatus && differences.isEmpty
  }
}

public struct FixtureReplay: Sendable {

  private let baseURL: String
  private let password: String
  private let mode: DiffMode
  private let session: URLSession
  /// The highest tier this run will replay. See `ReplayTier`.
  public let ceiling: ReplayTier
  /// Routes that reach the Private API and stop there, as `"POST /api/v1/chat/:guid/read"`.
  ///
  /// INJECTED rather than listed here, because the authority is `RouteTable`'s own
  /// `requires: .privateAPI` and a second copy would drift from it silently — which is the
  /// failure this whole harness exists to catch. `BBParity` has no dependencies on purpose,
  /// so the caller derives the set and hands it over.
  ///
  /// Empty is the safe default: with no set, nothing is recognised as double-backed and
  /// every non-harness route stays at `.realMac`, which is never admitted.
  public let privateAPIBackedRoutes: Set<String>

  /// - Parameter mode: `.shape` when the server under test holds different data from the
  ///   one the corpus was recorded against, which is every in-process run.
  /// - Parameter ceiling: how far this run may reach. Defaults to `.harness`, which is what
  ///   was replayed before tiers existed.
  public init(
    baseURL: String, password: String, mode: DiffMode = .shape,
    ceiling: ReplayTier = .harness, privateAPIBackedRoutes: Set<String> = []
  ) {
    self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
    self.password = password
    self.mode = mode
    self.ceiling = ceiling
    self.privateAPIBackedRoutes = privateAPIBackedRoutes

    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    self.session = URLSession(configuration: configuration)
  }

  public func run(_ fixtures: [RecordedFixture]) async -> [ReplayResult] {
    var results: [ReplayResult] = []
    // Sequential. Several of these fixtures write to the server's own database (a
    // webhook, a theme, a scheduled message) and running them concurrently would let one
    // fixture's write land inside another's read.
    for fixture in fixtures {
      results.append(await replay(fixture))
    }
    return results
  }

  public func replay(_ fixture: RecordedFixture) async -> ReplayResult {
    if let reason = skipReason(for: fixture) {
      return ReplayResult(
        fixture: fixture.name, method: fixture.request.method,
        path: fixture.request.routePath,
        expectedStatus: fixture.response.status, actualStatus: 0,
        differences: [], skipped: reason, error: nil
      )
    }

    do {
      let (status, object, raw) = try await send(fixture)

      guard let expected = fixture.response.body.jsonObject else {
        return ReplayResult(
          fixture: fixture.name, method: fixture.request.method,
          path: fixture.request.routePath,
          expectedStatus: fixture.response.status, actualStatus: status,
          differences: [], skipped: .nonJSONBody, error: nil
        )
      }
      guard let actual = object else {
        return ReplayResult(
          fixture: fixture.name, method: fixture.request.method,
          path: fixture.request.routePath,
          expectedStatus: fixture.response.status, actualStatus: status,
          differences: [
            .init(kind: .typeDiffers, path: "<body>", detail: "object vs \(raw.prefix(80))")
          ],
          skipped: nil, error: nil
        )
      }

      return ReplayResult(
        fixture: fixture.name, method: fixture.request.method,
        path: fixture.request.routePath,
        expectedStatus: fixture.response.status, actualStatus: status,
        differences: ResponseDiff.compare(expected: expected, actual: actual, mode: mode),
        skipped: nil, error: nil
      )
    } catch {
      return ReplayResult(
        fixture: fixture.name, method: fixture.request.method,
        path: fixture.request.routePath,
        expectedStatus: fixture.response.status, actualStatus: 0,
        differences: [], skipped: nil, error: String(describing: error)
      )
    }
  }

  private func skipReason(for fixture: RecordedFixture) -> ReplayResult.SkipReason? {
    // The tier the fixture NEEDS against the tier this run allows. `.harness` is the
    // default and reproduces the flat deny-list exactly; see `ReplayTier`.
    let needed = Self.tier(for: fixture, privateAPIBackedRoutes: privateAPIBackedRoutes)
    if needed > ceiling {
      return needed == .privateAPIDouble ? .aboveTier : .destructive
    }
    if fixture.recordedFrom == .swift { return .selfRecorded }
    if case .binary = fixture.response.body { return .binaryBody }
    // A multipart upload's body was stored as UTF-8 text, which replaced every non-UTF-8
    // byte of the embedded PNG with U+FFFD. Re-encoding that and calling it the same
    // request would test the harness's corruption, not the server.
    if case .text = fixture.request.body { return .lossyRequestBody }
    return nil
  }

  private func send(
    _ fixture: RecordedFixture
  ) async throws -> (status: Int, json: [String: Any]?, raw: String) {
    var components = URLComponents(string: baseURL + fixture.request.routePath)
    var items = fixture.request.queryItemsWithoutPassword
    items.append(URLQueryItem(name: "password", value: password))
    components?.queryItems = items

    guard let url = components?.url else {
      throw ReplayError.badURL(baseURL + fixture.request.path)
    }

    var request = URLRequest(url: url)
    request.httpMethod = fixture.request.method
    if case .json(let encoded) = fixture.request.body {
      request.httpBody = Data(encoded.utf8)
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    let (data, response) = try await session.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    return (status, object, String(decoding: data, as: UTF8.self))
  }

  /// Routes that act on the machine, refused before the request is built.
  ///
  /// **This is not a nicety.** The first run of this harness locked the developer's Mac:
  /// `POST /mac/lock` was in the corpus, the handler is real, and a replay is a request like
  /// any other. It went on to restart Messages and kick off a service restart in the same
  /// pass, on a machine that was being used over a remote session at the time.
  ///
  /// A deny-list rather than a "test mode" flag on the handlers, for two reasons: the flag
  /// would be one more thing a future harness could forget to set, and the handlers are
  /// exactly what this is here to exercise faithfully. Refusing at the driver keeps the
  /// server honest and the driver safe.
  ///
  /// Matched on the route, not on the fixture name, so a re-recording with a different
  /// filename is still refused.
  public static let destructiveRoutes: Set<String> = [
    // Locks the screen. Nothing recovers from this without the operator's password.
    "POST /api/v1/mac/lock",
    // Quits and relaunches Messages.app, dropping whatever the operator was doing in it.
    "POST /api/v1/mac/imessage/restart",
    // Tears down every service, or the whole process, under the test that is driving it.
    "GET /api/v1/server/restart/soft",
    "GET /api/v1/server/restart/hard",
    // Downloads and installs a new build of the server.
    "POST /api/v1/server/update/install",
  ]

  /// How far this fixture reaches, and therefore the tier it needs to be admitted.
  ///
  /// The order is the ladder, floor first. A route can only move DOWN it by being provably
  /// unable to reach further, never by looking harmless.
  ///
  /// - Parameter privateAPIBackedRoutes: routes carrying `requires: .privateAPI`, derived
  ///   by the caller from `RouteTable`. See the property of the same name.
  public static func tier(
    for fixture: RecordedFixture, privateAPIBackedRoutes: Set<String> = []
  ) -> ReplayTier {
    let route = "\(fixture.request.method) \(fixture.request.routePath)"
    // The floor. Nothing moves these, and nothing should be able to.
    if destructiveRoutes.contains(route) { return .never }
    // A GET changes nothing anywhere. This is the bulk of the corpus.
    if fixture.request.method == "GET" { return .harness }
    // The four reads that happen to be POSTs.
    if readOnlyWrites.contains(route) { return .harness }
    // A write that is not under a sending prefix touches the server's own database and
    // nothing else: a webhook row, a theme blob, a scheduled message. In the in-process
    // harness that database is in memory, so the write does not outlive the run.
    guard sendingPrefixes.contains(where: { fixture.request.routePath.hasPrefix($0) }) else {
      return .harness
    }
    // Under a sending prefix, the Private API gate is what decides. A gated route reaches
    // the published double and stops; an UNgated one under these prefixes is the
    // AppleScript path, which needs no helper and will message a real person.
    //
    // Matched against the route's TEMPLATE, since the fixture carries a concrete path.
    if privateAPIBackedRoutes.contains(where: { matches(template: $0, route: route) }) {
      return .privateAPIDouble
    }
    return .realMac
  }

  /// Whether a concrete `"POST /api/v1/chat/any;-;x@example.com/read"` is an instance of a
  /// template `"POST /api/v1/chat/:guid/read"`.
  ///
  /// Segment-wise, because a chat GUID contains `;` and `+` and, on the group routes, a
  /// second GUID-shaped segment after it. A substring test would match
  /// `/chat/:guid/participant` against `/chat/:guid/participant/add`, which are different
  /// routes with different tiers.
  static func matches(template: String, route: String) -> Bool {
    let left = template.split(separator: " ", maxSplits: 1)
    let right = route.split(separator: " ", maxSplits: 1)
    guard left.count == 2, right.count == 2, left[0] == right[0] else { return false }
    let templateSegments = left[1].split(separator: "/", omittingEmptySubsequences: false)
    let routeSegments = right[1].split(separator: "/", omittingEmptySubsequences: false)
    guard templateSegments.count == routeSegments.count else { return false }
    for (templateSegment, routeSegment) in zip(templateSegments, routeSegments) {
      if templateSegment.hasPrefix(":") { continue }
      if templateSegment != routeSegment { return false }
    }
    return true
  }

  /// Whether this fixture is withheld from a DEFAULT run.
  ///
  /// The corpus is documented as read-only and mostly is, but the send fixtures were
  /// recorded and committed, and "the helper is not connected so it will fail anyway" is an
  /// assumption about the machine the test runs on, not a property of the test. The
  /// AppleScript backend needs no helper.
  ///
  /// Kept as the DEFAULT-TIER question rather than being replaced by `tier(for:)`, and the
  /// distinction matters: `ReplayDenyListTests` and `DenyListedShapeCoverageTests` assert
  /// against this, and what they are really asserting is "not replayed unless somebody asks
  /// for it", which is still exactly true. A fixture that only reaches the Private API
  /// double is withheld here — because the default ceiling is `.harness` — and is admitted
  /// by `BB_PARITY_TIER=stub`, which is a deliberate act.
  ///
  /// Note that it takes no route set, so a double-backed route is not recognised as one and
  /// falls to `.realMac`. That is the safe direction, and the only direction a default may
  /// round in.
  public static func isDestructive(_ fixture: RecordedFixture) -> Bool {
    tier(for: fixture) > .harness
  }

  /// Non-GET routes that read and nothing more.
  public static let readOnlyWrites: Set<String> = [
    "POST /api/v1/message/query",
    "POST /api/v1/chat/query",
    "POST /api/v1/handle/query",
    "POST /api/v1/contact/query",
  ]

  /// Path prefixes whose non-GET routes reach Messages or FaceTime.
  public static let sendingPrefixes: [String] = [
    "/api/v1/message/", "/api/v2/message/",
    "/api/v1/chat/", "/api/v2/chat/",
    "/api/v1/facetime/", "/api/v2/facetime/",
    "/api/v1/handle/", "/api/v1/icloud/",
  ]

  public enum ReplayError: Error, CustomStringConvertible {
    case badURL(String)
    public var description: String {
      switch self {
      case .badURL(let url): "Could not build a URL from \(url)"
      }
    }
  }
}

extension Array where Element == ReplayResult {

  /// A readable report, worst first.
  ///
  /// Ordered by how much is wrong rather than by name, because the moment this output
  /// matters is the moment a hundred lines scroll past and only the top ten get read.
  public func report(showingMatches: Bool = false, limit: Int = 12) -> String {
    var lines: [String] = []
    let compared = filter { $0.skipped == nil && $0.error == nil }
    let failing = compared.filter { !$0.isMatch }
      .sorted { ($0.differences.count, $0.fixture) > ($1.differences.count, $1.fixture) }

    for result in failing {
      var headline = "✗ \(result.fixture)\n  \(result.method) \(result.path)"
      if result.expectedStatus != result.actualStatus {
        headline += ": status \(result.expectedStatus) vs \(result.actualStatus)"
      }
      let real = result.differences.filter { $0.kind != .notCompared }
      if !real.isEmpty { headline += ": \(real.count) difference(s)" }
      lines.append(headline)
      for difference in real.prefix(limit) { lines.append("    \(difference)") }
      if real.count > limit { lines.append("    … and \(real.count - limit) more") }
    }

    if showingMatches {
      for result in compared where result.isMatch {
        lines.append("✓ \(result.method) \(result.path) (\(result.actualStatus))")
      }
    }

    let skipped = filter { $0.skipped != nil }
    if !skipped.isEmpty {
      var counts: [String: Int] = [:]
      for result in skipped { counts[result.skipped!.rawValue, default: 0] += 1 }
      lines.append("")
      for (reason, count) in counts.sorted(by: { $0.key < $1.key }) {
        lines.append("· \(count) not replayed: \(reason)")
      }
    }

    lines.append("")
    lines.append(
      "\(compared.filter(\.isMatch).count)/\(compared.count) replayed fixtures match "
        + "(\(count) in the corpus)."
    )
    return lines.joined(separator: "\n")
  }
}
