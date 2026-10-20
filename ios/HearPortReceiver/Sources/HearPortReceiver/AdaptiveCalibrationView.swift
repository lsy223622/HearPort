#if canImport(SwiftUI) && os(iOS)
import SwiftUI

struct AdaptiveCalibrationView: View {
    let result: AdaptiveCalibrationResult?
    let canStart: Bool
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
            Section {
                Picker("Profile", selection: $goal) {
                    Text("Low latency").tag(1)
                    Text("Balanced").tag(2)
                    Text("Stability first").tag(4)
                }.pickerStyle(.segmented)
                Text("Search adjusts transport, encoding, bitrate, packet duration and delay budget for the selected goal.")
                    .font(.footnote).foregroundStyle(.secondary)
                Stepper("Maximum delay: \(maximum) ms", value: $maximum, in: 40...2000, step: 10)
                Picker("Observation window", selection: $seconds) {
                    Text("15 seconds").tag(15)
                    Text("30 seconds").tag(30)
                    Text("60 seconds").tag(60)
                }
                Text("Settings are repeated before selection. Final verification uses two windows of twice the selected duration. Remaining steps depend on observations.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button(starting ? LocalizedStringKey("Starting calibration…") : LocalizedStringKey("Start automatic test")) {
                    applied = false; start(goal, seconds, maximum)
                }.disabled(!canStart || starting)
                if let status { Text(status).font(.footnote).foregroundStyle(.secondary) }
            } header: {
                Text("Test goal")
            } footer: {
                Text("Playback pauses while random traffic tests the network route. Results stay on this iPad. USB audio settings are independent.")
            }
            if let result {
                Section {
                    Text(CalibrationResultsView.profileName(result.goal)).font(.headline)
                    Text(result.testedAt, style: .date) + Text(" ") + Text(result.testedAt, style: .time)
                    if let p = result.selected {
                        Text(p.format.label)
                        LabeledContent("Audio transport mode", value: p.reliable ? "Reliable stream" : "Datagram")
                        LabeledContent("Normal target", value: "\(p.budget.target) ms")
                        LabeledContent("Maximum total delay", value: "\(p.budget.maximum) ms")
                        let validation = result.validation
                        if let gap = validation.map(\.gapRatio).max(), let longest = validation.map(\.longestGapMilliseconds).max() {
                            Text("Verification: gaps \(gap * 100, specifier: "%.3f")% · longest \(longest, specifier: "%.1f") ms")
                                .font(.footnote)
                        }
                        Text(result.canApply ? LocalizedStringKey("Validated in both live repeats") : LocalizedStringKey("Validation did not confirm the goal; test again when conditions settle."))
                            .font(.footnote).foregroundStyle(.secondary)
                        Button(applied ? LocalizedStringKey("Applied for the next connection") : LocalizedStringKey("Apply parameters")) {
                            applied = apply()
                        }.disabled(applied || !result.canApply)
                    } else {
                        Text("Insufficient valid observations. Check the connection and test again.")
                    }
                    DisclosureGroup("Test observations") {
                        ForEach(Array(result.observations.enumerated()), id: \.offset) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(row.offset + 1) · \(row.element.parameters.format.label)")
                                Text("\(row.element.parameters.reliable ? "Reliable" : "Datagram") · \(row.element.parameters.budget.target)/\(row.element.parameters.budget.maximum) ms")
                                Text("Gaps \(row.element.measurement.gapRatio * 100, specifier: "%.3f")% · longest \(row.element.measurement.longestGapMilliseconds, specifier: "%.1f") ms")
                            }.font(.caption)
                        }
                    }
                } header: {
                    Text("Latest recommendation")
                } footer: {
                    Text("This is an observation of current network conditions, not a stability guarantee. Random payloads reserve codec preparation time but do not measure audio quality or decoder speed.")
                }
            }
        }
        .navigationTitle("Automatic test and recommendations")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
