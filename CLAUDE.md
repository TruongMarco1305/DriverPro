# DriverPro — working agreement

DriverPro is a native macOS server and cloud storage browser in the spirit of Cyberduck, written from
scratch in Swift. Cyberduck itself is GPL-licensed Java/.NET; **no Cyberduck code is copied here**. Its
observable behaviour is the specification, nothing more.

---

## Rule 1 — Document everything, as it lands

**The author of this project is learning Swift.** An undocumented diff teaches them nothing and cannot be
reviewed meaningfully. Documentation is therefore part of the work, not a cleanup pass afterwards.

No code lands without its explanation:

- **`///` doc comments on every public type, method, and property.** Say what it does, what the parameters
  mean, and what it throws. These surface in Xcode's Quick Help, so they are the primary way the codebase
  gets explored.
- **Comments explain _why_, not _what_.** `// increment i` is noise; `// SFTP servers may return a short
  read before EOF, so we loop rather than trusting one call` is the point.
- **Keep them short.** One or two sentences. A doc comment is a one-line summary plus its parameters;
  expand only where the behaviour is genuinely surprising. If an explanation needs a paragraph it
  belongs in `docs/` — put it there and link to it. A comment longer than the code it describes is a
  smell, and a wall of prose above every declaration stops being read, which defeats the point.
- **Swift idioms get a note where first used.** The first `actor`, the first `AsyncThrowingStream`, the
  first `@MainActor` hop each earn a sentence at the point of use, with the fuller write-up in
  `docs/swift-notes.md`.
- **`// MARK:` sectioning** in any file longer than ~100 lines.
- **Every target carries a header doc comment** stating its single responsibility and what it may not import.
- **Explain new concepts in conversation too** — when a Swift feature appears that hasn't been seen before,
  explain it in the reply rather than leaving it to be inferred from the diff.

A stale doc is a bug. A milestone is not done until its docs match what shipped.

### Where documentation lives

| Path | Contents |
|---|---|
| `docs/architecture.md` | Layer diagram; how a click in the browser becomes bytes on the wire. |
| `docs/swift-notes.md` | **The learning log.** Every non-obvious Swift feature the code uses, explained. |
| `docs/style.md` | Naming, file layout, error handling, `struct` vs `class` vs `actor`, testing conventions. |
| `docs/packages.md` | Every dependency: what, why, what replacing it would cost, license. |
| `docs/decisions/NNN-*.md` | ADRs for choices with real consequences. Context, decision, consequences. |
| `docs/milestones/MN-walkthrough.md` | A guided tour at each milestone's close. |

---

## Rule 2 — The layering boundary is absolute

```
App/  (SwiftUI)  ──depends on──▶  DriverProKit  ──▶  network
```

`Packages/DriverProKit` **must never import SwiftUI or AppKit.** That boundary is what allows the entire
engine to be built and tested from the terminal with `swift test`, with no app launch and no Xcode UI.

Within the Kit:

- `DPCore` — model types and the protocol-agnostic `Session` abstraction. Depends on nothing of ours.
- `DPCredentials` — Keychain, SSH keys, `known_hosts`.
- `DPBookmarks` — bookmark storage and `.duck` interchange.
- `DPTransfer` — the transfer queue engine.
- `DPProtocol*` — one target per protocol. These depend on `DPCore`; **nothing depends on them** except
  the composition root in the app. Protocol code never touches the UI; it awaits `SessionDelegate`.

---

## Rule 3 — Capabilities, not assumptions

Backends differ in kind, not just in detail. S3 has no rename (it is copy + delete), no POSIX permissions,
and no true empty directories. FTP has no dependable `stat`.

`SessionCapabilities` is load-bearing: the UI reads it to enable or disable commands, and the transfer
engine reads it to choose a strategy. Never assume an operation exists — ask.

---

## Build and test

```sh
# The engine — no Xcode required
cd Packages/DriverProKit && swift build && swift test

# The app
xcodegen generate && xcodebuild -scheme DriverPro -destination 'platform=macOS' build
```

`DriverPro.xcodeproj` is **generated** from `project.yml` and is gitignored. Edit `project.yml`, never the
project file.

## Lint, format, and hooks

```sh
brew install swiftlint swiftformat

# Once per clone — core.hooksPath is local config and is not carried by a fetch.
git config core.hooksPath Scripts

Scripts/lint-and-check.sh             # formatting, lint, unit tests
Scripts/lint-and-check.sh --fix       # rewrite what can be rewritten, then check
```

`Scripts/lint-and-check.sh` is the single source of truth for "is this code clean?". Everything else
calls it rather than repeating it, so CI and your machine cannot disagree.

| | Runs | Cost |
|---|---|---|
| `Scripts/pre-commit` | `lint-and-check.sh --staged --skip-tests` | ~0.5 s |
| `Scripts/pre-push` | `lint-and-check.sh` + the rule 2 layering checks | ~2 s warm |
| `Scripts/ci.sh` | `lint-and-check.sh`, plus tool versions and no skips | ~2 s warm |
| `Scripts/verify.sh` | all of the above **plus** the app build and the documentation rule | minutes |

The unit suite is deliberately not in `pre-commit`. A hook that runs 590 tests on every commit is a hook
that gets `--no-verify`d within a week, and a bypassed hook checks nothing.

Everything must run from the **repo root** — the scripts `cd` there themselves. SwiftLint reads
`.swiftlint.yml` from the working directory; started anywhere else it silently falls back to its defaults
and walks `.build`, which is every vendored dependency.

`git commit --no-verify` and `git push --no-verify` bypass the hooks. A deliberate act, not a shortcut.

Where a lint rule and `docs/style.md` disagree, the document wins and the rule gets configured, with the
reason written beside it. See `docs/decisions/018-lint-format-and-git-hooks.md`.

---

## Milestones

| | Scope |
|---|---|
| **M1** | Foundation + SFTP vertical slice: connect, browse, download, upload, bookmarks, Keychain. |
| **M2** | Browser and queue maturity: recursive transfers, resume, drag-and-drop, Quick Look, `.duck` I/O. |
| **M3** | WebDAV / Nextcloud — the first real test that the abstraction is protocol-agnostic. |
| **M4** | S3-compatible — exercises the capability system hardest. |
| **M5** | FTP / FTPS — hand-built on swift-nio, deliberately last. |
