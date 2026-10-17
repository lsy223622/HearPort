#if canImport(SwiftUI) && os(iOS)
import SwiftUI

struct ConnectionStatusSymbol: View {
    let connected: Bool
    let path: ConnectionPath
    let quality: AudioLinkQuality
    let recovering: Bool
    let connecting: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var assessing: Bool { connecting || recovering || (connected && quality == .unknown) }

    var body: some View {
        GeometryReader { geometry in
            let lineWidth = geometry.size.width * 48 / 1254
            ZStack {
                DeviceOutline().stroke(Color.primary, style: StrokeStyle(lineWidth: lineWidth,
                    lineCap: .round, lineJoin: .round))
                TimelineView(.animation(minimumInterval: 1.0 / 30,
                    paused: !assessing || reduceMotion || scenePhase != .active)) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: 2.4) / 2.4
                    let breath = assessing && !reduceMotion
                        ? 0.2 + 0.8 * (1 - cos(phase * 2 * .pi)) / 2 : 1
                    ZStack {
                        ForEach(0..<3) { index in
                            ConnectionMark(index: index, wired: path == .usb ? 1 : 0)
                                .stroke(quality.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                                .opacity(connected || connecting ? markOpacity(index) : 0)
                        }
                    }
                    .opacity(breath)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: path)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: connected)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: quality)
        .accessibilityHidden(true)
    }

    private func markOpacity(_ index: Int) -> Double {
        if path == .usb { return index == 0 ? (recovering ? 0.35 : 1) : 0 }
        guard !assessing else { return 0.65 }
        let count = quality == .stable ? 3 : quality == .variable ? 2 : 1
        return index < count ? 1 : 0.18
    }
}

private struct DeviceOutline: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 369, y: 570))
        path.addLine(to: CGPoint(x: 369, y: 405))
        path.addQuadCurve(to: CGPoint(x: 441, y: 333), control: CGPoint(x: 369, y: 333))
        path.addLine(to: CGPoint(x: 927, y: 333))
        path.addQuadCurve(to: CGPoint(x: 999, y: 405), control: CGPoint(x: 999, y: 333))
        path.addLine(to: CGPoint(x: 999, y: 565))
        path.move(to: CGPoint(x: 999, y: 914))
        path.addQuadCurve(to: CGPoint(x: 929, y: 984), control: CGPoint(x: 999, y: 984))
        path.addLine(to: CGPoint(x: 819, y: 984))
        path.addRoundedRect(in: CGRect(x: 253, y: 646, width: 498, height: 340), cornerSize: CGSize(width: 65, height: 65))
        return path.applying(CGAffineTransform(scaleX: rect.width / 1254, y: rect.height / 1254))
    }
}

private struct ConnectionMark: Shape {
    let index: Int
    var wired: CGFloat
    var animatableData: CGFloat {
        get { wired }
        set { wired = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let arcs: [[CGPoint]] = [
            [.init(x: 823, y: 703), .init(x: 839, y: 730), .init(x: 839, y: 764), .init(x: 823, y: 791)],
            [.init(x: 885, y: 666), .init(x: 915, y: 716), .init(x: 915, y: 778), .init(x: 885, y: 828)],
            [.init(x: 950, y: 627), .init(x: 995, y: 701), .init(x: 995, y: 793), .init(x: 950, y: 867)]
        ]
        let cable: [CGPoint] = [.init(x: 751, y: 816), .init(x: 1020, y: 816),
                                .init(x: 1100, y: 650), .init(x: 999, y: 565)]
        let scaleX: CGFloat = rect.width / 1254
        let scaleY: CGFloat = rect.height / 1254
        var points: [CGPoint] = []
        for (start, end) in zip(arcs[index], cable) {
            let x: CGFloat = start.x + (end.x - start.x) * wired
            let y: CGFloat = start.y + (end.y - start.y) * wired
            points.append(CGPoint(x: x * scaleX, y: y * scaleY))
        }
        var path = Path()
        path.move(to: points[0])
        path.addCurve(to: points[3], control1: points[1], control2: points[2])
        return path
    }
}

extension AudioLinkQuality {
    var title: LocalizedStringKey {
        switch self {
        case .unknown: return "Assessing link"
        case .stable: return "Stable"
        case .variable: return "Fluctuating"
        case .poor: return "Unstable"
        }
    }
    var color: Color {
        switch self {
        case .unknown: return .secondary
        case .stable: return .teal
        case .variable: return .orange
        case .poor: return .red
        }
    }
}
#endif
