/* notes.sqlite access: process stop, transactions and bound statements for the notes tools */

#import "NotesDatabase.h"
#import <sys/sysctl.h>
#import <signal.h>
#import <unistd.h>

#define NOTES_DB "/var/mobile/Library/Notes/notes.sqlite"
#define NOTES_INDEX @"/var/mobile/Library/Notes/notes.idx"
#define NOTES_PROCESS "MobileNotes"
#define NR_ERROR_DOMAIN @"OCNotesReminders"
#define NOTES_BUSY_TIMEOUT_MS 5000

#pragma mark - Shared helpers

NSError *NRError(NSString *message) {
    return [NSError errorWithDomain:NR_ERROR_DOMAIN code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

/* agent and gateway count tool callbacks on the main thread, so every result goes there */
void NRDeliver(OCToolResultBlock cb, id result, NSError *error) {
    dispatch_async(dispatch_get_main_queue(), ^{ cb(result, error); });
}

/* the model may send an id as a number or a string; eventkit ids are strings */
NSString *NRStringParam(NSDictionary *p, NSString *key) {
    id v = [p objectForKey:key];
    if ([v isKindOfClass:[NSString class]]) return [v length] > 0 ? v : nil;
    if ([v isKindOfClass:[NSNumber class]]) return [v stringValue];
    return nil;
}

#pragma mark - Notes database

/* one serial queue keeps notes writes ordered and keeps the kill wait off the main thread */
static dispatch_queue_t NRNotesQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("pro.matthesketh.legacypodclaw.notes", DISPATCH_QUEUE_SERIAL); });
    return q;
}

static NSArray *NRPidsNamed(const char *name) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    struct kinfo_proc *procs = NULL;
    size_t size = 0;
    /* the process table can grow between the size query and the read */
    for (int attempt = 0; attempt < 3; attempt++) {
        if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0) return nil;
        size += size / 4;
        procs = malloc(size);
        if (!procs) return nil;
        if (sysctl(mib, 4, procs, &size, NULL, 0) == 0) break;
        free(procs);
        procs = NULL;
    }
    if (!procs) return nil;
    NSMutableArray *pids = [NSMutableArray array];
    size_t count = size / sizeof(struct kinfo_proc);
    for (size_t i = 0; i < count; i++) {
        if (strncmp(procs[i].kp_proc.p_comm, name, MAXCOMLEN) == 0) {
            [pids addObject:@(procs[i].kp_proc.p_pid)];
        }
    }
    free(procs);
    return pids;
}

static BOOL NRWaitForExit(NSArray *pids, int tenths) {
    for (int i = 0; i < tenths; i++) {
        BOOL alive = NO;
        for (NSNumber *pid in pids) {
            if (kill([pid intValue], 0) == 0) { alive = YES; break; }
        }
        if (!alive) return YES;
        usleep(100000);
    }
    return NO;
}

/* mobilenotes caches notes in memory and would overwrite our row on its next save */
static BOOL NRStopMobileNotes(NSString **err) {
    NSArray *pids = NRPidsNamed(NOTES_PROCESS);
    if (!pids) { *err = @"Cannot read the process list to stop the Notes app."; return NO; }
    if ([pids count] == 0) return YES;
    for (NSNumber *pid in pids) kill([pid intValue], SIGTERM);
    if (NRWaitForExit(pids, 10)) return YES;
    /* a suspended app does not act on sigterm until it is resumed */
    for (NSNumber *pid in pids) kill([pid intValue], SIGKILL);
    if (NRWaitForExit(pids, 10)) return YES;
    *err = @"The Notes app did not quit. Close it and try again.";
    return NO;
}

void NRSetSQLError(sqlite3 *db, NSString *what, NSString **err) {
    if (err && !*err) *err = [NSString stringWithFormat:@"%@: %s", what, db ? sqlite3_errmsg(db) : "no database"];
}

static BOOL NRBind(sqlite3_stmt *s, NSArray *binds) {
    int i = 1;
    for (id v in binds) {
        int rc;
        if (v == [NSNull null]) {
            rc = sqlite3_bind_null(s, i);
        } else if ([v isKindOfClass:[NSString class]]) {
            rc = sqlite3_bind_text(s, i, [v UTF8String], -1, SQLITE_TRANSIENT);
        } else if ([v isKindOfClass:[NSNumber class]]) {
            const char *t = [v objCType];
            if (strcmp(t, @encode(double)) == 0 || strcmp(t, @encode(float)) == 0) {
                rc = sqlite3_bind_double(s, i, [v doubleValue]);
            } else {
                rc = sqlite3_bind_int64(s, i, [v longLongValue]);
            }
        } else {
            return NO;
        }
        if (rc != SQLITE_OK) return NO;
        i++;
    }
    return YES;
}

/* runs one write statement and returns the changed row count, or -1 on error */
int NRExec(sqlite3 *db, const char *sql, NSArray *binds, NSString **err) {
    sqlite3_stmt *s = NULL;
    if (sqlite3_prepare_v2(db, sql, -1, &s, NULL) != SQLITE_OK) { NRSetSQLError(db, @"Notes schema mismatch", err); return -1; }
    if (!NRBind(s, binds)) { sqlite3_finalize(s); NRSetSQLError(db, @"Bind failed", err); return -1; }
    int rc = sqlite3_step(s);
    sqlite3_finalize(s);
    if (rc != SQLITE_DONE) { NRSetSQLError(db, @"Notes write failed", err); return -1; }
    return sqlite3_changes(db);
}

/* reads one integer; returns NO when there is no row or the query fails */
BOOL NRQueryInt(sqlite3 *db, const char *sql, NSArray *binds, sqlite3_int64 *out, NSString **err) {
    sqlite3_stmt *s = NULL;
    if (sqlite3_prepare_v2(db, sql, -1, &s, NULL) != SQLITE_OK) { NRSetSQLError(db, @"Notes schema mismatch", err); return NO; }
    BOOL ok = NO;
    if (NRBind(s, binds) && sqlite3_step(s) == SQLITE_ROW && sqlite3_column_type(s, 0) != SQLITE_NULL) {
        *out = sqlite3_column_int64(s, 0);
        ok = YES;
    }
    sqlite3_finalize(s);
    return ok;
}

static sqlite3 *NROpenNotes(int flags, NSString **err) {
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(NOTES_DB, &db, flags, NULL) != SQLITE_OK) {
        *err = [NSString stringWithFormat:@"Cannot open the Notes database: %s", db ? sqlite3_errmsg(db) : "out of memory"];
        if (db) sqlite3_close(db);
        return NULL;
    }
    sqlite3_busy_timeout(db, NOTES_BUSY_TIMEOUT_MS);
    return db;
}

/* stops notes, opens the store and runs work inside begin immediate; any failure rolls back */
void NRNotesWrite(OCToolResultBlock cb, NSString *(^work)(sqlite3 *db, NSString **err)) {
    OCToolResultBlock done = [[cb copy] autorelease];
    dispatch_async(NRNotesQueue(), ^{
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        NSString *err = nil;
        NSString *result = nil;
        sqlite3 *db = NULL;
        if (NRStopMobileNotes(&err) && (db = NROpenNotes(SQLITE_OPEN_READWRITE, &err))) {
            if (sqlite3_exec(db, "BEGIN IMMEDIATE", NULL, NULL, NULL) != SQLITE_OK) {
                NRSetSQLError(db, @"Notes database is busy", &err);
            } else {
                result = work(db, &err);
                if (result && sqlite3_exec(db, "COMMIT", NULL, NULL, NULL) != SQLITE_OK) {
                    NRSetSQLError(db, @"Commit failed", &err);
                    result = nil;
                }
                if (!result) sqlite3_exec(db, "ROLLBACK", NULL, NULL, NULL);
            }
            sqlite3_close(db);
        }
        if (result) {
            /* notes rebuilds its search index from the database when the index file is missing */
            [[NSFileManager defaultManager] removeItemAtPath:NOTES_INDEX error:nil];
            NRDeliver(done, result, nil);
        } else {
            NRDeliver(done, nil, NRError(err ?: @"Notes write failed."));
        }
        [pool drain];
    });
}

void NRNotesRead(OCToolResultBlock cb, NSString *(^work)(sqlite3 *db, NSString **err)) {
    OCToolResultBlock done = [[cb copy] autorelease];
    dispatch_async(NRNotesQueue(), ^{
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        NSString *err = nil;
        NSString *result = nil;
        sqlite3 *db = NROpenNotes(SQLITE_OPEN_READONLY, &err);
        if (db) {
            result = work(db, &err);
            sqlite3_close(db);
        }
        if (result) NRDeliver(done, result, nil);
        else NRDeliver(done, nil, NRError(err ?: @"Notes read failed."));
        [pool drain];
    });
}

NSString *NRColumnString(sqlite3_stmt *s, int col) {
    const unsigned char *t = sqlite3_column_text(s, col);
    return t ? [NSString stringWithUTF8String:(const char *)t] : @"";
}

/* notes.app stores the body as html, so user text must be escaped */
NSString *NRNoteHTML(NSString *text) {
    NSMutableString *h = [[text mutableCopy] autorelease];
    [h replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, [h length])];
    [h replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, [h length])];
    [h replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, [h length])];
    [h replaceOccurrencesOfString:@"\n" withString:@"<br>" options:0 range:NSMakeRange(0, [h length])];
    return h;
}

NSString *NRPlainText(NSString *html) {
    NSMutableString *plain = [[html mutableCopy] autorelease];
    [plain replaceOccurrencesOfString:@"<br>" withString:@"\n" options:NSCaseInsensitiveSearch range:NSMakeRange(0, [plain length])];
    [plain replaceOccurrencesOfString:@"<div>" withString:@"\n" options:NSCaseInsensitiveSearch range:NSMakeRange(0, [plain length])];
    while (YES) {
        NSRange r = [plain rangeOfString:@"<[^>]+>" options:NSRegularExpressionSearch];
        if (r.location == NSNotFound) break;
        [plain deleteCharactersInRange:r];
    }
    [plain replaceOccurrencesOfString:@"&nbsp;" withString:@" " options:0 range:NSMakeRange(0, [plain length])];
    [plain replaceOccurrencesOfString:@"&lt;" withString:@"<" options:0 range:NSMakeRange(0, [plain length])];
    [plain replaceOccurrencesOfString:@"&gt;" withString:@">" options:0 range:NSMakeRange(0, [plain length])];
    [plain replaceOccurrencesOfString:@"&amp;" withString:@"&" options:0 range:NSMakeRange(0, [plain length])];
    return [plain stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}
