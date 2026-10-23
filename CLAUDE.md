# LegacyPodClaw

Native Objective-C AI assistant for jailbroken iOS 6 devices. Theos
project: one app plus four subprojects (`LegacyPodClawTweak`,
`LegacyPodClawPrefs`, `LegacyPodClawNC`, `LegacyPodClawDaemon`, the
daemon is `clawpodd`). `LegacyPodClawMCP/` holds the Python Mac-side
helpers.

Design record for this agent tooling: `.claude/plans/agent-tooling.md`.

## Target

- iOS 6.0 to 6.1.6, ARMv7 only, 256 MB RAM, app budget about 80 MB.
- Manual retain and release (`-fno-objc-arc`) in every target.
- No API newer than iOS 6. The SDK is 14.5, so a wrong API compiles
  and then crashes on the device.
- The code rules (API list, MRR, Logos, secret key lists, Makefiles)
  load from `.claude/rules/objc-ios6.md` when you touch a source file.
  Read that file before you plan a change to source code.

## Invariants

Do not break these. Each one closes a real defect.

1. All HTTPS goes through `CPTLSClient` (wolfSSL,
   `Frameworks/System/TLSClient.h`). For a one-shot request use `CPFetch`
   (`Frameworks/System/HTTPFetch.h`); it uses `CPTLSClient` for https and
   refuses schemes other than http and https. Do not add a new HTTPS call
   through `NSURLConnection`. The iOS 6 TLS stack cannot reach modern
   servers safely.
2. Secrets (API keys, tokens, passwords) go through `CPSecretStore`
   (`Frameworks/System/SecretStore.h`). It keeps them in the keychain
   through `clawpodd`. Never write a secret to the prefs plist.
3. Every tool call goes through `OCToolDispatcher`
   (`Frameworks/Tools/ToolDispatcher.h`). It validates the input,
   applies the guardrails, asks the user before a risky tool and
   enforces the timeout. Do not call a tool handler directly.

## Build

Builds do not run on Linux. They run on Matt's Mac mini through the
`mac` MCP tools. Use the `mac-build` skill (`/mac-build <name>`). Do not
say that a change builds until the skill reports `"status": "ok"`.

## Review

Before a commit that changes `.m`, `.h`, `.xm` or a Makefile, run the
`ios6-review` skill (`/ios6-review [base]`). Fix every `blocker` and
`high` finding.

## House rules

- Write prose (replies, docs, PR bodies, commit messages) in ASD-STE100
  Simplified Technical English. The user-level `STE-100` output style
  holds the rules.
- Code comments: lowercase, one line, say why.
- Pin exact versions for any package or tool you add.
- Commit only as the configured git user. Load the user-level
  `no-claude-help` skill before you write a commit message or PR body.
- Run `export SSH_AUTH_SOCK=/tmp/fleet-ssh-agent.sock` before
  `git push`.
- Tell Matt about every defect you see, also when it is not part of the
  task. Name it and ask whether to fix it.
- Do not edit `Vendor/` (wolfSSL and its build). It is pinned.
