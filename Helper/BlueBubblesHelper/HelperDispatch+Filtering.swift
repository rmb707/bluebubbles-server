//  HelperDispatch+Filtering
//  Filtering, spam and history: one piece of IMCore state with four ways in.
//
//  One role's worth of `HelperDispatch`; the switch that reaches these, and the request
//  reader they take, are in `HelperDispatch.swift`.

import BBPrivateAPIContract
import Foundation
import HelperShared

extension HelperDispatch {
  @MainActor
  static func clearChatHistory(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    return [.deleted: try await bridge.clearChatHistory(try data.chat())]
  }

  @MainActor
  static func getChatFilter(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    return encode(try await bridge.chatFilterState(chat: try data.chat()))
  }

  @MainActor
  static func markSenderKnown(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    return encode(
      try await bridge.markSenderKnown(
        chat: try data.chat(), saveInContacts: data.flag(.saveInContacts)
      ))
  }

  @MainActor
  static func getChatPresentation(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    return encode(try await bridge.chatPresentationState(chat: try data.chat()))
  }

  @MainActor
  static func markChatSpam(_ data: RequestData, on bridge: IMCoreBridge) async throws -> WireObject?
  {
    return encode(
      try await bridge.markChatAsSpam(
        ChatSpamRequest(
          chat: try data.chat(),
          reportToCarrier: data.flag(.reportToCarrier),
          dryRun: data.flag(.dryRun)
        )
      ))
  }

  @MainActor
  static func reportChatJunk(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    return encode(
      try await bridge.reportChatAsJunk(
        ChatSpamRequest(
          chat: try data.chat(),
          reportToCarrier: data.flag(.reportToCarrier),
          dryRun: data.flag(.dryRun)
        )
      ))
  }

  @MainActor
  static func setChatFilter(_ data: RequestData, on bridge: IMCoreBridge) async throws
    -> WireObject?
  {
    guard let category = data[.category]?.intValue else {
      throw PrivateAPIError.rejectedByMessages(
        reason: "set-chat-filter requires 'category'"
      )
    }
    return encode(try await bridge.setChatFilter(chat: try data.chat(), category: category))
  }

  static func encode(_ state: ChatFilterState) -> WireObject {
    var object: WireObject = [
      .isFiltered: state.isFiltered,
      .isKnownSender: state.isKnownSender,
      .isInUnknownSendersFilter: state.isInUnknownSendersFilter,
      .wasDetectedAsSMSSpam: state.wasDetectedAsSMSSpam,
      .canReportJunk: state.canReportJunk,
    ]
    // Absent when this release cannot say, for the reason the presentation state below gives.
    if let category = state.filterCategory { object[.filterCategory] = category }
    return object
  }

  /// Only the keys this release could answer.
  ///
  /// An absent key is "cannot say"; a `false` would be "no". Conflating them is the
  /// `canReportJunk` defect, where a missing selector was reported as a working feature
  /// being unavailable.
  static func encode(_ state: ChatPresentationState) -> WireObject {
    var object: WireObject = [:]
    if let value = state.shouldPresentSpamReasonPicker {
      object[.shouldPresentSpamReasonPicker] = value
    }
    if let value = state.isReportedAsSpam { object[.isReportedAsSpam] = value }
    if let value = state.wasDetectedAsSMSSpam { object[.wasDetectedAsSMSSpam] = value }
    if let value = state.wasDetectedAsSpam { object[.wasDetectedAsSpam] = value }
    if let value = state.isKnownChat { object[.isKnownChat] = value }
    if let value = state.completedInitialChatMessagesLoad {
      object[.completedInitialChatMessagesLoad] = value
    }
    if let value = state.isSMSSpamFilteringEnabled {
      object[.isSMSSpamFilteringEnabled] = value
    }
    return object
  }

  static func encode(_ result: ChatSpamResult) -> WireObject {
    [
      .messageCount: result.messageCount,
      .reportedToCarrier: result.reportedToCarrier,
      .dryRun: result.wasDryRun,
      .filter: encode(result.filter),
    ]
  }
}
