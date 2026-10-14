import HPCCore
import Foundation

// The pure rules a refresh is judged and merged by: how a collector run is
// classified, how a failure is summarised, and what a partial snapshot
// keeps from the previous one. Nonisolated and free of session state, so
// they are unit-tested directly (SessionTests) and ClusterSession stays
// about state transitions.

/// How one collector run turned out, decided from the snapshot alone.
enum RefreshClassification: Equatable {
    case success
    /// The SSH round trip worked — the collector's `remote` section answered
    /// through the ControlMaster — but Slurm commands failed or timed out
    /// (slurmctld down or overloaded). Not a connection problem: signing in
    /// again cannot fix it and would tear down a working master.
    case schedulerError(failedSections: Set<String>, message: String)
    /// No usable round trip (missing master, refused session, network).
    case transport(message: String)

    static func classify(_ snapshot: ClusterSnapshot) -> RefreshClassification {
        guard !snapshot.errors.isEmpty else {
            return .success
        }
        let message = snapshot.errors.joined(separator: "\n")
        guard !snapshot.remote.hostname.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .transport(message: message)
        }
        return .schedulerError(failedSections: failedSections(in: snapshot.errors), message: message)
    }

    /// Section names from the collector's "Section 'jobs' failed with exit 1"
    /// / "Section 'nodes' missing from remote output" errors.
    static func failedSections(in errors: [String]) -> Set<String> {
        var sections = Set<String>()
        for error in errors {
            // The collector's "No usable jobs listing (…)": the JSON listing
            // came back unusable and no pipe-format listing arrived. The job
            // list is empty because it failed, not because the queue is.
            if error.hasPrefix("No usable jobs listing") {
                sections.insert("jobs")
                continue
            }
            guard let start = error.range(of: "Section '"),
                  let end = error[start.upperBound...].firstIndex(of: "'") else {
                continue
            }
            sections.insert(String(error[start.upperBound..<end]))
        }
        return sections
    }
}

extension RefreshFailure {
    /// Local setup problems: the collector script or runtime folder is
    /// missing, python3 cannot be started. Everything else that throws out
    /// of a collector run is a failed round trip.
    nonisolated static func isConfigurationError(_ error: Error) -> Bool {
        if case MonitorError.missingFile = error {
            return true
        }
        // Process.run() and FileManager failures (no python3, an
        // uncreatable .runtime directory) are Cocoa errors; MonitorError
        // bridges to its own domain.
        return (error as NSError).domain == NSCocoaErrorDomain
    }

    /// The status-strip line for a configuration error.
    nonisolated static func configurationSummary(_ error: Error) -> String {
        if case MonitorError.missingFile(let path) = error {
            return path.hasSuffix(MonitorService.collectorScript)
                ? "Collector script missing at \(path)"
                : "Missing file: \(path)"
        }
        return "Could not run the collector: \(firstLine(of: error.localizedDescription))"
    }

    /// The first non-empty line, capped so a status line never wraps into
    /// a paragraph (the full text stays in `detail`).
    nonisolated static func firstLine(of text: String, limit: Int = 160) -> String {
        let line = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        guard line.count > limit else {
            return line
        }
        return String(line.prefix(limit - 1)) + "…"
    }
}

extension StorageSummary {
    /// A row the collector could not finish: the round trip ended before
    /// the volume ("not-collected"), or its filesystem gave no figures in
    /// time ("no-figures"). Unlike "missing", it says nothing about the
    /// volume, only about this refresh.
    var isCutShort: Bool {
        source == "unavailable" && (unavailableReason == "not-collected" || unavailableReason == "no-figures")
    }
}

extension ClusterSession {
    /// The storage rows to show after a refresh. `nil` (not collected:
    /// `--skip-storage`, the collector's stuck-storage guard, or a round
    /// trip that ended before the section) keeps the previous rows; `[]`
    /// means collected, no volumes. An optional volume whose row was cut
    /// short (unavailable / not-collected) is shown only when that label
    /// has had real figures — AIRE's absent Flash stays hidden.
    ///
    /// `carryCutRows`: a row cut short this time keeps the previous row of
    /// its label when that one had figures, so one slow `df`/`lfs` does not
    /// wipe good figures (or punch a gap in Trends) while the session
    /// retries a minute later. The session allows it only for a while after
    /// the last complete collection (`storageCarryLimit`), so figures are
    /// never passed off as current for long.
    nonisolated static func mergeStorage(
        previous: [StorageSummary]?,
        incoming: [StorageSummary]?,
        labelsWithFigures: Set<String>,
        carryCutRows: Bool = false
    ) -> [StorageSummary]? {
        guard let incoming else {
            return previous
        }
        var previousWithFigures: [String: StorageSummary] = [:]
        if carryCutRows {
            for row in previous ?? [] where row.source != "unavailable" && previousWithFigures[row.label] == nil {
                previousWithFigures[row.label] = row
            }
        }
        return incoming.compactMap { row in
            if row.isCutShort, let kept = previousWithFigures[row.label] {
                return kept
            }
            let cutOptional = row.optional
                && row.source == "unavailable"
                && row.unavailableReason == "not-collected"
            return (!cutOptional || labelsWithFigures.contains(row.label)) ? row : nil
        }
    }

    /// True when `merged` shows a row carried over from `previous` in place
    /// of one this refresh cut short — i.e. not every row on screen comes
    /// from `incoming`.
    nonisolated static func storageCarriesEarlierRows(incoming: [StorageSummary]?, merged: [StorageSummary]?) -> Bool {
        guard let incoming, let merged else {
            return false
        }
        let cutLabels = Set(incoming.filter(\.isCutShort).map(\.label))
        return merged.contains { cutLabels.contains($0.label) && !$0.isCutShort }
    }

    /// `snapshot` without the data that belongs to one account — its job
    /// list and its storage rows — and with the cluster-wide sections
    /// (partitions, nodes) kept. Used when the account changes, so a merge
    /// that falls back to "the previous data" can never show another
    /// account's queue or quotas as this one's.
    nonisolated static func withoutAccountData(in snapshot: ClusterSnapshot) -> ClusterSnapshot {
        guard !snapshot.jobs.isEmpty || snapshot.storage != nil else {
            return snapshot
        }
        return ClusterSnapshot(
            schemaVersion: snapshot.schemaVersion,
            collectedAt: snapshot.collectedAt,
            startedAt: snapshot.startedAt,
            durationMs: snapshot.durationMs,
            timings: snapshot.timings,
            storageSkipped: snapshot.storageSkipped,
            cluster: snapshot.cluster,
            remote: snapshot.remote,
            jobs: [],
            partitions: snapshot.partitions,
            nodes: snapshot.nodes,
            storage: nil,
            errors: snapshot.errors,
            warnings: snapshot.warnings
        )
    }

    /// `snapshot` with its storage replaced, every other field as collected.
    nonisolated static func withStorage(_ storage: [StorageSummary]?, in snapshot: ClusterSnapshot) -> ClusterSnapshot {
        guard storage != snapshot.storage else {
            return snapshot
        }
        return ClusterSnapshot(
            schemaVersion: snapshot.schemaVersion,
            collectedAt: snapshot.collectedAt,
            startedAt: snapshot.startedAt,
            durationMs: snapshot.durationMs,
            timings: snapshot.timings,
            storageSkipped: snapshot.storageSkipped,
            cluster: snapshot.cluster,
            remote: snapshot.remote,
            jobs: snapshot.jobs,
            partitions: snapshot.partitions,
            nodes: snapshot.nodes,
            storage: storage,
            errors: snapshot.errors,
            warnings: snapshot.warnings
        )
    }

    /// The previous snapshot's data for every core section that failed and
    /// came back empty; everything that did refresh is taken as new. The
    /// collector's errors move to warnings (the existing warnings chip shows
    /// them), plus a note per section kept from before. Storage follows
    /// `mergeStorage`.
    nonisolated static func merge(
        previous: ClusterSnapshot?,
        incoming: ClusterSnapshot,
        failedSections: Set<String>,
        labelsWithFigures: Set<String> = [],
        carryCutStorageRows: Bool = false
    ) -> ClusterSnapshot {
        var notes: [String] = []
        func keep<Element>(_ section: String, _ fresh: [Element], _ old: [Element]?, noun: String) -> [Element] {
            guard failedSections.contains(section), fresh.isEmpty, let old, !old.isEmpty else {
                return fresh
            }
            notes.append("Slurm \(section) query failed — showing the previous \(noun)")
            return old
        }
        let jobs = keep("jobs", incoming.jobs, previous?.jobs, noun: "job list")
        let partitions = keep("partitions", incoming.partitions, previous?.partitions, noun: "partitions")
        let nodes = keep("nodes", incoming.nodes, previous?.nodes, noun: "node list")
        return ClusterSnapshot(
            schemaVersion: incoming.schemaVersion,
            collectedAt: incoming.collectedAt,
            startedAt: incoming.startedAt,
            durationMs: incoming.durationMs,
            timings: incoming.timings,
            storageSkipped: incoming.storageSkipped,
            cluster: incoming.cluster ?? previous?.cluster,
            remote: incoming.remote,
            jobs: jobs,
            partitions: partitions,
            nodes: nodes,
            storage: mergeStorage(
                previous: previous?.storage,
                incoming: incoming.storage,
                labelsWithFigures: labelsWithFigures,
                carryCutRows: carryCutStorageRows
            ),
            errors: [],
            warnings: incoming.errors + notes + incoming.warnings
        )
    }
}
