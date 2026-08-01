import SwiftUI

@main
struct AliyunTokenBarApp: App {
    var body: some Scene {
        MenuBarExtra("AliyunTokenBar", systemImage: "speedometer") {
            Text("AliyunTokenBar")
                .padding()
        }
        .menuBarExtraStyle(.window)
    }
}
