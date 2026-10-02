import SwiftUI

struct CompassSymbol: View {
    let icon: CompassIcon
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            switch icon {
            case .arrow:
                Needle().fill(color)
            case .outline:
                Needle().stroke(color, style: StrokeStyle(lineWidth: max(1.5, geometry.size.width / 20), lineJoin: .round))
                    .padding(2)
            case .chevron:
                Path { path in
                    path.move(to: CGPoint(x: 0, y: geometry.size.height * 0.66))
                    path.addLine(to: CGPoint(x: geometry.size.width / 2, y: geometry.size.height * 0.2))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height * 0.66))
                }.stroke(color, style: StrokeStyle(lineWidth: max(2, geometry.size.width * 0.15), lineCap: .round, lineJoin: .round))
                    .padding(3)
            case .slim:
                Path { path in
                    let w = geometry.size.width, h = geometry.size.height
                    path.move(to: CGPoint(x: w * 0.5, y: 0))
                    path.addLine(to: CGPoint(x: w, y: h * 0.35))
                    path.addLine(to: CGPoint(x: w * 0.62, y: h * 0.35))
                    path.addLine(to: CGPoint(x: w * 0.62, y: h))
                    path.addLine(to: CGPoint(x: w * 0.38, y: h))
                    path.addLine(to: CGPoint(x: w * 0.38, y: h * 0.35))
                    path.addLine(to: CGPoint(x: 0, y: h * 0.35))
                    path.closeSubpath()
                }.fill(color)
            case .triangle:
                Path { path in
                    let w = geometry.size.width, h = geometry.size.height
                    path.move(to: CGPoint(x: w / 2, y: h * 0.12))
                    path.addLine(to: CGPoint(x: w, y: h * 0.82))
                    path.addLine(to: CGPoint(x: 0, y: h * 0.82))
                    path.closeSubpath()
                }.fill(color)
            case .kite:
                Path { path in
                    let w = geometry.size.width, h = geometry.size.height
                    path.move(to: CGPoint(x: w / 2, y: 0))
                    path.addLine(to: CGPoint(x: w, y: h * 0.7))
                    path.addLine(to: CGPoint(x: w / 2, y: h))
                    path.addLine(to: CGPoint(x: 0, y: h * 0.7))
                    path.closeSubpath()
                }.fill(color)
                Path { path in
                    let w = geometry.size.width, h = geometry.size.height
                    path.move(to: CGPoint(x: w / 2, y: 0))
                    path.addLine(to: CGPoint(x: w / 2, y: h))
                    path.addLine(to: CGPoint(x: 0, y: h * 0.7))
                    path.closeSubpath()
                }.fill(.white.opacity(0.25))
            case .doubleChevron:
                Path { path in
                    let w = geometry.size.width, h = geometry.size.height
                    for offset in [0.12, 0.48] {
                        path.move(to: CGPoint(x: w * 0.08, y: h * (offset + 0.3)))
                        path.addLine(to: CGPoint(x: w / 2, y: h * offset))
                        path.addLine(to: CGPoint(x: w * 0.92, y: h * (offset + 0.3)))
                    }
                }.stroke(color, style: StrokeStyle(lineWidth: max(2, geometry.size.width * 0.13), lineCap: .round, lineJoin: .round))
            case .needle:
                Path { path in
                    path.move(to: CGPoint(x: geometry.size.width / 2, y: 0))
                    path.addLine(to: CGPoint(x: geometry.size.width * 0.85, y: geometry.size.height / 2))
                    path.addLine(to: CGPoint(x: geometry.size.width * 0.15, y: geometry.size.height / 2))
                    path.closeSubpath()
                }.fill(color)
                Path { path in
                    path.move(to: CGPoint(x: geometry.size.width / 2, y: geometry.size.height))
                    path.addLine(to: CGPoint(x: geometry.size.width * 0.85, y: geometry.size.height / 2))
                    path.addLine(to: CGPoint(x: geometry.size.width * 0.15, y: geometry.size.height / 2))
                    path.closeSubpath()
                }.fill(color.opacity(0.25))
            }
        }
    }
}

private struct Needle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.18))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.closeSubpath()
        }
    }
}

struct CompassBorderView: View {
    let style: CompassBorder

    var body: some View {
        GeometryReader { geometry in
            let diameter = min(geometry.size.width, geometry.size.height)
            let weight = max(1, diameter / 180)
            ZStack {
                switch style {
                case .classic:
                    Circle().stroke(Palette.ink.opacity(0.13), lineWidth: weight)
                    ForEach(0..<60) { tick in
                        Rectangle().fill(Palette.ink.opacity(tick % 5 == 0 ? 0.4 : 0.15))
                            .frame(width: weight, height: diameter * (tick % 5 == 0 ? 0.05 : 0.022))
                            .offset(y: -diameter * 0.456).rotationEffect(.degrees(Double(tick) * 6))
                    }
                case .ring:
                    Circle().stroke(Palette.ink.opacity(0.3), lineWidth: weight)
                case .doubleRing:
                    Circle().stroke(Palette.ink.opacity(0.35), lineWidth: weight * 2)
                    Circle().stroke(Palette.ink.opacity(0.18), lineWidth: weight).padding(diameter * 0.035)
                case .dashed:
                    Circle().stroke(Palette.ink.opacity(0.35), style: StrokeStyle(lineWidth: weight, dash: [diameter * 0.045, diameter * 0.035]))
                case .dots:
                    ForEach(0..<36) { tick in
                        Circle().fill(Palette.ink.opacity(0.35)).frame(width: weight * 2, height: weight * 2)
                            .offset(y: -diameter * 0.49).rotationEffect(.degrees(Double(tick) * 10))
                    }
                case .quarters:
                    ForEach(0..<4) { tick in
                        Capsule().fill(Palette.ink.opacity(0.4)).frame(width: weight * 2, height: diameter * 0.09)
                            .offset(y: -diameter * 0.45).rotationEffect(.degrees(Double(tick) * 90))
                    }
                case .none:
                    Color.clear
                }
            }.frame(width: diameter, height: diameter)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }.accessibilityHidden(true)
    }
}
