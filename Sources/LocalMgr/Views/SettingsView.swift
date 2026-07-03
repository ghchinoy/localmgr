import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        TabView {
            Form {
                Section(header: Text("Apple Silicon Hardware Auto-Tuning")) {
                    Toggle("Automatically Tune Engine Flags on Launch", isOn: $settings.enableHardwareAutoTuning)
                    Text("When enabled, LocalMgr detects your exact M-series SoC and RAM capacity to automatically configure 100% Metal GPU offloading (-ngl 99), Flash Attention (--flash-attn), and safe context caps.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section(header: Text("Inference Defaults")) {
                    Picker("Default Context Length", selection: $settings.defaultContextLength) {
                        Text("4,096 tokens").tag(4096)
                        Text("8,192 tokens").tag(8192)
                        Text("16,384 tokens").tag(16384)
                        Text("32,768 tokens").tag(32768)
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("Hardware & Engines", systemImage: "cpu")
            }

            Form {
                Section(header: Text("API Gateway Configuration")) {
                    Stepper("Gateway Listening Port: \(String(settings.gatewayPort))", value: $settings.gatewayPort, in: 1024...65535)
                    Text("Restart LocalMgr after changing the gateway port.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section(header: Text("Idle VRAM Reclaiming")) {
                    Toggle("Auto-Unload Idle Models", isOn: $settings.enableIdleUnload)
                    if settings.enableIdleUnload {
                        Stepper("Unload after: \(settings.idleUnloadMinutes) minutes", value: $settings.idleUnloadMinutes, in: 1...120)
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("Gateway & Memory", systemImage: "network")
            }
        }
        .frame(width: 520, height: 340)
        .padding()
    }
}
