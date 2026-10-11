//  ScreenLoadingStatePolicyTests
//  A page that reads from the server says so while it is reading.
//
//  Every list page decided what to draw by asking whether its collection was empty, and a
//  collection is empty before the first result lands. So each page announced its empty state
//  ("No devices", "Nothing scheduled", "No conversations were found") for the whole of the
//  read, then replaced it with rows.
//
//  The pages had already learned half of this: each guards its empty state against a read
//  that FAILED, because "Nothing scheduled" over a refused read is a lie with a button on it.
//  A read that has not finished is the same lie one moment earlier. `ScreenState` keeps
//  `idle` and `loading` apart precisely so a page can tell, and these pages were discarding
//  that by reading only `state.value`.
//
//  A comment saying "check the loading state" is read once; this runs on every build. In the
//  shape of `ScreenReloadPolicyTests`.

import Foundation
import Testing

@Suite("Screen loading state policy")
struct ScreenLoadingStatePolicyTests {

  /// Files that compose a `ScreenModel` and deliberately never mention loading.
  ///
  /// `HomeView`, which `ScreenModel`'s own header already names: Home renders an em dash for
  /// a count it does not have yet. That is honest for a glance dashboard, where a spinner per
  /// tile would be more motion than the numbers are worth, and it never claims the count is
  /// zero, which is the failure this scan is about. And `HomeModel`, which is not a page: it
  /// HOLDS Home's two screens so they outlive the view, and draws nothing. The sections that
  /// draw them (`HomeActivitySection`, `HomeServerSection`) reach the screen through the
  /// model, so they never spell `ScreenModel<` and this scan does not see them; they say they
  /// are loading with a `Skeleton` of their own layout, which is Home's rule.
  private static let exempt: Set<String> = ["HomeView.swift", "HomeModel.swift"]

  @Test("A page whose content is a server read distinguishes empty from still loading")
  func everyScreenHandlesLoading() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let base = root.appending(path: "Sources/BlueBubblesApp")

    var offenders: [String] = []
    var scannedFiles = 0
    let files = try #require(FileManager.default.enumerator(atPath: base.path))
    for case let relative as String in files where relative.hasSuffix(".swift") {
      scannedFiles += 1
      let name = URL(fileURLWithPath: relative).lastPathComponent
      guard !Self.exempt.contains(name) else { continue }
      let source = try String(contentsOf: base.appending(path: relative), encoding: .utf8)
      // Only the pages that actually compose one. A file that merely mentions the type
      // (this scan's own siblings, the modifier that reloads it) is not a screen.
      //
      // **This scopes on `ScreenModel`, so a page that reads the server WITHOUT one is
      // never checked.** That is a real hole and it is deliberate rather than overlooked:
      // widening it to every file showing `ServerStoppedNotice` would flag the pages that
      // read nothing and merely say the server is off, and the rule this enforces is about
      // a page whose CONTENT is a read. Closing it properly means being able to tell those
      // apart, which needs more than a grep. Recorded here rather than left implicit, and
      // the page that motivated it — the push setup page, which has its own state type — is
      // covered by `ScreenReloadPolicyTests` instead.
      guard source.contains("ScreenModel {") || source.contains("ScreenModel<") else {
        continue
      }
      // Either spelling counts: a branch on `state.isLoading`, or a switch over the state
      // with a `.loading` case.
      let saysSomething =
        source.contains("state.isLoading") || source.contains("case .loading")
      if !saysSomething {
        offenders.append("Sources/BlueBubblesApp/\(relative)")
      }
    }

    // A FLOOR on what was scanned. A walk that finds nothing passes, and the rule

    // this file enforces then stops being enforced while looking exactly like

    // compliance. Six of the fourteen source scanners had no such floor.

    #expect(

      scannedFiles > 10,

      "scanned only \(scannedFiles) files; this check is not reading the tree")

    #expect(
      offenders.isEmpty,
      Comment(
        rawValue: "these pages render an empty state while their first read is still in "
          + "flight; branch on `screen.state.isLoading` before the empty case, and show "
          + "`LoadingNotice`:\n" + offenders.joined(separator: "\n"))
    )
  }

  /// A page's `body` draws something in EVERY state, and the compiler does not check it.
  ///
  /// `SubscriptionSettings` shipped as four `else if` branches with no final `else`. The state
  /// it left unnamed was the one every visit starts in — the server running, the read not yet
  /// made — so `body` produced no view at all. That is worse than a blank area: a view with
  /// nothing to draw has nothing to attach a modifier to, so the `.reloads` task that would
  /// have STARTED the read never ran. The page did not resolve a moment later; the tab was
  /// empty for as long as it was open, on a working server with a valid license.
  ///
  /// The check is coarse on purpose. It asks only whether the body's branching is closed —
  /// a `switch`, which the compiler makes exhaustive, or an `else` with no condition on it —
  /// because that is the property that was missing and it is one a grep can actually decide.
  /// It cannot tell whether a branch draws anything worth reading; `ScreenModel`'s own states
  /// are what the test above covers.
  @Test("A page that reads from the server draws something in every state")
  func everyScreenBodyIsTotal() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let base = root.appending(path: "Sources/BlueBubblesApp")

    var offenders: [String] = []
    var scannedPages = 0
    let files = try #require(FileManager.default.enumerator(atPath: base.path))
    for case let relative as String in files where relative.hasSuffix(".swift") {
      let name = URL(fileURLWithPath: relative).lastPathComponent
      guard !Self.exempt.contains(name) else { continue }
      let source = try String(contentsOf: base.appending(path: relative), encoding: .utf8)
      guard source.contains("ScreenModel {") || source.contains("ScreenModel<") else {
        continue
      }
      guard let body = Self.body(of: source) else { continue }
      scannedPages += 1
      // Statement position only. Matching anywhere in the text reads the prose in a string
      // literal as code: this sheet's own subtitle says "sent even if this window is
      // closed", which contains `if ` and nothing else.
      let lines = body.split(separator: "\n").map {
        $0.trimmingCharacters(in: .whitespaces)
      }
      let branches = lines.contains {
        $0.hasPrefix("if ") || $0.hasPrefix("} else if ") || $0.hasPrefix("switch ")
      }
      // No branching at all is total by definition: the body draws one thing.
      guard branches else { continue }
      let isClosed = lines.contains {
        $0.hasPrefix("switch ") || $0.hasPrefix("} else {") || $0.hasPrefix("else {")
      }
      if !isClosed { offenders.append("Sources/BlueBubblesApp/\(relative)") }
    }

    // The floor. A walk that finds no pages passes while enforcing nothing, and looks
    // exactly like compliance.
    #expect(
      scannedPages >= 5,
      Comment(
        rawValue: "found only \(scannedPages) pages composing a ScreenModel; this check is "
          + "not reading the tree"))

    #expect(
      offenders.isEmpty,
      Comment(
        rawValue: "these page bodies branch without a closing `else` or `switch`, so a state "
          + "they do not name renders nothing AND silently skips the `.task` that reads:\n"
          + offenders.joined(separator: "\n"))
    )
  }

  /// The text of `var body: some View { … }`, by brace matching.
  ///
  /// Line comments are dropped first so a brace inside prose cannot unbalance the count. A
  /// brace inside a string literal still could; none of these bodies has one, and the check
  /// this feeds fails loudly rather than silently if that changes.
  private static func body(of source: String) -> String? {
    let stripped = source.split(separator: "\n", omittingEmptySubsequences: false)
      .map { line -> Substring in
        guard let comment = line.range(of: "//") else { return line }
        return line[line.startIndex..<comment.lowerBound]
      }
      .joined(separator: "\n")
    guard let start = stripped.range(of: "var body: some View {") else { return nil }

    var depth = 0
    var index = stripped.index(before: start.upperBound)
    while index < stripped.endIndex {
      if stripped[index] == "{" { depth += 1 }
      if stripped[index] == "}" {
        depth -= 1
        if depth == 0 {
          return String(stripped[start.upperBound..<index])
        }
      }
      index = stripped.index(after: index)
    }
    return nil
  }
}
