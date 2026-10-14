import HPCCore
import Foundation

// Pure job-event logic: what started, what ended, and whether the gap since
// the last observation allows individual alerts. Kept free of
// UNUserNotificationCenter, files and clocks so it is unit-testable; the
// session decides when to diff and JobNotificationService only posts.

struct JobStateRecord: Codable, Equatable, Sendable {
    let jobId: String
    let name: String
    let partition: String
    let state: String
    let lastSeenAt: String
    /// Set for every element of a job array. Absent in baselines written
    /// before job arrays were understood (decoded as nil).
    let arrayJobID: Int?
    /// True for the pending remainder row of an array (one row standing for
    /// every queued task).
    let isArrayRemainder: Bool?

    init(
        jobId: String,
        name: String,
        partition: String,
        state: String,
        lastSeenAt: String,
        arrayJobID: Int? = nil,
        isArrayRemainder: Bool? = nil
    ) {
        self.jobId = jobId
        self.name = name
        self.partition = partition
        self.state = state
        self.lastSeenAt = lastSeenAt
        self.arrayJobID = arrayJobID
        self.isArrayRemainder = isArrayRemainder
    }
}

/// The job states last observed on one cluster. `updatedAt` is when the
/// cluster was last *observed* (every successful refresh advances it,
/// whether or not notifications are allowed), so its age measures time the
/// app did not watch — sleep, a VPN drop, the app not running, a pause.
struct JobStateSnapshot: Codable, Equatable, Sendable {
    let updatedAt: String
    let jobs: [String: JobStateRecord]
    /// Whose jobs these are, as `ClusterSession.jobIdentity` ("user@cluster";
    /// earlier builds wrote "user@host"). The job list is the signed-in
    /// account's, so a baseline from another account says nothing about
    /// which of the current jobs ended: diffing against it would announce
    /// every one of the old account's jobs as ended. Only the account part
    /// is compared (`JobStateDiff.account(of:)`). nil in baselines written
    /// before this was recorded (taken to match).
    let identity: String?

    init(updatedAt: String, jobs: [String: JobStateRecord], identity: String? = nil) {
        self.updatedAt = updatedAt
        self.jobs = jobs
        self.identity = identity
    }

    init(jobs: [Job], observedAt: String, identity: String? = nil) {
        self.identity = identity
        self.updatedAt = observedAt
        self.jobs = Dictionary(
            jobs.map { job in
                (
                    job.jobId,
                    JobStateRecord(
                        jobId: job.jobId,
                        name: job.name,
                        partition: job.partition,
                        state: job.state,
                        lastSeenAt: observedAt,
                        arrayJobID: job.arrayJobID,
                        isArrayRemainder: job.isArrayRemainder ? true : nil
                    )
                )
            },
            uniquingKeysWith: { _, last in last }
        )
    }

    /// Same jobs in the same states (timestamps ignored): nothing worth
    /// rewriting job_state.json for, apart from keeping `updatedAt` fresh.
    func hasSameStates(as other: JobStateSnapshot) -> Bool {
        guard jobs.count == other.jobs.count else {
            return false
        }
        for (id, record) in jobs {
            guard let match = other.jobs[id],
                  match.state == record.state,
                  match.name == record.name,
                  match.partition == record.partition else {
                return false
            }
        }
        return true
    }
}

struct JobStart: Equatable, Sendable {
    let name: String
    let jobId: String
    let partition: String
}

struct JobEnding: Equatable, Sendable {
    static let leftQueue = "Left queue"

    let name: String
    let jobId: String
    let partition: String
    let lastState: String
    let finalState: String
    let detail: String
}

/// Job events to announce for one refresh.
struct JobStateChanges: Equatable, Sendable {
    enum Delivery: Equatable, Sendable {
        /// The gap was short: one alert per event, as they happen.
        case individual
        /// The cluster was not watched for a while: a single catch-up alert
        /// ("While Calder was not being watched: …") instead of a burst.
        case summary(unobservedFor: TimeInterval)
    }

    let started: [JobStart]
    let ended: [JobEnding]
    let delivery: Delivery

    var isEmpty: Bool { started.isEmpty && ended.isEmpty }
}

enum JobStateDiff {
    /// Baselines up to this old diff normally (a couple of missed refreshes,
    /// a short VPN blip).
    static let individualWindow: TimeInterval = 10 * 60
    /// Beyond this, a diff would mostly report long-resolved jobs; the
    /// baseline is re-seeded silently instead. In between, one summary.
    static let summaryWindow: TimeInterval = 24 * 60 * 60

    /// What to announce, or nil when there is nothing to announce or the
    /// baseline must be re-seeded silently (none yet, unreadable timestamp,
    /// older than `summaryWindow`, or recorded for another account than
    /// `identity`'s — another account's jobs did not end just because they
    /// are not in this account's list). The caller saves the new baseline
    /// in every case.
    static func plan(previous: JobStateSnapshot?, current: [Job], now: Date, identity: String? = nil) -> JobStateChanges? {
        guard let previous else {
            return nil
        }
        if let recorded = previous.identity, let identity, account(of: recorded) != account(of: identity) {
            return nil
        }
        guard let observedAt = SlurmTimestamp.parse(previous.updatedAt) else {
            // No drift bound: re-seed rather than risk replaying an
            // arbitrarily old baseline.
            return nil
        }
        let gap = now.timeIntervalSince(observedAt)
        guard gap <= summaryWindow else {
            return nil
        }
        let (started, ended) = compute(previous: previous, current: current)
        guard !started.isEmpty || !ended.isEmpty else {
            return nil
        }
        return JobStateChanges(
            started: started,
            ended: ended,
            delivery: gap > individualWindow ? .summary(unobservedFor: gap) : .individual
        )
    }

    /// The account part of a job identity: everything before its last "@".
    /// That drops the "@cluster" of current identities and the "@host" of
    /// baselines written by earlier builds alike (neither part ever holds
    /// an "@"), so a baseline from before a login-host change, or from an
    /// earlier build, still matches its own account.
    static func account(of identity: String) -> Substring {
        guard let at = identity.lastIndex(of: "@") else {
            return identity[...]
        }
        return identity[..<at]
    }

    /// Starts (pending → running) and endings (a terminal state, or the job
    /// left squeue) between two observations.
    ///
    /// Job arrays: the pending remainder ("123", tasks "0-58") sheds one
    /// "123_N" row per task that starts, so a running task whose array had a
    /// pending remainder before counts as started, and a remainder that
    /// vanishes while the array still has tasks on the queue (its last task
    /// started, or its pending tasks were cancelled) is not an ending.
    static func compute(previous: JobStateSnapshot, current: [Job]) -> (started: [JobStart], ended: [JobEnding]) {
        let currentByID = Dictionary(current.map { ($0.jobId, $0) }, uniquingKeysWith: { _, last in last })
        let arraysOnQueue = Set(current.compactMap(\.arrayJobID))
        let arraysWithPendingRemainder = Set(
            previous.jobs.values
                .filter { $0.isArrayRemainder == true && JobState($0.state).isPending }
                .compactMap(\.arrayJobID)
        )

        var started: [JobStart] = []
        var ended: [JobEnding] = []
        var startedIDs = Set<String>()
        for job in current {
            let state = JobState(job.state)
            if let old = previous.jobs[job.jobId] {
                guard old.state != job.state else {
                    continue
                }
                if state.isFinished {
                    ended.append(JobEnding(
                        name: job.name,
                        jobId: job.jobId,
                        partition: job.partition,
                        lastState: old.state,
                        finalState: job.state,
                        detail: "Final state reported by Slurm."
                    ))
                } else if JobState(old.state).isPending, state.isRunning, startedIDs.insert(job.jobId).inserted {
                    // Only a queued job starting is news: a SUSPENDED job
                    // resuming is not.
                    started.append(JobStart(name: job.name, jobId: job.jobId, partition: job.partition))
                }
            } else if state.isRunning,
                      let array = job.arrayJobID,
                      arraysWithPendingRemainder.contains(array),
                      startedIDs.insert(job.jobId).inserted {
                started.append(JobStart(name: job.name, jobId: job.jobId, partition: job.partition))
            }
        }

        for old in previous.jobs.values where currentByID[old.jobId] == nil && !JobState(old.state).isFinished {
            if old.isArrayRemainder == true, let array = old.arrayJobID, arraysOnQueue.contains(array) {
                continue
            }
            ended.append(JobEnding(
                name: old.name,
                jobId: old.jobId,
                partition: old.partition,
                lastState: old.state,
                finalState: JobEnding.leftQueue,
                detail: "The job is no longer visible in squeue."
            ))
        }
        // Dictionary iteration order is random; keep alerts deterministic.
        ended.sort { $0.jobId.localizedStandardCompare($1.jobId) == .orderedAscending }
        return (started, ended)
    }
}

/// Decides when the "a GPU freed up" alert fires: on a 0 → >0 transition of
/// startable idle GPUs, subject to the user preference and a cooldown so a
/// flapping count (0 → 1 → 0 → 1 …) cannot spam. The baseline normally
/// advances to the current idle count, so enabling the preference later
/// starts from fresh data — except on the cooldown-suppressed path, where it
/// stays at 0 so the transition re-fires once the cooldown expires instead
/// of being dropped until the pool next drains to zero.
struct GPUFreeAlertTracker: Equatable {
    static let cooldown: TimeInterval = 600

    private(set) var previousIdle: Int?
    private(set) var lastFiredAt: Date?

    /// `idleGPUs` is nil when some node's allocation is unknown: "idle" then
    /// cannot be trusted, so the baseline is kept and nothing fires.
    /// Returns true when an alert should be attempted now.
    mutating func evaluate(idleGPUs: Int?, alertsEnabled: Bool, now: Date) -> Bool {
        guard let idle = idleGPUs else {
            return false
        }
        let previous = previousIdle
        previousIdle = idle
        guard alertsEnabled, previous == 0, idle > 0 else {
            return false
        }
        if let lastFiredAt, now.timeIntervalSince(lastFiredAt) < Self.cooldown {
            previousIdle = 0
            return false
        }
        return true
    }

    /// Starts the cooldown; called only when the alert was actually queued.
    mutating func recordFired(at date: Date) {
        lastFiredAt = date
    }
}
