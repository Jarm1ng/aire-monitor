import HPCCore
import SwiftUI

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

extension StorageKind {
    var color: Color {
        switch self {
        case .home: return .purple
        // Identity colours only (icons): never a status colour (orange is a
        // warning) or a metric colour (teal is CPU).
        case .scratch: return .blue
        case .flash: return .indigo
        case .other: return .gray
        }
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

/// Identity colour of a cluster, used for badges, sidebar rows and the
/// overview so AIRE and Calder data are never confused at a glance. The
/// components come from HPCCore's `ClusterIdentity`, shared with the widget.
struct ClusterAccent: Hashable, Sendable {
    let identity: ClusterIdentity

    var color: Color {
        Color(red: identity.accentRed, green: identity.accentGreen, blue: identity.accentBlue)
    }
}

/// Everything the app knows about one cluster. Connection, collection,
/// storage, partition and presentation knowledge all live here.
struct ClusterProfile: Identifiable, Sendable, Hashable {
    let identity: ClusterIdentity
    let defaultHostname: String
    /// One-line description for headers and empty states.
    let tagline: String
    let storage: [StorageVolumeSpec]
    let partitions: [PartitionHint]
    /// Partition used by the terminal's "GPU nodes" quick command.
    let gpuPartition: String?
    let documentationURL: URL

    var id: ClusterID { identity.id }
    var displayName: String { identity.displayName }
    /// Monogram shown in the cluster badge.
    var monogram: String { identity.monogram }
    var accent: ClusterAccent { ClusterAccent(identity: identity) }

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
        identity: .aire,
        defaultHostname: "aire.leeds.ac.uk",
        tagline: "L40S GPUs · 168-core CPU nodes · high-memory queue",
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
        documentationURL: URL(string: "https://arcdocs.leeds.ac.uk/aire/welcome.html")!
    )

    static let calder = ClusterProfile(
        identity: .calder,
        defaultHostname: "calder.leeds.ac.uk",
        tagline: "H200 GPUs · 128-core Turin CPU nodes · 48 h walltime",
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
