/*
 * GuardrailTests.m
 * LegacyPodClaw - OCGuardrails path checks
 */

#import "TestHarness.h"
#import "Guardrails.h"
#import <unistd.h>
#import <stdlib.h>

static OCGuardrailAction Check(NSString *path, OCFileOp op) {
    return [[OCGuardrails shared] checkPath:path forOperation:op].action;
}

void RunGuardrailTests(void) {
    for (NSString *path in @[@"/System", @"/System/Library/x", @"/usr/lib", @"/bin/ls", @"/sbin/launchd"])
        CHECK(Check(path, OCFileOpWrite) == OCGuardrailBlock, @"write to %@ blocked", path);
    CHECK(Check(@"/System", OCFileOpDelete) == OCGuardrailBlock, @"delete of /System itself blocked");
    CHECK(Check(@"/usr/../System/Library/x", OCFileOpWrite) == OCGuardrailBlock, @"dot segments resolved");
    CHECK(Check(@"/var/no-such-dir/../../System/x", OCFileOpWrite) == OCGuardrailBlock, @"dot segment below a missing dir refused");

    /* "link/.." is the symlink target's parent, not the link's parent; a lexical check gets this wrong */
    char dir[] = "/tmp/lpc-guard-XXXXXX";
    if (mkdtemp(dir)) {
        NSString *link = [[NSString stringWithUTF8String:dir] stringByAppendingPathComponent:@"v"];
        symlink("/private/var/tmp", [link fileSystemRepresentation]);
        NSString *path = [link stringByAppendingPathComponent:@"../Keychains/x"];
        CHECK(Check(path, OCFileOpRead) == OCGuardrailBlock, @"symlink then .. resolved physically: %@", path);
        unlink([link fileSystemRepresentation]);
        rmdir(dir);
    }

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
