import Flutter
import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Runner-side ActivityKit bridge. Compiles even before the CrewWidgets
/// extension exists; every call is a safe no-op below iOS 16.1.
enum LiveActivityBridge {
  static func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    #if canImport(ActivityKit)
    if #available(iOS 16.1, *) {
      let args = call.arguments as? [String: Any] ?? [:]
      let orderId = args["orderId"] as? String ?? ""
      switch call.method {
      case "startActivity":
        Manager.shared.start(
          orderId: orderId,
          tableName: args["tableName"] as? String ?? "Table",
          subtitle: args["subtitle"] as? String ?? ""
        )
        result(nil)
      case "updateActivity":
        Manager.shared.markReady(
          orderId: orderId,
          tableName: args["tableName"] as? String ?? "Table"
        )
        result(nil)
      case "endActivity":
        Manager.shared.end(orderId: orderId)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
      return
    }
    #endif
    result(nil) // silently unsupported
  }

  #if canImport(ActivityKit)
  @available(iOS 16.1, *)
  final class Manager {
    static let shared = Manager()
    private var live: [String: Activity<CrewOrderAttributes>] = [:]

    func start(orderId: String, tableName: String, subtitle: String) {
      guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
      let attrs = CrewOrderAttributes(orderId: orderId, tableName: tableName)
      let state = CrewOrderAttributes.ContentState(
        status: "preparing", subtitle: subtitle)
      do {
        if #available(iOS 16.2, *) {
          let content = ActivityContent(
            state: state, staleDate: Date().addingTimeInterval(2 * 60 * 60))
          live[orderId] = try Activity.request(
            attributes: attrs, content: content, pushType: nil)
        } else {
          live[orderId] = try Activity.request(
            attributes: attrs, contentState: state, pushType: nil)
        }
      } catch {
        print("[LiveActivity] start failed: \(error)")
      }
    }

    func markReady(orderId: String, tableName: String) {
      guard let activity = live[orderId] else { return }
      let state = CrewOrderAttributes.ContentState(
        status: "ready", subtitle: "Ready to serve — pick it up!")
      Task {
        if #available(iOS 16.2, *) {
          await activity.update(
            ActivityContent(state: state, staleDate: nil),
            alertConfiguration: AlertConfiguration(
              title: "\(tableName) ready",
              body: "Order is ready to serve",
              sound: .default))
        } else {
          await activity.update(using: state)
        }
      }
    }

    func end(orderId: String) {
      guard let activity = live.removeValue(forKey: orderId) else { return }
      Task {
        if #available(iOS 16.2, *) {
          await activity.end(nil, dismissalPolicy: .after(.now + 120))
        } else {
          await activity.end(dismissalPolicy: .immediate)
        }
      }
    }
  }
  #endif
}
