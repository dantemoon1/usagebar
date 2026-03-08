import SwiftUI
import UsageBarCore

@main
struct UsageBarApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            DashboardMenuView(model: model)
        } label: {
            BarIconView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
