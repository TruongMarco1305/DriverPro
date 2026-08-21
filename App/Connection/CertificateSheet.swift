//
//  CertificateSheet.swift
//  DriverPro
//

import DPCore
import DPPresentation
import SwiftUI

/// Asks whether to trust a certificate the system will not.
///
/// Deliberately the twin of ``HostKeySheet``, because it is the same question — *this server is not
/// vouched for by anyone; do you know it?* — and someone who has answered one should recognise the
/// other immediately.
///
/// An unknown certificate is routine: every self-hosted server has one, and the honest thing is to show
/// it and let the user decide. A **changed** certificate is not routine. It is red, it shows both
/// fingerprints, and it has no default button, so accepting is a deliberate click rather than a
/// reflexive Return.
struct CertificateSheet: View {

    @Environment(AppEnvironment.self) private var environment

    let challenge: CertificateChallenge
    let host: RemoteHost

    private var hasChanged: Bool {
        if case .changed = challenge.trust { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(
                hasChanged ? "The server's certificate has changed" : "Untrusted certificate",
                systemImage: hasChanged ? "exclamationmark.triangle.fill" : "lock.trianglebadge.exclamationmark"
            )
            .font(.headline)
            .foregroundStyle(hasChanged ? Color.red : Color.primary)

            Text(explanation)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    fingerprintRow("Fingerprint", challenge.fingerprint)
                    if case .changed(let previous) = challenge.trust {
                        Divider()
                        fingerprintRow("Previously", previous)
                    }
                    Divider()
                    detailRow("Issued to", challenge.subject)
                    detailRow("Issued by", challenge.issuer)
                    if let expiresAt = challenge.expiresAt {
                        detailRow("Expires", expiresAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                .font(.callout)
            }

            if !challenge.problems.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    // Why, in sentences. "Untrusted certificate" alone tells nobody what to do about it,
                    // while "it has expired" tells them to renew it.
                    ForEach(sortedProblems, id: \.self) { problem in
                        Label(problem.explanation, systemImage: "info.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            HStack {
                Button("Reject", role: .cancel) { answer(.reject) }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Accept Once") { answer(.acceptOnce) }
                Button("Trust Always") { answer(.acceptAndStore) }
                    // Only when it is not the serious case: a changed certificate must never be one
                    // Return away from being trusted forever.
                    .keyboardShortcut(hasChanged ? .none : .defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var explanation: String {
        if case .changed = challenge.trust {
            return """
            The certificate offered by “\(challenge.hostname)” is not the one you trusted before. This \
            happens when a server's certificate is renewed — but it is also what an impersonation looks \
            like. Only continue if you were expecting it to change.
            """
        }
        return """
        “\(challenge.hostname)” presented a certificate that this Mac cannot verify. That is normal for a \
        server you run yourself. Check the fingerprint against the server before accepting it.
        """
    }

    /// A stable order, so the same certificate always reads the same way.
    private var sortedProblems: [CertificateChallenge.Problem] {
        CertificateChallenge.Problem.allCases.filter { challenge.problems.contains($0) }
    }

    private func fingerprintRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).foregroundStyle(.secondary)
            Text(value)
                .monospaced()
                .textSelection(.enabled)      // so it can be pasted next to what the server reports
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    private func answer(_ decision: CertificateDecision) {
        environment.prompt.answerCertificate(decision)
    }
}
