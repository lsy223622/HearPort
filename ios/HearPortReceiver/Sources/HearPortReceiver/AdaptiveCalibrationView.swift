#if canImport(SwiftUI) && os(iOS)
import SwiftUI

struct AdaptiveCalibrationView: View {
    let result: AdaptiveCalibrationResult?
    let canStart: Bool
    let hasSelectedConnection: Bool
    let canChooseComputer: Bool
    let computers: [ComputerConnectionTarget]
    @Binding var selectedComputer: ComputerConnectionTarget?
    let starting: Bool
    let status: String?
    let start: (Int, Int, Int) -> Void
    let apply: () -> Bool
    @State private var goal = 2
    @State private var seconds = 15
    @State private var maximum = 300
    @State private var applied = false

    var body: some View {
        List {
            if let result { recommendation(result) }
            Section {
                if canChooseComputer {
                    NavigationLink {
                        CalibrationComputerPicker(computers: computers, selection: $selectedComputer)
                    } label: {
                        LabeledContent("PC", value: selectedComputer?.title ?? NSLocalizedString("Choose a PC", comment: ""))
                    }
                }
                CalibrationGoalPicker(selection: $goal).frame(height: 44)
                MillisecondsControl("Maximum acceptable delay", value: $maximum, range: 40...2000)
                Picker("Test segment duration", selection: $seconds) {
                    Text("15 seconds").tag(15)
                    Text("30 seconds").tag(30)
                    Text("60 seconds").tag(60)
                }
                Button {
                    applied = false; start(goal, seconds, maximum)
                } label: {
                    HStack {
                        Text(starting ? LocalizedStringKey("Starting calibration…") :
                            hasSelectedConnection ? LocalizedStringKey("Start automatic test") : LocalizedStringKey("No connection selected"))
                        if starting { ProgressView().tint(.blue) }
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.automatic).tint(.blue)
                .disabled(!canStart || starting)
                if let status { Text(status).font(.footnote).foregroundStyle(.secondary) }
            } header: {
                Text("Test goal")
            }
        }
        .navigationTitle("Automatic test and recommendations")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func recommendation(_ result: AdaptiveCalibrationResult) -> some View {
        Section {
            LabeledContent("Test goal") { Text(CalibrationResultsView.profileName(result.goal)) }
            if let p = result.selected {
                LabeledContent("Encoding", value: p.format.label)
                LabeledContent("Audio transport mode", value: p.reliable ? "Reliable stream" : "Datagram")
                LabeledContent("Normal target", value: "\(p.budget.target) ms")
                LabeledContent("Maximum total delay", value: "\(p.budget.maximum) ms")
                Button {
                    applied = apply()
                } label: {
                    Text(applied ? LocalizedStringKey("Applied for the next connection") : LocalizedStringKey("Apply parameters"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.automatic).tint(.blue)
                .disabled(applied || !result.canApply)
            } else {
                Text("Insufficient valid observations. Check the connection and test again.")
            }
            DisclosureGroup("Test details") {
                if result.transportComparison == "similar" {
                    Text("Both transports performed similarly within repeat variation; the existing preference was retained.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if result.transportComparison == "insufficient" {
                    Text("Insufficient valid observations to compare both transports.")
                        .font(.footnote).foregroundStyle(.orange)
                }
                if !result.canApply {
                    Text("Validation did not confirm the goal; test again when conditions settle.")
                        .font(.footnote).foregroundStyle(.orange)
                }
                ForEach(Array(result.observations.enumerated()), id: \.offset) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(row.offset + 1) · \(row.element.parameters.format.label)")
                        Text("\(row.element.parameters.reliable ? "Reliable" : "Datagram") · \(row.element.parameters.budget.target)/\(row.element.parameters.budget.maximum) ms")
                        Text("Gaps \(row.element.measurement.gapRatio * 100, specifier: "%.3f")% · longest \(row.element.measurement.longestGapMilliseconds, specifier: "%.1f") ms")
                    }.font(.caption)
                }
            }
        } header: {
            HStack {
                Text("Latest recommendation")
                Spacer()
                Text(result.testedAt, format: .dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute())
                    .accessibilityLabel(Text("Tested"))
                    .accessibilityValue(Text(result.testedAt, style: .date) + Text(" ") + Text(result.testedAt, style: .time))
            }.textCase(nil)
        }
    }
}

private struct CalibrationComputerPicker: View {
    let computers: [ComputerConnectionTarget]
    @Binding var selection: ComputerConnectionTarget?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if !computers.contains(where: { $0.hasNetwork }) {
                Text("No PCs found. Open HearPort on your PC.").foregroundStyle(.secondary)
            }
            ForEach(computers.filter { $0.hasNetwork }) { computer in
                Button {
                    selection = computer
                    dismiss()
                } label: {
                    HStack {
                        Text(computer.title)
                        Spacer()
                        if selection?.id == computer.id { Image(systemName: "checkmark") }
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.automatic).tint(.blue)
            }
        }
        .navigationTitle("Choose a PC").navigationBarTitleDisplayMode(.inline)
    }
}

private struct CalibrationGoalPicker: UIViewRepresentable {
    @Binding var selection: Int
    private let goals = [1, 2, 4]

    func makeUIView(context: Context) -> UISegmentedControl {
        let control = UISegmentedControl(items: ["Low latency", "Balanced", "Stability first"].map {
            NSLocalizedString($0, comment: "")
        })
        control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        control.accessibilityLabel = NSLocalizedString("Test goal", comment: "")
        return control
    }
    func updateUIView(_ control: UISegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        control.selectedSegmentIndex = goals.firstIndex(of: selection) ?? 1
        let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: control.traitCollection)
        control.setTitleTextAttributes([.font: font], for: .normal)
        control.setTitleTextAttributes([.font: font], for: .selected)
    }
    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }
    final class Coordinator: NSObject {
        var selection: Binding<Int>
        init(selection: Binding<Int>) { self.selection = selection }
        @objc func changed(_ control: UISegmentedControl) {
            guard (0..<3).contains(control.selectedSegmentIndex) else { return }
            selection.wrappedValue = [1, 2, 4][control.selectedSegmentIndex]
        }
    }
}
#endif
