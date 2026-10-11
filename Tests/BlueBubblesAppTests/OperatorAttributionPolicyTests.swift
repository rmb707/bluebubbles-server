//  OperatorAttributionPolicyTests
//  Every change the app makes to the server is recorded as the person's.
//
//  The audit log records work nothing attributed as `unattributed`, deliberately: blaming the
//  person at the Mac for work nobody traced is the worse error. So the app has to say when
//  the person is acting, and it does so with `asOperator` around the call. A screen that
//  forgets does not fail; it writes an audit row that says nobody did it. This scan is what
//  makes forgetting fail the build.
//
//  It finds each call that changes audited state (a settings write, an access-control change,
//  a webhook or schedule change, an import, a licence exchange) and walks back through the
//  braces that enclose it. One of those scopes has to be opened by `asOperator`, by an
//  explicit `AuditContext` scope (the app's own bookkeeping is `.system`), or by one of the
//  LANES below, each of which is itself checked to run its body as the operator.

import Foundation
import Testing

@Suite("Operator attribution policy")
struct OperatorAttributionPolicyTests {

  /// Calls that change state the audit log records, by the names the app's code gives the
  /// objects it calls them on. Receiver names rather than method names alone, because
  /// `set(` and `write(` are everywhere: a JSON builder, `UserDefaults`, a settings batch.
  static let auditedCalls = [
    #"\b(store|settings)\.(set|trySet|write|remove)\("#,
    #"\bsetting\.write\("#,
    #"resetToDefaults\("#,
    #"(accessControl|\$0)\.(unblock|allow|disallow|clearAllBlocks|blockPermanently)\("#,
    #"\b(create|update|delete)Webhook\("#,
    #"\bscheduling\.(create|update|delete|clearFinished)\("#,
    #"\bimporter\.apply\("#,
    #"\bsubscription\.(refresh|remove)\("#,
  ]

  /// What may open the enclosing scope.
  static let openers = ["asOperator", "AuditContext.acting(", "AuditContext.with("]

  /// Helpers that take a closure and run it as the operator, so a call inside one is
  /// attributed. Each names the file that defines it; `lanesRunAsOperator` reads that
  /// definition and fails if it stops doing so.
  static let lanes: [(opener: String, definedIn: String, definition: String)] = [
    ("screen.perform", "ScreenModel.swift", "func perform("),
    ("mutate", "Views/SecurityAdministration.swift", "private func mutate("),
  ]

  private static var appSources: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "Sources/BlueBubblesApp")
  }

  @Test("Every audited change the app makes runs as the operator")
  func auditedChangesRunAsOperator() throws {
    // SIMPLE word boundaries. The default is Unicode's (UAX #29), under which a `.` between
    // letters does not break a word, so `\b` never matches inside `model.serverAdmin.x(`
    // and every call reached through a property would be silently skipped.
    let patterns = try Self.auditedCalls.map { try Regex($0).wordBoundaryKind(.simple) }
    let accepted = Self.openers + Self.lanes.map(\.opener)

    var offenders: [String] = []
    var scannedFiles = 0
    var auditedCallsFound = 0
    let files = try #require(FileManager.default.enumerator(atPath: Self.appSources.path))
    for case let relative as String in files where relative.hasSuffix(".swift") {
      scannedFiles += 1
      let source = try String(
        contentsOf: Self.appSources.appending(path: relative), encoding: .utf8)
      let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map {
        Self.code(of: String($0))
      }
      for (index, line) in lines.enumerated() {
        for pattern in patterns {
          for match in line.matches(of: pattern) {
            auditedCallsFound += 1
            guard !Self.isEnclosed(lines, line: index, before: match.range.lowerBound, by: accepted)
            else { continue }
            offenders.append(
              "Sources/BlueBubblesApp/\(relative):\(index + 1): "
                + line.trimmingCharacters(in: .whitespaces))
          }
        }
      }
    }

    // FLOORS on what was scanned, so a walk that finds nothing cannot look like compliance.
    #expect(scannedFiles > 10, "scanned only \(scannedFiles) files; not reading the tree")
    #expect(
      auditedCallsFound > 15,
      "found only \(auditedCallsFound) audited calls; the patterns no longer match the app")
    #expect(
      offenders.isEmpty,
      Comment(
        rawValue: "these change audited state outside `asOperator`, so the audit log records "
          + "them as unattributed:\n" + offenders.joined(separator: "\n")))
  }

  @Test("Each lane the scan accepts runs its body as the operator")
  func lanesRunAsOperator() throws {
    for lane in Self.lanes {
      let source = try String(
        contentsOf: Self.appSources.appending(path: lane.definedIn), encoding: .utf8)
      let start = try #require(
        source.range(of: lane.definition), "\(lane.definedIn) no longer defines \(lane.opener)")
      // The definition's body: from its opening brace to the brace that closes it.
      let body = Self.braced(source, from: start.upperBound)
      #expect(
        body.contains("asOperator"),
        "\(lane.opener) in \(lane.definedIn) no longer runs its body as the operator")
    }
  }

  // MARK: - Reading source

  /// A line with its comment removed: a `//` that is not inside a string literal, roughly.
  /// Good enough for this tree, which does not put `//` in a string on a line it scans.
  private static func code(of line: String) -> String {
    guard let comment = line.range(of: "//") else { return line }
    let before = line[..<comment.lowerBound]
    let quotes = before.filter { $0 == "\"" }.count
    return quotes.isMultiple(of: 2) ? String(before) : line
  }

  /// Whether the call at `column` on `line` sits inside a scope opened on a line containing
  /// one of `openers`, walking outwards brace by brace.
  private static func isEnclosed(
    _ lines: [String], line: Int, before column: String.Index, by openers: [String]
  ) -> Bool {
    var unclosed = 0
    var index = line
    var text = Substring(lines[line][..<column])
    while true {
      var position = text.endIndex
      while position > text.startIndex {
        position = text.index(before: position)
        switch text[position] {
        case "}":
          unclosed += 1
        case "{" where unclosed > 0:
          unclosed -= 1
        case "{":
          // This brace opens a scope around the call. Is it one that names the operator?
          let opener = text[..<position]
          if openers.contains(where: opener.contains) { return true }
        default:
          continue
        }
      }
      index -= 1
      guard index >= 0 else { return false }
      text = Substring(lines[index])
    }
  }

  /// The text between the first `{` at or after `start` and its matching `}`.
  private static func braced(_ source: String, from start: String.Index) -> Substring {
    guard let open = source[start...].firstIndex(of: "{") else { return "" }
    var depth = 0
    var position = open
    while position < source.endIndex {
      switch source[position] {
      case "{": depth += 1
      case "}":
        depth -= 1
        if depth == 0 { return source[open...position] }
      default: break
      }
      position = source.index(after: position)
    }
    return source[open...]
  }
}
