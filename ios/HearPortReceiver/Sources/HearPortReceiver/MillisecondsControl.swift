#if canImport(SwiftUI) && os(iOS)
import SwiftUI

struct MillisecondsControl: View {
    let title: LocalizedStringKey
    @Binding var value: Int
    let range: ClosedRange<Int>
    @State private var text = ""
    @FocusState private var editing: Bool

    init(_ title: LocalizedStringKey, value: Binding<Int>, range: ClosedRange<Int>) {
        self.title = title; _value = value; self.range = range
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            HStack(spacing: 0) {
                adjustment("minus", delta: -5)
                TextField("ms", text: Binding(get: { text }, set: { input in
                    text = input
                    if let number = Int(input) {
                        value = min(range.upperBound, max(range.lowerBound, number))
                    }
                }))
                    .keyboardType(.numberPad).focused($editing)
                    .multilineTextAlignment(.center).monospacedDigit()
                    .frame(width: 66, height: 36)
                    .accessibilityLabel(Text(title))
                    .onSubmit { commit(); editing = false }
                adjustment("plus", delta: 5)
            }
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
            Text("ms").foregroundStyle(.secondary).font(.caption)
        }
        .onAppear { text = String(value) }
        .onChange(of: value) { if !editing { text = String($0) } }
        .onChange(of: editing) { if !$0 { commit() } }
        .onDisappear { commit() }
    }

    private func commit() {
        value = min(range.upperBound, max(range.lowerBound, Int(text) ?? value))
        text = String(value)
    }

    private func adjustment(_ symbol: String, delta: Int) -> some View {
        Button {
            commit(); value = min(range.upperBound, max(range.lowerBound, value + delta))
            text = String(value); editing = false
        } label: {
            Image(systemName: symbol).frame(width: 36, height: 36)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text(symbol == "plus" ? "Increase delay" : "Decrease delay"))
    }
}
#endif
