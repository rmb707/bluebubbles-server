//  ReplayTierSelectionTests
//  The derived route set is the load-bearing half of the tier ladder, so it is asserted
//  against the route table rather than trusted.
//
//  `ReplayTierSelection.privateAPIBackedRoutes` decides which recorded fixtures may be
//  replayed at `BB_PARITY_TIER=stub`, and the claim it rests on is a strong one: a route
//  carrying `requires: .privateAPI` reaches the published `FailingPrivateAPI` double and
//  stops there, because that double is a struct with no socket and no IMCore. If the
//  derivation ever admitted a route that does NOT carry that gate, the replay would drive
//  AppleScript against whatever account this Mac is signed in to.
//
//  So this suite asserts the derivation both ways: that it finds the gated routes, and that
//  it cannot possibly contain a sending one.

import BBHTTPAPI
import BBParity
import Foundation
import Testing

@Suite("Replay tier selection")
struct ReplayTierSelectionTests {

  private var routes: Set<String> { ReplayTierSelection.privateAPIBackedRoutes }

  @Test("The derived set is the route table's own Private API gate, nothing else")
  func derivationMatchesTheTable() {
    // Recomputed here from the same source but by a different route, so a typo in either
    // spelling shows up as a disagreement rather than as agreement with itself.
    var expected = 0
    for group in RouteTable.groups {
      for route in group.routes where route.requirements.contains(.privateAPI) {
        expected += 1
      }
    }
    #expect(routes.count == expected)
    #expect(expected > 0, "the table has Private API routes; a zero here means the scan broke")
  }

  @Test("It contains the gated chat routes, spelled as the router spells them")
  func containsKnownGatedRoutes() {
    #expect(routes.contains("POST /api/v1/chat/:guid/read"))
    #expect(routes.contains("POST /api/v1/chat/:guid/unread"))
    #expect(routes.contains("POST /api/v1/chat/:guid/typing"))
    #expect(routes.contains("DELETE /api/v1/chat/:guid/typing"))
  }

  /// **The safety assertion.** Everything else in the ladder is a convenience; this is the
  /// one that stops a test suite messaging somebody.
  @Test("No route that can send is in the set")
  func sendsAreNeverInTheSet() {
    for route in [
      "POST /api/v1/message/text",
      "POST /api/v1/message/attachment",
      "POST /api/v1/message/attachment/chunk",
      "POST /api/v1/message/multipart",
      "POST /api/v1/chat/new",
    ] {
      #expect(!routes.contains(route), "\(route) must never be admitted by the stub tier")
    }
  }

  /// The same property, stated so it survives a route being added.
  ///
  /// A route named above is one somebody thought of. This catches the one nobody did: every
  /// member of the set is re-checked against the table for its gate, so an entry that got in
  /// without one fails here whatever it is called.
  @Test("Every member of the set carries the gate that makes it safe")
  func everyMemberIsGated() {
    var gated: Set<String> = []
    for group in RouteTable.groups {
      for route in group.routes where route.requirements.contains(.privateAPI) {
        let segments = ["api", "v1", group.prefix, route.path]
          .filter { !$0.isEmpty }.joined(separator: "/")
        gated.insert("\(route.method.rawValue.uppercased()) /\(segments)")
      }
    }
    #expect(
      routes.subtracting(gated).isEmpty, "ungated routes in the set: \(routes.subtracting(gated))")
  }

  @Test("The deny-listed routes are not in the set either")
  func denyListedRoutesAreNotAdmitted() {
    // `mac/lock` is not Private-API-gated, so it could not arrive here anyway — but it is
    // worth a line, because "it cannot happen for a reason I have in my head" is how the
    // screen got locked the first time.
    for route in FixtureReplay.destructiveRoutes {
      #expect(!routes.contains(route), "\(route) is deny-listed and must never be admitted")
    }
  }

  @Test("The double answers only operations the reference recorded a success for")
  func succeedingSetIsEmptyAtTheDefaultTier() {
    // The default run must be byte-for-byte the run it always was.
    #expect(ReplayTierSelection.succeedingOperations(at: .harness).isEmpty)
    #expect(!ReplayTierSelection.succeedingOperations(at: .privateAPIDouble).isEmpty)
  }
}
