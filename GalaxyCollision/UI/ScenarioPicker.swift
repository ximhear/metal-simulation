import SwiftUI

/// On iOS, finish dismissing the list before applying the new scenario.
/// This view does not observe the frequently published frame/time statistics.
struct ScenarioPicker: View {
    @Binding var selection: EncounterPreset
    #if os(iOS)
    @State private var showingList = false
    @State private var pendingSelection: EncounterPreset?
    #endif

    var body: some View {
        #if os(iOS)
        Button {
            pendingSelection = nil
            showingList = true
        } label: {
            HStack {
                Label(selection.rawValue, systemImage: selection.icon)
                Spacer()
                Image(systemName: "chevron.down").font(.caption)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("은하 시뮬레이션 시나리오")
        .accessibilityValue(selection.rawValue)
        .sheet(isPresented: $showingList, onDismiss: {
            if let pendingSelection { selection = pendingSelection }
            pendingSelection = nil
        }) {
            ScenarioList(selected: selection) { preset in
                pendingSelection = preset
                showingList = false
            }
            .presentationDetents([.large])
        }
        #else
        Picker("시나리오", selection: $selection) {
            ForEach(EncounterPreset.allCases) { preset in
                Label(preset.rawValue, systemImage: preset.icon).tag(preset)
            }
        }
        .pickerStyle(.menu)
        .accessibilityLabel("은하 시뮬레이션 시나리오")
        #endif
    }
}

#if os(iOS)
private struct ScenarioList: View {
    let selected: EncounterPreset
    let choose: (EncounterPreset) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(EncounterPreset.allCases) { preset in
                Button { choose(preset) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: preset.icon).frame(width: 25)
                        Text(preset.rawValue)
                        Spacer()
                        if preset == selected { Image(systemName: "checkmark") }
                    }
                    .frame(minHeight: 32)
                    .contentShape(Rectangle())
                }
                .foregroundStyle(preset == selected ? Color.accentColor : Color.primary)
                .accessibilityAddTraits(preset == selected ? .isSelected : [])
            }
            .navigationTitle("시뮬레이션 선택")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { dismiss() }
                }
            }
        }
    }
}
#endif
