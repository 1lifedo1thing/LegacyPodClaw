/* ios 6 has no public notes api, so the notes tools share these notes.sqlite helpers */

#import <Foundation/Foundation.h>
#import <sqlite3.h>
#import "Agent.h"

NSError *NRError(NSString *message);
void NRDeliver(OCToolResultBlock cb, id result, NSError *error);
NSString *NRStringParam(NSDictionary *p, NSString *key);

void NRSetSQLError(sqlite3 *db, NSString *what, NSString **err);
int NRExec(sqlite3 *db, const char *sql, NSArray *binds, NSString **err);
BOOL NRQueryInt(sqlite3 *db, const char *sql, NSArray *binds, sqlite3_int64 *out, NSString **err);
NSString *NRColumnString(sqlite3_stmt *s, int col);
NSString *NRNoteHTML(NSString *text);
NSString *NRPlainText(NSString *html);

/* work returns the tool result, or nil with *err set to roll the transaction back */
void NRNotesWrite(OCToolResultBlock cb, NSString *(^work)(sqlite3 *db, NSString **err));
void NRNotesRead(OCToolResultBlock cb, NSString *(^work)(sqlite3 *db, NSString **err));
