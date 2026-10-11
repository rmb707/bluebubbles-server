//  ServerImporter
//  Reads an archive back into a server.
//
//  **Inspect, then apply, and they are separate calls.** `inspect` opens the archive, checks
//  the manifest and reports what is in it without writing anything; `apply` takes that
//  inspection and commits. A UI shows the first as a preview and a CLI prints it, so nobody
//  finds out what an import contained by running it.
//
//  **Sections are REPLACED, not merged.** A merge sounds gentler and is worse: importing a
//  webhook list that is missing one you deleted on the old server would leave it here, so
//  the result would match neither machine. Replace is a state somebody can reason about —
//  "this section now matches the archive" — and it is what a person restoring a backup
//  means. Settings are the one exception: those are written key by key over whatever is
//  there, because a settings file is a partial view by construction (`SettingPortability`
//  excludes a dozen keys) and clearing the rest would reset this server's own address,
//  migration state and onboarding.

import BBAppStore
import BBPersistence
import BBSettings
import Foundation
import GRDB
import Logging

public struct ServerImporter: Sendable {

  private let database: AppDatabase
  private let settings: SettingsStore
  private let logger: Logger

  public init(database: AppDatabase, settings: SettingsStore, logger: Logger) {
    self.database = database
    self.settings = settings
    self.logger = logger
  }

  /// What an archive holds, read without applying any of it.
  public struct Inspection: Sendable {
    public let manifest: ExportManifest
    /// How many records each section carries.
    public let counts: [ExportSection: Int]
    /// Whether `secrets.enc` is present, and therefore whether a password will be needed.
    public let hasSecrets: Bool
    /// Where the archive was unpacked. The caller removes it; `apply` does not.
    public let directory: URL

    public var sections: [ExportSection] { manifest.sections }
  }

  public enum Failure: Error, Equatable, CustomStringConvertible {
    case sectionMissing(ExportSection)
    case passwordRequired

    public var description: String {
      switch self {
      case .sectionMissing(let section):
        "This export lists \"\(section.title)\" but does not contain it. The file is "
          + "incomplete."
      case .passwordRequired:
        "This export contains passwords and keys. Enter the server password that was used "
          + "when it was made."
      }
    }
  }

  /// Unpacks and validates, writing nothing.
  ///
  /// The caller owns `Inspection.directory` and must remove it — it holds the archive's
  /// contents in the clear, which is the same material the export was careful about.
  public func inspect(_ archive: URL) async throws -> Inspection {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("bb-import-\(UUID().uuidString)", isDirectory: true)
    try await ZipArchive.extract(archive, into: directory)

    let manifestURL = directory.appendingPathComponent("export.json")
    guard FileManager.default.fileExists(atPath: manifestURL.path) else {
      try? FileManager.default.removeItem(at: directory)
      throw ExportManifest.Failure.notAnExport
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let manifest = try decoder.decode(
      ExportManifest.self, from: try Data(contentsOf: manifestURL))
    // BEFORE anything is counted or read. See the type's own header.
    try manifest.validate()

    var counts: [ExportSection: Int] = [:]
    for section in manifest.sections where section != .secrets {
      let url = directory.appendingPathComponent(section.fileName)
      guard let data = try? Data(contentsOf: url) else {
        try? FileManager.default.removeItem(at: directory)
        throw Failure.sectionMissing(section)
      }
      counts[section] = Self.count(in: data)
    }

    let secrets = directory.appendingPathComponent(ExportSection.secrets.fileName)
    return Inspection(
      manifest: manifest,
      counts: counts,
      hasSecrets: FileManager.default.fileExists(atPath: secrets.path),
      directory: directory
    )
  }

  /// What one import changed.
  public struct Report: Sendable {
    public let applied: [ExportSection]
    public let counts: [ExportSection: Int]
    /// Keys the archive carried that this server will not accept; see `SettingPortability`.
    public let skippedSettings: [String]
  }

  /// Applies the chosen sections.
  ///
  /// - Parameter sections: a subset of what the archive holds. Ticking a section the
  ///   archive does not contain is refused rather than ignored.
  /// - Parameter serverPassword: needed only for `.secrets`, and it is the password that was
  ///   typed when the export was MADE — not necessarily this server's.
  @discardableResult
  public func apply(
    _ inspection: Inspection, sections: Set<ExportSection>, serverPassword: String = ""
  ) async throws -> Report {
    let ordered = inspection.sections.filter(sections.contains)
    for section in ordered where !inspection.manifest.sections.contains(section) {
      throw Failure.sectionMissing(section)
    }
    if ordered.contains(.secrets), serverPassword.isEmpty {
      throw Failure.passwordRequired
    }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var counts: [ExportSection: Int] = [:]
    var skipped: [String] = []

    for section in ordered {
      let url = inspection.directory.appendingPathComponent(section.fileName)
      let data = try Data(contentsOf: url)
      let (count, ignored) = try await restore(
        section, from: data, decoder: decoder, password: serverPassword)
      counts[section] = count
      skipped.append(contentsOf: ignored)
    }

    logger.info(
      "Imported a server export",
      metadata: [
        "sections": .string(ordered.map(\.rawValue).joined(separator: ",")),
        "skippedSettings": .stringConvertible(skipped.count),
      ])
    return Report(applied: ordered, counts: counts, skippedSettings: skipped.sorted())
  }

  // MARK: - Sections

  private func restore(
    _ section: ExportSection, from data: Data, decoder: JSONDecoder, password: String
  ) async throws -> (Int, [String]) {
    switch section {
    case .settings:
      return try await restoreSettings(from: data, decoder: decoder)

    case .secrets:
      let envelope = try decoder.decode(SecretsEnvelope.self, from: data)
      let values = try decoder.decode(
        [String: String].self, from: try envelope.open(withPassword: password))
      // One batch, so the propagation pass that follows a settings write happens once
      // rather than once per credential.
      _ = try await settings.write { batch in
        for (key, value) in values.sorted(by: { $0.key < $1.key }) {
          batch.setDynamic(value, forKey: key, isSecret: true)
        }
      }
      return (values.count, [])

    case .webhooks:
      let rows = try decoder.decode([Webhook].self, from: data)
      try await database.write { db in
        try db.execute(sql: "DELETE FROM webhook")
        for var row in rows {
          row.id = nil
          try row.insert(db)
        }
      }
      return (rows.count, [])

    case .scheduledMessages:
      let rows = try decoder.decode([ScheduledMessage].self, from: data)
      try await database.write { db in
        try db.execute(sql: "DELETE FROM scheduled_message")
        for var row in rows {
          row.id = nil
          try row.insert(db)
        }
      }
      return (rows.count, [])

    case .devices:
      let rows = try decoder.decode([Device].self, from: data)
      try await database.write { db in
        try db.execute(sql: "DELETE FROM device")
        for var row in rows {
          row.id = nil
          try row.insert(db)
        }
      }
      return (rows.count, [])

    case .clientBackups:
      let rows = try decoder.decode([Backup].self, from: data)
      try await database.write { db in
        try db.execute(sql: "DELETE FROM backup")
        for var row in rows {
          row.id = nil
          try row.insert(db)
        }
      }
      return (rows.count, [])

    case .contacts:
      let rows = try decoder.decode([ExportedRow].self, from: data)
      try await write(rows, into: "contact")
      return (rows.count, [])

    case .accessControl:
      let groups = try decoder.decode([String: [ExportedRow]].self, from: data)
      try await write(groups["allowed"] ?? [], into: "allowed_client")
      try await write(groups["blocked"] ?? [], into: "blocked_client")
      return ((groups["allowed"]?.count ?? 0) + (groups["blocked"]?.count ?? 0), [])
    }
  }

  /// Settings are written key by key rather than replacing the table. See the header.
  private func restoreSettings(from data: Data, decoder: JSONDecoder) async throws
    -> (Int, [String])
  {
    let values = try decoder.decode([String: SettingValueBox].self, from: data)
    let secretKeys = Settings.secretKeys
    var applied = 0
    var skipped: [String] = []

    for (key, stored) in values.sorted(by: { $0.key < $1.key }) {
      // Checked again HERE, on the way in, and not only on the way out. An archive is a
      // file from outside this server: it may have been written by a version whose
      // portability list was shorter, or edited by hand. Trusting the exporter's
      // judgement about somebody else's file is how `server_address` gets imported.
      guard SettingPortability.isExportableSetting(key, secretKeys: secretKeys),
        let declaration = Settings.setting(forKey: key),
        let box = stored.box
      else {
        skipped.append(key)
        continue
      }
      // Through the declaration's own writer, so the value is validated the way it would
      // be if somebody typed it. A password policy or a range refusing an imported value
      // is the right outcome; writing round the validator would import a value the server
      // will not accept from any other path.
      do {
        try await declaration.write(settings, box)
        applied += 1
      } catch {
        skipped.append(key)
      }
    }
    return (applied, skipped)
  }

  /// Replaces a table read generically, column by column as the archive names them.
  ///
  /// Columns the archive has and this schema does not are DROPPED rather than failing the
  /// import: an export from a newer server carrying an extra column should restore what it
  /// can, because the alternative is refusing a file whose every other row is fine.
  private func write(_ rows: [ExportedRow], into table: String) async throws {
    try await database.write { db in
      let known = Set(try db.columns(in: table).map(\.name))
      try db.execute(sql: "DELETE FROM \(table)")
      for row in rows {
        let usable = row.values.filter { known.contains($0.key) && $0.key != "id" }
        guard !usable.isEmpty else { continue }
        let columns = usable.keys.sorted()
        let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
        try db.execute(
          sql: """
            INSERT INTO \(table) (\(columns.joined(separator: ", "))) VALUES (\(placeholders))
            """,
          arguments: StatementArguments(columns.map { usable[$0] ?? nil })
        )
      }
    }
  }

  /// How many records a section's JSON holds, for a preview.
  ///
  /// Shape-tolerant on purpose: most sections are an array, settings is an object, and
  /// access control is an object of arrays. A count is a courtesy — being unable to work
  /// one out must not stop an import.
  static func count(in data: Data) -> Int {
    guard let object = try? JSONSerialization.jsonObject(with: data) else { return 0 }
    if let array = object as? [Any] { return array.count }
    if let dictionary = object as? [String: Any] {
      let nested = dictionary.values.compactMap { $0 as? [Any] }
      return nested.isEmpty ? dictionary.count : nested.reduce(0) { $0 + $1.count }
    }
    return 0
  }
}
