import AppKit
import SwiftUI
import UsageBarCore

struct BarIconView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Image(nsImage: renderBarImage())
    }

    private func renderBarImage() -> NSImage {
        let barWidth = CGFloat(model.barWidth)
        let barHeight: CGFloat = 6
        let cornerRadius: CGFloat = 3
        let spacing: CGFloat = 3
        let padding: CGFloat = 1

        let isDual = model.displayMode == .dual
        let totalHeight = isDual ? barHeight * 2 + spacing + padding * 2 : barHeight + padding * 2
        let totalWidth = barWidth + padding * 2

        let image = NSImage(size: NSSize(width: totalWidth, height: totalHeight), flipped: false) { rect in
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
                    y = index == 0 ? padding + barHeight + spacing : padding
                } else {
                    y = padding
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

            return true
        }

        image.isTemplate = false
        return image
    }

    private func barConfig(for providerID: ProviderID) -> (fill: CGFloat, tint: NSColor) {
        let snapshot = model.providerSnapshot(for: providerID)
        let window = snapshot.fiveHourWindow ?? snapshot.sevenDayWindow
        let fill = CGFloat((window?.usedPercent ?? 0) / 100)
        let tint: NSColor
        switch model.colorMode {
        case .color:
            switch providerID {
            case .claude:
                tint = NSColor(red: 0.92, green: 0.43, blue: 0.18, alpha: 1.0)
            case .codex:
                tint = NSColor.labelColor
            }
        case .monochrome:
            tint = NSColor.labelColor
        }
        return (fill, tint)
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
