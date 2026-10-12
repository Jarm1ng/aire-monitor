import Testing
@testable import AIREMonitorApp

/// The wording of `MonitorService.explainSSHFailure` decides what the user
/// does next. The costly mistake is telling someone their password is wrong
/// when the server merely refused the connection (Calder's round-robin DNS
/// sometimes lands on a login node that drops new sessions): retyping a
/// correct password, or retrying a wrong one, moves the account towards a
/// lockout. These tests pin each classification to real OpenSSH output.
@Suite("SSH failure explanations")
struct SSHFailureExplanationTests {
    @Test("Exit 13 means the password was rejected")
    func exitCodeThirteenIsPasswordRejected() {
        let text = MonitorService.explainSSHFailure(
            "HPC-STATUS: Password prompt repeated",
            exitCode: 13,
            clusterName: "Calder"
        )
        #expect(text.hasPrefix("Password was rejected"))
        #expect(text.contains("password is wrong"))
        #expect(!text.contains("not a wrong password"))
    }

    @Test("Exit 13 wins over any text pattern in the raw output")
    func exitCodeThirteenTakesPrecedence() {
        // The helpers exit 13 only after the server re-prompts for the
        // password; whatever ssh printed afterwards is secondary.
        let text = MonitorService.explainSSHFailure(
            "Connection closed by 10.0.0.1 port 22",
            exitCode: 13,
            clusterName: "Calder"
        )
        #expect(text.hasPrefix("Password was rejected"))
    }

    @Test(
        "Server refusals before authentication are not a wrong password",
        arguments: [
            "Not allowed at this time",
            "kex_exchange_identification: Connection closed by remote host",
            "kex_exchange_identification: read: Connection reset by peer",
            "Connection closed by 10.41.22.7 port 22"
        ]
    )
    func closedBeforeAuthentication(raw: String) {
        let text = MonitorService.explainSSHFailure(raw, exitCode: 255, clusterName: "Calder")

        #expect(text.hasPrefix("Calder closed the connection before authentication."))
        #expect(text.contains("not a wrong password"))
        #expect(!text.contains("Password was rejected"))
        #expect(!text.contains("was rejected"))
    }

    @Test("ProxyCommand failure blames the rash jump tunnel")
    func unknownPort65535IsJumpTunnel() {
        // OpenSSH's spelling of "the ProxyCommand/-J hop died". It also
        // contains "Connection closed by", so the tunnel check must win.
        let text = MonitorService.explainSSHFailure(
            "Connection closed by UNKNOWN port 65535",
            exitCode: 255,
            clusterName: "Calder"
        )
        #expect(text.hasPrefix("The rash jump tunnel to Calder failed."))
        #expect(!text.contains("closed the connection before authentication"))
    }

    @Test("Permission denied is an authentication rejection")
    func permissionDeniedIsRejected() {
        let text = MonitorService.explainSSHFailure(
            "abcd1234@aire.leeds.ac.uk: Permission denied (publickey,keyboard-interactive).",
            exitCode: 255,
            clusterName: "AIRE"
        )
        #expect(text.hasPrefix("SSH authentication to AIRE was rejected."))
    }

    @Test("Permission denied followed by the disconnect is still a rejection")
    func permissionDeniedWithConnectionClosed() {
        // ssh commonly prints the disconnect after the auth failure; the
        // "closed before authentication" wording would wrongly reassure.
        let raw = """
        abcd1234@calder.leeds.ac.uk: Permission denied (keyboard-interactive).
        Connection closed by 10.41.22.7 port 22
        """
        let text = MonitorService.explainSSHFailure(raw, exitCode: 255, clusterName: "Calder")
        #expect(text.hasPrefix("SSH authentication to Calder was rejected."))
        #expect(!text.contains("not a wrong password"))
    }

    @Test(
        "Cluster-specific explanations name the cluster",
        arguments: [
            "Not allowed at this time",
            "Connection closed by UNKNOWN port 65535",
            "Permission denied (keyboard-interactive).",
            "Connection timed out during banner exchange",
            "Process timed out after 40s: /usr/bin/python3",
            "ssh: Could not resolve hostname calder.leeds.ac.uk: nodename nor servname provided",
            "something nobody has seen before"
        ]
    )
    func explanationNamesCluster(raw: String) {
        // With two clusters signing in back to back, an error that does not
        // say which cluster failed is ambiguous in the overview/menu bar.
        let text = MonitorService.explainSSHFailure(raw, exitCode: 255, clusterName: "Calder")
        #expect(text.contains("Calder"))
        #expect(!text.contains("AIRE"))
    }

    @Test("Raw output is appended verbatim, and omitted when empty")
    func rawOutputAppended() {
        let raw = "kex_exchange_identification: Connection closed by remote host"
        let withRaw = MonitorService.explainSSHFailure("  \(raw)\n", exitCode: 255, clusterName: "Calder")
        #expect(withRaw.hasSuffix("Raw SSH output:\n\(raw)"))

        let withoutRaw = MonitorService.explainSSHFailure("", exitCode: 255, clusterName: "Calder")
        #expect(withoutRaw == "SSH command to Calder failed.")
        #expect(!withoutRaw.contains("Raw SSH output"))
    }
}
