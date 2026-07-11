import SwiftUI
import WidgetKit

@main
struct CrewWidgetsBundle: WidgetBundle {
  var body: some Widget {
    CrewTablesWidget()
    if #available(iOS 16.1, *) {
      CrewLiveActivity()
    }
  }
}
