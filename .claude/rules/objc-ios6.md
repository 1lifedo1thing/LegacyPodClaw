---
paths:
  - "**/*.{m,h,xm}"
  - "**/Makefile"
---

# Objective-C and Logos rules for iOS 6 (ARMv7, MRR)

Targets: Claude Code (path-scoped rule). Source of truth for these rules:
this file. Plan: `.claude/plans/agent-tooling.md`. The project-wide
invariants (TLS, secrets, tool dispatch) are in `CLAUDE.md`.

The code runs on iOS 6.0 to 6.1.6, ARMv7, 256 MB RAM. The SDK in the
Makefile is 14.5, so the compiler accepts many APIs that do not exist
on the device. A wrong API compiles, links and then crashes with
"unrecognized selector" or a missing symbol on the device. Check the
availability of each API you add. If you are not sure, find an iOS 6
alternative or ask Matt.

The rule ids below are the ids that `ios6-review` reports.

## API (rule id `api`)

Do not use an API that is newer than iOS 6.1. Known traps and the
iOS 6 replacement:

| Do not use | Available from | Use on iOS 6 |
|---|---|---|
| `NSURLSession` and all its types | iOS 7 | `CPTLSClient` for HTTPS (see `CLAUDE.md`) |
| `base64EncodedStringWithOptions:`, `initWithBase64EncodedString:options:` | iOS 7 | a static helper like `OCBase64Encode` in `Frameworks/WebSocket/WebSocket.m` |
| `dateByAddingUnit:value:toDate:options:` | iOS 8 | `dateByAddingComponents:toDate:options:` with `NSDateComponents` |
| `NSCalendarUnitMinute` and other `NSCalendarUnit*` names | iOS 8 | `NSMinuteCalendarUnit` and the other old names |
| `containsString:`, `localizedCaseInsensitiveContainsString:` | iOS 8 | `rangeOfString:` (with `NSCaseInsensitiveSearch`) and check `location != NSNotFound` |
| `-[NSScanner scanUnsignedLongLong:]` | iOS 7 | `scanLongLong:`, or `strtoull` on a digit string you checked |
| `localizedStandardContainsString:`, `localizedStandardRangeOfString:` | iOS 9 | `rangeOfString:options:` with `NSCaseInsensitiveSearch \| NSDiacriticInsensitiveSearch` |
| `localizedUppercaseString`, `localizedLowercaseString`, `localizedCapitalizedString` | iOS 9 | `uppercaseString`, `lowercaseString`, `capitalizedString` |
| `stringByApplyingTransform:reverse:`, `applyTransform:reverse:range:updatedRange:`, `NSStringTransform*` | iOS 9 | `CFStringTransform` |
| `+stringEncodingForData:encodingOptions:convertedString:usedLossyConversion:` | iOS 8 | try `initWithData:encoding:` with each candidate encoding |
| `stringByAddingPercentEncodingWithAllowedCharacters:` | iOS 7 | `CFURLCreateStringByAddingPercentEscapes` |
| `NSURLComponents`, `NSURLQueryItem` | iOS 7, iOS 8 | build the query string by hand |
| `UIAlertController` | iOS 8 | `UIAlertView`, `UIActionSheet` |
| `isOperatingSystemAtLeastVersion:` | iOS 8 | compare `[[UIDevice currentDevice] systemVersion]` |
| Auto Layout anchors, `UIStackView`, `WKWebView` | iOS 8, iOS 9 | frames, `UIWebView` |
| `@import` modules | not set up | `#import` |

## Memory (rule id `mrr`)

- Every target builds with `-fno-objc-arc`. Write manual retain and
  release code.
- Do not use `__weak` or `weak` properties. They need ARC or a runtime
  flag that this build does not set. Use `assign` and clear the
  pointer in `dealloc`.
- Balance every `alloc`, `copy`, `new` and `retain` with a `release` or
  `autorelease`. Release every retained ivar in `dealloc` and call
  `[super dealloc]` last.
- Copy a block before you store it, and release it later.
- Put an `@autoreleasepool` around a loop that makes many temporary
  objects. The device has 256 MB RAM and the app budget is about 80 MB.

## Logos (rule id `logos`)

In a `.xm` file, do not put `%orig` and `return` on one line, for
example `if (x) { %orig; return; }`. Logos then generates broken code.
Put `%orig;` and `return;` on separate lines:

```objc
if (x) {
    %orig;
    return;
}
```

## Secrets (rule id `secret`)

When you add a new secret key name, add it to both lists in the same
commit:

- `Frameworks/System/SecretStore.m`, the set in `+isSecretKey:`
- `LegacyPodClawDaemon/SecretServer.m`, the array in `SecretKeys()`

If you add it to only one list, the read or the write fails at run
time with no compile error.

## Build files (rule id `build`)

- Add each new `.m` file to the `_FILES` list of the correct Makefile.
  A subproject (`LegacyPodClawTweak`, `LegacyPodClawPrefs`,
  `LegacyPodClawNC`, `LegacyPodClawDaemon`) has its own Makefile.
- Keep `ARCHS = armv7` and the `6.0` deployment target.
- Builds run only on the Mac mini. Use the `mac-build` skill.

## Comments (rule id `style`)

Write each code comment in lowercase, on one line, and say why, not
what.
