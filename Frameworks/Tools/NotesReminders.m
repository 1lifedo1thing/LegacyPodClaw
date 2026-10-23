/* notes tools write notes.sqlite in one transaction each; reminders tools use eventkit only */

#import "NotesReminders.h"
#import <EventKit/EventKit.h>
#import "NotesDatabase.h"

#define REMINDERS_LIST_LIMIT 50

#pragma mark - Reminders store

static EKEventStore *_nrEventStore = nil;

/* call on the main thread only; one store avoids reloading the calendar database per call */
static EKEventStore *NREventStore(void) {
    if (!_nrEventStore) _nrEventStore = [[EKEventStore alloc] init];
    return _nrEventStore;
}

static NSString *const NRDeniedMessage =
    @"Reminders access is denied. Allow it in Settings > Privacy > Reminders > LegacyPodClaw.";

/* runs work on the main thread once reminders access is granted, asking the user if needed */
static void NRWithReminders(OCToolResultBlock cb, void (^work)(EKEventStore *store)) {
    OCToolResultBlock done = [[cb copy] autorelease];
    void (^run)(EKEventStore *) = [[work copy] autorelease];
    dispatch_async(dispatch_get_main_queue(), ^{
        EKAuthorizationStatus status = [EKEventStore authorizationStatusForEntityType:EKEntityTypeReminder];
        if (status == EKAuthorizationStatusAuthorized) { run(NREventStore()); return; }
        if (status == EKAuthorizationStatusRestricted) { done(nil, NRError(@"Reminders access is restricted on this device.")); return; }
        if (status == EKAuthorizationStatusDenied) { done(nil, NRError(NRDeniedMessage)); return; }
        [NREventStore() requestAccessToEntityType:EKEntityTypeReminder completion:^(BOOL granted, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!granted) { done(nil, NRError(NRDeniedMessage)); return; }
                /* a store made before the grant does not see existing reminders */
                [_nrEventStore release];
                _nrEventStore = [[EKEventStore alloc] init];
                run(_nrEventStore);
            });
        }];
    });
}

static NSDateFormatter *NRDateFormatter(NSString *format) {
    NSDateFormatter *f = [[[NSDateFormatter alloc] init] autorelease];
    /* posix locale stops a 12-hour region setting from breaking the 24-hour format */
    [f setLocale:[[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"] autorelease]];
    [f setDateFormat:format];
    return f;
}

static NSString *NRDueString(EKReminder *r) {
    NSDateComponents *c = r.dueDateComponents;
    if (!c) return @"";
    NSDate *d = [[NSCalendar currentCalendar] dateFromComponents:c];
    if (!d) return @"";
    BOOL hasTime = [c hour] != NSUndefinedDateComponent;
    return [NSString stringWithFormat:@" (due: %@)", [NRDateFormatter(hasTime ? @"yyyy-MM-dd HH:mm" : @"yyyy-MM-dd") stringFromDate:d]];
}

static EKReminder *NRFindReminder(EKEventStore *store, NSString *rid) {
    EKCalendarItem *item = rid ? [store calendarItemWithIdentifier:rid] : nil;
    return [item isKindOfClass:[EKReminder class]] ? (EKReminder *)item : nil;
}

@implementation OCNotesReminders

+ (NSArray *)allTools {
    return @[
        [self createNoteTool], [self listNotesTool], [self readNoteTool],
        [self updateNoteTool], [self deleteNoteTool], [self searchNotesTool],
        [self createReminderTool], [self listRemindersTool],
        [self completeReminderTool], [self deleteReminderTool],
        [self listReminderListsTool], [self createReminderListTool]
    ];
}

+ (OCToolDefinition *)toolNamed:(NSString *)name description:(NSString *)desc schema:(NSDictionary *)schema {
    OCToolDefinition *t = [[[OCToolDefinition alloc] init] autorelease];
    t.name = name;
    t.toolDescription = desc;
    t.inputSchema = schema;
    return t;
}

#pragma mark - Notes

+ (OCToolDefinition *)createNoteTool {
    OCToolDefinition *t = [self toolNamed:@"create_note" description:@"Create a note visible in iOS Notes app. Quits the Notes app first."
        schema:@{@"type": @"object", @"properties": @{@"title": @{@"type": @"string"}, @"content": @{@"type": @"string"}}, @"required": @[@"title"]}];
    t.handler = ^(NSDictionary *p, OCToolResultBlock cb) {
        NSString *title = NRStringParam(p, @"title");
        if (!title) { cb(nil, NRError(@"A title is required.")); return; }
        NSString *content = NRStringParam(p, @"content");
        NSString *body = NRNoteHTML(content ?: title);
        NRNotesWrite(cb, ^NSString *(sqlite3 *db, NSString **err) {
            sqlite3_int64 noteEnt, noteMax, bodyEnt, bodyMax, counter, storePK;
            /* entity numbers come from the store itself so a schema change fails instead of corrupting */
            if (!NRQueryInt(db, "SELECT Z_ENT FROM Z_PRIMARYKEY WHERE Z_NAME=?", @[@"Note"], &noteEnt, err) ||
                !NRQueryInt(db, "SELECT Z_MAX FROM Z_PRIMARYKEY WHERE Z_NAME=?", @[@"Note"], &noteMax, err) ||
                !NRQueryInt(db, "SELECT Z_ENT FROM Z_PRIMARYKEY WHERE Z_NAME=?", @[@"NoteBody"], &bodyEnt, err) ||
                !NRQueryInt(db, "SELECT Z_MAX FROM Z_PRIMARYKEY WHERE Z_NAME=?", @[@"NoteBody"], &bodyMax, err)) {
                if (!*err) *err = @"Notes schema mismatch: Note or NoteBody missing from Z_PRIMARYKEY.";
                return nil;
            }
            if (!NRQueryInt(db, "SELECT ZCOUNTER FROM ZNEXTID WHERE Z_PK=1", @[], &counter, err)) {
                if (!*err) *err = @"Notes schema mismatch: ZNEXTID has no counter row.";
                return nil;
            }
            /* new notes join the store the user wrote to last, so they do not land in a sync account by chance */
            if (!NRQueryInt(db, "SELECT ZSTORE FROM ZNOTE WHERE ZDELETEDFLAG=0 ORDER BY ZMODIFICATIONDATE DESC LIMIT 1", @[], &storePK, err) &&
                !NRQueryInt(db, "SELECT MIN(Z_PK) FROM ZSTORE", @[], &storePK, err)) {
                if (!*err) *err = @"The Notes database has no note store.";
                return nil;
            }
            sqlite3_int64 notePK = noteMax + 1, bodyPK = bodyMax + 1, intId = counter + 1;
            double now = [[NSDate date] timeIntervalSinceReferenceDate];

            if (NRExec(db, "INSERT INTO ZNOTEBODY (Z_PK,Z_ENT,Z_OPT,ZOWNER,ZCONTENT) VALUES (?,?,1,?,?)",
                       @[@(bodyPK), @(bodyEnt), @(notePK), body], err) != 1) return nil;
            if (NRExec(db,
                "INSERT INTO ZNOTE (Z_PK,Z_ENT,Z_OPT,ZCONTAINSCJK,ZCONTENTTYPE,ZDELETEDFLAG,ZEXTERNALFLAGS,"
                "ZEXTERNALSERVERINTID,ZINTEGERID,ZISBOOKKEEPINGENTRY,ZBODY,ZSTORE,ZCREATIONDATE,"
                "ZMODIFICATIONDATE,ZAUTHOR,ZGUID,ZSERVERID,ZSUMMARY,ZTITLE) "
                "VALUES (?,?,1,0,0,0,0,-4294967296,?,0,?,?,?,?,NULL,NULL,NULL,NULL,?)",
                @[@(notePK), @(noteEnt), @(intId), @(bodyPK), @(storePK), @(now), @(now), title], err) != 1) return nil;
            if (NRExec(db, "UPDATE Z_PRIMARYKEY SET Z_MAX=? WHERE Z_NAME=?", @[@(notePK), @"Note"], err) != 1) return nil;
            if (NRExec(db, "UPDATE Z_PRIMARYKEY SET Z_MAX=? WHERE Z_NAME=?", @[@(bodyPK), @"NoteBody"], err) != 1) return nil;
            if (NRExec(db, "UPDATE ZNEXTID SET ZCOUNTER=? WHERE Z_PK=1", @[@(intId)], err) != 1) return nil;
            return [NSString stringWithFormat:@"Note '%@' created (ID: %lld).", title, notePK];
        });
    };
    return t;
}

+ (OCToolDefinition *)listNotesTool {
    OCToolDefinition *t = [self toolNamed:@"list_notes" description:@"List notes from iOS Notes app"
        schema:@{@"type": @"object", @"properties": @{}}];
    t.handler = ^(NSDictionary *p, OCToolResultBlock cb) {
        NRNotesRead(cb, ^NSString *(sqlite3 *db, NSString **err) {
            sqlite3_stmt *s = NULL;
            if (sqlite3_prepare_v2(db, "SELECT Z_PK,ZTITLE FROM ZNOTE WHERE ZDELETEDFLAG=0 ORDER BY ZMODIFICATIONDATE DESC LIMIT 20", -1, &s, NULL) != SQLITE_OK) {
                NRSetSQLError(db, @"Notes schema mismatch", err);
                return nil;
            }
            NSMutableArray *r = [NSMutableArray array];
            while (sqlite3_step(s) == SQLITE_ROW) {
                NSString *title = NRColumnString(s, 1);
                [r addObject:[NSString stringWithFormat:@"[%lld] %@", sqlite3_column_int64(s, 0), [title length] ? title : @"(untitled)"]];
            }
            sqlite3_finalize(s);
            return [r count] > 0 ? [r componentsJoinedByString:@"\n"] : @"No notes";
        });
    };
    return t;
}

+ (OCToolDefinition *)readNoteTool {
    OCToolDefinition *t = [self toolNamed:@"read_note" description:@"Read a note from iOS Notes app by ID"
        schema:@{@"type": @"object", @"properties": @{@"id": @{@"type": @"integer"}}, @"required": @[@"id"]}];
    t.handler = ^(NSDictionary *p, OCToolResultBlock cb) {
        sqlite3_int64 nid = [[p objectForKey:@"id"] longLongValue];
        NRNotesRead(cb, ^NSString *(sqlite3 *db, NSString **err) {
            sqlite3_stmt *s = NULL;
            if (sqlite3_prepare_v2(db, "SELECT n.ZTITLE,b.ZCONTENT FROM ZNOTE n JOIN ZNOTEBODY b ON n.ZBODY=b.Z_PK WHERE n.Z_PK=? AND n.ZDELETEDFLAG=0", -1, &s, NULL) != SQLITE_OK) {
                NRSetSQLError(db, @"Notes schema mismatch", err);
                return nil;
            }
            sqlite3_bind_int64(s, 1, nid);
            NSString *result = nil;
            if (sqlite3_step(s) == SQLITE_ROW) {
                result = [NSString stringWithFormat:@"%@\n\n%@", NRColumnString(s, 0), NRPlainText(NRColumnString(s, 1))];
            } else {
                *err = [NSString stringWithFormat:@"No note with ID %lld.", nid];
            }
            sqlite3_finalize(s);
            return result;
        });
    };
    return t;
}

+ (OCToolDefinition *)updateNoteTool {
    OCToolDefinition *t = [self toolNamed:@"update_note" description:@"Update a note in iOS Notes app. Quits the Notes app first."
        schema:@{@"type": @"object", @"properties": @{@"id": @{@"type": @"integer"}, @"title": @{@"type": @"string"}, @"content": @{@"type": @"string"}}, @"required": @[@"id"]}];
    t.handler = ^(NSDictionary *p, OCToolResultBlock cb) {
        sqlite3_int64 nid = [[p objectForKey:@"id"] longLongValue];
        NSString *title = NRStringParam(p, @"title");
        NSString *content = NRStringParam(p, @"content");
        if (!title && !content) { cb(nil, NRError(@"Give a title or content to change.")); return; }
        NSString *body = content ? NRNoteHTML(content) : nil;
        NRNotesWrite(cb, ^NSString *(sqlite3 *db, NSString **err) {
            double now = [[NSDate date] timeIntervalSinceReferenceDate];
            /* z_opt is the core data version; notes treats an unchanged version as an unchanged row */
            int n = NRExec(db, "UPDATE ZNOTE SET ZTITLE=COALESCE(?,ZTITLE),ZMODIFICATIONDATE=?,Z_OPT=Z_OPT+1 WHERE Z_PK=? AND ZDELETEDFLAG=0",
                           @[title ?: (id)[NSNull null], @(now), @(nid)], err);
            if (n < 0) return nil;
            if (n == 0) { *err = [NSString stringWithFormat:@"No note with ID %lld.", nid]; return nil; }
            if (body && NRExec(db, "UPDATE ZNOTEBODY SET ZCONTENT=?,Z_OPT=Z_OPT+1 WHERE Z_PK=(SELECT ZBODY FROM ZNOTE WHERE Z_PK=?)",
                               @[body, @(nid)], err) != 1) {
                if (!*err) *err = [NSString stringWithFormat:@"Note %lld has no body row.", nid];
                return nil;
            }
            return @"Note updated";
        });
    };
    return t;
}

+ (OCToolDefinition *)deleteNoteTool {
    OCToolDefinition *t = [self toolNamed:@"delete_note" description:@"Delete a note from iOS Notes app. Quits the Notes app first."
        schema:@{@"type": @"object", @"properties": @{@"id": @{@"type": @"integer"}}, @"required": @[@"id"]}];
    t.requiresConfirmation = YES;
    t.handler = ^(NSDictionary *p, OCToolResultBlock cb) {
        sqlite3_int64 nid = [[p objectForKey:@"id"] longLongValue];
        NRNotesWrite(cb, ^NSString *(sqlite3 *db, NSString **err) {
            double now = [[NSDate date] timeIntervalSinceReferenceDate];
            int n = NRExec(db, "UPDATE ZNOTE SET ZDELETEDFLAG=1,ZMODIFICATIONDATE=?,Z_OPT=Z_OPT+1 WHERE Z_PK=? AND ZDELETEDFLAG=0",
                           @[@(now), @(nid)], err);
            if (n < 0) return nil;
            if (n == 0) { *err = [NSString stringWithFormat:@"No note with ID %lld.", nid]; return nil; }
            return @"Note deleted";
        });
    };
    return t;
}

+ (OCToolDefinition *)searchNotesTool {
    OCToolDefinition *t = [self toolNamed:@"search_notes" description:@"Search notes by keyword"
        schema:@{@"type": @"object", @"properties": @{@"query": @{@"type": @"string"}}, @"required": @[@"query"]}];
    t.handler = ^(NSDictionary *p, OCToolResultBlock cb) {
        NSString *query = NRStringParam(p, @"query");
        if (!query) { cb(nil, NRError(@"A query is required.")); return; }
        /* escape like wildcards so the query matches literally */
        NSMutableString *esc = [[query mutableCopy] autorelease];
        [esc replaceOccurrencesOfString:@"\\" withString:@"\\\\" options:0 range:NSMakeRange(0, [esc length])];
        [esc replaceOccurrencesOfString:@"%" withString:@"\\%" options:0 range:NSMakeRange(0, [esc length])];
        [esc replaceOccurrencesOfString:@"_" withString:@"\\_" options:0 range:NSMakeRange(0, [esc length])];
        NSString *pattern = [NSString stringWithFormat:@"%%%@%%", esc];
        NRNotesRead(cb, ^NSString *(sqlite3 *db, NSString **err) {
            sqlite3_stmt *s = NULL;
            if (sqlite3_prepare_v2(db, "SELECT n.Z_PK,n.ZTITLE FROM ZNOTE n JOIN ZNOTEBODY b ON n.ZBODY=b.Z_PK "
                                       "WHERE n.ZDELETEDFLAG=0 AND (n.ZTITLE LIKE ?1 ESCAPE '\\' OR b.ZCONTENT LIKE ?1 ESCAPE '\\') LIMIT 10",
                                   -1, &s, NULL) != SQLITE_OK) {
                NRSetSQLError(db, @"Notes schema mismatch", err);
                return nil;
            }
            sqlite3_bind_text(s, 1, [pattern UTF8String], -1, SQLITE_TRANSIENT);
            NSMutableArray *r = [NSMutableArray array];
            while (sqlite3_step(s) == SQLITE_ROW) {
                [r addObject:[NSString stringWithFormat:@"[%lld] %@", sqlite3_column_int64(s, 0), NRColumnString(s, 1)]];
            }
            sqlite3_finalize(s);
            return [r count] > 0 ? [r componentsJoinedByString:@"\n"] : @"No matches";
        });
    };
    return t;
}

#pragma mark - Reminders

+ (OCToolDefinition *)createReminderTool {
    OCToolDefinition *t = [self toolNamed:@"create_reminder" description:@"Create a reminder visible in iOS Reminders app"
        schema:@{@"type": @"object", @"properties": @{
            @"title": @{@"type": @"string"},
            @"due_date": @{@"type": @"string", @"description": @"YYYY-MM-DD or YYYY-MM-DD HH:MM"},
            @"priority": @{@"type": @"integer", @"description": @"0 none, 1 high to 9 low"},
            @"notes": @{@"type": @"string"},
            @"list_id": @{@"type": @"string", @"description": @"List ID from list_reminder_lists. Omit for the default list."}},
            @"required": @[@"title"]}];
    t.handler = ^(NSDictionary *p, OCToolResultBlock cb) {
        NSString *title = NRStringParam(p, @"title");
        if (!title) { cb(nil, NRError(@"A title is required.")); return; }
        NSDateComponents *due = nil;
        NSString *ds = NRStringParam(p, @"due_date");
        if (ds) {
            NSCalendarUnit units = NSYearCalendarUnit | NSMonthCalendarUnit | NSDayCalendarUnit;
            NSDate *d = [NRDateFormatter(@"yyyy-MM-dd HH:mm") dateFromString:ds];
            if (d) units |= NSHourCalendarUnit | NSMinuteCalendarUnit;
            else d = [NRDateFormatter(@"yyyy-MM-dd") dateFromString:ds];
            if (!d) { cb(nil, NRError(@"due_date must be YYYY-MM-DD or YYYY-MM-DD HH:MM.")); return; }
            due = [[NSCalendar currentCalendar] components:units fromDate:d];
        }
        NSInteger priority = MAX(0, MIN(9, [[p objectForKey:@"priority"] integerValue]));
        NSString *notes = NRStringParam(p, @"notes");
        NSString *listId = NRStringParam(p, @"list_id");
        NRWithReminders(cb, ^(EKEventStore *store) {
            EKCalendar *cal = listId ? [store calendarWithIdentifier:listId] : [store defaultCalendarForNewReminders];
            if (!cal || !([cal allowedEntityTypes] & EKEntityMaskReminder)) {
                cb(nil, NRError(listId ? @"No reminder list with that ID. Use list_reminder_lists." : @"There is no default reminder list."));
                return;
            }
            EKReminder *r = [EKReminder reminderWithEventStore:store];
            r.title = title;
            r.calendar = cal;
            r.priority = priority;
            if (notes) r.notes = notes;
            if (due) r.dueDateComponents = due;
            NSError *error = nil;
            if (![store saveReminder:r commit:YES error:&error]) {
                cb(nil, NRError([NSString stringWithFormat:@"Cannot save the reminder: %@", [error localizedDescription]]));
                return;
            }
            cb([NSString stringWithFormat:@"Reminder '%@' created (ID: %@).", title, r.calendarItemIdentifier], nil);
        });
    };
    return t;
}

+ (OCToolDefinition *)listRemindersTool {
    OCToolDefinition *t = [self toolNamed:@"list_reminders" description:@"List reminders from iOS Reminders app"
        schema:@{@"type": @"object", @"properties": @{@"show_completed": @{@"type": @"boolean"}}, @"required": @[]}];
    t.handler = ^(NSDictionary *p, OCToolResultBlock cb) {
        BOOL all = [[p objectForKey:@"show_completed"] boolValue];
        OCToolResultBlock done = [[cb copy] autorelease];
        NRWithReminders(cb, ^(EKEventStore *store) {
            NSPredicate *pred = all ? [store predicateForRemindersInCalendars:nil]
                                    : [store predicateForIncompleteRemindersWithDueDateStarting:nil ending:nil calendars:nil];
            [store fetchRemindersMatchingPredicate:pred completion:^(NSArray *reminders) {
                NSMutableArray *lines = [NSMutableArray array];
                for (EKReminder *r in reminders) {
                    if ([lines count] >= REMINDERS_LIST_LIMIT) break;
                    [lines addObject:[NSString stringWithFormat:@"%@ [%@] %@%@ - %@", r.completed ? @"[x]" : @"[ ]",
                                      r.calendarItemIdentifier, r.title ?: @"", NRDueString(r), r.calendar.title ?: @""]];
                }
                NSString *result = [lines count] > 0 ? [lines componentsJoinedByString:@"\n"] : @"No reminders";
                NRDeliver(done, result, nil);
            }];
        });
    };
    return t;
}

+ (OCToolDefinition *)completeReminderTool {
    OCToolDefinition *t = [self toolNamed:@"complete_reminder" description:@"Complete a reminder in iOS Reminders app"
        schema:@{@"type": @"object", @"properties": @{@"id": @{@"type": @"string", @"description": @"Reminder ID from list_reminders"}}, @"required": @[@"id"]}];
    t.handler = ^(NSDictionary *p, OCToolResultBlock cb) {
        NSString *rid = NRStringParam(p, @"id");
        NRWithReminders(cb, ^(EKEventStore *store) {
            EKReminder *r = NRFindReminder(store, rid);
            if (!r) { cb(nil, NRError(@"No reminder with that ID. Use list_reminders.")); return; }
            r.completed = YES;
            NSError *error = nil;
            if (![store saveReminder:r commit:YES error:&error]) {
                cb(nil, NRError([NSString stringWithFormat:@"Cannot save the reminder: %@", [error localizedDescription]]));
                return;
            }
            cb(@"Reminder completed", nil);
        });
    };
    return t;
}

+ (OCToolDefinition *)deleteReminderTool {
    OCToolDefinition *t = [self toolNamed:@"delete_reminder" description:@"Delete a reminder from iOS Reminders app"
        schema:@{@"type": @"object", @"properties": @{@"id": @{@"type": @"string", @"description": @"Reminder ID from list_reminders"}}, @"required": @[@"id"]}];
    t.requiresConfirmation = YES;
    t.handler = ^(NSDictionary *p, OCToolResultBlock cb) {
        NSString *rid = NRStringParam(p, @"id");
        NRWithReminders(cb, ^(EKEventStore *store) {
            EKReminder *r = NRFindReminder(store, rid);
            if (!r) { cb(nil, NRError(@"No reminder with that ID. Use list_reminders.")); return; }
            NSError *error = nil;
            if (![store removeReminder:r commit:YES error:&error]) {
                cb(nil, NRError([NSString stringWithFormat:@"Cannot delete the reminder: %@", [error localizedDescription]]));
                return;
            }
            cb(@"Reminder deleted", nil);
        });
    };
    return t;
}

+ (OCToolDefinition *)listReminderListsTool {
    OCToolDefinition *t = [self toolNamed:@"list_reminder_lists" description:@"List all reminder lists (calendars) in Reminders app"
        schema:@{@"type": @"object", @"properties": @{}}];
    t.handler = ^(NSDictionary *p, OCToolResultBlock cb) {
        NRWithReminders(cb, ^(EKEventStore *store) {
            NSMutableArray *r = [NSMutableArray array];
            for (EKCalendar *cal in [store calendarsForEntityType:EKEntityTypeReminder]) {
                [r addObject:[NSString stringWithFormat:@"[%@] %@", cal.calendarIdentifier, cal.title ?: @"(unnamed)"]];
            }
            cb([r count] > 0 ? [r componentsJoinedByString:@"\n"] : @"No lists", nil);
        });
    };
    return t;
}

+ (OCToolDefinition *)createReminderListTool {
    OCToolDefinition *t = [self toolNamed:@"create_reminder_list" description:@"Create a new reminder list in Reminders app"
        schema:@{@"type": @"object", @"properties": @{@"name": @{@"type": @"string"}}, @"required": @[@"name"]}];
    t.handler = ^(NSDictionary *p, OCToolResultBlock cb) {
        NSString *name = NRStringParam(p, @"name");
        if (!name) { cb(nil, NRError(@"A name is required.")); return; }
        NRWithReminders(cb, ^(EKEventStore *store) {
            /* put the list next to the default list so it syncs the same way */
            EKSource *source = [[store defaultCalendarForNewReminders] source];
            if (!source) {
                for (EKSource *s in [store sources]) {
                    if (s.sourceType == EKSourceTypeLocal) { source = s; break; }
                }
            }
            if (!source) { cb(nil, NRError(@"No account can hold a new reminder list.")); return; }
            EKCalendar *cal = [EKCalendar calendarForEntityType:EKEntityTypeReminder eventStore:store];
            cal.title = name;
            cal.source = source;
            NSError *error = nil;
            if (![store saveCalendar:cal commit:YES error:&error]) {
                cb(nil, NRError([NSString stringWithFormat:@"Cannot create the list: %@", [error localizedDescription]]));
                return;
            }
            cb([NSString stringWithFormat:@"List '%@' created (ID: %@).", name, cal.calendarIdentifier], nil);
        });
    };
    return t;
}

@end
