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
        case lowPowerMode
        case alreadyAttempted
        case snapshotMissing
        case newWindowAlreadyStarted
    }

    /// Everything the pure decision needs, gathered by `scheduleCodexWindowKeepAliveIfNeeded` from live state.
    struct CodexWindowKeepAliveContext: Sendable {
        var enabled: Bool
        var window: ResetBoundaryWindow
        var codexEnabled: Bool
        var lowPowerModeEnabled: Bool
        var attemptedBoundaries: Set<Date>
        var refreshedSnapshot: UsageSnapshot?
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
        guard !context.lowPowerModeEnabled else { return .lowPowerMode }
        guard !context.attemptedBoundaries.contains(window.resetsAt) else { return .alreadyAttempted }
        guard let refreshedSnapshot = context.refreshedSnapshot else { return .snapshotMissing }
        if let refreshedResetsAt = refreshedSnapshot.primary?.resetsAt,
           refreshedResetsAt.timeIntervalSince(window.resetsAt) > self.codexWindowKeepAliveResetToleranceSeconds
        {
            return .newWindowAlreadyStarted
        }
        return nil
    }

    func scheduleCodexWindowKeepAliveIfNeeded(after window: ResetBoundaryWindow) {
        let logger = CodexBarLog.logger(LogCategories.provider(.codex, scope: "window-keepalive"))
        if let reason = Self.codexWindowKeepAliveSkipReason(CodexWindowKeepAliveContext(
            enabled: self.settings.codexWindowKeepAliveEnabled,
            window: window,
            codexEnabled: self.isEnabled(.codex),
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            attemptedBoundaries: self.attemptedCodexWindowKeepAliveBoundaries,
            refreshedSnapshot: self.snapshots[.codex]))
        {
            if reason != .disabled, reason != .notCodexSessionWindow {
                logger.debug("Codex window keep-alive skipped", metadata: ["reason": "\(reason)"])
            }
            return
        }

        self.recordAttemptedCodexWindowKeepAlive(window.resetsAt)
        let environment = self.codexFetchEnvironment()
        let runner = self.codexWindowKeepAliveRunner
        self.codexWindowKeepAliveTask?.cancel()
        self.codexWindowKeepAliveTask = Task.detached(priority: .utility) { [weak self] in
            logger.info("Codex window keep-alive ping starting")
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
            await self?.refreshProvider(.codex, coalesceIfRefreshing: true)
        }
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
