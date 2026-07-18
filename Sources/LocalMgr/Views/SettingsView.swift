import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var readiness: EngineReadinessService

    /// Engines shown first, in their "mature/default-on" grouping.
    private let coreEngines: [EngineType] = [.llamaCpp, .mlx, .liteRT]
    /// Engines shown second, under an "Experimental" sub-header, with a
    /// per-engine caption explaining why they ship off by default.
    private let experimentalEngines: [EngineType] = [.kokoro, .gemmaCpp]

    private func experimentalCaption(for engine: EngineType) -> String {
        switch engine {
        case .kokoro:
            return "Off by default: Kokoro TTS audio/model scanning is not yet implemented in the model catalog."
        case .gemmaCpp:
            return "Off by default: LocalMgr is tracking upstream google/gemma.cpp support for Gemma 4+ architectures before enabling this engine by default (localmgr-e3b)."
        default:
            return ""
        }
    }

    /// A two-way `Binding<Bool>` over `AppSettings.isEngineEnabled`/
    /// `setEngineEnabled`, so each `Toggle` below can bind generically over
    /// `EngineType` without a 5-way switch in the view itself. Also
    /// triggers `EngineReadinessService.refreshReadiness()` on every
    /// change, so the sidebar Component Readiness list and DiagnosticsView
    /// Health Checks reflect the new state immediately -- without this,
    /// a user would need to remember to hit the separate manual refresh
    /// button after flipping a toggle here.
    private func engineEnabledBinding(_ engine: EngineType) -> Binding<Bool> {
        Binding(
            get: { settings.isEngineEnabled(engine) },
            set: { newValue in
                settings.setEngineEnabled(engine, newValue)
                readiness.refreshReadiness()
            }
        )
    }

    var body: some View {
        TabView {
            Form {
                Section(header: Text("Apple Silicon Hardware Auto-Tuning")) {
                    Toggle("Automatically Tune Engine Flags on Launch", isOn: $settings.enableHardwareAutoTuning)
                    Text("When enabled, LocalMgr detects your exact M-series SoC and RAM capacity to automatically configure 100% Metal GPU offloading (-ngl 99), Flash Attention (--flash-attn), and safe context caps.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section(header: Text("Execution Engines")) {
                    ForEach(coreEngines) { engine in
                        Toggle(engine.rawValue, isOn: engineEnabledBinding(engine))
                    }
                    Text("Disabling an engine removes it from the sidebar's Component Readiness list and Diagnostics Health Checks, and prevents starting any model assigned to it.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Divider()

                    Text("Experimental / Off by Default")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                    ForEach(experimentalEngines) { engine in
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle(engine.rawValue, isOn: engineEnabledBinding(engine))
                            Text(experimentalCaption(for: engine))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
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
                    Text("Changes take effect immediately — the API Gateway rebinds to the new port automatically.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section(header: Text("Model Storage & Downloads")) {
                    TextField("Custom Download Directory Override", text: $settings.customDownloadPath, prompt: Text("Default: ~/Library/Application Support/LocalMgr/Models"))
                        .textFieldStyle(.roundedBorder)
                    Text("Leave blank to use default Application Support folder. Downloaded files are automatically indexed into your vault.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section(header: Text("Lifecycle & VRAM Reclaiming")) {
                    Toggle("Auto-Unload Idle Models", isOn: $settings.enableIdleUnload)
                    if settings.enableIdleUnload {
                        Stepper("Unload after: \(settings.idleUnloadMinutes) minutes", value: $settings.idleUnloadMinutes, in: 1...120)
                    }
                    Toggle("Terminate active engines when LocalMgr quits", isOn: $settings.terminateRunnersOnQuit)
                }
                Section(header: Text("About LocalMgr")) {
                    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0"
                    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "3"
                    LabeledContent("Application Version", value: "v\(version) (Build \(build))")
                    LabeledContent("Engine Storage", value: "Application Support / Engines")
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("Gateway & Memory", systemImage: "network")
            }
        }
        .frame(width: 520, height: 380)
        .padding()
    }
}
