import SwiftUI

struct ModelInspectorView: View {
    let model: ModelItem
    @EnvironmentObject var runner: BackendRunnerManager
    @EnvironmentObject var monitor: SystemMonitorService

    @State private var selectedTab: Int = 0

    var fitScore: MemoryFitScore {
        monitor.calculateFitScore(for: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.name)
                        .font(.largeTitle.bold())
                    Text("Engine: \(model.engineType.rawValue) • Format: \(model.format.rawValue)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()

                if runner.activeModel?.id == model.id {
                    Button(action: { runner.stopCurrent() }) {
                        Label("Stop Runner", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else {
                    Button(action: { runner.startModel(model) }) {
                        Label("Start Runner", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(10)

            // Memory Fit Card
            HStack {
                Image(systemName: "memorychip")
                    .font(.title2)
                VStack(alignment: .leading) {
                    Text("System Memory Fit Prediction")
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
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)

            // Tabs
            Picker("", selection: $selectedTab) {
                Text("Configuration & Info").tag(0)
                Text("Live Logs").tag(1)
            }
            .pickerStyle(.segmented)

            if selectedTab == 0 {
                Form {
                    Section(header: Text("Model File Details")) {
                        LabeledContent("File Path", value: model.fileURL.path)
                        LabeledContent("Size", value: model.sizeFormatted)
                        if let ctx = model.contextLength {
                            LabeledContent("Default Context Length", value: "\(ctx) tokens")
                        }
                    }

                    Section(header: Text("Runner Settings (Port: \(runner.port))")) {
                        Stepper("Port: \(runner.port)", value: $runner.port, in: 1024...65535)
                    }
                }
                .formStyle(.grouped)
            } else {
                ScrollView {
                    Text(runner.logOutput.isEmpty ? "No logs generated yet. Start the model to view stdout/stderr." : runner.logOutput)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(8)
            }

            Spacer()
        }
        .padding()
    }
}
