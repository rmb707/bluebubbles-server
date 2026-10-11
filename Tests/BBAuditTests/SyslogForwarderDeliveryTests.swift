//  SyslogForwarderDeliveryTests
//  What reaches a real receiver, rather than what the forwarder believes it sent.
//
//  Two defects, both found by measuring against a listener:
//
//    - **One oversized record stopped forwarding for good.** macOS refuses a datagram past
//      `net.inet.udp.maxdgram` (9,216 bytes by default), the forwarder retried the head of
//      its queue for ever, and every record behind it waited until a restart.
//    - **Stopping threw the queue away.** `audit.recording_stopped` is queued last and was
//      never sent, so a receiver could not tell a clean stop from a cut feed.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBCore
import Foundation
import Testing

@testable import BBAudit

@Suite("Syslog forwarder delivery", .serialized)
struct SyslogForwarderDeliveryTests {

  private func record(_ summary: String, blob: Int = 0) -> AuditEvent {
    AuditEvent(
      kind: .settingsChanged, actor: .operator, summary: summary,
      metadata: blob > 0 ? ["value": .string(String(repeating: "x", count: blob))] : [:])
  }

  /// The JSON body of a syslog message: everything after the structured-data field.
  private func body(of message: String) throws -> [String: AuditValue] {
    let start = try #require(message.firstIndex(of: "{"))
    let value = try AuditJSON.decode(AuditValue.self, from: Data(message[start...].utf8))
    guard case .object(let fields) = value else { throw POSIXError(.EINVAL) }
    return fields
  }

  @Test("An oversized record is shrunk to a datagram, and the records behind it still arrive")
  func oversizedDatagramDoesNotWedge() async throws {
    let receiver = try LoopbackSyslogReceiver(.udp)
    defer { receiver.stop() }
    let forwarder = SyslogForwarder(
      destination: SyslogDestination(host: "127.0.0.1", port: receiver.port, transport: .udp),
      hostname: "mac")
    let big = record("too big", blob: 20_000)
    await forwarder.export([big, record("after")])

    let arrived = await receiver.waitFor(2)
    await forwarder.stop()
    try #require(arrived.count == 2, "received \(arrived.count) of 2")

    #expect(arrived[0].utf8.count <= SyslogMessage.datagramLimit)
    let shrunk = try body(of: arrived[0])
    // The envelope survives, so the receiver's copy still joins the local one by uuid.
    #expect(shrunk["uuid"] == .string(big.uuid.uuidString.lowercased()))
    #expect(shrunk["summary"] == .string("too big"))
    guard case .object(let metadata)? = shrunk["metadata"] else {
      Issue.record("metadata is not an object")
      return
    }
    #expect(metadata["truncated"] == .bool(true))
    if case .int(let original)? = metadata["original_bytes"] {
      #expect(original > SyslogMessage.datagramLimit)
    } else {
      Issue.record("the truncation marker does not say how large the record was")
    }
    #expect(try body(of: arrived[1])["summary"] == .string("after"))
  }

  @Test("A record that fits is sent whole")
  func recordThatFitsIsUntouched() {
    let small = record("small", blob: 100)
    let message = SyslogMessage.format(
      small, hostname: "mac", processID: 1, facility: .local0, softwareVersion: nil,
      maximumBytes: SyslogMessage.datagramLimit)
    let unlimited = SyslogMessage.format(
      small, hostname: "mac", processID: 1, facility: .local0, softwareVersion: nil)
    #expect(message == unlimited)
  }

  @Test("A summary too long for the budget on its own is cut, and the message still fits")
  func longSummaryIsCut() throws {
    let wordy = record(String(repeating: "é", count: 6_000))
    let message = SyslogMessage.format(
      wordy, hostname: "mac", processID: 1, facility: .local0, softwareVersion: nil,
      maximumBytes: 2_048)
    #expect(message.utf8.count <= 2_048)
    guard case .string(let summary)? = try body(of: message)["summary"] else {
      Issue.record("no summary")
      return
    }
    #expect(summary.hasSuffix("…"))
  }

  @Test("Stopping delivers what is queued while the receiver is answering")
  func stopDrainsTheQueue() async throws {
    let receiver = try LoopbackSyslogReceiver(.tcp)
    defer { receiver.stop() }
    let forwarder = SyslogForwarder(
      destination: SyslogDestination(host: "127.0.0.1", port: receiver.port, transport: .tcp),
      hostname: "mac")
    // Connected first: the drain is for a receiver that is answering.
    await forwarder.export([record("first")])
    #expect(await receiver.waitFor(1).count == 1)

    await forwarder.export((1...200).map { record("queued \($0)") })
    await forwarder.stop()
    let arrived = await receiver.waitFor(201, timeout: .seconds(3))
    #expect(arrived.count == 201, "received \(arrived.count) of 201")
    #expect(await forwarder.queuedCount == 0)
  }

  @Test("Stopping does not wait on a receiver that is not answering")
  func stopIsBoundedWhenFailing() async throws {
    // A port nothing listens on: the connection is refused and the forwarder backs off.
    let closed = try LoopbackSyslogReceiver(.tcp)
    let port = closed.port
    closed.stop()
    try await Task.sleep(for: .milliseconds(150))
    let forwarder = SyslogForwarder(
      destination: SyslogDestination(host: "127.0.0.1", port: port, transport: .tcp),
      hostname: "mac")
    await forwarder.export([record("nowhere")])
    try await Task.sleep(for: .milliseconds(200))

    let started = ContinuousClock.now
    await forwarder.stop()
    #expect(ContinuousClock.now - started < .seconds(1))
  }
}
