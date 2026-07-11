import Foundation
#if canImport(ActivityKit)
import ActivityKit

/// ⚠️ Target membership: BOTH Runner and CrewWidgets.
struct CrewOrderAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    var status: String   // "preparing" | "ready"
    var subtitle: String
  }
  var orderId: String
  var tableName: String
}
#endif
