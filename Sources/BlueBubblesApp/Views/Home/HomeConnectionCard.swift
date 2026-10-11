//  HomeConnectionCard
//  How clients reach this server.
//
//  On Home rather than only on Guides because it is the answer to the question people open
//  this app to ask. The Guides page and a read-only settings row are not where someone looks
//  after starting the server.

import BBSettings
import SwiftUI

struct HomeConnectionCard: View {

  /// How clients reach this server, as the settings store has it.
  ///
  /// A snapshot struct rather than three `@State` strings so the card never renders a new
  /// address beside the previous method's name: the two change together, on the same
  /// settings write, and half of one update on screen is what someone reads as the truth.
  struct Connection: Equatable {
    /// The method's own name, from its manifest: "Cloudflare Tunnel", "Local Network".
    /// Falls back to the raw identifier, which is the honest answer for a method this
    /// build does not have installed.
    var method: String
    /// The published URL. Empty until the method has one, which is a real state and not
    /// an error: a tunnel takes a few seconds to come up.
    var address: String
    var port: Int
  }

  /// The settings whose changes this card has to notice.
  ///
  /// The address is the one that moves without anybody touching the UI: a tunnel publishes
  /// it seconds after start, and republishes it whenever it reconnects, so a card that read
  /// once at `.running` would show "not published yet" for the whole session.
  static let connectionKeys: Set<String> = [
    Settings.serverAddress.key, Settings.connectionMethod.key, Settings.socketPort.key,
  ]

  @Bindable var model: AppModel
  let connection: Connection?

  var body: some View {
    HomeCard(
      "Connection", symbol: "network",
      // Straight to the tab that owns the method picker, not to Settings' first tab.
      destination: ("Change", { model.openSettings(tab: .connection) })
    ) {
      // The method as a tag, matching how Guides tags the Private API state: it is a fixed
      // piece of vocabulary rather than a sentence, and it is the context that makes the
      // address below make sense.
      Tag(connection?.method ?? "-")

      LabeledContent("Server URL") {
        // Blanked, not merely annotated, when nothing is listening. `server_address` holds
        // whatever the connection method last published and no one clears it, so the value
        // survives the listener being switched off, and an address next to "enter this in
        // the app" is an instruction, not a status.
        CopyableValue(
          model.apiReachability.showsAddress ? (connection?.address ?? "") : "",
          placeholder: model.apiReachability.addressPlaceholder)
      }
      LabeledContent("Local port", value: connection.map { String($0.port) } ?? "-")

      if let note = model.apiReachability.note {
        Text(note)
          .font(.caption)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        Text("This is the URL to enter in the BlueBubbles app, with your server password.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
