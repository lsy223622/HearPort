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
            if let result { recommendation(result) }
            Section {
                Picker("Profile", selection: $goal) {
                    Text("Low latency").tag(1)
                    Text("Balanced").tag(2)
                    Text("Stability first").tag(4)
                }.pickerStyle(.segmented)
                MillisecondsControl("Maximum total delay", value: $maximum, range: 40...2000)
                Button {
                    applied = false; start(goal, seconds, maximum)
                } label: {
                    HStack {
                        if starting { ProgressView().tint(.white) }
                        Text(starting ? LocalizedStringKey("Starting calibration…") : LocalizedStringKey("Start automatic test"))
                    }.frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.borderedProminent).tint(.teal)
                .disabled(!canStart || starting)
                if let status { Text(status).font(.footnote).foregroundStyle(.secondary) }
                DisclosureGroup("Test details") {
                    Picker("Observation window", selection: $seconds) {
                        Text("15 seconds").tag(15)
                        Text("30 seconds").tag(30)
                        Text("60 seconds").tag(60)
                    }
                    Text("Each setting compares both transports twice. Final verification repeats the selected settings with longer windows.")
                    Text("Search adjusts transport, encoding, bitrate, packet duration and delay budget for the selected goal.")
                    Text("Detailed logging records each measurement and selection for manual export.")
                }.font(.footnote).foregroundStyle(.secondary)
            } header: {
                Text("Test goal")
            } footer: {
                Text("Playback pauses while random traffic tests the network route. Results stay on this iPad. USB audio settings are independent.")
            }
        }
        .navigationTitle("Automatic test and recommendations")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func recommendation(_ result: AdaptiveCalibrationResult) -> some View {
        Section {
            Text(CalibrationResultsView.profileName(result.goal)).font(.headline)
            if let p = result.selected {
                Text(p.format.label)
                LabeledContent("Audio transport mode", value: p.reliable ? "Reliable stream" : "Datagram")
                LabeledContent("Normal target", value: "\(p.budget.target) ms")
                LabeledContent("Maximum total delay", value: "\(p.budget.maximum) ms")
                if result.transportComparison == "similar" {
                    Text("Both transports performed similarly within repeat variation; the existing preference was retained.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if result.transportComparison == "insufficient" {
                    Text("Insufficient valid observations to compare both transports.")
                        .font(.footnote).foregroundStyle(.orange)
                } else if result.transportComparison == nil {
                    Text("Run a new test to compare both transports at every setting.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Text(result.canApply ? LocalizedStringKey("Validated in both live repeats") : LocalizedStringKey("Validation did not confirm the goal; test again when conditions settle."))
                    .font(.footnote).foregroundStyle(result.canApply ? Color.secondary : Color.orange)
                Button {
                    applied = apply()
                } label: {
                    Text(applied ? LocalizedStringKey("Applied for the next connection") : LocalizedStringKey("Apply parameters"))
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.borderedProminent).tint(.teal)
                .disabled(applied || !result.canApply)
            } else {
                Text("Insufficient valid observations. Check the connection and test again.")
            }
            DisclosureGroup("Test observations") {
                Text(result.testedAt, style: .date) + Text(" ") + Text(result.testedAt, style: .time)
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
#endif
