//  ReplayTierSelection
//  Which tier this run replays at, and which routes belong to the Private API tier.
//
//  Two jobs that both have to be right, and only one of them is interesting.
//
//  The dull one is reading `BB_PARITY_TIER`. The interesting one is deciding which routes
//  reach the published Private API double and stop there, because THAT is what makes the
//  second tier safe. Getting it wrong in one direction withholds a route that could have
//  been replayed; getting it wrong in the other lets AppleScript message somebody.
//
//  So it is not a list. It is derived from `RouteTable` itself — every route carrying
//  `requires: .privateAPI` — which is the same declaration the running server gates on. A
//  hand-kept list would be a second copy of a security-relevant fact, and this repository
//  has already learned what happens to second copies: `ValidationRuleParityTests` and
//  `RequestParameterParityTests` both exist because prose about the route table drifted from
//  the route table. A route that gains or loses its Private API gate moves tier here on the
//  next build, with nothing to remember.
//
//  `BBParity` takes the set as an argument rather than computing it, because it has no
//  dependencies on purpose and reaching into `BBHTTPAPI` to classify fixtures would invert
//  that. See `FixtureReplay.privateAPIBackedRoutes`.

import BBHTTPAPI
import BBParity
import BBTestSupport
import Foundation

/// Spelled once here so the selection below reads as a list of operations rather than a
/// list of deeply-qualified names.
typealias FailingPrivateAPIOperation = FailingPrivateAPI.VoidOperation

enum ReplayTierSelection {

  /// Every v1 route gated on the Private API, as `"POST /api/v1/chat/:guid/read"`.
  ///
  /// Templates, not concrete paths: the fixture carries `any;-;person@example.com` where the
  /// table carries `:guid`, and `FixtureReplay.matches(template:route:)` is what bridges
  /// them. v1 only, because the replay suite is v1 only — see `FixtureReplayTests`.
  static var privateAPIBackedRoutes: Set<String> {
    var routes: Set<String> = []
    for group in RouteTable.groups {
      for route in group.routes where route.requirements.contains(.privateAPI) {
        let segments = ["api", "v1", group.prefix, route.path]
          .filter { !$0.isEmpty }
          .joined(separator: "/")
        routes.insert("\(route.method.rawValue.uppercased()) /\(segments)")
      }
    }
    return routes
  }

  /// The ceiling this run was asked for.
  ///
  /// Refuses rather than falls back. A malformed or unbuilt request that quietly became
  /// `.harness` would report a pass over a tier it never touched, which is the one outcome
  /// this whole ladder exists to prevent.
  static func ceiling() throws -> ReplayTier {
    let requested = ReplayTier.requested()
    if let refusal = requested.refusal { throw TierRefusal(message: refusal) }
    // `refusal` is nil exactly when a ceiling is present.
    return requested.ceiling ?? .harness
  }

  struct TierRefusal: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
  }

  /// What the double is allowed to answer at the Private API tier.
  ///
  /// **Only the operations whose fixture recorded a 200.** The reason is the one the
  /// `ReplayServer` header already gives for its five read closures: three of the recorded
  /// helper fixtures are 500s FROM THE REFERENCE, and a double that succeeded there would
  /// manufacture agreement instead of finding a difference. `leaveChat` is the sharp case —
  /// the corpus holds both a 200 and a 500 for it — so it is left throwing and its 200 sits
  /// in the baseline where it can be read.
  ///
  /// `notifyAnyways` is deliberately NOT here even though its fixture records a 200. The
  /// route does not merely call the helper: it then WAITS for a column on the row to move,
  /// which is what `FailingPrivateAPI.onNotify` exists to fake. Letting the plain set admit
  /// it made the call succeed and the wait run to its timeout, so the fixture failed as a
  /// harness error rather than a comparison. `edit` and `unsend` have the same shape.
  ///
  /// Empty at `.harness`, so the default run is byte-for-byte the run it always was.
  static func succeedingOperations(at ceiling: ReplayTier) -> Set<FailingPrivateAPIOperation> {
    guard ceiling >= .privateAPIDouble else { return [] }
    return [
      .markRead, .markUnread,
      .startTyping, .stopTyping,
      .setDisplayName, .updateGroupPhoto,
      .addParticipant, .removeParticipant,
      .shareNickname, .modifyActiveAlias,
      .deleteChat,
    ]
  }
}
