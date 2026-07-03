import SwiftUI
import Combine

@MainActor
class AppSettings: ObservableObject {
    @AppStorage("enableHardwareAutoTuning") var enableHardwareAutoTuning: Bool = true
    @AppStorage("defaultContextLength") var defaultContextLength: Int = 8192
    @AppStorage("enableIdleUnload") var enableIdleUnload: Bool = true
    @AppStorage("idleUnloadMinutes") var idleUnloadMinutes: Int = 15
    @Published var gatewayPort: Int = UserDefaults.standard.integer(forKey: "gatewayPort") == 0 ? 4891 : UserDefaults.standard.integer(forKey: "gatewayPort") {
        didSet {
            UserDefaults.standard.set(gatewayPort, forKey: "gatewayPort")
        }
    }
    @AppStorage("customDownloadPath") var customDownloadPath: String = ""

    var resolvedDownloadURL: URL {
        if !customDownloadPath.isEmpty {
            return URL(fileURLWithPath: customDownloadPath)
        }
        let defaultURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("LocalMgr/Models")
        try? FileManager.default.createDirectory(at: defaultURL, withIntermediateDirectories: true)
        return defaultURL
    }
}
