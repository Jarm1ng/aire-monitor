import SwiftUI

/// Stable identifier of a monitored cluster. String-backed rather than an
/// enum so generic code never switches on a particular cluster: everything
/// cluster-specific lives in `ClusterProfile`, and adding a cluster means
/// adding one profile to `ClusterCatalog`.
struct ClusterID: RawRepresentable, Hashable, Codable, Sendable, Identifiable, CustomStringConvertible {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    var id: String { rawValue }
    var description: String { rawValue }

    static let aire = ClusterID("aire")
    static let calder = ClusterID("calder")
}

/// How the Mac reaches the university network. It is a property of where the
/// user is (on the VPN/campus or not), so one route applies to every cluster.
enum ConnectionRoute: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Straight to each cluster's login host. Requires the University VPN or
    /// the campus network; one Duo approval per cluster.
    case directVPN
    /// Tunnelled through rash.leeds.ac.uk. Works off-VPN; one Duo approval for
    /// rash (shared by every cluster) plus one per cluster.
    case rashJump

    var id: String { rawValue }

    var title: String {
        switch self {
        case .directVPN: return "Direct (VPN)"
        case .rashJump: return "Via rash jump host"
        }
    }

    /// Compact label for the segmented picker.
    var shortTitle: String {
        switch self {
        case .directVPN: return "Direct (VPN)"
        case .rashJump: return "rash jump"
        }
    }

    var detail: String {
        switch self {
        case .directVPN:
            return "Connect straight to each cluster over the University VPN — one Duo approval per cluster."
        case .rashJump:
            return "Tunnel through rash.leeds.ac.uk when off-VPN — one Duo approval for rash, then one per cluster."
        }
    }
}

/// One filesystem the collector reports for a cluster. Encoded verbatim into
/// the collector's `--storage-spec` argument, so the Python engine stays
/// cluster-agnostic.
struct StorageVolumeSpec: Codable, Sendable, Hashable {
    enum Quota: String, Codable, Sendable {
        /// `quota -s` on an NFS export (the shared /users home).
        case nfs
        /// Lustre: project quota when the directory carries a project id,
        /// otherwise the per-user quota on its mount.
        case lustre
        /// df only.
        case none
    }

    let label: String
    /// Candidate directories, first existing one wins. `$USER` and `$HOME`
    /// are the only tokens, expanded on the login node.
    let paths: [String]
    let quota: Quota
    /// Omitted from the snapshot (instead of reported as missing) when no
    /// candidate exists on the login node.
    let optional: Bool

    init(label: String, paths: [String], quota: Quota, optional: Bool = false) {
        self.label = label
        self.paths = paths
        self.quota = quota
        self.optional = optional
    }
}

/// Coarse kind of a storage space, derived from its label. Drives icons,
/// colors, trend series and sort order everywhere storage is shown.
enum StorageKind: Int, Comparable, Sendable {
    case home
    case scratch
    case flash
    case other

    init(label: String) {
        let lowered = label.lowercased()
        if lowered.contains("home") {
            self = .home
        } else if lowered.contains("scratch") {
            self = .scratch
        } else if lowered.contains("flash") {
            self = .flash
        } else {
            self = .other
        }
    }

    static func < (lhs: StorageKind, rhs: StorageKind) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var systemImage: String {
        switch self {
        case .home: return "house"
        case .scratch: return "externaldrive"
        case .flash: return "bolt.horizontal"
        case .other: return "internaldrive"
        }
    }

    var color: Color {
        switch self {
        case .home: return .purple
        case .scratch: return .teal
        case .flash: return .orange
        case .other: return .gray
        }
    }

    /// /users is one NFS export mounted on every Leeds cluster: the same
    /// quota appears in each cluster's snapshot and must not be summed.
    var isSharedAcrossClusters: Bool {
        self == .home
    }
}

/// What a partition is for, so dashboards can group and decorate partitions
/// without hard-coding any one cluster's partition names.
enum PartitionRole: String, Sendable {
    case gpu
    case cpu
    case highMemory
    case teaching
    case other

    var systemImage: String {
        switch self {
        case .gpu: return "memorychip"
        case .cpu: return "cpu"
        case .highMemory: return "memorychip.fill"
        case .teaching: return "graduationcap"
        case .other: return "square.grid.2x2"
        }
    }

    var title: String {
        switch self {
        case .gpu: return "GPU"
        case .cpu: return "CPU"
        case .highMemory: return "High memory"
        case .teaching: return "Teaching"
        case .other: return "Other"
        }
    }
}

struct PartitionHint: Sendable, Hashable {
    let name: String
    let role: PartitionRole
    /// One-line description shown on partition cards.
    let summary: String
    /// Lower sorts first.
    let sortRank: Int
}

/// Identity color of a cluster, used for badges, sidebar rows and the
/// overview so AIRE and Calder data are never confused at a glance.
enum ClusterAccent: String, Sendable {
    case green
    case violet

    var color: Color {
        switch self {
        case .green: return Color(red: 0.16, green: 0.74, blue: 0.48)
        case .violet: return Color(red: 0.56, green: 0.45, blue: 0.96)
        }
    }
}

/// Everything the app knows about one cluster. Connection, collection,
/// storage, partition and presentation knowledge all live here.
struct ClusterProfile: Identifiable, Sendable, Hashable {
    let id: ClusterID
    let displayName: String
    let defaultHostname: String
    /// One-line description for headers and empty states.
    let tagline: String
    let accent: ClusterAccent
    /// Monogram shown in the cluster badge.
    let monogram: String
    let storage: [StorageVolumeSpec]
    let partitions: [PartitionHint]
    /// Partition used by the terminal's "GPU nodes" quick command.
    let gpuPartition: String?
    /// Terminal quick command that prints this user's quotas.
    let quotaCommand: String
    let documentationURL: URL

    func hint(forPartition name: String) -> PartitionHint? {
        partitions.first { $0.name == name }
    }

    func role(forPartition name: String) -> PartitionRole? {
        hint(forPartition: name)?.role
    }

    static func == (lhs: ClusterProfile, rhs: ClusterProfile) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension ClusterProfile {
    static let aire = ClusterProfile(
        id: .aire,
        displayName: "AIRE",
        defaultHostname: "aire.leeds.ac.uk",
        tagline: "L40S GPUs · 168-core CPU nodes · high-memory queue",
        accent: .green,
        monogram: "A",
        storage: [
            StorageVolumeSpec(label: "Home", paths: ["$HOME"], quota: .nfs),
            // Aire 2.0 is expected to move scratch/flash to /scratch-aire and
            // /flash-aire; the candidates follow it without an app update.
            StorageVolumeSpec(
                label: "Scratch",
                paths: ["/scratch-aire/users/$USER", "/mnt/scratch/$USER", "/mnt/scratch/users/$USER"],
                quota: .lustre
            ),
            StorageVolumeSpec(
                label: "Flash",
                paths: ["/flash-aire/users/$USER", "/mnt/flash/$USER", "/mnt/flash/users/$USER"],
                quota: .lustre,
                optional: true
            )
        ],
        partitions: [
            PartitionHint(name: "gpu", role: .gpu, summary: "L40S GPU partition", sortRank: 0),
            PartitionHint(name: "nodes", role: .cpu, summary: "standard CPU partition", sortRank: 1),
            PartitionHint(name: "himem", role: .highMemory, summary: "high-memory CPU queue", sortRank: 2),
            PartitionHint(name: "teachingnodes", role: .teaching, summary: "teaching partition", sortRank: 3)
        ],
        gpuPartition: "gpu",
        // Same candidate order as the Scratch volume above, so the command
        // keeps working after the Aire 2.0 path change.
        quotaCommand: "quota -s; for d in /scratch-aire/users/$USER /mnt/scratch/$USER; do "
            + "[ -d \"$d\" ] && { lfs quota -h -u \"$USER\" \"$(df -P \"$d\" | awk 'NR==2{print $NF}')\"; break; }; done",
        documentationURL: URL(string: "https://arcdocs.leeds.ac.uk/aire/welcome.html")!
    )

    static let calder = ClusterProfile(
        id: .calder,
        displayName: "Calder",
        defaultHostname: "calder.leeds.ac.uk",
        tagline: "H200 GPUs · 128-core Turin CPU nodes · 48 h walltime",
        accent: .violet,
        monogram: "C",
        storage: [
            StorageVolumeSpec(label: "Home", paths: ["$HOME"], quota: .nfs),
            StorageVolumeSpec(
                label: "Scratch",
                paths: ["/scratch-calder/users/$USER", "/scratch-calder/$USER"],
                quota: .lustre
            ),
            StorageVolumeSpec(
                label: "Flash",
                paths: ["/flash-calder/users/$USER", "/flash-calder/$USER"],
                quota: .lustre,
                optional: true
            )
        ],
        partitions: [
            PartitionHint(name: "calder-gpu-hopper", role: .gpu, summary: "H200 GPU partition", sortRank: 0),
            PartitionHint(name: "calder-cpu-turin", role: .cpu, summary: "standard CPU partition", sortRank: 1),
            // Observed live on 2026-10-12: Calder's scheduler also carries
            // AIRE-generation nodes (L40 GPUs, Genoa CPUs), drained at the
            // time — presumably the Aire 2.0 move onto the new controller.
            PartitionHint(name: "aire-gpu-lovelace", role: .gpu, summary: "AIRE-generation L40 nodes on the Calder scheduler", sortRank: 2),
            PartitionHint(name: "aire-cpu-genoa", role: .cpu, summary: "AIRE-generation CPU nodes on the Calder scheduler", sortRank: 3)
        ],
        gpuPartition: "calder-gpu-hopper",
        // Calder scratch/flash use Lustre project quotas keyed by the
        // directory's project id, not per-user quotas.
        // Same rule as the collector: project quota when the directory has a
        // non-zero project id (project 0 is the filesystem-wide bucket of
        // unassigned files), otherwise the per-user quota; missing spaces
        // are skipped.
        quotaCommand: "quota -s; for d in /scratch-calder/users/$USER /flash-calder/users/$USER; do "
            + "[ -d \"$d\" ] || continue; m=$(df -P \"$d\" | awk 'NR==2{print $NF}'); "
            + "p=$(lfs project -d \"$d\" 2>/dev/null | awk 'NR==1{print $1}'); "
            + "if [ -n \"$p\" ] && [ \"$p\" -ne 0 ] 2>/dev/null; then lfs quota -h -p \"$p\" \"$m\"; "
            + "else lfs quota -h -u \"$USER\" \"$m\"; fi; done",
        documentationURL: URL(string: "https://arcdocs.leeds.ac.uk/calder/welcome.html")!
    )
}

enum ClusterCatalog {
    /// Display order everywhere (sidebar, overview, menu bar, widget).
    static let all: [ClusterProfile] = [.aire, .calder]

    static func profile(for id: ClusterID) -> ClusterProfile? {
        all.first { $0.id == id }
    }
}

/// Display name for a Slurm GPU gres type: "l40s" -> "L40S",
/// "nvidia_h200" -> "H200", "a100_80g" -> "A100 80G".
func gpuModelDisplayName(_ rawModel: String) -> String {
    var model = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
    for prefix in ["nvidia_", "nvidia-", "amd_", "amd-"] where model.lowercased().hasPrefix(prefix) {
        model = String(model.dropFirst(prefix.count))
    }
    return model
        .replacingOccurrences(of: "_", with: " ")
        .uppercased()
}
