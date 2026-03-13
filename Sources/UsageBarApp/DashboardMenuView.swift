import SwiftUI
import UsageBarCore

struct DashboardMenuView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            ProviderCardView(
                title: "Claude",
                snapshot: model.snapshot.claude,
                tint: BarPalette.tint(for: .claude, mode: model.colorMode),
                history: model.usageHistory,
                sparklinesEnabled: model.sparklinesEnabled
            )

            ProviderCardView(
                title: "Codex",
                snapshot: model.snapshot.codex,
                tint: BarPalette.tint(for: .codex, mode: model.colorMode),
                history: model.usageHistory,
                sparklinesEnabled: model.sparklinesEnabled
            )

            Divider()

            HStack {
                MenuItemButton("Quit") {
                    DispatchQueue.main.async {
                        NSApplication.shared.terminate(nil)
                    }
                }

                Spacer()

                Text("v0.3")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Spacer()

                MenuItemButton("Settings") {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
        .padding(12)
        .frame(width: 280)
        .onAppear {
            model.refresh()
        }
    }

    private var header: some View {
        HStack {
            Text("UsageBar")
                .font(.headline)

            Spacer()

            if model.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }
        }
    }

}

private struct ProviderCardView: View {
    let title: String
    let snapshot: ProviderSnapshot
    let tint: Color
    var history: UsageHistory? = nil
    var sparklinesEnabled: Bool = true

    private var errorKind: ErrorKind { snapshot.errorKind }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            if errorKind != .none {
                errorBanner
            }

            if snapshot.fiveHourWindow != nil || snapshot.sevenDayWindow != nil {
                quotaRow(for: .fiveHour)
                quotaRow(for: .sevenDay)
            }

            ForEach(snapshot.metrics) { metric in
                metricRow(label: metric.label, value: metric.value)
            }

            if errorKind == .none, !snapshot.notes.isEmpty {
                ForEach(snapshot.notes, id: \.self) { note in
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            HStack {
                Text(snapshot.sourceLabel)
                Spacer()
                if let updated = snapshot.lastUpdatedAt {
                    Text(UsageBarFormatting.shortDateTimeText(for: updated))
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
        }
    }

    @ViewBuilder
    private func quotaRow(for kind: QuotaWindowKind) -> some View {
        let window = snapshot.window(for: kind)

        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(kind.displayName)
                    .font(.caption.weight(.medium))
                Spacer()
                if let window {
                    Text("\(Int(window.usedPercent))% used")
                        .font(.caption.monospacedDigit())
                } else {
                    Text("—")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))

                    if let window {
                        Capsule()
                            .fill(tint)
                            .frame(width: geometry.size.width * CGFloat(window.usedPercent / 100))
                    }
                }
            }
            .frame(height: 6)

            if sparklinesEnabled, let history, window != nil {
                let values = history.values(provider: snapshot.providerID, window: kind)
                if values.count >= 2 {
                    SparklineView(values: values, tint: tint)
                        .frame(height: 20)
                }
            }

            if let window {
                if window.usedPercent >= 100, let resetAt = window.resetAt,
                   let countdown = UsageBarFormatting.countdownText(until: resetAt) {
                    HStack(spacing: 4) {
                        Image(systemName: "hourglass")
                            .foregroundStyle(.orange)
                        Text("Resets in \(countdown)")
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 4) {
                        if let resetAt = window.resetAt {
                            let resetText = kind == .fiveHour
                                ? UsageBarFormatting.shortResetText(for: resetAt)
                                : UsageBarFormatting.longResetText(for: resetAt)
                            Text("Resets \(resetText)")
                        }
                        if let history,
                           let rate = history.burnRate(provider: snapshot.providerID, window: kind, currentPercent: window.usedPercent),
                           showBurnRate(rate: rate, resetAt: window.resetAt) {
                            if window.resetAt != nil {
                                Text("·")
                            }
                            Text(rate.projectionText)
                                .foregroundStyle(.orange.opacity(0.8))
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func metricRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    @ViewBuilder
    private var errorBanner: some View {
        let iconColor: Color = {
            switch errorKind {
            case .needsLogin: .blue
            case .cookieExpired: .orange
            case .rateLimited: .yellow
            case .apiError: .red
            case .none: .secondary
            }
        }()

        HStack(alignment: .top, spacing: 6) {
            Image(systemName: errorKind.icon)
                .foregroundStyle(iconColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(errorKind.title)
                    .font(.caption.weight(.medium))
                Text(errorDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Only show burn rate if you'd hit 100% before the window resets.
    private func showBurnRate(rate: BurnRate, resetAt: Date?) -> Bool {
        guard let resetAt else { return true }
        let hoursUntilReset = resetAt.timeIntervalSinceNow / 3600
        return rate.hoursToFull < hoursUntilReset
    }

    private var errorDetail: String {
        switch errorKind {
        case .needsLogin:
            snapshot.providerID == .claude
                ? "Run `claude` then `/login`, or set a cookie in Settings"
                : "Run `codex --login`"
        case .cookieExpired:
            "Re-authenticate to resume tracking"
        case .rateLimited:
            "Will retry automatically"
        case .apiError:
            snapshot.notes.first ?? "Unknown error"
        case .none:
            ""
        }
    }
}

/// A minimal sparkline rendered as a stroked path with a subtle gradient fill.
struct SparklineView: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let lo = max((values.min() ?? 0) - 2, 0)
            let hi = min((values.max() ?? 100) + 2, 100)
            let range = max(hi - lo, 1)

            let points: [CGPoint] = values.enumerated().map { i, v in
                let x = values.count == 1 ? w / 2 : w * CGFloat(i) / CGFloat(values.count - 1)
                let y = h - h * CGFloat((v - lo) / range)
                return CGPoint(x: x, y: y)
            }

            // Fill
            Path { path in
                path.move(to: CGPoint(x: points[0].x, y: h))
                for pt in points { path.addLine(to: pt) }
                path.addLine(to: CGPoint(x: points.last!.x, y: h))
                path.closeSubpath()
            }
            .fill(
                LinearGradient(
                    colors: [tint.opacity(0.15), tint.opacity(0.02)],
                    startPoint: .top, endPoint: .bottom
                )
            )

            // Line
            Path { path in
                path.move(to: points[0])
                for pt in points.dropFirst() { path.addLine(to: pt) }
            }
            .stroke(tint.opacity(0.6), lineWidth: 1)
        }
    }
}

/// A button styled like a native NSMenu item with blue highlight on hover.
private struct MenuItemButton: View {
    let title: String
    let action: () -> Void
    @State private var isHovered = false

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(isHovered ? .white : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovered ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .onTapGesture { action() }
    }
}
