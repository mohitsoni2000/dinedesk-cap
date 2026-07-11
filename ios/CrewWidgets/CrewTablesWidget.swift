import SwiftUI
import WidgetKit

private let appGroup = "group.com.command.crew"
private let terra = Color(red: 0.878, green: 0.365, blue: 0.219)
private let ok = Color(red: 0.122, green: 0.643, blue: 0.333)

struct FloorEntry: TimelineEntry {
  let date: Date
  let mine: Int, free: Int, ready: Int
  let revenue: String, updated: String
}

struct FloorProvider: TimelineProvider {
  func read() -> FloorEntry {
    let d = UserDefaults(suiteName: appGroup)
    return FloorEntry(
      date: .now,
      mine: d?.integer(forKey: "w_mine") ?? 0,
      free: d?.integer(forKey: "w_free") ?? 0,
      ready: d?.integer(forKey: "w_ready") ?? 0,
      revenue: d?.string(forKey: "w_revenue") ?? "₹0",
      updated: d?.string(forKey: "w_updated") ?? "--:--")
  }
  func placeholder(in: Context) -> FloorEntry { read() }
  func getSnapshot(in: Context, completion: @escaping (FloorEntry) -> Void) {
    completion(read())
  }
  func getTimeline(in: Context, completion: @escaping (Timeline<FloorEntry>) -> Void) {
    completion(Timeline(entries: [read()], policy: .never))
  }
}

struct CrewTablesWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "CrewTablesWidget", provider: FloorProvider()) { e in
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("COMMAND.CREW")
            .font(.system(size: 9, weight: .heavy)).tracking(1.2)
            .opacity(0.6)
          Spacer()
          Text(e.updated).font(.system(size: 9)).opacity(0.5)
        }
        HStack(spacing: 14) {
          Stat(n: e.mine, label: "MINE", color: terra)
          Stat(n: e.free, label: "FREE", color: ok)
          Stat(n: e.ready, label: "READY",
               color: e.ready > 0 ? ok : .white.opacity(0.4),
               highlight: e.ready > 0)
        }
        Spacer(minLength: 0)
        Text(e.revenue + " on tables")
          .font(.system(size: 12, weight: .semibold))
          .opacity(0.85)
      }
      .foregroundStyle(.white)
      .padding(2)
      .containerBackground(for: .widget) {
        Color(red: 0.118, green: 0.09, blue: 0.063)
      }
    }
    .configurationDisplayName("My floor")
    .description("Tables, ready orders and running total at a glance.")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}

private struct Stat: View {
  let n: Int; let label: String; let color: Color
  var highlight = false
  var body: some View {
    VStack(spacing: 1) {
      Text("\(n)")
        .font(.system(size: 24, weight: .heavy))
        .foregroundStyle(color)
      Text(label)
        .font(.system(size: 8, weight: .bold)).tracking(0.8)
        .opacity(0.6)
    }
    .padding(.horizontal, highlight ? 7 : 0)
    .background(highlight ? ok.opacity(0.18) : .clear,
                in: RoundedRectangle(cornerRadius: 8))
  }
}
