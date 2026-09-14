import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct CodexWindowKeepAliveTests {
    private static let resetsAt = Date(timeIntervalSince1970: 1_700_000_000)

    @Test
    func `runner sends the documented exec ping in a read-only sandbox`() {
        let arguments = CodexWindowKeepAliveRunner.arguments()

        #expect(arguments.first == "exec")
        #expect(arguments.contains("--skip-git-repo-check"))
        #expect(arguments.contains("--json"))
        #expect(arguments.last == "ping")
        let sandboxIndex = arguments.firstIndex(of: "--sandbox")
        #expect(sandboxIndex.map { arguments[$0 + 1] } == "read-only")
    }

    @Test
    func `runner fails closed when the Codex CLI cannot be resolved`() async {
        await #expect(throws: CodexWindowKeepAliveError.self) {
            try await CodexWindowKeepAliveRunner.run(
                environment: [:],
                timeout: 1,
                resolveExecutable: { _, _ in nil })
        }
    }

    @Test
    func `keep-alive runs only for the Codex session window after an expired boundary`() {
        let reason = UsageStore.codexWindowKeepAliveSkipReason(UsageStore.CodexWindowKeepAliveContext(
            enabled: true,
            window: Self.window(),
            codexEnabled: true,
            lowPowerModeEnabled: false,
            attemptedBoundaries: [],
            refreshedSnapshot: Self.snapshot(primaryResetsAt: Self.resetsAt)))

        #expect(reason == nil)
    }

    @Test
    func `keep-alive stays off by default`() {
        let settings = testSettingsStore(suiteName: "CodexWindowKeepAliveTests-default")

        #expect(settings.codexWindowKeepAliveEnabled == false)
        #expect(UsageStore.codexWindowKeepAliveSkipReason(UsageStore.CodexWindowKeepAliveContext(
            enabled: settings.codexWindowKeepAliveEnabled,
            window: Self.window(),
            codexEnabled: true,
            lowPowerModeEnabled: false,
            attemptedBoundaries: [],
            refreshedSnapshot: Self.snapshot(primaryResetsAt: Self.resetsAt))) == .disabled)
    }

    @Test
    func `setting persists to user defaults`() throws {
        let defaults = try #require(UserDefaults(suiteName: "CodexWindowKeepAliveTests-persist-\(UUID().uuidString)"))
        let settings = testSettingsStore(suiteName: "CodexWindowKeepAliveTests-persist", userDefaults: defaults)

        settings.codexWindowKeepAliveEnabled = true

        #expect(defaults.bool(forKey: "codexWindowKeepAliveEnabled"))
        #expect(settings.codexWindowKeepAliveEnabled)
    }

    @Test
    func `keep-alive ignores other providers and weekly windows`() {
        let claudeReason = UsageStore.codexWindowKeepAliveSkipReason(UsageStore.CodexWindowKeepAliveContext(
            enabled: true,
            window: Self.window(instanceID: .claude),
            codexEnabled: true,
            lowPowerModeEnabled: false,
            attemptedBoundaries: [],
            refreshedSnapshot: Self.snapshot(primaryResetsAt: Self.resetsAt)))
        let weeklyReason = UsageStore.codexWindowKeepAliveSkipReason(UsageStore.CodexWindowKeepAliveContext(
            enabled: true,
            window: Self.window(windowMinutes: 7 * 24 * 60),
            codexEnabled: true,
            lowPowerModeEnabled: false,
            attemptedBoundaries: [],
            refreshedSnapshot: Self.snapshot(primaryResetsAt: Self.resetsAt)))
        let unknownReason = UsageStore.codexWindowKeepAliveSkipReason(UsageStore.CodexWindowKeepAliveContext(
            enabled: true,
            window: Self.window(windowMinutes: nil),
            codexEnabled: true,
            lowPowerModeEnabled: false,
            attemptedBoundaries: [],
            refreshedSnapshot: Self.snapshot(primaryResetsAt: Self.resetsAt)))

        #expect(claudeReason == .notCodexSessionWindow)
        #expect(weeklyReason == .notCodexSessionWindow)
        #expect(unknownReason == .notCodexSessionWindow)
    }

    @Test
    func `keep-alive skips disabled provider low power and repeated boundaries`() {
        let snapshot = Self.snapshot(primaryResetsAt: Self.resetsAt)

        #expect(UsageStore.codexWindowKeepAliveSkipReason(UsageStore.CodexWindowKeepAliveContext(
            enabled: true,
            window: Self.window(),
            codexEnabled: false,
            lowPowerModeEnabled: false,
            attemptedBoundaries: [],
            refreshedSnapshot: snapshot)) == .codexDisabled)
        #expect(UsageStore.codexWindowKeepAliveSkipReason(UsageStore.CodexWindowKeepAliveContext(
            enabled: true,
            window: Self.window(),
            codexEnabled: true,
            lowPowerModeEnabled: true,
            attemptedBoundaries: [],
            refreshedSnapshot: snapshot)) == .lowPowerMode)
        #expect(UsageStore.codexWindowKeepAliveSkipReason(UsageStore.CodexWindowKeepAliveContext(
            enabled: true,
            window: Self.window(),
            codexEnabled: true,
            lowPowerModeEnabled: false,
            attemptedBoundaries: [Self.resetsAt],
            refreshedSnapshot: snapshot)) == .alreadyAttempted)
        #expect(UsageStore.codexWindowKeepAliveSkipReason(UsageStore.CodexWindowKeepAliveContext(
            enabled: true,
            window: Self.window(),
            codexEnabled: true,
            lowPowerModeEnabled: false,
            attemptedBoundaries: [],
            refreshedSnapshot: nil)) == .snapshotMissing)
    }

    @Test
    func `keep-alive does not ping when a new window already started`() {
        let advanced = Self.snapshot(primaryResetsAt: Self.resetsAt.addingTimeInterval(5 * 60 * 60))
        let stillExpired = Self.snapshot(primaryResetsAt: Self.resetsAt.addingTimeInterval(30))
        let noReset = Self.snapshot(primaryResetsAt: nil)

        #expect(UsageStore.codexWindowKeepAliveSkipReason(UsageStore.CodexWindowKeepAliveContext(
            enabled: true,
            window: Self.window(),
            codexEnabled: true,
            lowPowerModeEnabled: false,
            attemptedBoundaries: [],
            refreshedSnapshot: advanced)) == .newWindowAlreadyStarted)
        #expect(UsageStore.codexWindowKeepAliveSkipReason(UsageStore.CodexWindowKeepAliveContext(
            enabled: true,
            window: Self.window(),
            codexEnabled: true,
            lowPowerModeEnabled: false,
            attemptedBoundaries: [],
            refreshedSnapshot: stillExpired)) == nil)
        #expect(UsageStore.codexWindowKeepAliveSkipReason(UsageStore.CodexWindowKeepAliveContext(
            enabled: true,
            window: Self.window(),
            codexEnabled: true,
            lowPowerModeEnabled: false,
            attemptedBoundaries: [],
            refreshedSnapshot: noReset)) == nil)
    }

    @Test
    @MainActor
    func `store pings once per boundary through the injected runner`() async throws {
        let settings = testSettingsStore(suiteName: "CodexWindowKeepAliveTests-store")
        settings.providerDetectionCompleted = true
        let metadata = try #require(ProviderRegistry.shared.metadata[.codex])
        settings.setProviderEnabled(provider: .codex, metadata: metadata, enabled: true)
        settings.codexWindowKeepAliveEnabled = true
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        store.snapshots[.codex] = Self.snapshot(primaryResetsAt: Self.resetsAt)
        let counter = PingCounter()
        store.codexWindowKeepAliveRunner = { _ in await counter.increment() }
        defer { store.codexWindowKeepAliveTask?.cancel() }

        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else { return }

        store.scheduleCodexWindowKeepAliveIfNeeded(after: Self.window())
        let firstTask = try #require(store.codexWindowKeepAliveTask)
        store.scheduleCodexWindowKeepAliveIfNeeded(after: Self.window())

        #expect(store.codexWindowKeepAliveTask == firstTask)
        #expect(store.attemptedCodexWindowKeepAliveBoundaries == [Self.resetsAt])
        try await Self.waitUntil { await counter.count == 1 }
        #expect(await counter.count == 1)
    }

    private static func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: @Sendable () async -> Bool) async throws
    {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Timed out waiting for keep-alive ping")
    }

    private static func window(
        instanceID: ProviderInstanceID = .codex,
        windowMinutes: Int? = 300) -> UsageStore.ResetBoundaryWindow
    {
        UsageStore.ResetBoundaryWindow(
            instanceID: instanceID,
            windowMinutes: windowMinutes,
            resetsAt: self.resetsAt)
    }

    private static func snapshot(primaryResetsAt: Date?) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: 300,
                resetsAt: primaryResetsAt,
                resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: self.resetsAt.addingTimeInterval(UsageStore.resetBoundaryRefreshGraceSeconds),
            identity: nil)
    }
}

private actor PingCounter {
    private(set) var count = 0

    func increment() {
        self.count += 1
    }
}
