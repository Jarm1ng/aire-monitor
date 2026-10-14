import Foundation

/// The client options every ssh or scp process that rides a cluster's
/// ControlMaster must pass. They encode three invariants, kept in one place
/// so a new call site cannot quietly drop one:
///
/// - **Never prompt.** BatchMode (plus no password or keyboard-interactive
///   auth) means a dead master can never turn into a password prompt or a
///   surprise Duo push. Passwords only ever travel through the login helper.
/// - **Never become a master.** `ControlMaster=no`: a `ControlMaster auto`
///   block in ~/.ssh/config (common for an `aire` alias) must never turn a
///   client into a new master on the app's own socket path, dialling the
///   host directly and bypassing the jump host.
/// - **Fail fast.** If the master vanished between the `-O check` pre-flight
///   and launch, OpenSSH silently falls back to a direct connection;
///   `ConnectTimeout=5` bounds that attempt instead of hanging until the
///   kernel TCP timeout (~75 s) on an unreachable login node.
///
/// Terminals, the file manager's quit-time cleanup and
/// `MonitorService.runRemoteCommand` use `sshArguments`; every scp
/// (`RemoteFileService.scpArguments`) uses `scpOptions`.
enum SSHMuxOptions {
    /// `-o` options shared by ssh and scp.
    static func clientOptions(username: String) -> [String] {
        [
            "-o", "User=\(username)",
            "-o", "BatchMode=yes",
            "-o", "PasswordAuthentication=no",
            "-o", "KbdInteractiveAuthentication=no",
            "-o", "ConnectTimeout=5",
            "-o", "ControlMaster=no"
        ]
    }

    /// ssh: rides the cluster's own master through `-S`. Each cluster has
    /// its own socket (keyed by cluster, user, host and route), so an AIRE
    /// client can never ride Calder's session.
    static func sshArguments(settings: ConnectionSettings) -> [String] {
        ["-S", settings.controlPath] + clientOptions(username: settings.username)
    }

    /// scp: `-S` means "ssh program" to scp, so the socket goes through
    /// `-o ControlPath=` instead.
    static func scpOptions(settings: ConnectionSettings) -> [String] {
        ["-o", "ControlPath=\(settings.controlPath)"] + clientOptions(username: settings.username)
    }
}
