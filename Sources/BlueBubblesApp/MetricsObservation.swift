//  MetricsObservation
//  What the server is doing, followed for the life of the server.
//
//  The server samples itself every few seconds and publishes a snapshot (`ServerMetrics`);
//  this is the follow. Home reads the result off the model the way it reads service health,
//  and never runs a timer of its own: a value that moves on the clock is the server's to
//  announce.
//
//  ONE stream, THREE properties, because they move at three different rates and a view
//  observes a property, not a field. The snapshot itself changes on every sample (its `at`,
//  its memory reading), and a view that reads it is re-evaluated every five seconds, which is
//  right for a figure that is live. The minute ring changes once a minute, and the sparklines
//  drawn from it should be rebuilt once a minute, not on every sample of a memory reading they
//  do not show. The message minute changes when a message arrives and at most once a minute,
//  and the activity section's read is keyed on it and on nothing else: keyed on the COUNT it
//  re-read a month of `chat.db` three ways on every sample of a busy server. Measured before
//  the split: every sample re-evaluated the whole of Home, four charts included.

import BlueBubblesServerCore
import Foundation

extension AppModel {

  /// Follows the metrics. Cancelled by `stopFollowingServer`.
  ///
  /// Subscribed before the seed read, so no sample falls between them.
  func followMetrics(_ metrics: ServerMetrics) {
    metricsTask?.cancel()
    metricsTask = Task { [weak self] in
      let snapshots = await metrics.snapshots()
      self?.applyMetrics(await metrics.snapshot)
      for await snapshot in snapshots {
        self?.applyMetrics(snapshot)
      }
    }
  }

  /// Assigns each of the three properties only when its own value moved, so a view following
  /// the slow one is not woken by the fast one.
  func applyMetrics(_ snapshot: ServerMetrics.Snapshot?) {
    metrics = snapshot
    let ring = snapshot?.recent ?? []
    if ring != metricsRing { metricsRing = ring }
    let count = snapshot?.newMessages ?? 0
    if count != newMessagesSeen {
      newMessagesSeen = count
      if let at = snapshot?.at {
        let minute = HomeDashboard.minute(at)
        if minute != newMessageMinute { newMessageMinute = minute }
      }
    }
  }
}
