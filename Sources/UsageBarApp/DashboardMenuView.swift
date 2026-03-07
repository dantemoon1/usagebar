import SwiftUI
import UsageBarCore

struct DashboardMenuView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            ProviderCardView(
                title: "Claude",
                snapshot: model.snapshot.claude,
                tint: BarPalette.tint(for: .claude, mode: model.colorMode),
                reloginHint: model.claudeNeedsRelogin ? "Run `claude` then `/login`" : nil
            )

            ProviderCardView(
                title: "Codex",
                snapshot: model.snapshot.codex,
                tint: BarPalette.tint(for: .codex, mode: model.colorMode),
                reloginHint: model.codexNeedsRelogin ? "Run `codex --login`" : nil
            )

            Divider()

            settingsSection

            Divider()

            HStack {
                MenuItemButton("Quit") {
                    DispatchQueue.main.async {
                        NSApplication.shared.terminate(nil)
                    }
                }

                Spacer()

                Text("v0.1")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Settings")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            settingRow("Mode") {
                Picker("Mode", selection: Binding(
                    get: { model.displayMode },
                    set: { model.displayMode = $0 }
                )) {
                    ForEach(DisplayMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
            }

            if model.displayMode == .single {
                settingRow("Provider") {
                    Picker("Provider", selection: Binding(
                        get: { model.singleBarProvider },
                        set: { model.singleBarProvider = $0 }
                    )) {
                        ForEach(ProviderID.allCases, id: \.self) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    .labelsHidden()
                }
            }

            settingRow("Colors") {
                Picker("Colors", selection: Binding(
                    get: { model.colorMode },
                    set: { model.colorMode = $0 }
                )) {
                    ForEach(ColorMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
            }

            settingRow("Width") {
                Slider(value: $model.barWidth, in: 20...60, step: 5)
                    .accessibilityLabel("Width")
                Text("\(Int(model.barWidth))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 20, alignment: .trailing)
            }

            Toggle("Launch at login", isOn: Binding(
                get: { LaunchAtLogin.isEnabled },
                set: { LaunchAtLogin.setEnabled($0) }
            ))
            .font(.caption)
        }
    }

    private func settingRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            content()
        }
    }
}

private struct ProviderCardView: View {
    let title: String
    let snapshot: ProviderSnapshot
    let tint: Color
    var reloginHint: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            if let hint = reloginHint {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(hint)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if snapshot.fiveHourWindow != nil || snapshot.sevenDayWindow != nil {
                quotaRow(for: .fiveHour)
                quotaRow(for: .sevenDay)
            }

            ForEach(snapshot.metrics) { metric in
                metricRow(label: metric.label, value: metric.value)
            }

            if reloginHint == nil, !snapshot.notes.isEmpty {
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

            if let window, let resetAt = window.resetAt {
                let resetText = kind == .fiveHour
                    ? UsageBarFormatting.shortResetText(for: resetAt)
                    : UsageBarFormatting.longResetText(for: resetAt)
                Text("Resets \(resetText)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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
