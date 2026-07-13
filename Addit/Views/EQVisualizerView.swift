import SwiftUI

struct EQVisualizerView: View {
    @Environment(AudioAnalyzerService.self) private var analyzer
    @Environment(ThemeService.self) private var themeService

    private let yLabelWidth: CGFloat = 32
    private let xLabelHeight: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let plotWidth = geo.size.width - yLabelWidth * 2
            let plotHeight = geo.size.height - xLabelHeight

            ZStack(alignment: .topLeading) {
                // Y-axis labels
                VStack {
                    Text("0")
                        .offset(y: -4)
                    Spacer()
                    Text("-60")
                        .offset(y: 4)
                }
                .font(.readout(8))
                .foregroundStyle(.secondary.opacity(0.7))
                .frame(width: yLabelWidth - 4, height: plotHeight)

                // Plot area
                ZStack(alignment: .bottomLeading) {
                    // Axis lines
                    Path { path in
                        let origin = CGPoint(x: 0, y: plotHeight)
                        // Y axis
                        path.move(to: CGPoint(x: 0, y: 0))
                        path.addLine(to: origin)
                        // X axis
                        path.addLine(to: CGPoint(x: plotWidth, y: plotHeight))
                    }
                    .stroke(.secondary.opacity(0.3), lineWidth: 0.5)

                    // Bars
                    barsView(width: plotWidth, height: plotHeight)
                }
                .frame(width: plotWidth, height: plotHeight)
                .offset(x: yLabelWidth)

                // X-axis labels
                HStack {
                    Text("20")
                    Spacer()
                    Text("20k")
                }
                .font(.readout(8))
                .foregroundStyle(.secondary.opacity(0.7))
                .frame(width: plotWidth)
                .offset(x: yLabelWidth, y: plotHeight + 2)
            }
        }
    }

    private func barsView(width: CGFloat, height: CGFloat) -> some View {
        let barCount = analyzer.bands.count
        let spacing: CGFloat = 4
        let totalSpacing = spacing * CGFloat(barCount - 1)
        let barWidth = (width - totalSpacing) / CGFloat(barCount)

        return HStack(alignment: .bottom, spacing: spacing) {
            ForEach(0..<barCount, id: \.self) { index in
                let barHeight = max(4, CGFloat(analyzer.bands[index]) * height)
                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(
                        LinearGradient(
                            colors: [
                                themeService.accentColor,
                                themeService.accentColor.opacity(0.5)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: barWidth, height: barHeight)
                    .animation(.easeOut(duration: 0.08), value: analyzer.bands[index])
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}
