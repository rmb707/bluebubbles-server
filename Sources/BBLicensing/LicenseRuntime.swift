//  LicenseRuntime
//  The one live answer to "what is this server entitled to", and the only thing the HTTP gate
//  ever asks.
//
//  AN ACTOR HOLDING A VALUE, and the value is what makes the gate free. `LicenseStage` reads
//  `status()` on every gated request; if that read touched the settings store, let alone the
//  network, every gated request would inherit a database hop or a timeout. So the status is
//  computed when something changes — a refresh, a key being entered, the clock crossing a
//  boundary — and read from memory in between.
//
//  IT PRIMES ITSELF. The first `status()` loads the token from disk; nothing else has to
//  remember to. The load used to happen only in `LicenseService.start()`, which made the
//  gate's answer depend on a schedule having run: a server whose license service had not
//  started yet, or had been switched off, answered "no license" to a customer whose valid
//  token was sitting in settings. One settings read on the first gated request is the price,
//  and every read after it is the stored value.
//
//  IT HOLDS THE SECRET SO NOTHING ELSE HAS TO. `license_key` cannot be declared by a service
//  (see `LicenseStore`), so the service is handed this instead: it can ask whether a key
//  exists and ask for a refresh, and there is no method that returns the key. That is the
//  same shape as `authenticateRequests` — present a question, get an answer, never hold the
//  credential.
//
//  NOTHING HERE RAISES AN ALERT. Diagnostics belong to the service that owns the schedule;
//  this type reports an outcome and lets the caller decide what a person should be told.
//
//  IT DOES TELL THE AUDITOR, because it is the only thing that knows. A status that moves, an
//  exchange that succeeds or fails, a revocation and a removal are each handed to
//  `LicenseAuditing` as they happen; the bridge in the composition root decides what a record
//  keeps. The actor is whoever the task-local names, so a refresh from the Subscription page
//  is the operator's and the daily tick is the service's.

import BBCore
import BBLicense
import Foundation

/// What one refresh attempt did. Reported rather than acted on — see the header.
public enum RefreshOutcome: Sendable, Equatable {
  /// No key entered. Not a failure, and the overwhelmingly common case.
  case noKey
  /// The issuer answered with a token and this server is entitled to the tier it names.
  case refreshed(SubscriptionTier)
  /// The issuer answered with a token and the evaluation still refuses: the subscription
  /// period it describes has ended, or it was issued to another Mac. The issuer mints a
  /// token for an ended subscription so the page can say WHEN it ended, which is why this is
  /// not `.failed` (nothing went wrong) and not `.refreshed` (nothing is granted).
  case notEntitled(LicenseRefusal)
  /// The issuer says this license is disabled. Durable: persisted, not retried away.
  case revoked
  /// Could not confirm. Says nothing about the license — see `LicenseStatus`.
  case failed(reason: String)
}

public actor LicenseRuntime {

  private let store: LicenseStore
  private let client: EntitlementClient
  private let evaluator: LicenseEvaluator
  private let machine: String
  private let clock: any BBClock
  private let verify: @Sendable (String) throws -> EntitlementToken
  private let auditor: (any LicenseAuditing)?

  /// `nil` until the first load. Not `.none`, which is a real answer ("no license") and must
  /// not be what a request sees before anything has looked at the disk.
  private var current: LicenseStatus?
  /// Thresholds already warned about, so a daily timer does not produce a daily alert for the
  /// same unchanged problem. Cleared by a successful refresh.
  private var warned: Set<TimeInterval> = []
  private var statusSubscribers: [UUID: AsyncStream<LicenseStatus>.Continuation] = [:]

  public init(
    store: LicenseStore,
    client: EntitlementClient,
    machine: String,
    clock: any BBClock = SystemClock(),
    verify: @escaping @Sendable (String) throws -> EntitlementToken = {
      try TokenVerifier.verify($0)
    },
    auditor: (any LicenseAuditing)? = nil
  ) {
    self.store = store
    self.client = client
    self.machine = machine
    self.clock = clock
    self.verify = verify
    self.auditor = auditor
    self.evaluator = LicenseEvaluator(clock: clock, machine: machine)
  }

  /// The current entitlement. Cheap after the first call: an actor hop and a stored value.
  /// The first call loads from disk; see the header.
  public func status() async -> LicenseStatus {
    if let current { return current }
    return await reload()
  }

  /// Whether a key has been entered. What the service's `canRun` asks, so an unlicensed
  /// server runs no licensing code at all.
  public func hasKey() async -> Bool { await store.hasKey() }

  /// Recomputes from what is on disk, without reaching the network.
  ///
  /// Called at start and whenever the settings change. Also worth calling on a timer even
  /// when a refresh is not due: a status can go stale purely because time passed, and a
  /// server that only re-evaluated on a successful refresh would keep reporting an entitlement
  /// whose token expired hours ago.
  @discardableResult
  public func reload() async -> LicenseStatus {
    let verify = self.verify
    let status = evaluator.status(of: await store.load(verifier: verify))
    let previous = current
    let moved = status != previous
    current = status
    if moved {
      for continuation in statusSubscribers.values { continuation.yield(status) }
      // The first evaluation of a run is a move from nothing, and worth a record only when it
      // found something: every unlicensed server would otherwise write "no licence" on each
      // start.
      if previous != nil || status != .none {
        auditor?.record(.statusChanged(previous: previous, current: status))
      }
    }
    return status
  }

  /// Every status this runtime computes that differs from the one before it: a refresh
  /// landing, a key entered or removed, a token lapsing on a reload. The newest is kept for
  /// a slow consumer.
  ///
  /// What `LicenseService` follows to report its health, and the reason it has to: the
  /// registry reads a service's health only when told to, and the status moves on paths the
  /// service does not run, the Subscription page's own refresh among them.
  public func statusChanges() -> AsyncStream<LicenseStatus> {
    let (stream, continuation) = AsyncStream.makeStream(
      of: LicenseStatus.self, bufferingPolicy: .bufferingNewest(1))
    let id = UUID()
    statusSubscribers[id] = continuation
    continuation.onTermination = { [weak self] _ in
      Task { await self?.removeStatusSubscriber(id) }
    }
    return stream
  }

  private func removeStatusSubscriber(_ id: UUID) {
    statusSubscribers[id] = nil
  }

  /// One exchange with the issuer, then a reload.
  @discardableResult
  public func refresh() async -> RefreshOutcome {
    let key = await store.key()
    guard !key.isEmpty else {
      await reload()
      return .noKey
    }

    do {
      let response = try await client.exchange(key: key, machine: machine)
      if response.isRevoked {
        // Once per revocation: the daily tick repeats the issuer's answer, and a record a
        // day saying the same thing is a record nobody reads.
        let alreadyRevoked = current == .revoked
        try? await store.markRevoked()
        await reload()
        if !alreadyRevoked { auditor?.record(.revoked) }
        return .revoked
      }
      try await store.store(token: response.token, checkedAt: clock.now)
      warned.removeAll()
      let status = await reload()
      // The token the issuer answered with, whatever the evaluation made of it: the record
      // says what was received, and the status record beside it says what it means.
      if let token = try? verify(response.token) {
        auditor?.record(.refreshed(token))
      }
      guard let tier = status.tier else {
        // An active status always has a tier, so a missing one IS a blanket refusal; the
        // fallback is unreachable and names the honest answer if it were not.
        return .notEntitled(status.blanketRefusal ?? .unverifiable)
      }
      return .refreshed(tier)
    } catch {
      // A failed refresh does NOT clear the token. The one in hand stays valid for its
      // window, which is the entire point of the window.
      await reload()
      let reason = String(describing: error)
      auditor?.record(.refreshFailed(reason: reason))
      return .failed(reason: reason)
    }
  }

  /// The warning threshold newly crossed, or `nil` when there is nothing new to say.
  ///
  /// Returns each threshold at most once per run of failures, so the caller can alert
  /// unconditionally on a non-nil answer.
  public func pendingWarning() async -> TimeInterval? {
    let state = await store.load(verifier: verify)
    guard let crossed = evaluator.warningThresholdCrossed(of: state) else { return nil }
    guard !warned.contains(crossed) else { return nil }
    warned.insert(crossed)
    return crossed
  }

  /// Removes the license from this Mac.
  public func clear() async throws {
    let previous = await status()
    try await store.clear()
    warned.removeAll()
    await reload()
    auditor?.record(.removed(previous: previous))
  }

  /// A closure the HTTP layer can hold without holding this actor.
  ///
  /// Resolved at CALL time, never captured: a license is entered, lapses and is renewed while
  /// the server runs, so a boolean or a status taken once at construction would be wrong
  /// within hours.
  public nonisolated func statusProvider() -> @Sendable () async -> LicenseStatus {
    { [weak self] in
      guard let self else { return .none }
      return await self.status()
    }
  }
}
