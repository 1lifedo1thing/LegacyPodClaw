---
name: mac-build
description: >-
  Use this skill when you must compile, link or package LegacyPodClaw,
  check that a change builds, get the .deb, or find Theos compile or
  link errors ("does it build", "make package", "build the tweak",
  "Undefined symbols"). Builds cannot run on this Linux host; this
  skill runs them on Matt's Mac mini through the mac MCP tools. Use it
  before you claim that any Objective-C, Logos or Makefile change
  works. It does not install on a device, publish a release or deploy
  a server.
argument-hint: "[build-name]"
allowed-tools: mcp__mac__mac_status mcp__mac__mac_put Bash(.claude/skills/mac-build/scripts/pack.sh *)
---

# mac-build: build LegacyPodClaw on the Mac mini

Targets: Claude Code. Reason: the build uses the `mac` MCP server tools
(`mcp__mac__mac_status`, `mcp__mac__mac_put`, `mcp__mac__mac_run`).
Design: `.claude/plans/agent-tooling.md` (pattern A9 supervised
execution). Reload it before you change this skill.

The scripts decide the result. Do not read the build log yourself to
decide "it builds". Do not report success unless the remote script
prints `"status": "ok"`.

## Scripts

- `scripts/pack.sh <name> [repo_root]` runs on this host. It writes the
  tarball (without `docs`, `.git`, `.theos`, `packages`, `.claude`) and
  prints JSON with the tarball path.
- `scripts/remote-build.sh <name>` runs on the Mac. It clears
  `~/lpc-build-<name>`, extracts the tarball, copies
  `Vendor/libwolfssl.a` and `Vendor/wolfssl` from `~/lpc-build`,
  removes `.theos` dirs, runs `THEOS=~/theos make package
  FINALPACKAGE=1` and prints JSON:
  `{"status","make_exit","errors","undefined","deb","log"}`, plus
  `tail` (the last 15 log lines) on a failure.

Both scripts print `--help`.

## Procedure

1. Pick the build name: `[a-z0-9][a-z0-9-]{0,39}`, for example the
   last part of the branch name (`refactor/gateway-dispatch` gives
   `gateway-dispatch`). Do not use a name that another session uses
   at the same time. If `$ARGUMENTS` is set, use it.
2. Call `mcp__mac__mac_status`. If the tunnel is down, stop and give
   Matt the command it prints. Do not try another route.
3. From the repo root, run:
   `.claude/skills/mac-build/scripts/pack.sh <name>`
   Keep the `tarball` value.
4. Call `mcp__mac__mac_run` with
   `mkdir -p ~/lpc-build-<name> && echo $HOME`. Keep the home path.
5. Call `mcp__mac__mac_put` two times:
   - `tarball` to `<home>/lpc-build-<name>/lpc.tgz`
   - `.claude/skills/mac-build/scripts/remote-build.sh` to
     `<home>/lpc-build-<name>/remote-build.sh`
6. Call `mcp__mac__mac_run` with
   `bash ~/lpc-build-<name>/remote-build.sh <name>`,
   `timeout_seconds: 600`. Keep the default login shell.
7. Read the JSON.
   - `status` is `ok`: report the `deb` path. Done.
   - `status` is `fail`: each `errors` and `undefined` entry starts with
     the log line number. For more context, call `mcp__mac__mac_run`
     with `sed -n '<from>,<to>p' <log>`. Fix the cause in the local
     tree, then go to step 3.
   - `status` is `fail` but `errors` and `undefined` are empty: read
     `tail`. A tool failure (for example `ldid: command not found`) is
     a Mac setup problem. Report it to Matt. Do not change the code.
8. Stop after three failed builds in a row. Report the remaining
   `errors` and `undefined` lines to Matt and ask how to continue.

## Result template

```
Build <name>: ok | fail
deb: <path on the Mac or none>
errors: <count>  undefined: <count>
<one line for each remaining error: file:line message>
```

## Gotchas

- `Undefined symbols` with `_OBJC_CLASS_$_X` usually means a new `.m`
  file is missing from a `_FILES` list in a Makefile.
- An iOS 7+ API often compiles without error, because the SDK is 14.5.
  A clean build does not prove iOS 6 compatibility. Run `ios6-review`
  for that.
- `~/lpc-build` holds the shared vendor copy. Never build in it and
  never delete it.
