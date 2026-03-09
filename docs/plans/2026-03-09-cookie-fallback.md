# Cookie-Based Fallback for Claude Usage

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a cookie-based fallback to `ClaudeAPIProvider` so usage data is fetched via `claude.ai` web API when OAuth tokens fail, and remove all token refresh logic.

**Architecture:** Two-tier fetch — try OAuth first (read-only, no refresh), fall back to browser cookie hitting `claude.ai/api/organizations/{orgId}/usage` via `URLSession`. Cookie stored as plain text file at `~/.usagebar/claude-cookie.txt`. Dashboard gets a cookie input field and a setup prompt when both methods fail.

**Tech Stack:** Swift 6.2, SwiftUI, Foundation URLSession, macOS 14+

---

### Task 1: Strip token refresh logic from ClaudeAPIProvider

**Files:**
- Modify: `Sources/UsageBarCore/ClaudeAPIProvider.swift`

**Step 1: Simplify the Credential struct**

Remove `refreshToken`, `expiresAt`, `rawData`, `needsRefresh`, and `CredentialSource`. The struct only needs `accessToken`.

```swift
private struct Credential: Sendable {
    let accessToken: String
}
```

**Step 2: Simplify credential loading**

Remove `parseCredential` source tracking. Both `loadFromFile()` and `loadFromKeychain()` just return the access token string. Remove `CredentialSource` enum entirely.

```swift
private func loadCredential() -> Credential? {
    if let cred = loadFromFile() { return cred }
    if let cred = loadFromKeychain() { return cred }
    return nil
}
```

Note: this now returns `nil` instead of throwing — we handle missing credentials by falling through to cookie.

**Step 3: Remove all refresh-related code**

Delete these methods entirely:
- `refreshAndSave(_:)`
- `updatedRawData(from:accessToken:refreshToken:expiresAt:)`
- `saveCredential(_:)`

Delete the `TokenRefreshResponse` struct at the bottom of the file.

Remove these static properties:
- `clientID`
- `scopes`
- `tokenURL`
- `refreshBufferMs`

**Step 4: Simplify `loadSnapshot()` flow**

Replace the entire `loadSnapshot()` body with a simpler two-tier flow (cookie fallback comes in Task 2):

```swift
public func loadSnapshot(now: Date) async -> ProviderSnapshot {
    DebugLog.trimIfNeeded()

    // Tier 1: Try OAuth token
    if let cred = loadCredential() {
        DebugLog.log("[Claude] loaded OAuth token")
        do {
            let (data, resp) = try await fetchUsage(accessToken: cred.accessToken)
            let status = resp?.statusCode ?? 0
            DebugLog.log("[Claude] OAuth API returned \(status)")
            if status == 200 {
                return try decodeAndBuild(data: data, now: now, source: "Claude API (OAuth)")
            }
            if status == 429 {
                throw ProviderError.rateLimited
            }
            DebugLog.log("[Claude] OAuth failed with \(status), will try cookie fallback")
        } catch let error as ProviderError {
            if case .rateLimited = error {
                DebugLog.log("[Claude] error: \(error.userMessage)")
                return .unavailable(providerID: .claude, sourceLabel: "Claude API", notes: [error.userMessage])
            }
            DebugLog.log("[Claude] OAuth error: \(error.userMessage), will try cookie fallback")
        } catch {
            DebugLog.log("[Claude] OAuth error: \(error.localizedDescription), will try cookie fallback")
        }
    } else {
        DebugLog.log("[Claude] no OAuth credentials found, will try cookie fallback")
    }

    // Tier 2: Cookie fallback (Task 2)
    return await loadViaCookie(now: now)
}
```

**Step 5: Update `decodeAndBuild` to accept a source label**

```swift
private func decodeAndBuild(data: Data, now: Date, source: String = "Claude API") throws -> ProviderSnapshot {
    let usage = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
    return buildSnapshot(from: usage, now: now, sourceLabel: source)
}

private func buildSnapshot(from usage: ClaudeUsageResponse, now: Date, sourceLabel: String) -> ProviderSnapshot {
    // ... same body but use sourceLabel parameter instead of hardcoded "Claude API"
}
```

**Step 6: Add a stub for `loadViaCookie`**

```swift
private func loadViaCookie(now: Date) async -> ProviderSnapshot {
    // Implemented in Task 2
    return .unavailable(providerID: .claude, sourceLabel: "Claude API",
                        notes: ["No credentials available. Run `claude login` or set a browser cookie."],
                        isAuthError: true)
}
```

**Step 7: Verify it compiles**

Run: `cd /Users/dante/.superset/worktrees/usagebar/Dante/claude-usage-fallback && swift build 2>&1 | tail -5`
Expected: Build succeeds

**Step 8: Commit**

```bash
git add Sources/UsageBarCore/ClaudeAPIProvider.swift
git commit -m "refactor: remove OAuth token refresh, simplify to read-only credential loading"
```

---

### Task 2: Add cookie-based fallback fetch

**Files:**
- Modify: `Sources/UsageBarCore/ClaudeAPIProvider.swift`

**Step 1: Add cookie storage helpers**

Add a static property for the cookie file path and read/write methods:

```swift
private static let cookieFileURL: URL = {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".usagebar")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("claude-cookie.txt")
}()

private func loadCookie() -> String? {
    guard let data = try? Data(contentsOf: Self.cookieFileURL) else { return nil }
    let cookie = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (cookie?.isEmpty == false) ? cookie : nil
}

public static func saveCookie(_ cookie: String) {
    let dir = cookieFileURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        .write(to: cookieFileURL, atomically: true, encoding: .utf8)
}

public static func clearCookie() {
    try? FileManager.default.removeItem(at: cookieFileURL)
}
```

**Step 2: Add org ID extraction from cookie string**

```swift
private func extractOrgId(from cookie: String) -> String? {
    for part in cookie.components(separatedBy: ";") {
        let trimmed = part.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("lastActiveOrg=") {
            return trimmed.replacingOccurrences(of: "lastActiveOrg=", with: "")
        }
    }
    return nil
}
```

**Step 3: Add the cookie-based fetch method**

```swift
private static let webUsageURLBase = "https://claude.ai/api/organizations/"

private func fetchUsageWithCookie(cookie: String, orgId: String) async throws -> (Data, HTTPURLResponse?) {
    guard let url = URL(string: "\(Self.webUsageURLBase)\(orgId)/usage") else {
        throw ProviderError.apiError("Invalid URL for org \(orgId)")
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue(cookie, forHTTPHeaderField: "Cookie")
    request.setValue("*/*", forHTTPHeaderField: "Accept")
    request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
    request.setValue("https://claude.ai", forHTTPHeaderField: "Referer")
    request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
    let (data, response) = try await URLSession.shared.data(for: request)
    return (data, response as? HTTPURLResponse)
}
```

**Step 4: Implement `loadViaCookie`**

Replace the stub from Task 1:

```swift
private func loadViaCookie(now: Date) async -> ProviderSnapshot {
    guard let cookie = loadCookie() else {
        DebugLog.log("[Claude] no cookie stored")
        return .unavailable(providerID: .claude, sourceLabel: "Claude API",
                            notes: ["No credentials available. Set a browser cookie in settings or run `claude login`."],
                            isAuthError: true)
    }
    guard let orgId = extractOrgId(from: cookie) else {
        DebugLog.log("[Claude] cookie missing lastActiveOrg")
        return .unavailable(providerID: .claude, sourceLabel: "Claude API",
                            notes: ["Cookie missing org ID. Re-copy the full cookie from claude.ai."],
                            isAuthError: true)
    }

    do {
        let (data, resp) = try await fetchUsageWithCookie(cookie: cookie, orgId: orgId)
        let status = resp?.statusCode ?? 0
        DebugLog.log("[Claude] cookie API returned \(status)")

        if status == 200 {
            return try decodeAndBuild(data: data, now: now, source: "Claude API (cookie)")
        }
        if status == 429 {
            DebugLog.log("[Claude] cookie rate limited")
            return .unavailable(providerID: .claude, sourceLabel: "Claude API", notes: ["Rate limited. Will retry on next refresh."])
        }

        let body = String(data: data, encoding: .utf8) ?? ""
        DebugLog.log("[Claude] cookie failed \(status): \(body.prefix(200))")
        return .unavailable(providerID: .claude, sourceLabel: "Claude API",
                            notes: ["Cookie auth failed (\(status)). Re-copy cookie from claude.ai."],
                            isAuthError: true)
    } catch {
        DebugLog.log("[Claude] cookie error: \(error.localizedDescription)")
        return .unavailable(providerID: .claude, sourceLabel: "Claude API",
                            notes: [error.localizedDescription])
    }
}
```

**Step 5: Verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds

**Step 6: Commit**

```bash
git add Sources/UsageBarCore/ClaudeAPIProvider.swift
git commit -m "feat: add cookie-based fallback for Claude usage fetching"
```

---

### Task 3: Add cookie input to dashboard UI

**Files:**
- Modify: `Sources/UsageBarApp/DashboardMenuView.swift`
- Modify: `Sources/UsageBarApp/AppModel.swift`

**Step 1: Add cookie state to AppModel**

Add a published property and methods for cookie management:

```swift
// In AppModel class:
@Published var claudeCookie: String = ""

// In init(), after loading cached snapshot:
claudeCookie = loadStoredCookie()

private func loadStoredCookie() -> String {
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".usagebar/claude-cookie.txt")
    return (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

func saveClaudeCookie(_ cookie: String) {
    claudeCookie = cookie
    ClaudeAPIProvider.saveCookie(cookie)
}

func clearClaudeCookie() {
    claudeCookie = ""
    ClaudeAPIProvider.clearCookie()
}
```

**Step 2: Add cookie section to DashboardMenuView settings**

In `settingsSection`, after the "Launch at login" toggle, add:

```swift
Divider()

Text("Claude Cookie")
    .font(.caption.weight(.semibold))
    .foregroundStyle(.secondary)

if model.claudeCookie.isEmpty {
    Text("Paste your claude.ai cookie for fallback auth when OAuth expires.")
        .font(.caption2)
        .foregroundStyle(.tertiary)
} else {
    HStack {
        Text("Cookie set ✓")
            .font(.caption2)
            .foregroundStyle(.green)
        Spacer()
        MenuItemButton("Clear") {
            model.clearClaudeCookie()
        }
    }
}

HStack {
    MenuItemButton("Paste Cookie") {
        if let str = NSPasteboard.general.string(forType: .string), !str.isEmpty {
            model.saveClaudeCookie(str)
            model.refresh()
        }
    }

    Spacer()

    MenuItemButton("How?") {
        NSWorkspace.shared.open(URL(string: "https://claude.ai/settings")!)
    }
}
```

**Step 3: Update the re-login hint for Claude**

In `DashboardMenuView`, change the Claude card's `reloginHint`:

```swift
ProviderCardView(
    title: "Claude",
    snapshot: model.snapshot.claude,
    tint: BarPalette.tint(for: .claude, mode: model.colorMode),
    reloginHint: model.claudeNeedsRelogin
        ? "Run `claude login` or paste a cookie below"
        : nil
)
```

**Step 4: Verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds

**Step 5: Commit**

```bash
git add Sources/UsageBarApp/DashboardMenuView.swift Sources/UsageBarApp/AppModel.swift Sources/UsageBarCore/ClaudeAPIProvider.swift
git commit -m "feat: add cookie input to dashboard settings for Claude fallback auth"
```

---

### Task 4: Build and smoke test

**Step 1: Full build**

Run: `swift build 2>&1 | tail -10`
Expected: Build succeeds with no errors

**Step 2: Manual smoke test**

Run the app and verify:
1. OAuth fetch works if credentials are valid
2. Dashboard shows "Claude API (OAuth)" or "Claude API (cookie)" as source label
3. Cookie paste button works
4. When OAuth fails and no cookie is set, the prompt appears

**Step 3: Commit any fixes**

```bash
git add -A
git commit -m "fix: address build/smoke-test issues"
```
