/*
 * main.m
 * LegacyPodClaw - host test runner; exits non-zero when a check fails
 */

#import "TestHarness.h"

int gTestsRun = 0;
int gTestsFailed = 0;

int main(void) {
    @autoreleasepool {
        RunParserTests();
        RunGuardrailTests();
        RunToolInputTests();
    }
    printf("%d checks, %d failed\n", gTestsRun, gTestsFailed);
    return gTestsFailed ? 1 : 0;
}
