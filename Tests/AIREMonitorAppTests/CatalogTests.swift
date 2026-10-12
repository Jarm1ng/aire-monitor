import Foundation
import Testing
@testable import AIREMonitorApp

@Suite("SidebarSelection")
struct SidebarSelectionTests {
    @Test("storageKey round-trips", arguments: [
        SidebarSelection.overview,
        .cluster(.aire),
        .cluster(.calder)
    ])
    func roundTrip(selection: SidebarSelection) {
        #expect(SidebarSelection(storageKey: selection.storageKey) == selection)
    }

    @Test("storageKey spelling is stable")
    func keySpelling() {
        // Persisted in preferences.json; changing the spelling would reset
        // every user's last selection.
        #expect(SidebarSelection.overview.storageKey == "overview")
        #expect(SidebarSelection.cluster(.calder).storageKey == "cluster:calder")
        #expect(SidebarSelection.cluster(.aire).storageKey == "cluster:aire")
    }

    @Test("Missing or unknown keys decode to nil", arguments: [nil, "", "jobs", "Overview", "aire"] as [String?])
    func invalidKeys(key: String?) {
        #expect(SidebarSelection(storageKey: key) == nil)
    }
}

@Suite("Storage kinds")
struct StorageKindTests {
    @Test("Labels map to kinds", arguments: [
        ("Home", StorageKind.home),
        ("Scratch", .scratch),
        ("Flash", .flash),
        ("Other", .other),
        ("HOME", .home),
        ("Project scratch", .scratch),
        ("Archive", .other)
    ])
    func labelMapping(label: String, kind: StorageKind) {
        #expect(StorageKind(label: label) == kind)
    }

    @Test("Display order is home, scratch, flash, other")
    func ordering() {
        #expect([StorageKind.other, .flash, .home, .scratch].sorted() == [.home, .scratch, .flash, .other])
    }

    @Test("Only home is shared across clusters")
    func sharedAcrossClusters() {
        // /users is one NFS export: summing it per cluster would double count.
        #expect(StorageKind.home.isSharedAcrossClusters)
        #expect(!StorageKind.scratch.isSharedAcrossClusters)
        #expect(!StorageKind.flash.isSharedAcrossClusters)
        #expect(!StorageKind.other.isSharedAcrossClusters)
    }
}

@Suite("GPU model names")
struct GPUModelNameTests {
    @Test("Slurm gres types become display names", arguments: [
        ("nvidia_h200", "H200"),
        ("l40s", "L40S"),
        ("a100_80g", "A100 80G"),
        (" nvidia_h200 ", "H200")
    ])
    func displayName(raw: String, expected: String) {
        #expect(gpuModelDisplayName(raw) == expected)
    }

    @Test("Both clusters' gres strings parse to model and count")
    func gresParsing() {
        #expect(slurmGPUModel(from: "gpu:nvidia_h200:8").map(gpuModelDisplayName) == "H200")
        #expect(slurmGPUTotal(from: "gpu:nvidia_h200:8") == 8)
        #expect(slurmGPUModel(from: "gpu:l40s:3(S:0-1)").map(gpuModelDisplayName) == "L40S")
        #expect(slurmGPUTotal(from: "gpu:l40s:3(S:0-1)") == 3)
        #expect(slurmGPUModel(from: "(null)") == nil)
        #expect(slurmGPUTotal(from: "(null)") == 0)
    }
}

@Suite("Cluster catalog")
struct ClusterCatalogTests {
    @Test("AIRE and Calder are both catalogued, in display order, with unique ids")
    func catalogContents() {
        let ids = ClusterCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.contains(.aire))
        #expect(ids.contains(.calder))
        #expect(ids.first == .aire)
        #expect(ClusterCatalog.profile(for: .calder)?.displayName == "Calder")
        #expect(ClusterCatalog.profile(for: .aire)?.defaultHostname == "aire.leeds.ac.uk")
        #expect(ClusterCatalog.profile(for: ClusterID("bede")) == nil)
    }

    @Test("Display names, hosts, accents and monograms are distinct")
    func profilesAreDistinguishable() {
        // Two clusters' data must never be confusable at a glance.
        let profiles = ClusterCatalog.all
        #expect(Set(profiles.map(\.displayName)).count == profiles.count)
        #expect(Set(profiles.map(\.defaultHostname)).count == profiles.count)
        #expect(Set(profiles.map(\.accent)).count == profiles.count)
        #expect(Set(profiles.map(\.monogram)).count == profiles.count)
    }

    @Test("Partition roles resolve per cluster")
    func partitionRoles() {
        #expect(ClusterProfile.calder.role(forPartition: "calder-gpu-hopper") == .gpu)
        #expect(ClusterProfile.calder.role(forPartition: "calder-cpu-turin") == .cpu)
        #expect(ClusterProfile.aire.role(forPartition: "gpu") == .gpu)
        #expect(ClusterProfile.aire.role(forPartition: "nodes") == .cpu)
        #expect(ClusterProfile.aire.role(forPartition: "himem") == .highMemory)
        #expect(ClusterProfile.aire.role(forPartition: "teachingnodes") == .teaching)

        #expect(ClusterProfile.aire.role(forPartition: "debug") == nil)
        #expect(ClusterProfile.calder.role(forPartition: "") == nil)
        // Partition names are only meaningful within their own cluster.
        #expect(ClusterProfile.calder.role(forPartition: "gpu") == nil)
        #expect(ClusterProfile.aire.role(forPartition: "calder-gpu-hopper") == nil)
    }

    @Test("Each profile's GPU partition is one of its GPU partition hints", arguments: catalogIDs)
    func gpuPartitionIsHinted(id: ClusterID) throws {
        let profile = catalogProfile(id)
        let gpuPartition = try #require(profile.gpuPartition)
        #expect(profile.role(forPartition: gpuPartition) == .gpu)
        #expect(Set(profile.partitions.map(\.name)).count == profile.partitions.count)
    }

    @Test("Every profile reports the shared NFS home first", arguments: catalogIDs)
    func homeVolume(id: ClusterID) throws {
        let profile = catalogProfile(id)
        let home = try #require(profile.storage.first)
        #expect(StorageKind(label: home.label) == .home)
        #expect(home.quota == .nfs)
        #expect(home.paths == ["$HOME"])
        #expect(!home.optional)
        #expect(Set(profile.storage.map(\.label)).count == profile.storage.count)
    }
}
