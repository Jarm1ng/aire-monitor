import HPCCore
import Foundation

// MARK: - Quick commands

/// One quick-command chip. Built per cluster from its `ClusterProfile`, so
/// partition names and quota tooling always match the cluster the command
/// runs on: AIRE's `gpu` partition does not exist on Calder, and Calder's
/// scratch and flash use Lustre project quotas rather than per-user ones.
struct TerminalQuickCommand: Identifiable, Equatable {
    let title: String
    let command: String
    let systemImage: String
    /// Full-screen programs must never be typed into an existing shell:
    /// a later chip's text would land in them as raw keystrokes.
    var opensDedicatedSession = false

    var id: String { title }

    static func items(for profile: ClusterProfile) -> [TerminalQuickCommand] {
        items(storage: profile.storage, gpuPartition: profile.gpuPartition)
    }

    static func items(storage: [StorageVolumeSpec], gpuPartition: String?) -> [TerminalQuickCommand] {
        var items = [
            TerminalQuickCommand(title: "My jobs", command: "squeue --me", systemImage: "list.bullet.rectangle"),
            TerminalQuickCommand(title: "Cluster", command: "sinfo", systemImage: "square.grid.2x2")
        ]
        if let quota = TerminalQuotaCommand.build(from: storage) {
            items.append(TerminalQuickCommand(title: "Quota", command: quota, systemImage: "internaldrive"))
        }
        // A cluster without a GPU partition simply has no GPU chip, rather
        // than one that always fails with "invalid partition".
        let gpuPartition = gpuPartition?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !gpuPartition.isEmpty {
            items.append(
                TerminalQuickCommand(
                    title: "GPU nodes",
                    command: "sinfo -N -p \(SSHTerminalCommand.shellWord(gpuPartition))",
                    systemImage: "memorychip"
                )
            )
        }
        items.append(
            TerminalQuickCommand(
                title: "htop",
                command: "htop || top",
                systemImage: "gauge",
                opensDedicatedSession: true
            )
        )
        return items
    }
}

// MARK: - Quota command

/// Builds the Quota chip's shell command from the cluster's storage specs —
/// the same specs the collector receives as `--storage-spec` — so the chip
/// can never drift from the Storage tab: every candidate directory is
/// tried in the same order (first existing one wins), and Lustre spaces use
/// the collector's rule (project quota when the directory carries a
/// non-zero project id, otherwise the per-user quota on its mount).
///
/// The command is typed into the user's interactive shell (or run by the
/// remote login shell), so it sticks to syntax bash, zsh and sh share, and
/// its loop variables are `hpc_`-prefixed so they cannot clobber anything
/// the user has set.
enum TerminalQuotaCommand {
    /// nil when no space has a quota to show (df-only specs are skipped:
    /// `df` alone is not a quota).
    static func build(from specs: [StorageVolumeSpec]) -> String? {
        var parts: [String] = []
        if specs.contains(where: { $0.quota == .nfs }) {
            // One NFS quota table covers every NFS space (the shared home).
            parts.append("quota -s")
        }
        for spec in specs where spec.quota == .lustre && !spec.paths.isEmpty {
            parts.append(lustreLoop(for: spec))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    private static func lustreLoop(for spec: StorageVolumeSpec) -> String {
        let candidates = spec.paths.map(doubleQuotedPath).joined(separator: " ")
        // Mount point = df -P column 6 onwards, re-joined in case it holds
        // spaces (identical to the collector's awk).
        let mount = #"hpc_m=$(df -P "$hpc_d" | awk 'NR==2{m=$6; for(i=7;i<=NF;i++) m=m" "$i; print m}')"#
        let project = #"hpc_p=$(lfs project -d "$hpc_d" 2>/dev/null | awk 'NR==1{print $1}')"#
        let label = SSHTerminalCommand.shellQuote("== \(spec.label):")
        return [
            "for hpc_d in \(candidates); do [ -d \"$hpc_d\" ] || continue",
            mount,
            project,
            // Project 0 is the filesystem-wide bucket of unassigned files,
            // never the user's own quota.
            "case $hpc_p in ''|*[!0-9]*) hpc_p=0;; esac",
            "echo \(label) \"$hpc_d\"",
            "if [ \"$hpc_p\" -ne 0 ]; then lfs quota -h -p \"$hpc_p\" \"$hpc_m\"; "
                + "else lfs quota -h -u \"$USER\" \"$hpc_m\"; fi",
            "break; done"
        ].joined(separator: "; ")
    }

    /// Double-quotes a spec path so `$USER` and `$HOME` (the only tokens a
    /// spec may contain, expanded on the login node) still expand, while
    /// every other shell metacharacter — a stray `$`, backquote, backslash
    /// or quote — is escaped and stays literal.
    static func doubleQuotedPath(_ path: String) -> String {
        let tokens = ["${USER}": "USER", "${HOME}": "HOME", "$USER": "USER", "$HOME": "HOME"]
        var result = "\""
        var index = path.startIndex
        scan: while index < path.endIndex {
            let rest = path[index...]
            for (token, name) in tokens where rest.hasPrefix(token) {
                let after = path.index(index, offsetBy: token.count)
                // "$USERX" would be read as the variable USERX: brace it.
                let continuesIdentifier = after < path.endIndex
                    && (path[after].isLetter || path[after].isNumber || path[after] == "_")
                result += continuesIdentifier || token.hasPrefix("${") ? "${\(name)}" : "$\(name)"
                index = after
                continue scan
            }
            let character = path[index]
            if "\"\\`$".contains(character) {
                result.append("\\")
            }
            result.append(character)
            index = path.index(after: index)
        }
        return result + "\""
    }
}
