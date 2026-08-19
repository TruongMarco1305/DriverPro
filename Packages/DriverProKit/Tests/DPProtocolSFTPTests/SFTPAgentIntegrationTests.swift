//
//  SFTPAgentIntegrationTests.swift
//  DPProtocolSFTPTests
//

import DPCore
import DPCredentials
import DPTestSupport
import Foundation
import Testing
@testable import DPProtocolSFTP

/// `ssh-agent` authentication against a real SSH server, through a real agent.
///
/// This is the only test that exercises the whole agent path at once: our wire format talking to OpenSSH's
/// agent, our NIOSSH custom key carrying its signature, and a real `sshd` deciding whether to believe it. The
/// hermetic suites prove each piece; only this proves they compose.
///
/// Gated separately from the rest — `script.sh` starts a container, but it will not start an agent or put
/// your keys in it. Run it deliberately:
///
/// ```sh
/// eval "$(ssh-agent -s)"
/// ssh-add infra/integration/keys/id_ed25519
/// DP_AGENT_TESTS=1 infra/integration/script.sh
/// ```
///
/// **These tests never touch `~/.ssh/known_hosts`** — each gets a throwaway file.
@Suite(
    "SFTP ssh-agent integration",
    .enabled(if: AgentIntegrationConfig.isEnabled,
             "run with DP_AGENT_TESTS=1 and a key loaded in ssh-agent"),
    .serialized
)
struct SFTPAgentIntegrationTests {

    private func makeSession() -> SFTPSession {
        SFTPSession(
            host: RemoteHost(
                protocolIdentifier: .sftp,
                hostname: IntegrationConfig.host ?? "localhost",
                port: IntegrationConfig.port,
                username: IntegrationConfig.user
            ),
            knownHosts: KnownHostsStore(
                fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("dp-known_hosts-\(UUID().uuidString)")
            )
        )
    }

    @Test("The agent is reachable and holds at least one key")
    func agentIsReachable() throws {
        // Checked separately so that a missing agent fails here with something readable, rather than
        // surfacing as a puzzling authentication failure in the tests below.
        let client = try #require(SSHAgentClient(), "SSH_AUTH_SOCK is not set")
        #expect(try !client.identities().isEmpty, "add a key with `ssh-add`")
    }

    @Test("A key held by the agent logs in and lists a directory")
    func connectsThroughTheAgent() async throws {
        let session = makeSession()
        defer { Task { await session.disconnect() } }

        try await session.connect(
            credentials: .sshAgent(username: IntegrationConfig.user),
            delegate: ScriptedDelegate(hostKeyDecision: .acceptOnce, credentials: nil)
        )

        // Listing, not just connecting: authentication succeeding while the SFTP subsystem failed to open
        // would otherwise look like a pass.
        _ = try await session.list(RemotePath(IntegrationConfig.basePath))
    }

    @Test("Signing through the agent does not stall other work on the connection")
    func signingDoesNotStallTransfers() async throws {
        // The agent signs on an event loop thread, synchronously — see `AgentSignedKey`. An agent connection
        // therefore gets its own single-threaded group. What this checks is the consequence: two agent
        // connections, opened at once, both complete rather than one waiting behind the other's signing.
        let first = makeSession()
        let second = makeSession()
        defer {
            Task { await first.disconnect() }
            Task { await second.disconnect() }
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for session in [first, second] {
                group.addTask {
                    try await session.connect(
                        credentials: .sshAgent(username: IntegrationConfig.user),
                        delegate: ScriptedDelegate(hostKeyDecision: .acceptOnce, credentials: nil)
                    )
                    _ = try await session.list(RemotePath(IntegrationConfig.basePath))
                }
            }
            try await group.waitForAll()
        }
    }

}

/// Whether the agent tests should run.
///
/// Two conditions, both deliberate. `DP_AGENT_TESTS` because loading a key into an agent is something a
/// person does on purpose, and a suite that silently used whatever happened to be in the developer's agent
/// would be unpredictable. And a server, because there is nothing to log in to otherwise.
enum AgentIntegrationConfig {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["DP_AGENT_TESTS"] == "1" && IntegrationConfig.isEnabled
    }
}
