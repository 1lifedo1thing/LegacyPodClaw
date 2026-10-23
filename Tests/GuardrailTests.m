/*
 * GuardrailTests.m
 * LegacyPodClaw - OCGuardrails path checks
 */

#import "TestHarness.h"
#import "Guardrails.h"

static OCGuardrailAction Check(NSString *path, OCFileOp op) {
    return [[OCGuardrails shared] checkPath:path forOperation:op].action;
}

void RunGuardrailTests(void) {
    for (NSString *path in @[@"/System", @"/System/Library/x", @"/usr/lib", @"/bin/ls", @"/sbin/launchd"])
        CHECK(Check(path, OCFileOpWrite) == OCGuardrailBlock, @"write to %@ blocked", path);
    CHECK(Check(@"/System", OCFileOpDelete) == OCGuardrailBlock, @"delete of /System itself blocked");
    CHECK(Check(@"/tmp/../System/x", OCFileOpWrite) == OCGuardrailBlock, @"dot segments resolved");

    for (NSString *path in @[@"/var/Keychains", @"/var/Keychains/keychain-2.db", @"/private/var/Keychains/x",
                             @"/var/mobile/Library/SMS/sms.db", @"/var/mobile/Library/AddressBook"])
        CHECK(Check(path, OCFileOpRead) == OCGuardrailBlock, @"read of %@ blocked", path);

    CHECK(Check(@"/System/Library", OCFileOpRead) == OCGuardrailAllow, @"read of system files allowed");
    CHECK(Check(@"/etc/hosts", OCFileOpWrite) == OCGuardrailConfirm, @"write to /etc needs approval");
    CHECK(Check(@"/var/mobile/Library/Preferences/com.apple.springboard.plist", OCFileOpWrite) == OCGuardrailConfirm,
          @"apple preferences need approval");
    CHECK(Check(@"relative/path", OCFileOpRead) == OCGuardrailBlock, @"relative path refused");
    CHECK(Check(nil, OCFileOpRead) == OCGuardrailBlock, @"missing path refused");
}
