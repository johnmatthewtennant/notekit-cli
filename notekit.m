// notekit.m — compilation hub
// Originally scaffolded by generate-notes-cli.py — now maintained manually

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreData/CoreData.h>
#include <mach-o/dyld.h>
#include <fcntl.h>

#include "notekit-generated.m"
#include "notekit-handwritten.m"
#include "notekit-tests.m"

// --- Main ---

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) { usage(); return 1; }

        loadFramework();

        NSString *command = [NSString stringWithUTF8String:argv[1]];

        // Parse arguments
        NSMutableArray *positional = [NSMutableArray array];
        NSMutableDictionary *opts = [NSMutableDictionary dictionary];

        for (int i = 2; i < argc; i++) {
            NSString *arg = [NSString stringWithUTF8String:argv[i]];
            if ([arg hasPrefix:@"--"]) {
                NSString *flag = [arg substringFromIndex:2];
                if ([flag isEqualToString:@"help"] ||
                    [flag isEqualToString:@"claude"] ||
                    [flag isEqualToString:@"agents"] ||
                    [flag isEqualToString:@"force"] ||
                    [flag isEqualToString:@"body-offset"] ||
                    [flag isEqualToString:@"dry-run"] ||
                    [flag isEqualToString:@"backup"] ||
                    [flag isEqualToString:@"case-insensitive"]) {
                    opts[flag] = @"true";
                } else if (i + 1 < argc) {
                    opts[flag] = [NSString stringWithUTF8String:argv[++i]];
                }
            } else {
                [positional addObject:arg];
            }
        }

        // Resolve keyword args: --title, --name, --text, --query, --search-text, --new-title
        // Keyword args take priority over positional args
        NSString *kwTitle = opts[@"title"];
        NSString *kwName = opts[@"name"];
        NSString *kwText = opts[@"text"];
        NSString *kwQuery = opts[@"query"];
        NSString *kwSearchText = opts[@"search-text"];
        NSString *kwNewTitle = opts[@"new-title"];

        NSString *folderName = opts[@"folder"];
        id viewContext = getViewContext();

        // Reject unexpected positional arguments
        if (positional.count > 0 &&
            ![command isEqualToString:@"folders"] &&
            ![command isEqualToString:@"install-skill"] &&
            ![command isEqualToString:@"test"]) {
            fprintf(stderr, "Error: unexpected argument '%s'. All arguments must use --flag syntax.\n", [positional[0] UTF8String]);
            usage();
            return 1;
        }

        if ([command isEqualToString:@"folders"]) {
            return cmdFolders(viewContext);

        } else if ([command isEqualToString:@"list"]) {
            NSUInteger limit = opts[@"limit"] ? [opts[@"limit"] integerValue] : 50;
            return cmdList(viewContext, folderName, limit);

        } else if ([command isEqualToString:@"get"]) {
            NSString *noteID = opts[@"id"];
            if (!noteID && !kwTitle) { fprintf(stderr, "Error: --title or --id required\n"); usage(); return 1; }
            if (noteID) {
                id note = findNoteByID(viewContext, noteID);
                if (!note) errorExit([NSString stringWithFormat:@"Note not found with id: %@", noteID]);
                return cmdGetNote(note);
            }
            return cmdGet(viewContext, kwTitle, folderName);

        } else if ([command isEqualToString:@"read"]) {
            NSString *noteID = opts[@"id"];
            if (!noteID && !kwTitle) { fprintf(stderr, "Error: --title or --id required\n"); usage(); return 1; }
            if (noteID) {
                id note = findNoteByID(viewContext, noteID);
                if (!note) errorExit([NSString stringWithFormat:@"Note not found with id: %@", noteID]);
                return cmdReadNote(note);
            }
            return cmdRead(viewContext, kwTitle, folderName);

        } else if ([command isEqualToString:@"read-attrs"]) {
            NSString *noteID = opts[@"id"];
            if (!noteID && !kwTitle) { fprintf(stderr, "Error: --title or --id required\n"); usage(); return 1; }
            if (noteID) {
                id note = findNoteByID(viewContext, noteID);
                if (!note) errorExit([NSString stringWithFormat:@"Note not found with id: %@", noteID]);
                return cmdReadAttrsNote(note);
            }
            return cmdReadAttrs(viewContext, kwTitle, folderName);

        } else if ([command isEqualToString:@"read-structured"]) {
            NSString *noteID = opts[@"id"];
            if (!noteID && !kwTitle) { fprintf(stderr, "Error: --title or --id required\n"); usage(); return 1; }
            if (noteID) {
                id note = findNoteByID(viewContext, noteID);
                if (!note) errorExit([NSString stringWithFormat:@"Note not found with id: %@", noteID]);
                return cmdReadStructuredNote(note);
            }
            return cmdReadStructured(viewContext, kwTitle, folderName);

        } else if ([command isEqualToString:@"read-markdown"]) {
            NSString *noteID = opts[@"id"];
            if (!noteID && !kwTitle) { fprintf(stderr, "Error: --title or --id required\n"); usage(); return 1; }
            if (noteID) {
                id note = findNoteByID(viewContext, noteID);
                if (!note) errorExit([NSString stringWithFormat:@"Note not found with id: %@", noteID]);
                return cmdReadMarkdownNote(note);
            }
            id note = requireSingleNote(viewContext, kwTitle, folderName);
            return cmdReadMarkdownNote(note);

        } else if ([command isEqualToString:@"write-markdown"]) {
            NSString *noteID = opts[@"id"];
            if (!noteID) { fprintf(stderr, "Error: --id required\n"); usage(); return 1; }
            id note = findNoteByID(viewContext, noteID);
            if (!note) errorExit([NSString stringWithFormat:@"Note not found with id: %@", noteID]);
            BOOL dryRun = [opts[@"dry-run"] isEqualToString:@"true"];
            BOOL backupFlag = [opts[@"backup"] isEqualToString:@"true"];
            return cmdWriteMarkdownNote(note, viewContext, dryRun, backupFlag);

        } else if ([command isEqualToString:@"set-attr"]) {
            NSString *noteID = opts[@"id"];
            if (!noteID || noteID.length == 0) { fprintf(stderr, "Error: --id required\n"); usage(); return 1; }
            if (!opts[@"offset"] || !opts[@"length"]) { fprintf(stderr, "Error: --offset and --length required\n"); usage(); return 1; }
            return cmdSetAttr(viewContext, noteID,
                [opts[@"offset"] integerValue], [opts[@"length"] integerValue], opts);

        } else if ([command isEqualToString:@"move"]) {
            NSString *noteID = opts[@"id"];
            if (!noteID || noteID.length == 0) { fprintf(stderr, "Error: --id required\n"); usage(); return 1; }
            if (!opts[@"to"]) { fprintf(stderr, "Error: --to required\n"); usage(); return 1; }
            return cmdMoveNote(viewContext, noteID, opts[@"to"]);

        } else if ([command isEqualToString:@"search"]) {
            if (!kwQuery) { fprintf(stderr, "Error: --query required\n"); usage(); return 1; }
            return cmdSearch(viewContext, kwQuery, folderName);

        } else if ([command isEqualToString:@"pin"]) {
            NSString *noteID = opts[@"id"];
            if (!noteID || noteID.length == 0) { fprintf(stderr, "Error: --id required\n"); usage(); return 1; }
            return cmdPin(viewContext, noteID, YES);

        } else if ([command isEqualToString:@"unpin"]) {
            NSString *noteID = opts[@"id"];
            if (!noteID || noteID.length == 0) { fprintf(stderr, "Error: --id required\n"); usage(); return 1; }
            return cmdPin(viewContext, noteID, NO);

        } else if ([command isEqualToString:@"duplicate"]) {
            NSString *noteID = opts[@"id"];
            if (!noteID || noteID.length == 0) { fprintf(stderr, "Error: --id required\n"); usage(); return 1; }
            return cmdDuplicate(viewContext, noteID, kwNewTitle);

        } else if ([command isEqualToString:@"create-folder"]) {
            if (!kwName) { fprintf(stderr, "Error: --name required\n"); usage(); return 1; }
            return cmdCreateFolder(viewContext, kwName);

        } else if ([command isEqualToString:@"delete-folder"]) {
            if (!kwName) { fprintf(stderr, "Error: --name required\n"); usage(); return 1; }
            return cmdDeleteFolder(viewContext, kwName);

        } else if ([command isEqualToString:@"create-empty"]) {
            if (!folderName) { fprintf(stderr, "Error: --folder required\n"); usage(); return 1; }
            return cmdCreateEmpty(viewContext, folderName);

        } else if ([command isEqualToString:@"create"]) {
            if (!folderName) { fprintf(stderr, "Error: --folder required\n"); usage(); return 1; }
            if (!kwTitle) { fprintf(stderr, "Error: --title required\n"); usage(); return 1; }
            NSString *body = opts[@"body"];
            NSInteger styleVal = -1;
            if (opts[@"style"]) {
                if (!isStrictInteger(opts[@"style"], &styleVal)) {
                    errorExit(@"--style must be a number. Valid styles: 0=title, 1=heading, 3=body, 100=dash-list, 102=numbered-list, 103=checklist");
                }
                if (!isValidStyle(styleVal)) {
                    errorExit(@"Invalid --style value. Valid styles: 0=title, 1=heading, 3=body, 100=dash-list, 102=numbered-list, 103=checklist");
                }
            }
            return cmdCreate(viewContext, folderName, kwTitle, body, styleVal);

        } else if ([command isEqualToString:@"delete"]) {
            NSString *noteID = opts[@"id"];
            if (!noteID || noteID.length == 0) { fprintf(stderr, "Error: --id required\n"); usage(); return 1; }
            return cmdDelete(viewContext, noteID);

        } else if ([command isEqualToString:@"append"]) {
            NSString *noteID = opts[@"id"];
            if (!noteID || noteID.length == 0) { fprintf(stderr, "Error: --id required\n"); usage(); return 1; }
            if (!kwText) { fprintf(stderr, "Error: --text required\n"); usage(); return 1; }
            NSInteger styleVal = -1;
            if (opts[@"style"]) {
                if (!isStrictInteger(opts[@"style"], &styleVal)) {
                    errorExit(@"--style must be a number. Valid styles: 0=title, 1=heading, 3=body, 4=code-block, 100=dash-list, 102=numbered-list, 103=checklist");
                }
                if (!isValidStyle(styleVal)) {
                    errorExit(@"Invalid --style value. Valid styles: 0=title, 1=heading, 3=body, 4=code-block, 100=dash-list, 102=numbered-list, 103=checklist");
                }
            }
            return cmdAppend(viewContext, noteID, kwText, styleVal);

        } else if ([command isEqualToString:@"insert"]) {
            NSString *noteID = opts[@"id"];
            if (!noteID || noteID.length == 0) { fprintf(stderr, "Error: --id required\n"); usage(); return 1; }
            if (!kwText) { fprintf(stderr, "Error: --text required\n"); usage(); return 1; }
            if (!opts[@"position"]) { fprintf(stderr, "Error: --position required\n"); usage(); return 1; }
            NSInteger styleVal = -1;
            if (opts[@"style"]) {
                if (!isStrictInteger(opts[@"style"], &styleVal)) {
                    errorExit(@"--style must be a number. Valid styles: 0=title, 1=heading, 3=body, 4=code-block, 100=dash-list, 102=numbered-list, 103=checklist");
                }
                if (!isValidStyle(styleVal)) {
                    errorExit(@"Invalid --style value. Valid styles: 0=title, 1=heading, 3=body, 4=code-block, 100=dash-list, 102=numbered-list, 103=checklist");
                }
            }
            return cmdInsert(viewContext, noteID, kwText, [opts[@"position"] integerValue],
                [opts[@"body-offset"] isEqualToString:@"true"], styleVal);

        } else if ([command isEqualToString:@"delete-range"]) {
            NSString *noteID = opts[@"id"];
            if (!noteID || noteID.length == 0) { fprintf(stderr, "Error: --id required\n"); usage(); return 1; }
            if (!opts[@"start"] || !opts[@"length"]) { fprintf(stderr, "Error: --start and --length required\n"); usage(); return 1; }
            return cmdDeleteRange(viewContext, noteID, [opts[@"start"] integerValue], [opts[@"length"] integerValue],
                [opts[@"body-offset"] isEqualToString:@"true"]);

        } else if ([command isEqualToString:@"search-offset"]) {
            NSString *noteID = opts[@"id"];
            if (!noteID || noteID.length == 0) { fprintf(stderr, "Error: --id required\n"); usage(); return 1; }
            if (!kwText) { fprintf(stderr, "Error: --text required\n"); usage(); return 1; }
            BOOL caseInsensitive = [opts[@"case-insensitive"] isEqualToString:@"true"];
            return cmdSearchOffset(viewContext, noteID, kwText, caseInsensitive);

        } else if ([command isEqualToString:@"replace"]) {
            NSString *noteID = opts[@"id"];
            if (!noteID || noteID.length == 0) { fprintf(stderr, "Error: --id required\n"); usage(); return 1; }
            if (!opts[@"search"] || !opts[@"replacement"]) { fprintf(stderr, "Error: --search and --replacement required\n"); usage(); return 1; }
            return cmdReplace(viewContext, noteID, opts[@"search"], opts[@"replacement"]);

        } else if ([command isEqualToString:@"delete-line"]) {
            NSString *noteID = opts[@"id"];
            if (!noteID || noteID.length == 0) { fprintf(stderr, "Error: --id required\n"); usage(); return 1; }
            if (!kwSearchText) { fprintf(stderr, "Error: --search-text required\n"); usage(); return 1; }
            return cmdDeleteLine(viewContext, noteID, kwSearchText);

        } else if ([command isEqualToString:@"get-link"]) {
            if (!opts[@"id"]) errorExit(@"get-link requires --id");
            return cmdGetLink(viewContext, opts[@"id"]);

        } else if ([command isEqualToString:@"add-link"]) {
            if (!opts[@"id"]) errorExit(@"add-link requires --id");
            if (!opts[@"target"]) errorExit(@"add-link requires --target");
            NSInteger position = opts[@"position"] ? [opts[@"position"] integerValue] : -1;
            return cmdAddLink(viewContext, opts[@"id"], opts[@"target"], opts[@"text"], position);

        } else if ([command isEqualToString:@"add-note-link"]) {
            if (!opts[@"id"]) errorExit(@"add-note-link requires --id");
            if (!opts[@"target"]) errorExit(@"add-note-link requires --target");
            NSInteger position = opts[@"position"] ? [opts[@"position"] integerValue] : -1;
            return cmdAddNoteLink(viewContext, opts[@"id"], opts[@"target"], position);

        } else if ([command isEqualToString:@"install-skill"]) {
            BOOL wantClaude = [opts[@"claude"] isEqualToString:@"true"];
            BOOL wantAgents = [opts[@"agents"] isEqualToString:@"true"];
            BOOL force = [opts[@"force"] isEqualToString:@"true"];
            // Default: install to both
            if (!wantClaude && !wantAgents) { wantClaude = YES; wantAgents = YES; }
            return cmdInstallSkill(wantClaude, wantAgents, force);

        } else if ([command isEqualToString:@"test"]) {
            return cmdTest(viewContext);

        } else {
            fprintf(stderr, "Unknown command: %s\n", [command UTF8String]);
            usage();
            return 1;
        }
    }
}
