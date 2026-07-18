import SwiftUI

struct ModelInspectorView: View {
    let model: ModelItem
    @EnvironmentObject var runner: BackendRunnerManager
    @EnvironmentObject var monitor: SystemMonitorService
    @EnvironmentObject var readiness: EngineReadinessService

    @State private var selectedTab: Int = 0
    @State private var contextLengthSlider: Double = 8192

    var isEngineReady: Bool {
        readiness.isReady(for: model.engineType)
    }

    var st: EngineComponentStatus {
        readiness.status(for: model.engineType)
    }

    var breakdown: MemoryPressureBreakdown {
        model.memoryPressure(forContextLength: Int(contextLengthSlider))
    }

    var fitScore: MemoryFitScore {
        monitor.calculateFitScore(for: model, contextLength: Int(contextLengthSlider))
    }

    var compatibilityColor: Color {
        switch model.compatibilityTier {
        case .verified: return .green
        case .recognizedUnverified: return .orange
        case .unrecognizedArchitecture: return .orange
        case .unparseable: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.name)
                        .font(.largeTitle.bold())
                    HStack(spacing: 8) {
                        Text("Engine: \(model.engineType.rawValue) • Format: \(model.format.rawValue)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Label(model.compatibilityTier.badgeLabel, systemImage: model.compatibilityTier.symbolName)
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(compatibilityColor.opacity(0.15))
                            .foregroundColor(compatibilityColor)
                            .cornerRadius(4)
                            .help("Compatibility tier: how confident LocalMgr is that this file's architecture is a verified combination with \(model.engineType.rawValue).")
                    }
                }
                Spacer()

                if runner.activeModel?.id == model.id && (runner.status == .running || runner.status == .starting) {
                    Button(action: { runner.stopCurrent() }) {
                        Label("Stop Runner", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .keyboardShortcut(".", modifiers: [.command])
                } else {
                    Button(action: { runner.startModel(model) }) {
                        Label("Start Runner", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(!isEngineReady)
                    .keyboardShortcut("r", modifiers: [.command])
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(10)

            if !isEngineReady {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Prerequisite Missing: \(model.engineType.defaultBinaryName) is not installed on this machine. \(st.installHint)")
                        .font(.subheadline)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.15))
                .cornerRadius(8)
            }

            // Compatibility-tier notice: distinct from the engine-readiness
            // banner above -- that answers "is the engine binary installed
            // at all", this answers "how confident is LocalMgr that this
            // specific file's architecture is a combination it has
            // verified with that engine". Only shown for non-verified
            // tiers so a fully-verified model shows no extra chrome.
            if model.compatibilityTier.isConcerning {
                HStack(alignment: .top) {
                    Image(systemName: model.compatibilityTier.symbolName)
                        .foregroundColor(compatibilityColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(model.compatibilityTier.badgeLabel): \(model.compatibilityMessage)")
                            .font(.subheadline)
                        if let action = model.compatibilityRecommendedAction {
                            Text(action)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(compatibilityColor.opacity(0.12))
                .cornerRadius(8)
            }

            // Precise Memory Pressure Card
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "memorychip")
                        .font(.title2)
                    VStack(alignment: .leading) {
                        Text("Precise Memory Pressure & Fit Prediction")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(fitScore.rawValue)
                            .font(.headline)
                    }
                    Spacer()
                    Text("Available RAM: \(monitor.shortMemorySummary)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundColor(.secondary)
                }

                Divider()

                HStack(spacing: 20) {
                    VStack(alignment: .leading) {
                        Text("Model Weights")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(breakdown.formattedWeights)
                            .font(.subheadline.bold())
                    }
                    VStack(alignment: .leading) {
                        Text("KV Cache (\(Int(contextLengthSlider)) ctx)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(breakdown.formattedKVCache)
                            .font(.subheadline.bold())
                    }
                    VStack(alignment: .leading) {
                        Text("Total Estimated RAM/VRAM")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(breakdown.formattedTotal)
                            .font(.subheadline.bold())
                            .foregroundColor(fitScore == .thrashing ? .red : .primary)
                    }
                }
            }
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)

            // Tabs
            Picker("", selection: $selectedTab) {
                Text("Configuration & Info").tag(0)
                Text("Live Logs").tag(1)
                Text("Quick Test Ping").tag(2)
            }
            .pickerStyle(.segmented)

            if selectedTab == 0 {
                Form {
                    Section(header: Text("Context & Execution Parameters")) {
                        VStack(alignment: .leading) {
                            Text("Target Context Length: \(Int(contextLengthSlider)) tokens")
                            Slider(value: $contextLengthSlider, in: 2048...65536, step: 2048)
                        }
                    }

                    Section(header: Text("Model File Details")) {
                        LabeledContent("File Path", value: model.fileURL.path)
                        LabeledContent("Size", value: model.sizeFormatted)
                        LabeledContent("Chat Template", value: model.chatTemplate ?? "Auto-Detected")
                        if let ctx = model.contextLength {
                            LabeledContent("Default Context Length", value: "\(ctx) tokens")
                        }
                    }

                    Section(header: Text("Runner Settings (Port: \(String(runner.port)))")) {
                        Stepper("Port: \(String(runner.port))", value: $runner.port, in: 1024...65535)
                    }
                }
                .formStyle(.grouped)
            } else if selectedTab == 1 {
                ScrollView {
                    if runner.activeModel?.id == model.id || runner.lastRunModelID == model.id {
                        Text(runner.logOutput.isEmpty ? "No logs generated yet. Waiting for stdout/stderr..." : runner.logOutput)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Image(systemName: "pause.circle.fill")
                                    .foregroundColor(.secondary)
                                Text("This model is currently stopped.")
                                    .font(.headline)
                            }
                            Text("The live logs pane displays terminal output for the active or last run engine session. Click 'Start Runner' at the top right to start \(model.name) and stream its stdout/stderr.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(8)
            } else {
                QuickTestView(model: model)
            }

            Spacer()
        }
        .padding()
    }
}

struct QuickTestView: View {
    let model: ModelItem
    @EnvironmentObject var runner: BackendRunnerManager
    @State private var promptText: String = "Hello! Please confirm you are working in one sentence."

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if runner.activeModel?.id != model.id || runner.status != .running {
                HStack {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(.blue)
                    Text("Start this model runner above to send a quick verification ping.")
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.12))
                .cornerRadius(8)
            } else {
                Text("Verify Model Readiness")
                    .font(.headline)
                Text("Send a lightweight 256-token verification ping directly to port \(String(runner.port)) to confirm weights initialized properly before connecting external IDEs.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    TextField("Test Prompt", text: $promptText)
                        .textFieldStyle(.roundedBorder)
                    Button(action: {
                        runner.sendTestPing(modelName: model.name, promptText: promptText)
                    }) {
                        if runner.isPinging {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Send Ping", systemImage: "paperplane.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(runner.isPinging || promptText.isEmpty)
                }

                if !runner.lastPingResponse.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Model Response:")
                            .font(.caption.bold())
                            .foregroundColor(.secondary)
                        ScrollView {
                            Text(runner.lastPingResponse)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding()
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(8)
                }
            }
        }
        .padding(.vertical, 8)
    }
}
