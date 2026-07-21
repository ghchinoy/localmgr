import SwiftUI

/// The 3 mutually-exclusive states a model's engine can be in, replacing a
/// simple ready/not-ready boolean. `.disabled` is distinct from `.missing`:
/// a disabled engine is a user choice (Settings -> Hardware & Engines) with
/// a clear remedy (flip the toggle), whereas a missing engine means the
/// binary genuinely isn't installed on this machine (a different remedy --
/// install it).
enum EngineReadinessBadgeState {
    case ready
    case missing
    case disabled

    var label: String {
        switch self {
        case .ready: return "🟢 Ready"
        case .missing: return "🔴 Missing Engine"
        case .disabled: return "⚪️ Engine Disabled"
        }
    }

    var color: Color {
        switch self {
        case .ready: return .green
        case .missing: return .red
        case .disabled: return .secondary
        }
    }
}

/// Computes the 3-state badge for a model's engine from the enabled setting
/// and live readiness together, so both `ModelListView` and
/// `ModelInspectorView` derive identical state from one shared function.
@MainActor
func engineReadinessBadgeState(for engine: EngineType, settings: AppSettings, readiness: EngineReadinessService) -> EngineReadinessBadgeState {
    guard settings.isEngineEnabled(engine) else { return .disabled }
    return readiness.isReady(for: engine) ? .ready : .missing
}

struct ModelListView: View {
    @EnvironmentObject var catalog: ModelCatalogService
    @EnvironmentObject var runner: BackendRunnerManager
    @EnvironmentObject var readiness: EngineReadinessService
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Filter Format", selection: $catalog.selectedFilter) {
                    ForEach(ModelCatalogService.ModelFilterCategory.allCases) { cat in
                        Text(cat.rawValue).tag(cat)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Sort", selection: $catalog.selectedSortOption) {
                    ForEach(ModelCatalogService.ModelSortOption.allCases) { opt in
                        Text(opt.rawValue).tag(opt)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 140)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            List(selection: $catalog.selectedModel) {
            ForEach(catalog.filteredModels) { model in
                let badgeState = engineReadinessBadgeState(for: model.engineType, settings: settings, readiness: readiness)
                let isReady = badgeState == .ready
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

                                Text(badgeState.label)
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(badgeState.color.opacity(0.15))
                                    .foregroundColor(badgeState.color)
                                    .cornerRadius(4)
                            }
                            
                            if catalog.selectedSortOption == .lastUsed, let desc = catalog.lastUsedDescription(for: model) {
                                Text("Last run: \(desc)")
                                    .font(.caption2)
                                    .foregroundColor(.accentColor)
                            } else if catalog.selectedSortOption == .mostFrequent {
                                let count = catalog.usageCount(for: model)
                                Text("Run count: \(count) time\(count == 1 ? "" : "s")")
                                    .font(.caption2)
                                    .foregroundColor(.accentColor)
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
