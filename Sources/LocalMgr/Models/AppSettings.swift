import SwiftUI
import Combine

@MainActor
class AppSettings: ObservableObject {
    @AppStorage("enableHardwareAutoTuning") var enableHardwareAutoTuning: Bool = true
    @AppStorage("defaultContextLength") var defaultContextLength: Int = 8192
    @AppStorage("enableIdleUnload") var enableIdleUnload: Bool = true
    @AppStorage("idleUnloadMinutes") var idleUnloadMinutes: Int = 15
    @AppStorage("gatewayPort") var gatewayPort: Int = 4891
}
