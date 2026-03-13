import AppKit
import SwiftUI
import UsageBarCore

struct BarIconView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Image(nsImage: renderBarImage())
    }

    private struct LabelSpec {
        let text: String
        let color: NSColor
        let font: NSFont
    }

    private func displayedPercent(for providerID: ProviderID) -> Double? {
        let snapshot = model.providerSnapshot(for: providerID)
        let window = snapshot.fiveHourWindow ?? snapshot.sevenDayWindow
        return window?.usedPercent
    }

    private func labelSpec(for providerID: ProviderID) -> LabelSpec? {
        guard model.showPercentageLabel,
              let percent = displayedPercent(for: providerID) else { return nil }
        let fontSize: CGFloat = model.displayMode == .dual ? 8 : 9
        return LabelSpec(
            text: "\(Int(percent))%",
            color: barTint(for: providerID),
            font: .monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)
        )
    }

    private func renderBarImage() -> NSImage {
        let barWidth = CGFloat(model.barWidth)
        let barHeight: CGFloat = 6
        let cornerRadius: CGFloat = 3
        let spacing: CGFloat = 3
        let padding: CGFloat = 1
        let labelGap: CGFloat = model.showPercentageLabel ? 4 : 0
        let claudeLabel = model.displayMode == .dual ? labelSpec(for: .claude) : nil
        let codexLabel = model.displayMode == .dual ? labelSpec(for: .codex) : nil
        let singleLabel = model.displayMode == .single ? labelSpec(for: model.singleBarProvider) : nil
        let maxLabelWidth = [claudeLabel, codexLabel, singleLabel]
            .compactMap { labelWidth(for: $0) }
            .max() ?? 0
        let maxLabelHeight = [claudeLabel, codexLabel, singleLabel]
            .compactMap { labelHeight(for: $0) }
            .max() ?? 0
        let rowHeight = max(barHeight, maxLabelHeight)

        let isDual = model.displayMode == .dual
        let totalHeight = isDual ? rowHeight * 2 + spacing + padding * 2 : rowHeight + padding * 2
        let totalWidth = barWidth + padding * 2 + (maxLabelWidth > 0 ? labelGap + maxLabelWidth : 0)

        let image = NSImage(size: NSSize(width: totalWidth, height: totalHeight), flipped: false) { _ in
            NSGraphicsContext.current?.cgContext.setShouldAntialias(true)

            let bars: [(fill: CGFloat, tint: NSColor)]
            switch model.displayMode {
            case .single:
                let config = barConfig(for: model.singleBarProvider)
                bars = [(config.fill, config.tint)]
            case .dual:
                let claudeConfig = barConfig(for: .claude)
                let codexConfig = barConfig(for: .codex)
                bars = [(claudeConfig.fill, claudeConfig.tint), (codexConfig.fill, codexConfig.tint)]
            }

            for (index, bar) in bars.enumerated() {
                let y: CGFloat
                if isDual {
                    // First bar at top, second at bottom (flipped coords: bottom = lower y)
                    y = index == 0
                        ? padding + rowHeight + spacing + (rowHeight - barHeight) / 2
                        : padding + (rowHeight - barHeight) / 2
                } else {
                    y = padding + (rowHeight - barHeight) / 2
                }

                let trackRect = NSRect(x: padding, y: y, width: barWidth, height: barHeight)
                let trackPath = NSBezierPath(roundedRect: trackRect, xRadius: cornerRadius, yRadius: cornerRadius)

                // Track background - use label colors that adapt to menu bar appearance
                NSColor.labelColor.withAlphaComponent(0.2).setFill()
                trackPath.fill()

                // Track border
                NSColor.labelColor.withAlphaComponent(0.4).setStroke()
                trackPath.lineWidth = 0.5
                trackPath.stroke()

                // Fill
                if bar.fill > 0 {
                    let fillWidth = max(barWidth * bar.fill, cornerRadius * 2)
                    let fillRect = NSRect(x: padding, y: y, width: fillWidth, height: barHeight)
                    let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: cornerRadius, yRadius: cornerRadius)
                    bar.tint.setFill()
                    fillPath.fill()
                }
            }

            let labelX = padding + barWidth + labelGap
            switch model.displayMode {
            case .single:
                if let singleLabel {
                    drawLabel(singleLabel, x: labelX, midY: padding + rowHeight / 2)
                }
            case .dual:
                if let claudeLabel {
                    drawLabel(claudeLabel, x: labelX, midY: padding + rowHeight + spacing + rowHeight / 2)
                }
                if let codexLabel {
                    drawLabel(codexLabel, x: labelX, midY: padding + rowHeight / 2)
                }
            }

            return true
        }

        image.isTemplate = false
        return image
    }

    private func labelWidth(for spec: LabelSpec?) -> CGFloat? {
        guard let spec else { return nil }
        return attributedLabel(spec).size().width
    }

    private func labelHeight(for spec: LabelSpec?) -> CGFloat? {
        guard let spec else { return nil }
        return attributedLabel(spec).size().height
    }

    private func drawLabel(_ spec: LabelSpec, x: CGFloat, midY: CGFloat) {
        let attr = attributedLabel(spec)
        let size = attr.size()
        let origin = CGPoint(x: x, y: midY - size.height / 2)
        attr.draw(at: origin)
    }

    private func attributedLabel(_ spec: LabelSpec) -> NSAttributedString {
        NSAttributedString(string: spec.text, attributes: [
            .font: spec.font,
            .foregroundColor: spec.color,
        ])
    }

    private func barConfig(for providerID: ProviderID) -> (fill: CGFloat, tint: NSColor) {
        let fill = CGFloat((displayedPercent(for: providerID) ?? 0) / 100)
        return (fill, barTint(for: providerID))
    }

    private func barTint(for providerID: ProviderID) -> NSColor {
        switch model.colorMode {
        case .color:
            switch providerID {
            case .claude:
                return NSColor(red: 0.92, green: 0.43, blue: 0.18, alpha: 1.0)
            case .codex:
                return NSColor.labelColor
            }
        case .monochrome:
            return NSColor.labelColor
        }
    }
}

enum BarPalette {
    static func tint(for providerID: ProviderID, mode: ColorMode) -> Color {
        switch mode {
        case .color:
            switch providerID {
            case .claude:
                Color(red: 0.92, green: 0.43, blue: 0.18)
            case .codex:
                .primary
            }
        case .monochrome:
            .primary
        }
    }
}
