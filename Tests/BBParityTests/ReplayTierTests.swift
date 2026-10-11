//  ReplayTierTests
//  The ladder decides what a test suite is allowed to do to the machine it runs on, so it is
//  asserted rather than read.
//
//  The failure this guards against is not subtle and has happened: the first run of the
//  replay harness locked this developer's Mac over a remote session. What is new is that the
//  guard is no longer a flat list — a route now moves tier on the strength of a derived
//  property — and a classification that silently widened would put a send back in scope with
//  nothing saying so.
//
//  The safety-relevant direction is the one to read first: `isDestructive` must still answer
//  yes for everything it answered yes for before tiers existed, because two other suites
//  assert against it and both are about not messaging real people.

import Foundation
import Testing

@testable import BBParity

@Suite("Replay tiers")
struct ReplayTierTests {

  private func fixture(_ method: String, _ path: String) -> RecordedFixture {
    RecordedFixture(
      name: "\(method.lowercased())_\(path).json",
      request: .init(
        method: method, path: path, headers: [:], body: .empty
      ),
      response: .init(status: 200, headers: [:], body: .empty)
    )
  }

  /// The route set the real suite derives from `RouteTable`. A handful of real entries, so
  /// the matcher is exercised against the shapes it actually meets.
  private let privateAPIRoutes: Set<String> = [
    "POST /api/v1/chat/:guid/read",
    "POST /api/v1/chat/:guid/typing",
    "POST /api/v1/chat/:guid/participant/add",
    "POST /api/v1/message/react",
    "PUT /api/v1/chat/:guid",
  ]

  // MARK: The ladder

  @Test("A GET reaches nothing and is always at the floor")
  func readsAreHarnessTier() {
    #expect(FixtureReplay.tier(for: fixture("GET", "/api/v1/chat/count")) == .harness)
    #expect(FixtureReplay.tier(for: fixture("GET", "/api/v1/message/count")) == .harness)
  }

  @Test("A write that only touches the server's own database is at the floor")
  func serverLocalWritesAreHarnessTier() {
    // app.db-backed, and in the harness that database is in memory.
    #expect(FixtureReplay.tier(for: fixture("POST", "/api/v1/webhook")) == .harness)
    #expect(FixtureReplay.tier(for: fixture("POST", "/api/v1/backup/theme")) == .harness)
    #expect(FixtureReplay.tier(for: fixture("POST", "/api/v1/contact")) == .harness)
    // The four reads that happen to be POSTs.
    #expect(FixtureReplay.tier(for: fixture("POST", "/api/v1/message/query")) == .harness)
    #expect(FixtureReplay.tier(for: fixture("POST", "/api/v1/chat/query")) == .harness)
  }

  @Test("A Private-API-gated route reaches the double and stops there")
  func gatedRoutesAreDoubleTier() {
    let read = fixture("POST", "/api/v1/chat/any;-;person@example.com/read")
    #expect(
      FixtureReplay.tier(for: read, privateAPIBackedRoutes: privateAPIRoutes)
        == .privateAPIDouble)
    let typing = fixture("POST", "/api/v1/chat/any;+;chat000000000000000001/typing")
    #expect(
      FixtureReplay.tier(for: typing, privateAPIBackedRoutes: privateAPIRoutes)
        == .privateAPIDouble)
  }

  /// **The one that matters.** A send is not gated on the Private API — the AppleScript
  /// backend needs no helper — so it must never be classified as reaching only the double,
  /// whatever set it is given.
  @Test("A send reaches the real Mac, and no route set can make it look otherwise")
  func sendsAreAlwaysRealMac() {
    for path in [
      "/api/v1/message/text", "/api/v1/message/attachment", "/api/v1/message/multipart",
      "/api/v1/chat/new",
    ] {
      #expect(
        FixtureReplay.tier(for: fixture("POST", path), privateAPIBackedRoutes: privateAPIRoutes)
          == .realMac,
        "\(path) must stay at the real-Mac tier"
      )
    }
  }

  @Test("The deny-list is the floor and no tier admits it")
  func denyListedRoutesAreNever() {
    #expect(FixtureReplay.tier(for: fixture("POST", "/api/v1/mac/lock")) == .never)
    #expect(
      FixtureReplay.tier(for: fixture("POST", "/api/v1/mac/imessage/restart")) == .never)
    #expect(FixtureReplay.tier(for: fixture("GET", "/api/v1/server/restart/hard")) == .never)
    #expect(
      FixtureReplay.tier(for: fixture("POST", "/api/v1/server/update/install")) == .never)
    // Even handed the full route set, and even though one of them is a GET.
    #expect(
      FixtureReplay.tier(
        for: fixture("GET", "/api/v1/server/restart/soft"),
        privateAPIBackedRoutes: privateAPIRoutes) == .never)
  }

  // MARK: The safety property two other suites rest on

  @Test("Without a route set, nothing is recognised as double-backed")
  func defaultClassificationRoundsSafe() {
    // `isDestructive` takes no set, so a gated route falls to `.realMac` rather than being
    // admitted. That is the only direction a default may round in.
    let read = fixture("POST", "/api/v1/chat/any;-;person@example.com/read")
    #expect(FixtureReplay.tier(for: read) == .realMac)
    #expect(FixtureReplay.isDestructive(read))
  }

  @Test("isDestructive still answers the default-tier question")
  func isDestructiveIsUnchanged() {
    // What `ReplayDenyListTests` and `DenyListedShapeCoverageTests` assert against.
    #expect(FixtureReplay.isDestructive(fixture("POST", "/api/v1/mac/lock")))
    #expect(FixtureReplay.isDestructive(fixture("POST", "/api/v1/message/text")))
    #expect(FixtureReplay.isDestructive(fixture("POST", "/api/v1/message/react")))
    #expect(!FixtureReplay.isDestructive(fixture("POST", "/api/v1/message/query")))
    #expect(!FixtureReplay.isDestructive(fixture("GET", "/api/v1/ping")))
  }

  // MARK: The matcher

  @Test("A template matches an instance segment for segment")
  func templateMatching() {
    #expect(
      FixtureReplay.matches(
        template: "POST /api/v1/chat/:guid/read",
        route: "POST /api/v1/chat/any;-;person@example.com/read"))
    // A chat GUID carries `;` and `+`, which is why this is segment-wise rather than a
    // substring or a regular expression.
    #expect(
      FixtureReplay.matches(
        template: "POST /api/v1/chat/:guid/read",
        route: "POST /api/v1/chat/any;+;chat000000000000000001/read"))
  }

  @Test("A longer path is not an instance of a shorter template")
  func templateRejectsExtraSegments() {
    // The case a substring test gets wrong, and it is a tier boundary: these are two
    // different routes and a naive match would hand one the other's classification.
    #expect(
      !FixtureReplay.matches(
        template: "POST /api/v1/chat/:guid/participant",
        route: "POST /api/v1/chat/any;+;x/participant/add"))
  }

  @Test("The verb is part of the identity")
  func templateRejectsWrongVerb() {
    #expect(
      !FixtureReplay.matches(
        template: "POST /api/v1/chat/:guid/typing",
        route: "DELETE /api/v1/chat/any;-;person@example.com/typing"))
  }

  // MARK: Reading the environment

  @Test("No variable means the tier that was always replayed")
  func defaultIsHarness() {
    #expect(ReplayTier.requested(from: [:]) == .ceiling(.harness))
    #expect(ReplayTier.requested(from: ["BB_PARITY_TIER": ""]) == .ceiling(.harness))
  }

  @Test("The stub tier is spelled `stub` and is admitted")
  func stubIsAdmitted() {
    #expect(ReplayTier.requested(from: ["BB_PARITY_TIER": "stub"]) == .ceiling(.privateAPIDouble))
    #expect(ReplayTier.requested(from: ["BB_PARITY_TIER": " STUB "]) == .ceiling(.privateAPIDouble))
  }

  @Test("A tier that is named but not built is refused, not ignored")
  func unbuiltTiersAreRefused() {
    // Refused rather than falling back, because a run that quietly dropped to the default
    // would report a pass over a tier it never touched.
    let live = ReplayTier.requested(from: ["BB_PARITY_TIER": "live"])
    #expect(live == .notBuilt(.realMac))
    #expect(live.ceiling == nil)
    #expect(live.refusal?.contains("is not built") == true)
    #expect(ReplayTier.requested(from: ["BB_PARITY_TIER": "never"]) == .notBuilt(.never))
  }

  @Test("An unrecognised value is refused and names what is supported")
  func unrecognisedValuesAreRefused() {
    let nonsense = ReplayTier.requested(from: ["BB_PARITY_TIER": "yes-please"])
    #expect(nonsense == .unrecognised("yes-please"))
    #expect(nonsense.ceiling == nil)
    #expect(nonsense.refusal?.contains("harness") == true)
    #expect(nonsense.refusal?.contains("stub") == true)
  }
}
