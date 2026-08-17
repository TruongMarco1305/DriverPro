//
//  PromptCoordinatorTests.swift
//  DPPresentationTests
//

import DPCore
import DPServices
import Foundation
import Testing
@testable import DPPresentation

@Suite("PromptCoordinator")
@MainActor
struct PromptCoordinatorTests {

    private let host = RemoteHost(protocolIdentifier: .sftp, hostname: "example.com", port: 22, username: "duck")

    private var challenge: HostKeyChallenge {
        HostKeyChallenge(hostname: "example.com", port: 22, keyType: "ssh-ed25519",
                         fingerprint: "SHA256:abc", trust: .unknown)
    }

    /// Waits for a question to appear, so a test never races the task that asks it.
    private func waitForPending(_ coordinator: PromptCoordinator) async throws {
        for _ in 0..<200 where coordinator.pending == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(coordinator.pending != nil, "no question arrived")
    }

    @Test("A host key answer resumes the waiting caller")
    func hostKeyAnswerResumes() async throws {
        let coordinator = PromptCoordinator()

        // The engine's side: suspends until answered. If the continuation were dropped, this task would
        // never finish and the test would time out rather than fail — which is the failure mode worth
        // guarding against.
        let asking = Task { await coordinator.askHostKey(challenge, for: host) }

        try await waitForPending(coordinator)
        coordinator.answerHostKey(.acceptAndStore)

        #expect(await asking.value == .acceptAndStore)
        #expect(coordinator.pending == nil)
    }

    @Test("A credential answer resumes the waiting caller")
    func credentialAnswerResumes() async throws {
        let coordinator = PromptCoordinator()
        let request = CredentialRequest(host: host, reason: .initial)

        let asking = Task { await coordinator.askCredentials(request) }
        try await waitForPending(coordinator)
        coordinator.answerCredentials(.password(username: "duck", password: "hunter2"))

        let supplied = try #require(await asking.value)
        #expect(supplied.username == "duck")
    }

    @Test("Dismissing counts as a refusal, not a dropped question")
    func dismissMeansCancel() async throws {
        // A closed sheet has to answer something. Refusing is the safe reading: the user did not consent.
        let coordinator = PromptCoordinator()
        let asking = Task { await coordinator.askHostKey(challenge, for: host) }

        try await waitForPending(coordinator)
        coordinator.dismiss()

        #expect(await asking.value == .reject)
    }

    @Test("Dismissing a credential question supplies nothing")
    func dismissCredentials() async throws {
        let coordinator = PromptCoordinator()
        let asking = Task { await coordinator.askCredentials(CredentialRequest(host: host, reason: .initial)) }

        try await waitForPending(coordinator)
        coordinator.dismiss()

        #expect(await asking.value == nil)
    }

    @Test("A second question queues rather than replacing the first")
    func questionsQueue() async throws {
        // A connection asks about the host key and then for a password. Replacing the first would
        // strand its continuation, and the connection would hang with no error to show.
        let coordinator = PromptCoordinator()

        let hostKeyTask = Task { await coordinator.askHostKey(challenge, for: host) }
        try await waitForPending(coordinator)

        let credentialsTask = Task {
            await coordinator.askCredentials(CredentialRequest(host: host, reason: .initial))
        }
        // Let the second question land behind the first.
        try await Task.sleep(for: .milliseconds(20))
        #expect(coordinator.pendingCount == 2)

        guard case .hostKey? = coordinator.pending else {
            Issue.record("the first question should still be the one on screen")
            return
        }

        coordinator.answerHostKey(.acceptOnce)
        #expect(await hostKeyTask.value == .acceptOnce)

        try await waitForPending(coordinator)
        guard case .credentials? = coordinator.pending else {
            Issue.record("the queued question should now be showing")
            return
        }
        coordinator.answerCredentials(nil)
        #expect(await credentialsTask.value == nil)
        #expect(coordinator.pendingCount == 0)
    }

    @Test("Answering with the wrong kind is ignored")
    func mismatchedAnswerIgnored() async throws {
        // A stale view must not be able to resume a continuation that expects a different type.
        let coordinator = PromptCoordinator()
        let asking = Task { await coordinator.askHostKey(challenge, for: host) }
        try await waitForPending(coordinator)

        coordinator.answerCredentials(.password(username: "duck", password: "x"))
        #expect(coordinator.pendingCount == 1, "the host key question should still be waiting")

        coordinator.answerHostKey(.acceptOnce)
        #expect(await asking.value == .acceptOnce)
    }

    @Test("dismissAll releases every waiting caller")
    func dismissAllReleasesEverything() async throws {
        // Closing a window mid-handshake must not leave continuations suspended forever.
        let coordinator = PromptCoordinator()

        let first = Task { await coordinator.askHostKey(challenge, for: host) }
        try await waitForPending(coordinator)
        let second = Task { await coordinator.askCredentials(CredentialRequest(host: host, reason: .initial)) }
        try await Task.sleep(for: .milliseconds(20))

        coordinator.dismissAll()

        #expect(await first.value == .reject)
        #expect(await second.value == nil)
        #expect(coordinator.pendingCount == 0)
    }

    @Test("Preloaded credentials are used without showing a sheet")
    func preloadedCredentialsSkipTheSheet() async throws {
        // The connection sheet already collected a password; asking again over the top of it would be
        // absurd.
        let coordinator = PromptCoordinator()
        coordinator.preload(.password(username: "duck", password: "hunter2"), for: host)

        let supplied = await coordinator.askCredentials(CredentialRequest(host: host, reason: .initial))

        #expect(supplied?.username == "duck")
        #expect(coordinator.pendingCount == 0, "no sheet should have been raised")
    }

    @Test("Preloaded credentials are consumed, so a retry reaches the user")
    func preloadIsConsumed() async throws {
        // If the server refuses them, showing the same password again would loop forever.
        let coordinator = PromptCoordinator()
        coordinator.preload(.password(username: "duck", password: "wrong"), for: host)

        _ = await coordinator.askCredentials(CredentialRequest(host: host, reason: .initial))

        let asking = Task {
            await coordinator.askCredentials(CredentialRequest(host: host, reason: .initial))
        }
        try await waitForPending(coordinator)
        coordinator.dismiss()
        #expect(await asking.value == nil)
    }

    @Test("A retry always reaches the user, even with something preloaded")
    func retryIgnoresPreload() async throws {
        let coordinator = PromptCoordinator()
        coordinator.preload(.password(username: "duck", password: "wrong"), for: host)

        let asking = Task {
            await coordinator.askCredentials(
                CredentialRequest(host: host, reason: .retry(afterFailure: "bad password"))
            )
        }
        try await waitForPending(coordinator)
        coordinator.answerCredentials(.password(username: "duck", password: "right"))

        #expect(await asking.value?.method != nil)
    }

    @Test("Answering when nothing is pending does nothing")
    func answeringIdleIsSafe() {
        let coordinator = PromptCoordinator()
        coordinator.answerHostKey(.acceptOnce)
        coordinator.answerCredentials(nil)
        coordinator.dismiss()
        #expect(coordinator.pendingCount == 0)
    }
}
