import AntigravityPorterCore
import SwiftUI

@main
struct AntigravityPorterApp: App {
    @State private var status = PorterAppStatus()

    var body: some Scene {
        MenuBarExtra("AntigravityPorter", systemImage: "point.3.connected.trianglepath.dotted") {
            VStack(alignment: .leading, spacing: 8) {
                Text("AntigravityPorter")
                    .font(.headline)
                Text(status.proxyEnabled ? "Proxy on" : "Proxy off")
                Text("Port \(status.port)")
                Divider()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding()
            .frame(width: 240)
        }
    }
}

private struct PorterAppStatus {
    var proxyEnabled = false
    var port = 18080
}
