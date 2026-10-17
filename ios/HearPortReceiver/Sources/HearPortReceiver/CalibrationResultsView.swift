#if canImport(SwiftUI) && canImport(Charts) && os(iOS)
import SwiftUI
import Charts

struct CalibrationResultsView: View {
    let result: CalibrationResult?
    let apply: (Int) -> Void
    var canStart = false
    var starting = false
    var startStatus: String?
    var start: ((Int, Int) -> Void)?
    @State private var applied: Int?
    @State private var seconds = 30
    @State private var maximum = 300

    var body: some View {
        List {
            Section {
                Picker("Duration per round", selection: $seconds) {
                    Text("30 seconds").tag(30)
                    Text("60 seconds").tag(60)
                    Text("120 seconds").tag(120)
                }
                Stepper("Calibration ceiling: \(maximum) ms", value: $maximum, in: 40...2000, step: 10)
                Button { start?(seconds, maximum) } label: {
                    Text(starting ? LocalizedStringKey("Starting calibration…") : LocalizedStringKey("Start environment calibration"))
                }
                    .disabled(!canStart || starting)
                if let startStatus { Text(startStatus).font(.footnote).foregroundStyle(.secondary) }
            } header: { Text("New calibration") } footer: {
                Text("Calibration temporarily stops playback and tests this PC's local network connection. Connect a remembered PC with a network route to start.")
            }
            if let result {
                Section("Test conditions") {
                    Text(result.testedAt, style: .date) + Text(" ") + Text(result.testedAt, style: .time)
                    Text("\(result.seconds) s / round · ceiling \(result.maximum) ms")
                    Text(result.context.device + " · " + result.context.operatingSystem)
                    Text(result.context.output + " · \(Int(result.context.sampleRate)) Hz")
                    Text(result.usable ? LocalizedStringKey("Complete observation") : LocalizedStringKey("Incomplete observation; parameters cannot be applied."))
                }
                ForEach([1,2,4], id: \.self) { profile in
                    Section(Self.profileName(profile)) {
                        let recommendation = result.analysis?.recommendations.first { $0.profile == profile }
                        Text(Self.statusName(result.validationStatus(profile: profile)))
                        if let choice = recommendation?.choice {
                            Text(choice.reliable ? "Reliable stream" : "Datagram")
                            Text("Target \(choice.budget.target) ms · maximum \(choice.budget.maximum) ms · output reserve \(choice.outputReserve) ms")
                            if let m = recommendation?.measurement {
                                Text("Sampling replay").font(.headline)
                                measurement(m)
                            }
                            ForEach(Array(result.validation.filter { $0.reliable == choice.reliable && $0.budget == choice.budget }.enumerated()), id: \.offset) { item in
                                Text("Live validation \(item.offset + 1)").font(.headline)
                                measurement(item.element)
                            }
                            Button(applied == profile ? LocalizedStringKey("Applied for the next connection") : LocalizedStringKey("Apply for the next connection")) {
                                apply(profile); applied = profile
                            }.disabled(!result.usable)
                        } else {
                            Text("No candidate met this profile's sampling target.")
                        }
                    }
                }
                if let analysis = result.analysis {
                    Section("Sampling replay: age and gaps") {
                        Chart(Array(analysis.candidates.filter(\.valid).enumerated()), id: \.offset) { item in
                            PointMark(x: .value("Source age P95 (ms)", item.element.ageP95Milliseconds ?? 0),
                                      y: .value("Gap (%)", item.element.gapRatio * 100))
                                .foregroundStyle(by: .value("Transport", item.element.reliable ? "Reliable" : "Datagram"))
                        }.frame(height: 230)
                        Text("Each point replays the same recorded input within its transport. The sender used the sampling ceiling; changing its deadline may change delivery. Live validation uses new traffic.")
                        DisclosureGroup("Candidate details") {
                            ForEach(Array(analysis.candidates.enumerated()), id: \.offset) { item in
                                let m = item.element
                                Text("\(m.reliable ? "Reliable" : "Datagram") · \(m.budget.target)/\(m.budget.maximum) ms").font(.headline)
                                measurement(m)
                            }
                        }
                    }
                    Section("Fixed deadline coverage") {
                        Chart(coverage(analysis), id: \.id) { point in
                            LineMark(x: .value("Maximum budget (ms)", point.maximum), y: .value("Unavailable (%)", point.ratio * 100))
                                .foregroundStyle(by: .value("Transport", point.reliable ? "Reliable" : "Datagram"))
                        }.frame(height: 230)
                        Text("Coverage uses a fixed deadline and does not simulate buffering. Missing source and output interruption are separate axes; they are never added together.")
                    }
                    DisclosureGroup("Paired block uncertainty") {
                        Text("Fixed-seed resampling of five-second paired blocks; an interval overlapping zero does not establish equivalence or a rare-failure rate.")
                        ForEach(Array(analysis.pairedRanges.enumerated()), id: \.offset) { item in
                            let p = item.element
                            Text("\(p.reliable ? "Reliable" : "Datagram") · \(p.budget.target)/\(p.budget.maximum) vs \(p.referenceBudget.target)/\(p.referenceBudget.maximum) ms · \(p.lowerDifference * 100, specifier: "%.3f")…\(p.upperDifference * 100, specifier: "%.3f") pp")
                        }
                    }
                }
                Section("Selection rules") {
                    Text("Low latency: gaps ≤0.5%, longest ≤40 ms; Balanced: gaps ≤0.1%, longest ≤20 ms. Both choose the lowest qualifying source age P95. Stability first minimizes gap ratio, then longest gap, then source age within the selected ceiling.")
                }
                Section("Limits") {
                    Text("Zero gaps means none were observed in this test. It is not a guarantee for future network conditions.")
                    Text("Source age includes estimated output reserve. Audio DSP, render output and acoustic latency were not measured.")
                    Text("If either live repeat misses the profile target, its status is downgraded. Worse live gaps remain provisional; network changes can explain the difference.")
                }
            }
        }
        .navigationTitle("Environment calibration")
        .navigationBarTitleDisplayMode(.inline)
    }
    @ViewBuilder private func measurement(_ m: CalibrationMeasurement) -> some View {
        if let age = m.ageP95Milliseconds { Text("Source age P95: \(age, specifier: "%.1f") ms") }
        if m.gapRatio == 0 { Text("No gaps observed in this sample") }
        else { Text("Gap: \(m.gapRatio * 100, specifier: "%.3f")% · longest \(m.longestGapMilliseconds, specifier: "%.1f") ms") }
        Text("Source unavailable: \(Double(m.missingSourceFrames) / 48, specifier: "%.1f") ms · output interruption: \(m.missingOutputSeconds * 1000, specifier: "%.1f") ms")
        Text("Startup: \(m.startupMilliseconds, specifier: "%.1f") ms · maximum rate correction: \(m.maximumCorrection * 100, specifier: "%.2f")%")
        if !m.valid { Text("Insufficient valid data") }
    }
    static func profileName(_ profile: Int) -> LocalizedStringKey {
        profile == 1 ? "Low latency" : profile == 2 ? "Balanced" : "Stability first"
    }
    static func statusName(_ status: String) -> LocalizedStringKey {
        switch status {
        case "observed": return "Observed in both live repeats"
        case "provisional": return "Provisional: live gaps worsened"
        case "not_met": return "Live validation missed the target"
        case "incomplete": return "Incomplete observation"
        default: return "No qualifying recommendation"
        }
    }
    private struct Coverage {
        var id: String { "\(reliable)-\(maximum)" }
        let reliable: Bool
        let maximum: Int
        let ratio: Double
    }
    private func coverage(_ analysis: CalibrationAnalysis) -> [Coverage] {
        [false,true].flatMap { reliable in
            Array(Set(analysis.coverage.filter { $0.reliable == reliable }.map(\.maximumMilliseconds))).sorted().map { maximum in
                let samples = analysis.coverage.filter { $0.reliable == reliable && $0.maximumMilliseconds == maximum }
                let total = samples.reduce(UInt64(0)) { $0 + $1.observableFrames }
                return Coverage(reliable: reliable, maximum: maximum, ratio: total > 0 ?
                    Double(samples.reduce(UInt64(0)) { $0 + $1.unavailableSourceFrames }) / Double(total) : 1)
            }
        }
    }
}
#endif
