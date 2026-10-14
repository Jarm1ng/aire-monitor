import HPCCore
import SwiftUI

/// How one cluster should be presented right now: a single mapping from the
/// session's flags to a phase, wording and the one primary action, shared by
/// the hero, sidebar row, overview card and menu bar so they can never
/// disagree (e.g. one offering Connect while another says "checking").
struct ClusterPresentation: Equatable {
    enum Phase: Equatable {
        /// Monitoring switched off (`hasCache`: a stale snapshot exists).
        case off(hasCache: Bool)
        /// Never signed in this run and no live master was found.
        case notConnected
        /// Startup / route-change probe still running against a possible
        /// live master. Never offer Connect here (and "Connect all" skips
        /// it): the probe may be about to confirm a live master, and a
        /// confirmed Reconnect would tear that master down.
        case checking
        case queued
        case signingIn
        /// Signed in; the first snapshot is still being collected.
        case loadingFirstSnapshot
        case live
        case paused
        /// Showing cached data; the session is not confirmed live.
        case stale
    }

    enum Action: Equatable {
        case connect
        case turnOn
        case resume
    }

    let phase: Phase
    let title: String
    let detail: String
    let primaryAction: Action?
    /// Whether a manual or opportunistic refresh makes sense. False when
    /// there is known to be no master (it would only paint a red "control
    /// master is not running" error) or a sign-in owns the session.
    let allowsRefresh: Bool
    let tint: Color
    let showsProgress: Bool

    @MainActor
    init(session: ClusterSession) {
        let name = session.displayName
        if !session.isEnabled {
            phase = .off(hasCache: session.snapshot != nil)
            title = "Off"
            detail = "\(name) is not being monitored."
            primaryAction = .turnOn
            allowsRefresh = false
            tint = .gray
            showsProgress = false
        } else if session.isLoggingIn {
            phase = .signingIn
            title = "Signing in"
            detail = Self.normalizedProgress(session.loginProgress, clusterName: name)
                ?? "Approve the Duo push on your phone when it arrives."
            primaryAction = nil
            allowsRefresh = false
            tint = .orange
            showsProgress = true
        } else if session.isLoginQueued {
            phase = .queued
            title = "Waiting"
            detail = "\(name) signs in next — Duo pushes arrive one at a time."
            primaryAction = nil
            allowsRefresh = false
            tint = .orange
            showsProgress = true
        } else if session.isPaused {
            phase = .paused
            title = "Paused"
            detail = session.snapshot == nil
                ? "No snapshot has been collected yet."
                : "Background refreshes are paused; the last snapshot stays on screen."
            primaryAction = .resume
            allowsRefresh = true
            tint = .orange
            showsProgress = false
        } else if session.isLoggedIn, session.snapshot == nil {
            phase = .loadingFirstSnapshot
            title = "Loading"
            detail = "Signed in — collecting the first \(name) snapshot…"
            primaryAction = nil
            allowsRefresh = true
            tint = .green
            showsProgress = true
        } else if session.isLoggedIn {
            phase = .live
            title = "Live"
            // While Slurm itself is failing over a healthy connection the
            // status line names the error; the session stays live (signing
            // in again could not fix it) but is tinted as degraded.
            detail = session.statusMessage
            primaryAction = nil
            allowsRefresh = true
            tint = session.schedulerIssue == nil ? .green : .orange
            showsProgress = false
        } else if !session.hasCompletedFirstProbe {
            phase = .checking
            title = "Checking"
            detail = "Looking for an open \(name) session…"
            primaryAction = nil
            allowsRefresh = false
            tint = .orange
            showsProgress = true
        } else if session.snapshot != nil {
            phase = .stale
            title = "Cached"
            detail = session.statusMessage
            primaryAction = .connect
            allowsRefresh = !session.lastFailureWasMissingMaster
            tint = .orange
            showsProgress = false
        } else {
            phase = .notConnected
            title = "Not connected"
            detail = "Sign in to load jobs, GPUs and storage from \(name)."
            primaryAction = .connect
            allowsRefresh = false
            tint = .gray
            showsProgress = false
        }
    }

    /// "waiting for Duo approval on your phone (Calder)" ->
    /// "Waiting for Duo approval on your phone": the cluster is already named
    /// wherever this text appears.
    static func normalizedProgress(_ raw: String?, clusterName: String) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        let suffix = "(\(clusterName))"
        if text.hasSuffix(suffix) {
            text = String(text.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

extension ClusterSession {
    var presentation: ClusterPresentation { ClusterPresentation(session: self) }
}
