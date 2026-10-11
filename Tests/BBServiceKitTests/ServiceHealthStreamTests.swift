//  ServiceHealthStreamTests
//  The registry's health stream: what publishes a snapshot, and what a consumer sees.
//
//  The app draws service state from this stream rather than polling `health()`, so the
//  properties that matter are that a transition the registry performs publishes without
//  being asked, and that a service whose health moved on its own can ask.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import Foundation
import Testing

@testable import BBServiceKit

/// The next snapshot satisfying `predicate`, or nil if none arrives in time.
///
/// A deadline rather than an open `for await`: the failure this guards against is a
/// snapshot that never comes, and without one that is a hung test rather than a red one.
private func nextSnapshot(
  in stream: AsyncStream<[ServiceIdentifier: ServiceHealth]>,
  timeout: Duration = .seconds(5),
  where predicate: @escaping @Sendable ([ServiceIdentifier: ServiceHealth]) -> Bool
) async -> [ServiceIdentifier: ServiceHealth]? {
  await withTaskGroup(of: [ServiceIdentifier: ServiceHealth]?.self) { group in
    group.addTask {
      for await snapshot in stream where predicate(snapshot) { return snapshot }
      return nil
    }
    group.addTask {
      try? await Task.sleep(for: timeout)
      return nil
    }
    let first = await group.next() ?? nil
    group.cancelAll()
    return first
  }
}

@Suite("Health stream", .serialized)
struct ServiceHealthStreamTests {

  private static let database = ServiceIdentifier("database")

  @Test("Starting and stopping a service publishes a snapshot")
  func lifecyclePublishes() async throws {
    let registry = ServiceRegistry(host: TestContext(recorder: LifecycleRecorder()))
    await registry.register(DatabaseService.self)
    let changes = await registry.healthChanges()

    try await registry.startAll()
    let running = await nextSnapshot(in: changes) { $0[Self.database] == .running }
    #expect(running != nil, "no snapshot reported the service running")

    await registry.stopAll()
    let stopped = await nextSnapshot(in: changes) {
      if case .inactive? = $0[Self.database] { return true }
      return false
    }
    #expect(stopped != nil, "no snapshot reported the service stopped")
  }

  /// A tunnel dropping or a helper connecting changes a service's health without the
  /// registry doing anything, so the service has to be able to say so.
  @Test("A service reporting its own change publishes a snapshot")
  func reportedChangePublishes() async throws {
    let registry = ServiceRegistry(host: TestContext(recorder: LifecycleRecorder()))
    await registry.register(MoodyService.self)
    await MoodyService.mood.set(.running)
    try await registry.startAll()

    // Subscribed after startup, so the only thing that can publish is the report.
    let changes = await registry.healthChanges()
    await MoodyService.mood.set(.degraded(reason: "tunnel dropped"))
    await registry.noteHealthChanged()
    let snapshot = await nextSnapshot(in: changes) { _ in true }
    #expect(snapshot?[MoodyService.id] == .degraded(reason: "tunnel dropped"))
  }

  /// The registry sweeps health on its liveness tick as a safety net, and a service may
  /// report more often than its health moves (the search indexer, once a page). Neither
  /// may cost a consumer a re-render: the app redraws every service row on each snapshot.
  @Test("A report that changes nothing publishes nothing")
  func unchangedReportIsWithheld() async throws {
    let registry = ServiceRegistry(host: TestContext(recorder: LifecycleRecorder()))
    await registry.register(MoodyService.self)
    await MoodyService.mood.set(.running)
    let changes = await registry.healthChanges()
    try await registry.startAll()
    _ = await nextSnapshot(in: changes) { $0[MoodyService.id] == .running }

    await registry.noteHealthChanged()
    // A real change afterwards is the first thing the consumer sees; had the unchanged
    // report been published, this would read `.running` instead.
    await MoodyService.mood.set(.degraded(reason: "moved"))
    await registry.noteHealthChanged()
    let next = await nextSnapshot(in: changes) { _ in true }
    #expect(next?[MoodyService.id] == .degraded(reason: "moved"))
  }

  @Test("A subscriber that stops listening is forgotten")
  func terminationUnsubscribes() async throws {
    let registry = ServiceRegistry(host: TestContext(recorder: LifecycleRecorder()))
    await registry.register(DatabaseService.self)
    do {
      let changes = await registry.healthChanges()
      var iterator = changes.makeAsyncIterator()
      await registry.noteHealthChanged()
      _ = await iterator.next()
    }
    // Nothing observable from outside but the absence of a leak; publishing to a dropped
    // subscriber must at least not trap.
    await registry.noteHealthChanged()
  }
}

/// A service whose health is whatever the test last said it was.
actor MoodyService: RecordingService {
  static var manifest: ServiceManifest { .minimal(id: "moody") }

  /// Shared, because the registry builds the instance and the test cannot reach it.
  static let mood = Mood()

  actor Mood {
    private(set) var value: ServiceHealth = .running
    func set(_ value: ServiceHealth) { self.value = value }
  }

  let recorder: LifecycleRecorder
  init(host: TestContext) { recorder = host.recorder }

  var health: ServiceHealth {
    get async { await Self.mood.value }
  }
}
