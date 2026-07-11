import SwiftUI
import WidgetKit
#if canImport(ActivityKit)
import ActivityKit

private let terra = Color(red: 0.878, green: 0.365, blue: 0.219)
private let ok = Color(red: 0.122, green: 0.643, blue: 0.333)

@available(iOS 16.1, *)
struct CrewLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: CrewOrderAttributes.self) { context in
      // Lock screen banner
      LockCard(context: context)
        .activityBackgroundTint(Color.black.opacity(0.85))
        .activitySystemActionForegroundColor(.white)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Text(context.attributes.tableName)
            .font(.system(size: 22, weight: .bold, design: .serif))
            .foregroundStyle(.white)
        }
        DynamicIslandExpandedRegion(.trailing) {
          StatusPill(ready: context.state.status == "ready")
        }
        DynamicIslandExpandedRegion(.bottom) {
          Text(context.state.subtitle)
            .font(.caption)
            .foregroundStyle(.white.opacity(0.8))
        }
      } compactLeading: {
        Image(systemName: "fork.knife")
          .foregroundStyle(context.state.status == "ready" ? ok : terra)
      } compactTrailing: {
        Circle()
          .fill(context.state.status == "ready" ? ok : terra)
          .frame(width: 10, height: 10)
      } minimal: {
        Image(systemName: context.state.status == "ready"
              ? "checkmark.circle.fill" : "flame.fill")
          .foregroundStyle(context.state.status == "ready" ? ok : terra)
      }
    }
  }
}

@available(iOS 16.1, *)
private struct LockCard: View {
  let context: ActivityViewContext<CrewOrderAttributes>
  var body: some View {
    HStack(spacing: 12) {
      Circle()
        .fill(context.state.status == "ready" ? ok : terra)
        .frame(width: 12, height: 12)
      VStack(alignment: .leading, spacing: 2) {
        Text(context.attributes.tableName)
          .font(.system(size: 19, weight: .bold, design: .serif))
        Text(context.state.subtitle)
          .font(.caption)
          .opacity(0.8)
      }
      Spacer()
      StatusPill(ready: context.state.status == "ready")
    }
    .foregroundStyle(.white)
    .padding(14)
  }
}

private struct StatusPill: View {
  let ready: Bool
  var body: some View {
    Text(ready ? "READY" : "PREPARING")
      .font(.system(size: 10, weight: .heavy))
      .padding(.horizontal, 9).padding(.vertical, 5)
      .background((ready ? ok : terra), in: Capsule())
      .foregroundStyle(.white)
  }
}
#endif
