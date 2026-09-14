import CodexBarCore
import Foundation

/// Opt-in Codex window keep-alive: after the 5-hour window expires, send one tiny `codex exec` prompt so the next
/// window starts right away even when nobody is using Codex. Provider-specific by design.
extension UsageStore {
    /// Windows longer than this are weekly/monthly lanes, never the 5h session window.
    nonisolated static let codexWindowKeepAliveMaximumWindowMinutes = 12 * 60
    /// A refreshed reset later than the expired boundary by more than this means a new window already started.
    nonisolated static let codexWindowKeepAliveResetToleranceSeconds: TimeInterval = 60
    /// Give the backend a moment to register the new window before reading usage again.
    nonisolated static let codexWindowKeepAliveFollowUpRefreshDelaySeconds: TimeInterval = 5

    enum CodexWindowKeepAliveSkipReason: Equatable, Sendable {
        case disabled
        case notCodexSessionWindow
        case codexDisabled
        case manualRefreshCadence
        case lowPowerMode
        /// The selected managed workspace differs from what `auth.json` names. `codex exec` only receives
        /// `CODEX_HOME`, so the paid request would land in the auth-file workspace instead of the displayed one.
        case managedWorkspaceUnsupported
        case alreadyAttempted
        case snapshotMissing
        /// The boundary pass did not publish a fresh Codex snapshot (fetch failed and the prior one was kept),
        /// so the expired reset it shows proves nothing about the current window.
        case snapshotStale
        case newWindowAlreadyStarted
    }

    /// Everything the pure decision needs, gathered by `scheduleCodexWindowKeepAliveIfNeeded` from live state.
    struct CodexWindowKeepAliveContext: Sendable {
        var enabled: Bool
        var window: ResetBoundaryWindow
        var codexEnabled: Bool
        var refreshCadenceIsManual: Bool
        var lowPowerModeEnabled: Bool
        /// `ProviderSettingsSnapshot.CodexProviderSettings.managedWorkspaceAccountID` for the selected account.
        var selectedManagedWorkspaceID: String?
        var attemptedBoundaries: Set<Date>
        var refreshedSnapshot: UsageSnapshot?
        /// When the boundary refresh pass began; a fresh publication must be at or after this instant.
        var refreshStartedAt: Date
        /// When the store last published a successfully fetched Codex snapshot.
        var snapshotPublishedAt: Date?
    }

    /// Pure decision so the trigger is testable without launching anything. Returns `nil` when the ping should run.
    nonisolated static func codexWindowKeepAliveSkipReason(
        _ context: CodexWindowKeepAliveContext) -> CodexWindowKeepAliveSkipReason?
    {
        guard context.enabled else { return .disabled }
        let window = context.window
        guard window.instanceID == .codex,
              let windowMinutes = window.windowMinutes,
              windowMinutes <= self.codexWindowKeepAliveMaximumWindowMinutes
        else { return .notCodexSessionWindow }
        guard context.codexEnabled else { return .codexDisabled }
        guard !context.refreshCadenceIsManual else { return .manualRefreshCadence }
        guard !context.lowPowerModeEnabled else { return .lowPowerMode }
        if let workspaceID = context.selectedManagedWorkspaceID, !workspaceID.isEmpty {
            return .managedWorkspaceUnsupported
        }
        guard !context.attemptedBoundaries.contains(window.resetsAt) else { return .alreadyAttempted }
        guard let refreshedSnapshot = context.refreshedSnapshot else { return .snapshotMissing }
        guard let publishedAt = context.snapshotPublishedAt,
              publishedAt >= context.refreshStartedAt
        else { return .snapshotStale }
        if let refreshedResetsAt = refreshedSnapshot.primary?.resetsAt,
           refreshedResetsAt.timeIntervalSince(window.resetsAt) > self.codexWindowKeepAliveResetToleranceSeconds
        {
            return .newWindowAlreadyStarted
        }
        return nil
    }

    /// Re-checked on the main actor right before the CLI launches, so turning the toggle off or switching the
    /// selected Codex account after the boundary fired still prevents the request.
    nonisolated static func codexWindowKeepAliveRemainsAdmitted(
        enabled: Bool,
        capturedEnvironment: [String: String],
        currentEnvironment: [String: String]) -> Bool
    {
        enabled && capturedEnvironment == currentEnvironment
    }

    func scheduleCodexWindowKeepAliveIfNeeded(after window: ResetBoundaryWindow, refreshStartedAt: Date) {
        let logger = CodexBarLog.logger(LogCategories.provider(.codex, scope: "window-keepalive"))
        if let reason = Self.codexWindowKeepAliveSkipReason(CodexWindowKeepAliveContext(
            enabled: self.settings.codexWindowKeepAliveEnabled,
            window: window,
            codexEnabled: self.isEnabled(.codex),
            refreshCadenceIsManual: self.settings.refreshFrequency == .manual,
            lowPowerModeEnabled: self.settings.backgroundWorkLowPowerModeEnabled,
            selectedManagedWorkspaceID: self.selectedCodexManagedWorkspaceID(),
            attemptedBoundaries: self.attemptedCodexWindowKeepAliveBoundaries,
            refreshedSnapshot: self.snapshots[.codex],
            refreshStartedAt: refreshStartedAt,
            snapshotPublishedAt: self.lastSnapshotPublicationAt[.codex]))
        {
            if reason != .disabled, reason != .notCodexSessionWindow {
                logger.info("Codex window keep-alive skipped", metadata: ["reason": "\(reason)"])
            }
            return
        }

        self.recordAttemptedCodexWindowKeepAlive(window.resetsAt)
        let environment = self.codexFetchEnvironment()
        let runner = self.codexWindowKeepAliveRunner
        self.codexWindowKeepAliveTask?.cancel()
        self.codexWindowKeepAliveTask = Task.detached(priority: .utility) { [weak self] in
            guard let self, await self.codexWindowKeepAliveRemainsAdmitted(capturedEnvironment: environment) else {
                logger.info("Codex window keep-alive cancelled before launch", metadata: ["reason": "consent"])
                return
            }
            guard !Task.isCancelled else { return }
            logger.info("Codex window keep-alive ping starting", metadata: ["resetsAt": "\(window.resetsAt)"])
            do {
                try await runner(environment)
                logger.info("Codex window keep-alive ping finished")
            } catch {
                logger.warning(
                    "Codex window keep-alive ping failed",
                    metadata: ["error": error.localizedDescription])
                return
            }
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .seconds(Self.codexWindowKeepAliveFollowUpRefreshDelaySeconds))
            guard !Task.isCancelled else { return }
            await self.refreshProvider(.codex, coalesceIfRefreshing: true)
        }
    }

    /// Drops any pending ping. Called when the toggle is turned off so no queued request survives the consent change.
    func cancelCodexWindowKeepAlive() {
        self.codexWindowKeepAliveTask?.cancel()
        self.codexWindowKeepAliveTask = nil
    }

    private func codexWindowKeepAliveRemainsAdmitted(capturedEnvironment: [String: String]) -> Bool {
        Self.codexWindowKeepAliveRemainsAdmitted(
            enabled: self.settings.codexWindowKeepAliveEnabled,
            capturedEnvironment: capturedEnvironment,
            currentEnvironment: self.codexFetchEnvironment())
    }

    /// Mirrors the admission `CodexOAuthNativeRefreshCLIStrategy` applies: the CLI cannot carry a selected managed
    /// workspace, so any non-nil ID here must keep the ping off.
    private func selectedCodexManagedWorkspaceID() -> String? {
        self.settings.codexSettingsSnapshot(tokenOverride: nil).managedWorkspaceAccountID
    }

    private func recordAttemptedCodexWindowKeepAlive(_ resetsAt: Date) {
        self.attemptedCodexWindowKeepAliveBoundaries.insert(resetsAt)
        if self.attemptedCodexWindowKeepAliveBoundaries.count > 64,
           let oldest = self.attemptedCodexWindowKeepAliveBoundaries.min()
        {
            self.attemptedCodexWindowKeepAliveBoundaries.remove(oldest)
        }
    }
}
