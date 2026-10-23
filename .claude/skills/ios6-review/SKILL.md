---
name: ios6-review
description: >-
  Use this skill to check LegacyPodClaw Objective-C, header or Logos
  (.xm) changes for iOS 6 compatibility before a commit, a push or a
  PR. It finds iOS 7+ APIs, ARC-only code (weak refs), unbalanced
  retain/release, HTTPS outside CPTLSClient, secrets outside
  CPSecretStore, tool calls that skip OCToolDispatcher, the Logos
  "%orig; return;" one-line trap, secret key lists out of sync and
  new .m files missing from a Makefile. Use it also when a change
  builds but crashes on the device, or when asked "will this run on
  iOS 6". It is read-only. It is not a general code review, a style
  review or a security audit, and it does not build (use mac-build).
argument-hint: "[base-ref | --all]"
context: fork
agent: general-purpose
model: sonnet
background: false
allowed-tools: Read Grep Glob Bash(.claude/skills/ios6-review/scripts/scan.sh *) Bash(git diff *) Bash(git log *) Bash(git show *)
---

# ios6-review: iOS 6 compatibility check

Targets: Claude Code. Reason: runs as a forked skill with a fresh
context. Design: `.claude/plans/agent-tooling.md` (S4 validation gate
with an S7 scan). Rubric: `.claude/rules/objc-ios6.md` plus the three
invariants in `CLAUDE.md`. Do not copy the rubric here; read it.

You are read-only. Do not edit, stage or commit any file.

## Procedure

1. Run the scan from the repo root. Pass `$ARGUMENTS` if it is set:
   `.claude/skills/ios6-review/scripts/scan.sh $ARGUMENTS`
   Exit code 1 only means that the scan found a blocker or high line.
   Exit code 2 means bad use: report it and stop.
2. Read `.claude/rules/objc-ios6.md` and the "Invariants" section of
   `CLAUDE.md`.
3. Read the diff for the same range: `git diff <base> -- '*.m' '*.h'
   '*.xm' '*Makefile'` (the scan prints the range). For `--all`, read
   only the files that the scan flags.
4. For each scan finding, confirm or dismiss it. Dismiss only with a
   reason you can point to, for example "inside a string literal" or
   "plain HTTP to the LAN music proxy, comment says why".
5. Look for rule breaks that a grep cannot see:
   - retain, copy or alloc with no matching release; ivar not released
     in `dealloc`; block stored without `copy`
   - a new `.m` file that is not in a `_FILES` list
   - an HTTPS request built through any path other than `CPTLSClient`
   - a new secret key name, or a secret written to the prefs plist
   - a tool handler called without `OCToolDispatcher`
   - any API you cannot confirm exists on iOS 6.1. Mark it `medium`
     and say "not confirmed" in place of a guess.
6. Return only the receipt below. One finding per problem. Each `fix`
   is one sentence in Simplified Technical English.

## Receipt (return exactly this JSON, nothing else)

```json
{
  "verdict": "pass",
  "range": "<range from the scan>",
  "findings": [
    {"sev": "blocker", "rule": "api", "file": "Frameworks/X.m", "line": 12,
     "fix": "Use dateByAddingComponents:toDate:options: in place of dateByAddingUnit:."}
  ],
  "notes": ""
}
```

- `verdict` is `fail` when any finding is `blocker` or `high`, else
  `pass`.
- `sev`: `blocker` (crash or build break on iOS 6), `high` (breaks an
  invariant), `medium` (not confirmed, or a leak), `low` (style).
- `rule`: one of `api`, `mrr`, `logos`, `secret`, `tls`, `dispatch`,
  `build`, `style`.
- `notes`: one line, or empty. Name pre-existing problems outside the
  range here so that the caller can tell Matt.
