import SwiftUI
import UsageBarCore

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Display") {
                Picker("Mode", selection: Binding(
                    get: { model.displayMode },
                    set: { model.displayMode = $0 }
                )) {
                    ForEach(DisplayMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                if model.displayMode == .single {
                    Picker("Provider", selection: Binding(
                        get: { model.singleBarProvider },
                        set: { model.singleBarProvider = $0 }
                    )) {
                        ForEach(ProviderID.allCases, id: \.self) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                }

                Picker("Colors", selection: Binding(
                    get: { model.colorMode },
                    set: { model.colorMode = $0 }
                )) {
                    ForEach(ColorMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                HStack {
                    Text("Bar Width")
                    Slider(value: $model.barWidth, in: 20...60, step: 5)
                    Text("\(Int(model.barWidth))px")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }
            }

            Section("Claude Cookie") {
                cookieStatusRow

                HStack(spacing: 8) {
                    Button("Paste from Clipboard") {
                        if let str = NSPasteboard.general.string(forType: .string), !str.isEmpty {
                            model.saveClaudeCookie(str)
                        }
                    }

                    if !model.claudeCookie.isEmpty {
                        Button("Validate") {
                            model.validateCookie()
                        }
                        .disabled(model.cookieValidation == .validating)

                        Button("Clear", role: .destructive) {
                            model.clearClaudeCookie()
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Used as a fallback when OAuth tokens expire.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 4) {
                        Text("To get your cookie:")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Button("Open claude.ai/settings/usage") {
                            NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
                        }
                        .font(.caption)
                        .buttonStyle(.link)
                    }

                    Text("Then open DevTools (\u{2318}\u{2325}I) \u{2192} Network tab \u{2192} refresh the page \u{2192} click the \"usage\" request \u{2192} copy the full Cookie header value.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { LaunchAtLogin.isEnabled },
                    set: { LaunchAtLogin.setEnabled($0) }
                ))

                Toggle("Usage notifications", isOn: Binding(
                    get: { model.notificationsEnabled },
                    set: { newValue in
                        model.notificationsEnabled = newValue
                        if newValue { model.requestNotificationPermission() }
                    }
                ))

                if model.notificationsEnabled {
                    if model.notificationsDenied {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("Notifications blocked in System Settings.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Open") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings")!)
                            }
                            .font(.caption)
                            .buttonStyle(.link)
                        }
                    } else {
                        Text("Alerts at 50%, 75%, 90%, 95%, 99% for each quota window.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            if !model.claudeCookie.isEmpty && model.cookieValidation == .none {
                model.validateCookie()
            }
            model.checkNotificationPermission()
        }
    }

    @ViewBuilder
    private var cookieStatusRow: some View {
        switch model.cookieValidation {
        case .none:
            if model.claudeCookie.isEmpty {
                Label("No cookie set", systemImage: "minus.circle")
                    .foregroundStyle(.secondary)
            } else {
                Label("Cookie set, not validated", systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
            }
        case .validating:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Validating cookie...")
                    .foregroundStyle(.secondary)
            }
        case .valid:
            Label("Cookie valid", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .invalid(let reason):
            VStack(alignment: .leading, spacing: 2) {
                Label("Cookie invalid", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
