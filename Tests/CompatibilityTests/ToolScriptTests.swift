//  ToolScriptTests
//  Every script a person runs loads `.env`, and the loader stays safe to point at one.
//
//  A `.env` file is a convention, not a shell feature. Nothing reads it unless a script is
//  written to read it, and the failure is silent in the direction that costs the most:
//  `Tools/dev-bundle.sh` resolves `${DEV_SIGNING_IDENTITY:--}` and treats the fallback as
//  "sign ad-hoc", so a script that forgot to load the file still builds, still succeeds, and
//  invalidates every TCC grant the app had — Full Disk Access, Automation, Contacts — with
//  nothing in the output a reader would stop at.
//
//  That is the whole reason this is a test and not a note in CONTRIBUTING.md: the next script
//  added under `Tools/` or `Packaging/` inherits the behaviour only if someone remembers, and
//  the thing that goes wrong when they do not is invisible.

import Foundation
import Testing

@Suite("Tool scripts")
struct ToolScriptTests {

  /// The repository root, from this file rather than the working directory: `swift test` runs
  /// from wherever it is invoked, and these paths are relative to the tree.
  private static var root: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // CompatibilityTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()
  }

  /// Scripts that are RUN, as distinct from the two that are only ever sourced.
  ///
  /// A shebang is the discriminator, and it is the file's own statement about which it is:
  /// `dotenv.sh` and `private-api/lib.sh` both open with a comment saying they are sourced
  /// and never run, and neither carries one.
  private func executableScripts() throws -> [(path: String, source: String)] {
    var found: [(String, String)] = []
    for directory in ["Tools", "Packaging"] {
      let base = Self.root.appendingPathComponent(directory)
      guard
        let walk = FileManager.default.enumerator(
          at: base, includingPropertiesForKeys: nil)
      else { continue }
      for case let url as URL in walk where url.pathExtension == "sh" {
        // A checkout that has built the vendored probe carries someone else's scripts.
        guard !url.path.contains("/.build/") else { continue }
        let text = try String(contentsOf: url, encoding: .utf8)
        guard text.hasPrefix("#!") else { continue }
        found.append((url.path.replacingOccurrences(of: Self.root.path + "/", with: ""), text))
      }
    }
    return found
  }

  /// Scripts that deliberately do not load `.env`, each with the reason.
  ///
  /// A list rather than a silent skip, because "this one does not need it" and "nobody got to
  /// this one" are the same absence otherwise.
  private let exempt: [String: String] = [
    "Tools/private-api/dump-headers-vm.sh":
      "Runs inside a macOS VM, from the share `vm-share.sh` builds, where there is no "
      + "checkout and no `.env` to read. It refuses to run from the repository at all — it "
      + "dies if `lib.sh` is beside it — so the load would be dead code where it executes."
  ]

  @Test("Every script a person runs loads .env")
  func scriptsLoadDotenv() throws {
    let scripts = try executableScripts()
    // A scan with no floor reports success when it stops matching. Fifteen scripts exist
    // today; ten is a floor that a real deletion would have to pass before this goes quiet.
    #expect(
      scripts.count >= 10,
      "found only \(scripts.count) runnable scripts; the walk is broken, not the tree")

    for script in scripts {
      if let reason = exempt[script.path] {
        #expect(reason.count > 40, "\(script.path) is exempt for no stated reason")
        #expect(
          !script.source.contains("dotenv.sh"),
          "\(script.path) is listed as exempt but loads .env; delete the exemption")
        continue
      }
      // Either directly, or through `private-api/lib.sh`, which loads it for the seven
      // scripts that source it. `contains` on the bare name would also match the guard in
      // `dump-headers-vm.sh`, which TESTS for lib.sh rather than sourcing it.
      let loadsDirectly = script.source.contains("bb_load_dotenv")
      let loadsViaLibrary = script.source.contains("&& pwd)/lib.sh\"")
      #expect(
        loadsDirectly || loadsViaLibrary,
        """
        \(script.path) does not load `.env`. Source Tools/dotenv.sh and call \
        `bb_load_dotenv` before any `cd`, or add it to `exempt` with the reason. A script \
        that skips this reads no configuration from the file and, if it signs anything, \
        falls back to ad-hoc silently.
        """)
    }
  }

  @Test("The loader reads the working directory, not its own")
  func dotenvReadsTheWorkingDirectory() throws {
    // The distinction the scripts depend on. Five of them `cd` to the repository root as
    // their second statement, so a loader resolving against `${BASH_SOURCE[0]}` would read
    // `Packaging/.env` and `Tools/.env` — neither of which anybody writes — and one
    // resolving after the `cd` would ignore where the person actually stood.
    let code = try loaderCode()
    let readsWorkingDirectory = code.contains("local file=\".env\"")
    #expect(readsWorkingDirectory, "the loader no longer names `.env` relative to the cwd")
    // CODE ONLY. The header explains at length why it does not resolve against
    // `${BASH_SOURCE[0]}`, and a scan that read comments would fail on the sentence saying
    // the right thing — which is the classic way a policy test teaches people to delete the
    // explanation rather than fix the code.
    let resolvesAgainstItself = code.contains("BASH_SOURCE")
    #expect(
      !resolvesAgainstItself,
      "the loader resolves `.env` against its own location; it must use the working directory")
  }

  /// `Tools/dotenv.sh` with its comment lines removed.
  private func loaderCode() throws -> String {
    let text = try String(
      contentsOf: Self.root.appendingPathComponent("Tools/dotenv.sh"), encoding: .utf8)
    return text.split(separator: "\n", omittingEmptySubsequences: false)
      .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
      .joined(separator: "\n")
  }

  @Test("The loader never evaluates the file it reads")
  func dotenvDoesNotEval() throws {
    // `.env` is hand-edited and travels between machines, and this one holds a Sparkle
    // signing key and an API key. Expanding `$VAR` with `eval` would also run any `$(…)` in
    // it, so the expansion is done by hand and `$(…)` is emitted literally. Asserted rather
    // than trusted: `eval` is exactly the shortcut someone reaches for when adding a feature
    // to a parser like this one.
    for line in try loaderCode().split(separator: "\n") {
      let statement = line.trimmingCharacters(in: .whitespaces)
      let evaluates = statement.contains("eval ")
      #expect(
        !evaluates,
        "Tools/dotenv.sh evaluates its input: `\(statement)`. Expand variables by hand.")
    }
  }

  @Test("The scripts load .env before changing directory")
  func loadHappensBeforeTheCD() throws {
    // Order is the whole meaning of "from the working directory". `build-app.sh`,
    // `make-dmg.sh`, `notarize-app.sh`, `sign-app.sh` and `dev-bundle.sh` all run
    // `cd "$(dirname "$0")/.."` near the top; loading after it would silently switch the
    // file being read from the caller's directory to the repository root.
    for script in try executableScripts() {
      guard let cd = script.source.range(of: "\ncd \"$(dirname \"$0\")"),
        let load = script.source.range(of: "\nbb_load_dotenv")
      else { continue }
      #expect(
        load.lowerBound < cd.lowerBound,
        """
        \(script.path) loads `.env` after it changes directory, so it reads the repository \
        root's file rather than the one where the command was run.
        """)
    }
  }

  /// The headless CLI is its own bundle, and it needs its own resource bundles.
  ///
  /// `Bundle.main` inside `Helpers/bluebubbles-server.app` is that nested bundle, so the
  /// accessor SwiftPM generates looks in ITS `Contents/Resources` and never in the app's. Both
  /// scripts copied the bundles into the app only, and the documented headless binary aborted
  /// with `fatalError` on the first phone number it parsed. Each script now copies them into
  /// the nested bundle too, and refuses to finish without PhoneNumberKit's there.
  @Test("Both bundle scripts give the nested CLI its own resource bundles")
  func cliBundleCarriesResources() throws {
    for path in ["Packaging/build-app.sh", "Tools/dev-bundle.sh"] {
      let source = try String(
        contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
      #expect(
        source.contains(#"cp -R "$resource" "$CLI_APP/Contents/Resources/""#),
        "\(path) does not copy the resource bundles into the CLI bundle")
      #expect(
        source.contains(#""$CLI_APP/Contents/Resources/PhoneNumberKit_PhoneNumberKit.bundle""#),
        "\(path) does not check that the CLI bundle carries PhoneNumberKit's resources")
    }
  }
}
