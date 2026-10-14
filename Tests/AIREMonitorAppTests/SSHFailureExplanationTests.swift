import HPCCore
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

    @Test("Exit 15 means Duo was not approved — never a password problem")
    func exitCodeFifteenIsDuoNotApproved() {
        // The helpers exit 15 only after the password was accepted; the raw
        // text may well contain "Permission denied" from the ssh that ended.
        let text = MonitorService.explainSSHFailure(
            "abcd1234@calder.leeds.ac.uk: Permission denied (keyboard-interactive).",
            exitCode: 15,
            clusterName: "Calder"
        )
        #expect(text.hasPrefix(
            "Calder: the Duo push was declined or timed out. Your password was accepted. Approve the push on your phone and connect again."
        ))
        let advice = text.components(separatedBy: "Raw SSH output:").first ?? text
        #expect(!advice.lowercased().contains("lock"))
        #expect(!advice.contains("re-enter"))
        #expect(!advice.contains("wrong"))
        #expect(!advice.contains("rejected"))
    }

    @Test("Exit 15 maps to duoNotApproved on both legs, naming the jump host on the jump leg")
    func exitCodeFifteenErrorBothLegs() {
        let target = MonitorService.loginError("duo-denied", exitCode: 15, clusterName: "AIRE")
        guard case .duoNotApproved(let targetMessage) = target else {
            Issue.record("expected duoNotApproved, got \(target)")
            return
        }
        #expect(targetMessage.hasPrefix("AIRE: the Duo push was declined"))

        let jump = MonitorService.loginError(
            "duo-timeout",
            exitCode: 15,
            clusterName: "rash.leeds.ac.uk (jump host)",
            isJumpLeg: true
        )
        guard case .duoNotApproved(let jumpMessage) = jump else {
            Issue.record("expected duoNotApproved on the jump leg, got \(jump)")
            return
        }
        #expect(jumpMessage.hasPrefix("rash.leeds.ac.uk (jump host): the Duo push was declined"))

        // The other jump-leg codes keep their meaning.
        if case .passwordRejected = MonitorService.loginError("x", exitCode: 13, clusterName: "rash", isJumpLeg: true) {} else {
            Issue.record("jump-leg 13 must stay a rejected password")
        }
        if case .jumpHostFailed = MonitorService.loginError("x", exitCode: 1, clusterName: "rash", isJumpLeg: true) {} else {
            Issue.record("other jump-leg failures stop the queue as jumpHostFailed")
        }
    }

    @Test("Starter exit 5: the existing session was left running, and Reconnect is the way to replace it")
    func exitCodeFiveLeftRunning() {
        let raw = "The existing AIRE session answers on its control socket, but a check command through it did not come back within 15 s."
        let error = MonitorService.loginError(raw, exitCode: MonitorService.existingSessionUnresponsiveExitCode, clusterName: "AIRE")
        guard case .existingSessionUnresponsive(let message) = error else {
            Issue.record("expected existingSessionUnresponsive, got \(error)")
            return
        }
        #expect(message.hasPrefix("The existing AIRE session did not answer in time, so it was left running."))
        #expect(message.contains("Nothing on it was closed and no password was sent"))
        #expect(message.contains("Choose Reconnect… to replace it now"))
        #expect(message.hasSuffix("Raw SSH output:\n\(raw)"))
        #expect(!message.lowercased().contains("password was rejected"))
        #expect(error.errorDescription == message)

        // Only the target starter means this. The jump leg keeps its own
        // rules, and explainSSHFailure (also used for collector and scancel
        // failures, where a remote exit 5 means something else) gives 5 no
        // special meaning.
        if case .jumpHostFailed = MonitorService.loginError("x", exitCode: 5, clusterName: "rash", isJumpLeg: true) {} else {
            Issue.record("a jump-leg exit 5 is an ordinary jump-host failure")
        }
        #expect(!MonitorService.explainSSHFailure("x", exitCode: 5, clusterName: "AIRE").contains("Reconnect"))
    }

    @Test("A successful sign-in counts as a checked password only when a leg says it sent one")
    func passwordVerification() {
        let reusedTarget = """
        HPC-STATUS: reusing the existing AIRE session
        HPC-STATUS: connected to AIRE
        auth_ok|login1.aire|abcd1234|2026-10-13T12:00:00+01:00
        """
        let freshTarget = """
        HPC-STATUS: starting AIRE authentication
        HPC-STATUS: password sent (AIRE)
        HPC-STATUS: waiting for Duo approval on your phone (AIRE)
        HPC-STATUS: connected to AIRE
        """
        let reusedJump = """
        HPC-STATUS: reusing the shared jump-host session
        HPC-STATUS: connected to the shared jump host
        """
        let freshJump = """
        HPC-STATUS: starting jump host authentication
        HPC-STATUS: password sent (jump host)
        HPC-STATUS: waiting for Duo approval on your phone (jump host)
        """
        #expect(!MonitorService.passwordWasVerified(jumpLegOutput: nil, targetLegOutput: reusedTarget, clusterName: "AIRE"))
        #expect(MonitorService.passwordWasVerified(jumpLegOutput: nil, targetLegOutput: freshTarget, clusterName: "AIRE"))
        #expect(!MonitorService.passwordWasVerified(jumpLegOutput: reusedJump, targetLegOutput: reusedTarget, clusterName: "AIRE"))
        #expect(MonitorService.passwordWasVerified(jumpLegOutput: freshJump, targetLegOutput: reusedTarget, clusterName: "AIRE"))
        #expect(MonitorService.passwordWasVerified(jumpLegOutput: reusedJump, targetLegOutput: freshTarget, clusterName: "AIRE"))
        // Another cluster's line proves nothing about this sign-in.
        #expect(!MonitorService.passwordWasVerified(jumpLegOutput: nil, targetLegOutput: "HPC-STATUS: password sent (Calder)", clusterName: "AIRE"))
    }

    @Test("Exit 124 is a login timeout whatever the partial output says")
    func exitCode124IsTimeout() {
        let text = MonitorService.explainSSHFailure(
            "Connection closed by 10.41.22.7 port 22",
            exitCode: 124,
            clusterName: "Calder"
        )
        #expect(text.hasPrefix("The Calder login timed out."))
        #expect(!text.contains("closed the connection before authentication"))
        if case .loginTimedOut = MonitorService.loginError("x", exitCode: 124, clusterName: "Calder") {} else {
            Issue.record("124 must map to loginTimedOut")
        }
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
