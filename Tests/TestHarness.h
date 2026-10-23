/*
 * TestHarness.h
 * LegacyPodClaw - minimal assertions for the macOS host test target
 */

#import <Foundation/Foundation.h>

extern int gTestsRun;
extern int gTestsFailed;

#define CHECK(cond, ...) do { \
    gTestsRun++; \
    if (!(cond)) { \
        gTestsFailed++; \
        fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, [[NSString stringWithFormat:__VA_ARGS__] UTF8String]); \
    } \
} while (0)

void RunParserTests(void);
void RunGuardrailTests(void);
void RunToolInputTests(void);
