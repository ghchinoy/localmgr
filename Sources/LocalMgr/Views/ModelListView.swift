import SwiftUI

struct ModelListView: View {
    @EnvironmentObject var catalog: ModelCatalogService
    @EnvironmentObject var runner: BackendRunnerManager
    @EnvironmentObject var readiness: EngineReadinessService

    var body: some View {
        VStack(spacing: 0) {
            Picker("Filter Format", selection: $catalog.selectedFilter) {
                ForEach(ModelCatalogService.ModelFilterCategory.allCases) { cat in
                    Text(cat.rawValue).tag(cat)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            List(selection: $catalog.selectedModel) {
            ForEach(catalog.filteredModels) { model in
                let isReady = readiness.isReady(for: model.engineType)
                NavigationLink(value: model) {
                    HStack(spacing: 12) {
                        Image(systemName: model.engineType.iconName)
                            .font(.title2)
                            .foregroundColor(isReady ? .accentColor : .secondary)
                            .frame(width: 32)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.name)
                                .font(.headline)
                            HStack(spacing: 6) {
                                Text(model.format.rawValue)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.15))
                                    .cornerRadius(4)

                                if let quant = model.quantization {
                                    Text(quant)
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.blue.opacity(0.15))
                                        .cornerRadius(4)
                                }

                                Text(model.sizeFormatted)
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                Text(isReady ? "🟢 Ready" : "🔴 Missing Engine")
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(isReady ? Color.green.opacity(0.15) : Color.red.opacity(0.15))
                                    .foregroundColor(isReady ? .green : .red)
                                    .cornerRadius(4)
                            }
                        }

                        Spacer()

                        if runner.activeModel?.id == model.id {
                            Text("RUNNING")
                                .font(.caption.bold())
                                .foregroundColor(.green)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.green.opacity(0.15))
                                .cornerRadius(6)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        }
        .searchable(text: $catalog.searchText, prompt: "Search models...")
        .navigationTitle("Models (\(catalog.filteredModels.count))")
    }
}
