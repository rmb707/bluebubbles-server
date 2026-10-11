//  ServerExportTests
//  Exporting a server and reading it back.
//
//  Two properties carry most of the weight here, and neither is "the round trip works".
//
//  **Secrets cannot leave without the password, and a server that has none cannot export
//  them at all.** An empty password is the shipped default, so allowing it would mean the
//  least configured servers produce the most dangerous files.
//
//  **A setting that describes the server it came from must not travel.** `server_address` is
//  written by the connection method and an imported one points clients at nothing; the
//  `migration_*` keys would tell a server it has already adopted an installation it has
//  never seen. Those are checked on the way out AND on the way in, because an archive is a
//  file from outside this server.
//
//  NO REAL ADDRESSES; see CONTRIBUTING.md.

import BBAppStore
import BBBuiltIns
import BBExport
import BBPersistence
import BBSettings
import BlueBubblesServerCore
import Foundation
import GRDB
import Logging
import Testing

@Suite("Server export", .serialized)
struct ServerExportTests {

  private let logger = Logger(label: "bluebubbles.test.export")

  private func harness() async throws -> (AppDatabase, SettingsStore, URL) {
    let database = try AppDatabase.inMemory(contributors: AppSchema.contributors)
    let settings = try await SettingsStore(database: database, secrets: InMemorySecretStore())
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-export-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (database, settings, root)
  }

  private func exporter(_ database: AppDatabase, _ settings: SettingsStore) -> ServerExporter {
    ServerExporter(
      database: database, settings: settings, serverVersion: "test", logger: logger)
  }

  // MARK: The round trip

  @Test("Settings and webhooks survive an export and an import into a fresh server")
  func roundTrip() async throws {
    let (source, sourceSettings, root) = try await harness()
    defer { try? FileManager.default.removeItem(at: root) }

    try await sourceSettings.set(Settings.socketPort, to: 8080)
    try await sourceSettings.set(Settings.connectionMethod, to: "app.bluebubbles.proxy.ngrok")
    _ = try await WebhookRepository(database: source).upsert(
      url: "https://hooks.example.com/a", events: ["new-message"])

    let report = try await exporter(source, sourceSettings).export(
      sections: [.settings, .webhooks], to: root)
    #expect(FileManager.default.fileExists(atPath: report.url.path))
    #expect(report.url.lastPathComponent.hasPrefix("bluebubbles-export-"))
    #expect(report.url.pathExtension == "zip")

    let (target, targetSettings, _) = try await harness()
    let importer = ServerImporter(database: target, settings: targetSettings, logger: logger)
    let inspection = try await importer.inspect(report.url)
    defer { try? FileManager.default.removeItem(at: inspection.directory) }
    #expect(Set(inspection.sections) == [.settings, .webhooks])
    #expect(!inspection.hasSecrets)

    _ = try await importer.apply(inspection, sections: [.settings, .webhooks])
    #expect(await targetSettings.get(Settings.socketPort) == 8080)
    #expect(
      await targetSettings.get(Settings.connectionMethod) == "app.bluebubbles.proxy.ngrok")
    let webhooks = try await WebhookRepository(database: target).all()
    #expect(webhooks.map(\.url) == ["https://hooks.example.com/a"])
  }

  @Test("Only the ticked sections are written")
  func selectionIsHonoured() async throws {
    let (source, settings, root) = try await harness()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try await WebhookRepository(database: source).upsert(
      url: "https://hooks.example.com/a", events: ["*"])

    let report = try await exporter(source, settings).export(sections: [.settings], to: root)
    let (target, targetSettings, _) = try await harness()
    let importer = ServerImporter(database: target, settings: targetSettings, logger: logger)
    let inspection = try await importer.inspect(report.url)
    defer { try? FileManager.default.removeItem(at: inspection.directory) }
    #expect(inspection.sections == [.settings])
  }

  // MARK: Secrets

  @Test("A server with no password cannot export secrets")
  func noPasswordNoSecrets() async throws {
    // The shipped default is an empty password, so this is the state a fresh install sits
    // in. Refused rather than exported in the clear, and refused rather than quietly
    // dropped: somebody who ticked the box must not end up believing they have a backup of
    // something they do not.
    let (database, settings, root) = try await harness()
    defer { try? FileManager.default.removeItem(at: root) }
    await #expect(throws: SecretsEnvelope.Failure.noServerPassword) {
      _ = try await exporter(database, settings).export(
        sections: [.settings, .secrets], to: root, serverPassword: "")
    }
  }

  @Test("Exporting secrets needs THIS server's password, not just any password")
  func secretsNeedTheRealPassword() async throws {
    // "Is a password set" and "is this that password" are two questions, and only checking
    // the first would let anybody with a shell on this Mac encrypt the credentials under a
    // password of their choosing and walk away with a file they can open.
    let (database, settings, root) = try await harness()
    defer { try? FileManager.default.removeItem(at: root) }
    try await settings.set(Settings.password, to: "a-long-enough-passphrase-42")

    await #expect(throws: SecretsEnvelope.Failure.wrongPassword) {
      _ = try await exporter(database, settings).export(
        sections: [.secrets], to: root, serverPassword: "something-else-entirely-99")
    }
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty,
      "a refused export still wrote a file")
  }

  @Test("Secrets travel encrypted and need the same password back")
  func secretsRoundTrip() async throws {
    let (source, sourceSettings, root) = try await harness()
    defer { try? FileManager.default.removeItem(at: root) }
    let password = "a-long-enough-passphrase-42"
    try await sourceSettings.set(Settings.password, to: password)

    let report = try await exporter(source, sourceSettings).export(
      sections: [.secrets], to: root, serverPassword: password)

    // The archive must not carry the password anywhere a search would find it.
    let raw = try Data(contentsOf: report.url)
    #expect(
      raw.range(of: Data(password.utf8)) == nil,
      "the password appears in the archive in the clear")

    let (target, targetSettings, _) = try await harness()
    let importer = ServerImporter(database: target, settings: targetSettings, logger: logger)
    let inspection = try await importer.inspect(report.url)
    defer { try? FileManager.default.removeItem(at: inspection.directory) }
    #expect(inspection.hasSecrets)

    _ = try await importer.apply(
      inspection, sections: [.secrets], serverPassword: password)
    #expect(await targetSettings.get(Settings.password) == password)
  }

  @Test("The wrong password does not open the secrets")
  func wrongPasswordIsRefused() async throws {
    let (source, sourceSettings, root) = try await harness()
    defer { try? FileManager.default.removeItem(at: root) }
    try await sourceSettings.set(Settings.password, to: "a-long-enough-passphrase-42")
    let report = try await exporter(source, sourceSettings).export(
      sections: [.secrets], to: root, serverPassword: "a-long-enough-passphrase-42")

    let (target, targetSettings, _) = try await harness()
    let importer = ServerImporter(database: target, settings: targetSettings, logger: logger)
    let inspection = try await importer.inspect(report.url)
    defer { try? FileManager.default.removeItem(at: inspection.directory) }

    await #expect(throws: SecretsEnvelope.Failure.corrupt) {
      _ = try await importer.apply(
        inspection, sections: [.secrets], serverPassword: "not-the-right-one")
    }
    #expect(await targetSettings.get(Settings.password).isEmpty, "a failed open wrote anyway")
  }

  @Test("Importing secrets without a password is refused before anything is read")
  func secretsNeedAPassword() async throws {
    let (source, sourceSettings, root) = try await harness()
    defer { try? FileManager.default.removeItem(at: root) }
    try await sourceSettings.set(Settings.password, to: "a-long-enough-passphrase-42")
    let report = try await exporter(source, sourceSettings).export(
      sections: [.secrets], to: root, serverPassword: "a-long-enough-passphrase-42")

    let (target, targetSettings, _) = try await harness()
    let importer = ServerImporter(database: target, settings: targetSettings, logger: logger)
    let inspection = try await importer.inspect(report.url)
    defer { try? FileManager.default.removeItem(at: inspection.directory) }
    await #expect(throws: ServerImporter.Failure.passwordRequired) {
      _ = try await importer.apply(inspection, sections: [.secrets])
    }
  }

  // MARK: What must not travel

  @Test("A setting describing this server does not leave it")
  func nonPortableSettingsAreNotExported() async throws {
    let (database, settings, root) = try await harness()
    defer { try? FileManager.default.removeItem(at: root) }
    try await settings.set(Settings.serverAddress, to: "https://old.example.com")
    try await settings.set(Settings.migrationSettingsState, to: "completed")

    let report = try await exporter(database, settings).export(sections: [.settings], to: root)
    let importer = ServerImporter(
      database: try AppDatabase.inMemory(contributors: AppSchema.contributors),
      settings: settings, logger: logger)
    let inspection = try await importer.inspect(report.url)
    defer { try? FileManager.default.removeItem(at: inspection.directory) }

    let json = try Data(
      contentsOf: inspection.directory.appendingPathComponent("settings.json"))
    let values = try JSONDecoder().decode([String: SettingValueBox].self, from: json)
    #expect(values[Settings.serverAddress.key] == nil, "an output setting was exported")
    #expect(
      values[Settings.migrationSettingsState.key] == nil,
      "this Mac's migration state travelled")
    #expect(values[Settings.socketPort.key] != nil, "an ordinary setting was left out")
  }

  @Test("A hand-edited archive cannot smuggle a non-portable setting in")
  func nonPortableSettingsAreRefusedOnImport() async throws {
    // Checked again on the way IN. An archive is a file from outside this server: it may
    // have been written by a version with a shorter list, or edited by hand.
    let (source, sourceSettings, root) = try await harness()
    defer { try? FileManager.default.removeItem(at: root) }
    let report = try await exporter(source, sourceSettings).export(
      sections: [.settings], to: root)

    let (target, targetSettings, _) = try await harness()
    try await targetSettings.set(Settings.serverAddress, to: "http://10.0.0.5:1234")
    let importer = ServerImporter(database: target, settings: targetSettings, logger: logger)
    let inspection = try await importer.inspect(report.url)
    defer { try? FileManager.default.removeItem(at: inspection.directory) }

    // Forge the file the way a person with a text editor would.
    let settingsFile = inspection.directory.appendingPathComponent("settings.json")
    var values = try JSONDecoder().decode(
      [String: SettingValueBox].self, from: try Data(contentsOf: settingsFile))
    values[Settings.serverAddress.key] = SettingValueBox(
      .string("https://attacker.example.com"))
    try JSONEncoder().encode(values).write(to: settingsFile)

    let applied = try await importer.apply(inspection, sections: [.settings])
    #expect(applied.skippedSettings.contains(Settings.serverAddress.key))
    #expect(
      await targetSettings.get(Settings.serverAddress) == "http://10.0.0.5:1234",
      "an imported archive overwrote this server's own address")
  }

  // MARK: The archive itself

  @Test("An archive from a newer format is refused rather than partly read")
  func newerSchemaIsRefused() async throws {
    let (database, settings, root) = try await harness()
    defer { try? FileManager.default.removeItem(at: root) }
    let report = try await exporter(database, settings).export(sections: [.settings], to: root)

    let importer = ServerImporter(database: database, settings: settings, logger: logger)
    let inspection = try await importer.inspect(report.url)
    defer { try? FileManager.default.removeItem(at: inspection.directory) }

    // Rewrite the manifest as a future version would, then re-zip it.
    let manifestURL = inspection.directory.appendingPathComponent("export.json")
    var manifest =
      try JSONSerialization.jsonObject(with: try Data(contentsOf: manifestURL))
      as! [String: Any]
    manifest["schemaVersion"] = ExportManifest.currentSchemaVersion + 1
    try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
    let future = root.appendingPathComponent("future.zip")
    try await ZipArchive.create(contentsOf: inspection.directory, into: future)

    await #expect(
      throws: ExportManifest.Failure.unsupportedSchema(ExportManifest.currentSchemaVersion + 1)
    ) {
      _ = try await importer.inspect(future)
    }
  }

  @Test("Something that is not an export says so")
  func notAnExport() async throws {
    let (database, settings, root) = try await harness()
    defer { try? FileManager.default.removeItem(at: root) }
    let junk = root.appendingPathComponent("junk")
    try FileManager.default.createDirectory(at: junk, withIntermediateDirectories: true)
    try Data("hello".utf8).write(to: junk.appendingPathComponent("readme.txt"))
    let archive = root.appendingPathComponent("junk.zip")
    try await ZipArchive.create(contentsOf: junk, into: archive)

    let importer = ServerImporter(database: database, settings: settings, logger: logger)
    await #expect(throws: ExportManifest.Failure.notAnExport) {
      _ = try await importer.inspect(archive)
    }
  }

  @Test("The file is named for when it was made, and is not world readable")
  func fileNameAndPermissions() async throws {
    let (database, settings, root) = try await harness()
    defer { try? FileManager.default.removeItem(at: root) }
    let moment = Date(timeIntervalSince1970: 1_790_000_000)
    let report = try await exporter(database, settings).export(
      sections: [.settings], to: root, at: moment)

    #expect(report.url.lastPathComponent == ExportManifest.fileName(at: moment))
    let mode =
      try FileManager.default.attributesOfItem(atPath: report.url.path)[.posixPermissions]
      as? NSNumber
    #expect((mode?.intValue ?? 0) & 0o077 == 0, "the export is readable by other accounts")
  }
}

/// Every declared setting is classified as portable or not, on purpose.
///
/// The scanner this repository writes for rules a compiler cannot check. A plain filter
/// would silently start exporting the next `server_address` somebody adds, and the failure
/// would not surface until a person restored a backup onto a second Mac and could not reach
/// it. Here, adding a setting that describes its own machine and not saying so fails the
/// build.
@Suite("Setting portability")
struct SettingPortabilityTests {

  @Test("Every non-portable key is real, and says why")
  func exclusionsAreRealAndExplained() {
    let declared = Set(Settings.allKeys)
    for (key, reason) in SettingPortability.nonPortable {
      #expect(declared.contains(key), "\(key) is excluded from exports but is not a setting")
      #expect(
        reason.count > 20,
        "\(key) is excluded with a reason too short to be one: \"\(reason)\"")
    }
  }

  @Test("The keys that describe a particular server do not travel")
  func theDangerousOnesAreExcluded() {
    // Named individually rather than asserted as a count, because a count passes when
    // somebody swaps one exclusion for another.
    for key in [
      Settings.serverAddress.key, Settings.tlsCertificateOrigin.key,
      Settings.tlsCertificateExpiresAt.key, Settings.migrationSettingsState.key,
      Settings.migrationPushState.key, Settings.migrationCertificatesState.key,
      Settings.migrationPlaintextSecretsState.key, Settings.migrationSavedRecordsState.key,
      Settings.legacyConfigImported.key, Settings.onboardingComplete.key,
      Settings.onboardingSelections.key, Settings.lastRunVersion.key,
      Settings.lastFcmRestart.key,
    ] {
      #expect(!SettingPortability.isPortable(key), "\(key) would be carried between servers")
    }
  }

  @Test("Service bookkeeping is matched by shape, not by a list that goes stale")
  func serviceVersionsAreExcluded() {
    for manifest in BuiltInManifests.all {
      #expect(!SettingPortability.isPortable("\(manifest.id.rawValue).__version"))
    }
  }

  @Test("A secret is never exportable as a setting")
  func secretsAreNeverSettings() {
    // They have their own encrypted section with its own gate. One reaching `settings.json`
    // would be a credential in the clear inside an archive whose design says otherwise.
    for key in Settings.secretKeys {
      #expect(
        !SettingPortability.isExportableSetting(key, secretKeys: Settings.secretKeys),
        "\(key) is a secret and would have been written into settings.json")
    }
  }

  @Test("Ordinary configuration does travel")
  func ordinarySettingsArePortable() {
    // The other direction: an over-broad exclusion would make an export that restores
    // nothing, and would look exactly like a working one.
    for key in [
      Settings.socketPort.key, Settings.connectionMethod.key,
      Settings.enablePrivateAPI.key, Settings.startDelay.key,
    ] {
      #expect(SettingPortability.isPortable(key), "\(key) would not survive an export")
    }
  }
}
