import SwiftUI

struct ModelListView: View {
    @EnvironmentObject var catalog: ModelCatalogService
    @EnvironmentObject var runner: BackendRunnerManager

    var body: some View {
        List(selection: $catalog.selectedModel) {
            ForEach(catalog.filteredModels) { model in
                NavigationLink(value: model) {
                    HStack(spacing: 12) {
                        Image(systemName: model.engineType.iconName)
                            .font(.title2)
                            .foregroundColor(.accentColor)
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
        .searchable(text: $catalog.searchText, prompt: "Search models...")
        .navigationTitle("Models (\(catalog.filteredModels.count))")
    }
}
