import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct CodexWindowKeepAliveTests {
    private static let resetsAt = Date(timeIntervalSince1970: 1_700_000_000)
    /// When the boundary refresh pass started: the expired reset plus the scheduler's grace period.
    private static let refreshStartedAt = resetsAt.addingTimeInterval(UsageStore.resetBoundaryRefreshGraceSeconds)
    /// A Codex publication that happened during that pass.
    private static let freshPublicationAt = refreshStartedAt.addingTimeInterval(1)

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
        #expect(UsageStore.codexWindowKeepAliveSkipReason(Self.context()) == nil)
    }

    @Test
    func `keep-alive stays off by default`() {
        let settings = testSettingsStore(suiteName: "CodexWindowKeepAliveTests-default")

        #expect(settings.codexWindowKeepAliveEnabled == false)
        #expect(UsageStore.codexWindowKeepAliveSkipReason(
            Self.context(enabled: settings.codexWindowKeepAliveEnabled)) == .disabled)
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
        #expect(UsageStore.codexWindowKeepAliveSkipReason(
            Self.context(window: Self.window(instanceID: .claude))) == .notCodexSessionWindow)
        #expect(UsageStore.codexWindowKeepAliveSkipReason(
            Self.context(window: Self.window(windowMinutes: 7 * 24 * 60))) == .notCodexSessionWindow)
        #expect(UsageStore.codexWindowKeepAliveSkipReason(
            Self.context(window: Self.window(windowMinutes: nil))) == .notCodexSessionWindow)
    }

    @Test
    func `keep-alive skips disabled provider low power and repeated boundaries`() {
        #expect(UsageStore.codexWindowKeepAliveSkipReason(Self.context(codexEnabled: false)) == .codexDisabled)
        #expect(UsageStore.codexWindowKeepAliveSkipReason(Self.context(lowPowerModeEnabled: true)) == .lowPowerMode)
        #expect(UsageStore.codexWindowKeepAliveSkipReason(
            Self.context(attemptedBoundaries: [Self.resetsAt])) == .alreadyAttempted)
        #expect(UsageStore.codexWindowKeepAliveSkipReason(Self.context(refreshedSnapshot: nil)) == .snapshotMissing)
    }

    @Test
    func `keep-alive stays inert under Manual refresh cadence`() {
        #expect(UsageStore.codexWindowKeepAliveSkipReason(
            Self.context(refreshCadenceIsManual: true)) == .manualRefreshCadence)
    }

    @Test
    func `keep-alive rejects a selected managed workspace the CLI cannot carry`() {
        #expect(UsageStore.codexWindowKeepAliveSkipReason(
            Self.context(selectedManagedWorkspaceID: "workspace-example")) == .managedWorkspaceUnsupported)
        #expect(UsageStore.codexWindowKeepAliveSkipReason(Self.context(selectedManagedWorkspaceID: "")) == nil)
        #expect(UsageStore.codexWindowKeepAliveSkipReason(Self.context(selectedManagedWorkspaceID: nil)) == nil)
    }

    @Test
    func `keep-alive requires a Codex snapshot published by the boundary pass`() {
        #expect(UsageStore.codexWindowKeepAliveSkipReason(Self.context(snapshotPublishedAt: nil)) == .snapshotStale)
        #expect(UsageStore.codexWindowKeepAliveSkipReason(Self.context(
            snapshotPublishedAt: Self.refreshStartedAt.addingTimeInterval(-1))) == .snapshotStale)
        #expect(UsageStore.codexWindowKeepAliveSkipReason(Self.context(
            snapshotPublishedAt: Self.refreshStartedAt)) == nil)
        #expect(UsageStore.codexWindowKeepAliveSkipReason(Self.context(
            snapshotPublishedAt: Self.freshPublicationAt)) == nil)
    }

    @Test
    func `keep-alive does not ping when a new window already started`() {
        let advanced = Self.snapshot(primaryResetsAt: Self.resetsAt.addingTimeInterval(5 * 60 * 60))
        let stillExpired = Self.snapshot(primaryResetsAt: Self.resetsAt.addingTimeInterval(30))
        let noReset = Self.snapshot(primaryResetsAt: nil)

        #expect(UsageStore.codexWindowKeepAliveSkipReason(
            Self.context(refreshedSnapshot: advanced)) == .newWindowAlreadyStarted)
        #expect(UsageStore.codexWindowKeepAliveSkipReason(Self.context(refreshedSnapshot: stillExpired)) == nil)
        #expect(UsageStore.codexWindowKeepAliveSkipReason(Self.context(refreshedSnapshot: noReset)) == nil)
    }

    @Test
    func `pending ping is dropped when consent or the selected account changes`() {
        let captured = ["CODEX_HOME": "/tmp/a"]

        #expect(UsageStore.codexWindowKeepAliveRemainsAdmitted(
            enabled: true, capturedEnvironment: captured, currentEnvironment: captured))
        #expect(!UsageStore.codexWindowKeepAliveRemainsAdmitted(
            enabled: false, capturedEnvironment: captured, currentEnvironment: captured))
        #expect(!UsageStore.codexWindowKeepAliveRemainsAdmitted(
            enabled: true, capturedEnvironment: captured, currentEnvironment: ["CODEX_HOME": "/tmp/b"]))
    }

    @Test
    @MainActor
    func `toggle explains why it is inert under Manual cadence or an added workspace`() {
        let settings = Self.keepAliveSettings(suiteName: "CodexWindowKeepAliveTests-status")
        defer { settings._test_codexAccountSnapshotLoader = nil }

        #expect(CodexProviderImplementation.windowKeepAliveStatusText(settings: settings) == nil)

        settings.refreshFrequency = .manual
        #expect(CodexProviderImplementation.windowKeepAliveStatusText(settings: settings)?.contains("Manual") == true)

        settings.refreshFrequency = .fiveMinutes
        Self.selectManagedWorkspace(in: settings)
        #expect(settings.codexSettingsSnapshot(tokenOverride: nil).managedWorkspaceAccountID == "workspace-example")
        #expect(CodexProviderImplementation.windowKeepAliveStatusText(settings: settings)?
            .contains("workspace") == true)
    }

    @Test
    @MainActor
    func `store pings once per boundary through the injected runner`() async throws {
        let settings = Self.keepAliveSettings(suiteName: "CodexWindowKeepAliveTests-store")
        defer { settings._test_codexAccountSnapshotLoader = nil }
        let store = Self.makeStore(settings: settings)
        let counter = PingCounter()
        store.codexWindowKeepAliveRunner = { _ in await counter.increment() }
        defer { store.cancelCodexWindowKeepAlive() }

        store.scheduleCodexWindowKeepAliveIfNeeded(after: Self.window(), refreshStartedAt: Self.storeRefreshStartedAt)
        let firstTask = try #require(store.codexWindowKeepAliveTask)
        store.scheduleCodexWindowKeepAliveIfNeeded(after: Self.window(), refreshStartedAt: Self.storeRefreshStartedAt)

        #expect(store.codexWindowKeepAliveTask == firstTask)
        #expect(store.attemptedCodexWindowKeepAliveBoundaries == [Self.resetsAt])
        try await Self.waitUntil { await counter.count == 1 }
        #expect(await counter.count == 1)
    }

    @Test
    @MainActor
    func `store does not ping when the pass kept a stale Codex snapshot`() {
        let settings = Self.keepAliveSettings(suiteName: "CodexWindowKeepAliveTests-stale")
        defer { settings._test_codexAccountSnapshotLoader = nil }
        let store = Self.makeStore(settings: settings)
        store.lastSnapshotPublicationAt[.codex] = Self.storeRefreshStartedAt.addingTimeInterval(-60)

        store.scheduleCodexWindowKeepAliveIfNeeded(after: Self.window(), refreshStartedAt: Self.storeRefreshStartedAt)

        #expect(store.codexWindowKeepAliveTask == nil)
        #expect(store.attemptedCodexWindowKeepAliveBoundaries.isEmpty)
    }

    @Test
    @MainActor
    func `store does not ping for a selected managed workspace`() {
        let settings = Self.keepAliveSettings(suiteName: "CodexWindowKeepAliveTests-workspace")
        defer { settings._test_codexAccountSnapshotLoader = nil }
        Self.selectManagedWorkspace(in: settings)
        let store = Self.makeStore(settings: settings)

        store.scheduleCodexWindowKeepAliveIfNeeded(after: Self.window(), refreshStartedAt: Self.storeRefreshStartedAt)

        #expect(store.codexWindowKeepAliveTask == nil)
        #expect(store.attemptedCodexWindowKeepAliveBoundaries.isEmpty)
    }

    @Test
    @MainActor
    func `store drops a queued ping when the toggle is turned off before launch`() async throws {
        let settings = Self.keepAliveSettings(suiteName: "CodexWindowKeepAliveTests-consent")
        defer { settings._test_codexAccountSnapshotLoader = nil }
        let store = Self.makeStore(settings: settings)
        let counter = PingCounter()
        store.codexWindowKeepAliveRunner = { _ in await counter.increment() }
        defer { store.cancelCodexWindowKeepAlive() }

        store.scheduleCodexWindowKeepAliveIfNeeded(after: Self.window(), refreshStartedAt: Self.storeRefreshStartedAt)
        let task = try #require(store.codexWindowKeepAliveTask)
        // The detached task must hop back to the main actor before launching; flipping the toggle first wins.
        settings.codexWindowKeepAliveEnabled = false
        await task.value

        let pinged = await counter.hasPinged
        #expect(!pinged)

        store.cancelCodexWindowKeepAlive()
        #expect(store.codexWindowKeepAliveTask == nil)
    }

    // MARK: - Helpers

    /// A boundary pass that started well before `makeStore` records its Codex publication at `Date()`.
    private static let storeRefreshStartedAt = resetsAt

    @MainActor
    private static func keepAliveSettings(suiteName: String) -> SettingsStore {
        let settings = testSettingsStore(suiteName: suiteName)
        settings.providerDetectionCompleted = true
        if let metadata = ProviderRegistry.shared.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: metadata, enabled: true)
        }
        settings.codexWindowKeepAliveEnabled = true
        settings.refreshFrequency = .fiveMinutes
        settings.backgroundWorkLowPowerModePreference = .off
        settings._test_codexAccountSnapshotLoader = { _ in Self.reconciliationSnapshot(stored: nil) }
        return settings
    }

    @MainActor
    private static func makeStore(settings: SettingsStore) -> UsageStore {
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        store.snapshots[.codex] = Self.snapshot(primaryResetsAt: Self.resetsAt)
        store.lastSnapshotPublicationAt[.codex] = Date()
        return store
    }

    /// Selects an added (managed) account whose stored workspace differs from whatever its auth file names.
    @MainActor
    private static func selectManagedWorkspace(in settings: SettingsStore) {
        let stored = ManagedCodexAccount(
            id: UUID(),
            email: "account@example.com",
            providerAccountID: "workspace-example",
            managedHomePath: "/tmp/codexbar-window-keepalive-tests/managed",
            createdAt: 1,
            updatedAt: 1,
            lastAuthenticatedAt: 1)
        let snapshot = Self.reconciliationSnapshot(stored: stored)
        settings._test_codexAccountSnapshotLoader = { _ in snapshot }
        settings.codexActiveSource = .managedAccount(id: stored.id)
    }

    private static func reconciliationSnapshot(stored: ManagedCodexAccount?) -> CodexAccountReconciliationSnapshot {
        CodexAccountReconciliationSnapshot(
            storedAccounts: stored.map { [$0] } ?? [],
            activeStoredAccount: stored,
            liveSystemAccount: nil,
            matchingStoredAccountForLiveSystemAccount: nil,
            activeSource: stored.map { .managedAccount(id: $0.id) } ?? .liveSystem,
            hasUnreadableAddedAccountStore: false,
            storedAccountRuntimeIdentities: stored.map { [$0.id: .providerAccount(id: "workspace-example")] } ?? [:])
    }

    private static func context(
        enabled: Bool = true,
        window: UsageStore.ResetBoundaryWindow = Self.window(),
        codexEnabled: Bool = true,
        refreshCadenceIsManual: Bool = false,
        lowPowerModeEnabled: Bool = false,
        selectedManagedWorkspaceID: String? = nil,
        attemptedBoundaries: Set<Date> = [],
        refreshedSnapshot: UsageSnapshot? = Self.snapshot(primaryResetsAt: Self.resetsAt),
        refreshStartedAt: Date = Self.refreshStartedAt,
        snapshotPublishedAt: Date? = Self.freshPublicationAt) -> UsageStore.CodexWindowKeepAliveContext
    {
        UsageStore.CodexWindowKeepAliveContext(
            enabled: enabled,
            window: window,
            codexEnabled: codexEnabled,
            refreshCadenceIsManual: refreshCadenceIsManual,
            lowPowerModeEnabled: lowPowerModeEnabled,
            selectedManagedWorkspaceID: selectedManagedWorkspaceID,
            attemptedBoundaries: attemptedBoundaries,
            refreshedSnapshot: refreshedSnapshot,
            refreshStartedAt: refreshStartedAt,
            snapshotPublishedAt: snapshotPublishedAt)
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
    private(set) var hasPinged = false

    func increment() {
        self.count += 1
        self.hasPinged = true
    }
}
