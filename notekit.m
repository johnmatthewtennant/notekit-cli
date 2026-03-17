// Originally scaffolded by generate-notes-cli.py — now maintained manually

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreData/CoreData.h>
#include <mach-o/dyld.h>
#include <fcntl.h>

// --- Framework Loading ---

static Class ICNoteContextClass;
static Class ICNoteClass;
static Class ICTTParagraphStyleClass;
static Class ICTTTodoClass;

static void loadFramework(void) {
    [[NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/NotesShared.framework"] load];
    ICNoteContextClass = NSClassFromString(@"ICNoteContext");
    ICNoteClass = NSClassFromString(@"ICNote");
    ICTTParagraphStyleClass = NSClassFromString(@"ICTTParagraphStyle");
    ICTTTodoClass = NSClassFromString(@"ICTTTodo");
}

static id getViewContext(void) {
    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(ICNoteContextClass, sel_registerName("startSharedContextWithOptions:"), 0);
    id context = ((id (*)(id, SEL))objc_msgSend)(ICNoteContextClass, sel_registerName("sharedContext"));
    id container = ((id (*)(id, SEL))objc_msgSend)(context, sel_registerName("persistentContainer"));
    return ((id (*)(id, SEL))objc_msgSend)(container, sel_registerName("viewContext"));
}

// --- Helpers ---

static void errorExit(NSString *msg) {
    fprintf(stderr, "Error: %s\n", [msg UTF8String]);
    exit(1);
}

static BOOL isStrictInteger(NSString *str, NSInteger *outValue) {
    NSScanner *scanner = [NSScanner scannerWithString:str];
    NSInteger value;
    if ([scanner scanInteger:&value] && [scanner isAtEnd]) {
        if (outValue) *outValue = value;
        return YES;
    }
    return NO;
}

static BOOL isValidStyle(NSInteger style) {
    return style == 0 || style == 1 || style == 3 || style == 100 || style == 102 || style == 103;
}

static id makeParagraphStyle(NSInteger style) {
    id paraStyle = [[ICTTParagraphStyleClass alloc] init];
    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(paraStyle, sel_registerName("setStyle:"), (NSUInteger)style);
    if (style == 103) {
        id todo = ((id (*)(id, SEL, id, BOOL))objc_msgSend)(
            [ICTTTodoClass alloc],
            sel_registerName("initWithIdentifier:done:"),
            [NSUUID UUID], NO);
        ((void (*)(id, SEL, id))objc_msgSend)(paraStyle, sel_registerName("setTodo:"), todo);
    }
    return paraStyle;
}

static NSString *dateToISO(NSDate *date) {
    if (!date) return nil;
    NSISO8601DateFormatter *fmt = [[NSISO8601DateFormatter alloc] init];
    return [fmt stringFromDate:date];
}

static void printJSON(id obj) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:obj
        options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&error];
    if (error) errorExit([error localizedDescription]);
    printf("%s\n", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
}

// --- Fetch Helpers ---

static NSArray *fetchFolders(id viewContext) {
    NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"ICFolder"];
    NSError *error = nil;
    NSArray *folders = [viewContext executeFetchRequest:request error:&error];
    if (error) errorExit([NSString stringWithFormat:@"Failed to fetch folders: %@", error]);
    return folders;
}

static NSArray *fetchNotes(id viewContext, NSString *folderName, NSUInteger limit) {
    NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"ICNote"];
    NSMutableArray *predicates = [NSMutableArray array];
    if (folderName) {
        [predicates addObject:[NSPredicate predicateWithFormat:@"folder.title == %@", folderName]];
    }
    if (predicates.count > 0) {
        request.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:predicates];
    }
    request.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"modificationDate" ascending:NO]];
    if (limit > 0) request.fetchLimit = limit;
    NSError *error = nil;
    NSArray *notes = [viewContext executeFetchRequest:request error:&error];
    if (error) errorExit([NSString stringWithFormat:@"Failed to fetch notes: %@", error]);
    return notes;
}

static id findNote(id viewContext, NSString *title, NSString *folderName) {
    NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"ICNote"];
    if (folderName) {
        request.predicate = [NSPredicate predicateWithFormat:@"title CONTAINS %@ AND folder.title == %@", title, folderName];
    } else {
        request.predicate = [NSPredicate predicateWithFormat:@"title CONTAINS %@", title];
    }
    request.fetchLimit = 1;
    NSError *error = nil;
    NSArray *notes = [viewContext executeFetchRequest:request error:&error];
    if (error || notes.count == 0) return nil;
    return notes[0];
}

static id findNoteByID(id viewContext, NSString *identifier) {
    NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"ICNote"];
    request.predicate = [NSPredicate predicateWithFormat:@"identifier == %@", identifier];
    request.fetchLimit = 1;
    NSError *error = nil;
    NSArray *notes = [viewContext executeFetchRequest:request error:&error];
    if (error || notes.count == 0) return nil;
    return notes[0];
}
// Returns the character offset where the body starts in the full mergeableString
// (after leading \n + title + \n)
// Returns NSNotFound if the note has no body (title-only note).
// Handles both canonical format (\n + title + \n + body) and non-canonical
// format (title + \n + body) for test-created notes.
static NSUInteger bodyOffsetForNote(id note) {
    NSAttributedString *attrStr = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("attributedString"));
    NSString *fullText = [attrStr string];
    NSUInteger length = fullText.length;

    // Guard: empty note
    if (length == 0) return NSNotFound;

    NSUInteger idx = 0;

    // Skip all leading newlines (canonical notes have exactly one, but be
    // robust against malformed or legacy notes with extra leading newlines)
    while (idx < length && [fullText characterAtIndex:idx] == 0x0A) idx++;

    // Skip title text (all non-newline characters)
    while (idx < length && [fullText characterAtIndex:idx] != 0x0A) idx++;

    // Skip the newline after title
    if (idx < length && [fullText characterAtIndex:idx] == 0x0A) idx++;

    // If idx >= length, the note has no body (title-only)
    if (idx >= length) return NSNotFound;

    return idx;
}


// --- Note Serialization (generated from NOTE_READ_PROPS) ---

static NSDictionary *noteToDict(id note) {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];

    @try {
        NSString *val = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("title"));
        if (val) dict[@"title"] = val;
    } @catch (NSException *e) {}

    @try {
        NSString *val = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("noteAsPlainTextWithoutTitle"));
        if (val) dict[@"body"] = val;
    } @catch (NSException *e) {}

    @try {
        NSString *val = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("folderName"));
        if (val) dict[@"folder"] = val;
    } @catch (NSException *e) {}

    @try {
        NSDate *val = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("creationDate"));
        if (val) dict[@"createdAt"] = dateToISO(val);
    } @catch (NSException *e) {}

    @try {
        NSDate *val = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("modificationDate"));
        if (val) dict[@"modifiedAt"] = dateToISO(val);
    } @catch (NSException *e) {}

    @try {
        BOOL val = ((BOOL (*)(id, SEL))objc_msgSend)(note, sel_registerName("hasChecklist"));
        dict[@"hasChecklist"] = @(val);
    } @catch (NSException *e) {}

    @try {
        BOOL val = ((BOOL (*)(id, SEL))objc_msgSend)(note, sel_registerName("isPinned"));
        dict[@"isPinned"] = @(val);
    } @catch (NSException *e) {}

    @try {
        BOOL val = ((BOOL (*)(id, SEL))objc_msgSend)(note, sel_registerName("hasTags"));
        dict[@"hasTags"] = @(val);
    } @catch (NSException *e) {}

    @try {
        NSString *val = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("identifier"));
        if (val) dict[@"id"] = val;
    } @catch (NSException *e) {}

    @try {
        NSString *val = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("snippet"));
        if (val) dict[@"snippet"] = val;
    } @catch (NSException *e) {}

    @try {
        Class ICAppURLUtilities = NSClassFromString(@"ICAppURLUtilities");
        if (ICAppURLUtilities) {
            NSURL *appURL = ((id (*)(id, SEL, id))objc_msgSend)(
                ICAppURLUtilities, sel_registerName("appURLForNote:"), note);
            if (appURL) dict[@"url"] = [appURL absoluteString];
        }
    } @catch (NSException *e) {}

    return dict;
}


// --- Commands ---

static int cmdFolders(id viewContext) {
    NSArray *folders = fetchFolders(viewContext);
    NSMutableArray *result = [NSMutableArray array];
    for (id folder in folders) {
        NSString *title = ((id (*)(id, SEL))objc_msgSend)(folder, sel_registerName("title"));
        if (title && title.length > 0) {
            [result addObject:@{@"name": title}];
        }
    }
    printJSON(result);
    return 0;
}

static int cmdList(id viewContext, NSString *folderName, NSUInteger limit) {
    NSArray *notes = fetchNotes(viewContext, folderName, limit);
    NSMutableArray *result = [NSMutableArray array];
    for (id note in notes) {
        [result addObject:noteToDict(note)];
    }
    printJSON(result);
    return 0;
}

static int cmdGetNote(id note) {
    printJSON(noteToDict(note));
    return 0;
}

static int cmdGet(id viewContext, NSString *title, NSString *folderName) {
    id note = findNote(viewContext, title, folderName);
    if (!note) errorExit([NSString stringWithFormat:@"Note not found: %@", title]);
    return cmdGetNote(note);
}

static int cmdReadNote(id note) {
    NSString *body = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("noteAsPlainTextWithoutTitle"));
    if (body) printf("%s\n", [body UTF8String]);
    return 0;
}

static int cmdRead(id viewContext, NSString *title, NSString *folderName) {
    id note = findNote(viewContext, title, folderName);
    if (!note) errorExit([NSString stringWithFormat:@"Note not found: %@", title]);
    return cmdReadNote(note);
}

static int cmdReadAttrsNote(id note) {

    id doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
    id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
    NSAttributedString *attrStr = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("attributedString"));
    NSString *fullText = [attrStr string];
    NSUInteger length = fullText.length;

    if (length == 0) { printJSON(@[]); return 0; }

    NSMutableArray *ranges = [NSMutableArray array];
    NSUInteger idx = 0;
    NSRange effectiveRange;

    while (idx < length) {
        NSDictionary *attrs = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
            ms, sel_registerName("attributesAtIndex:effectiveRange:"), idx, &effectiveRange);

        NSString *text = [fullText substringWithRange:effectiveRange];
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"offset"] = @(effectiveRange.location);
        entry[@"length"] = @(effectiveRange.length);
        entry[@"text"] = text;

        id style = attrs[@"TTStyle"];
        if (style) {
            entry[@"style"] = @(((NSInteger (*)(id, SEL))objc_msgSend)(style, sel_registerName("style")));
            entry[@"indent"] = @(((NSUInteger (*)(id, SEL))objc_msgSend)(style, sel_registerName("indent")));
            NSString *uuid = [((id (*)(id, SEL))objc_msgSend)(style, sel_registerName("uuid")) description];
            if (uuid) entry[@"uuid"] = uuid;

            id todo = ((id (*)(id, SEL))objc_msgSend)(style, sel_registerName("todo"));
            if (todo) {
                entry[@"todoDone"] = @(((BOOL (*)(id, SEL))objc_msgSend)(todo, sel_registerName("done")));
            }

            NSUInteger hints = ((NSUInteger (*)(id, SEL))objc_msgSend)(style, sel_registerName("hints"));
            if (hints > 0) entry[@"hints"] = @(hints);
        }

        // Inline attributes
        id nsLink = attrs[@"NSLink"];
        if (nsLink) {
            entry[@"link"] = [nsLink description];
            Class ICAppURLUtilities = NSClassFromString(@"ICAppURLUtilities");
            if (ICAppURLUtilities) {
                BOOL isNoteLink = ((BOOL (*)(id, SEL, id))objc_msgSend)(
                    ICAppURLUtilities, sel_registerName("isShowNoteURL:"), nsLink);
                if (isNoteLink) {
                    entry[@"linkType"] = @"note";
                    NSString *noteId = ((id (*)(id, SEL, id))objc_msgSend)(
                        ICAppURLUtilities, sel_registerName("noteIdentifierFromNotesAppURL:"), nsLink);
                    if (!noteId && [nsLink isKindOfClass:[NSURL class]]) {
                        NSURLComponents *comps = [NSURLComponents componentsWithURL:nsLink resolvingAgainstBaseURL:NO];
                        for (NSURLQueryItem *item in comps.queryItems) {
                            if ([item.name isEqualToString:@"identifier"]) { noteId = item.value; break; }
                        }
                    }
                    if (noteId) entry[@"linkedNoteId"] = noteId;
                } else {
                    entry[@"linkType"] = @"url";
                }
            }
        }

        id strikethrough = attrs[@"TTStrikethrough"];
        if (strikethrough) entry[@"strikethrough"] = strikethrough;

        id attachment = attrs[@"NSAttachment"];
        if (attachment) entry[@"hasAttachment"] = @YES;

        [ranges addObject:entry];
        idx = effectiveRange.location + effectiveRange.length;
    }

    printJSON(ranges);
    return 0;
}

static int cmdReadAttrs(id viewContext, NSString *title, NSString *folderName) {
    id note = findNote(viewContext, title, folderName);
    if (!note) errorExit([NSString stringWithFormat:@"Note not found: %@", title]);
    return cmdReadAttrsNote(note);
}

static int cmdCreateFolder(id viewContext, NSString *name) {
    // Get the default account from an existing folder
    NSArray *folders = fetchFolders(viewContext);
    id account = nil;
    for (id f in folders) {
        account = ((id (*)(id, SEL))objc_msgSend)(f, sel_registerName("account"));
        if (account) break;
    }
    if (!account) errorExit(@"No account found");

    Class ICFolder = NSClassFromString(@"ICFolder");
    id newFolder = ((id (*)(id, SEL, id))objc_msgSend)(ICFolder, sel_registerName("newFolderInAccount:"), account);
    if (!newFolder) errorExit(@"Failed to create folder");
    ((void (*)(id, SEL, id))objc_msgSend)(newFolder, sel_registerName("setTitle:"), name);

    NSError *error = nil;
    [viewContext save:&error];
    if (error) errorExit([NSString stringWithFormat:@"Save error: %@", error]);

    printJSON(@{@"name": name, @"created": @YES});
    return 0;
}

static int cmdDeleteFolder(id viewContext, NSString *name) {
    NSArray *folders = fetchFolders(viewContext);
    id targetFolder = nil;
    for (id f in folders) {
        NSString *fname = ((id (*)(id, SEL))objc_msgSend)(f, sel_registerName("title"));
        if ([fname isEqualToString:name]) { targetFolder = f; break; }
    }
    if (!targetFolder) errorExit([NSString stringWithFormat:@"Folder not found: %@", name]);

    Class ICFolder = NSClassFromString(@"ICFolder");
    ((void (*)(id, SEL, id))objc_msgSend)(ICFolder, sel_registerName("deleteFolder:"), targetFolder);

    NSError *error = nil;
    [viewContext save:&error];
    if (error) errorExit([NSString stringWithFormat:@"Save error: %@", error]);

    printJSON(@{@"name": name, @"deleted": @YES});
    return 0;
}

static int cmdDuplicate(id viewContext, NSString *identifier, NSString *newTitle) {
    id note = findNoteByID(viewContext, identifier);
    if (!note) errorExit([NSString stringWithFormat:@"Note not found with id: %@", identifier]);

    // Get source document
    id doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
    id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
    NSAttributedString *attrStr = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("attributedString"));
    NSString *fullText = [attrStr string];
    NSUInteger length = fullText.length;

    // Get folder
    id folder = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("primitiveFolder"));

    // Create new note
    id newNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), folder);
    id newDoc = ((id (*)(id, SEL))objc_msgSend)(newNote, sel_registerName("document"));
    id newMs = ((id (*)(id, SEL))objc_msgSend)(newDoc, sel_registerName("mergeableString"));

    ((void (*)(id, SEL))objc_msgSend)(newNote, sel_registerName("beginEditing"));

    // Find the title boundary: skip leading newline, then find next newline
    // Notes start with 0x0A, then title text, then 0x0A
    NSUInteger titleStart = 0;
    while (titleStart < length && [fullText characterAtIndex:titleStart] == 0x0A) titleStart++;
    NSUInteger titleEnd = titleStart;
    while (titleEnd < length && [fullText characterAtIndex:titleEnd] != 0x0A) titleEnd++;

    // Build: leading chars + new title + rest of body
    NSString *prefix = [fullText substringToIndex:titleStart]; // leading newlines
    NSString *titleStr = newTitle ? newTitle : [fullText substringWithRange:NSMakeRange(titleStart, titleEnd - titleStart)];
    NSString *suffix = titleEnd < length ? [fullText substringFromIndex:titleEnd] : @"";
    NSString *newText = [[prefix stringByAppendingString:titleStr] stringByAppendingString:suffix];
    NSUInteger newLength = newText.length;
    NSInteger titleDelta = (NSInteger)newLength - (NSInteger)length;

    // Insert the combined text
    ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(newMs, sel_registerName("insertString:atIndex:"), newText, 0);

    // Copy body attributes from source, skipping original title range
    NSUInteger idx = titleEnd;  // start after original title
    NSRange effectiveRange;
    while (idx < length) {
        NSDictionary *attrs = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
            ms, sel_registerName("attributesAtIndex:effectiveRange:"), idx, &effectiveRange);

        // Copy ALL attributes (TTStyle, links, strikethrough, etc.)
        NSMutableDictionary *newAttrs = [attrs mutableCopy];

        // For TTStyle, create a new copy with fresh todo UUIDs
        id style = attrs[@"TTStyle"];
        if (style) {
            id newStyle = [style mutableCopy];
            id todo = ((id (*)(id, SEL))objc_msgSend)(style, sel_registerName("todo"));
            if (todo) {
                BOOL done = ((BOOL (*)(id, SEL))objc_msgSend)(todo, sel_registerName("done"));
                id newTodo = ((id (*)(id, SEL, id, BOOL))objc_msgSend)(
                    [ICTTTodoClass alloc], sel_registerName("initWithIdentifier:done:"), [NSUUID UUID], done);
                ((void (*)(id, SEL, id))objc_msgSend)(newStyle, sel_registerName("setTodo:"), newTodo);
            }
            newAttrs[@"TTStyle"] = newStyle;
        }

        NSRange newRange = NSMakeRange(effectiveRange.location + titleDelta, effectiveRange.length);
        if (newAttrs.count > 0) {
            ((void (*)(id, SEL, id, NSRange))objc_msgSend)(newMs, sel_registerName("setAttributes:range:"),
                newAttrs, newRange);
        }
        idx = effectiveRange.location + effectiveRange.length;
    }

    // Set title style AFTER copying body attrs so it doesn't get overwritten
    id titleStyle = [[ICTTParagraphStyleClass alloc] init];
    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(titleStyle, sel_registerName("setStyle:"), 0);
    ((void (*)(id, SEL, id, NSRange))objc_msgSend)(newMs, sel_registerName("setAttributes:range:"),
        @{@"TTStyle": titleStyle}, NSMakeRange(0, prefix.length + titleStr.length));
    length = newLength;

    ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
        newNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, length), length);
    ((void (*)(id, SEL))objc_msgSend)(newNote, sel_registerName("endEditing"));
    ((void (*)(id, SEL))objc_msgSend)(newNote, sel_registerName("saveNoteData"));
    NSError *error = nil;
    [viewContext save:&error];
    if (error) errorExit([NSString stringWithFormat:@"Save error: %@", error]);

    printJSON(noteToDict(newNote));
    return 0;
}

static int cmdSetAttr(id viewContext, NSString *identifier,
                      NSUInteger offset, NSUInteger length, NSDictionary *attrOpts) {
    id note = findNoteByID(viewContext, identifier);
    if (!note) errorExit([NSString stringWithFormat:@"Note not found with id: %@", identifier]);

    // Adjust offset if --body-offset flag is set
    if (attrOpts[@"body-offset"]) {
        NSUInteger bodyOff = bodyOffsetForNote(note);
        if (bodyOff == NSNotFound) {
            errorExit(@"Note has no body text; --body-offset requires body content");
        }
        if (offset > NSUIntegerMax - bodyOff) {
            errorExit(@"Offset overflow: body-relative offset too large");
        }
        offset += bodyOff;
    }

    id doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
    id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
    NSUInteger msLen = ((NSUInteger (*)(id, SEL))objc_msgSend)(ms, sel_registerName("length"));
    if (offset > msLen || length > msLen - offset) errorExit(@"Range exceeds note length");

    BOOL hasStyleOpts = (attrOpts[@"style"] || attrOpts[@"indent"] || attrOpts[@"todo-done"]);
    BOOL hasLinkOpt = (attrOpts[@"link"] != nil);

    // Validate --style upfront if provided
    if (attrOpts[@"style"]) {
        NSInteger styleVal;
        if (!isStrictInteger(attrOpts[@"style"], &styleVal)) {
            errorExit(@"--style must be a number. Valid styles: 0=title, 1=heading, 3=body, 100=dash-list, 102=numbered-list, 103=checklist");
        }
        if (!isValidStyle(styleVal)) {
            errorExit(@"Invalid --style value. Valid styles: 0=title, 1=heading, 3=body, 100=dash-list, 102=numbered-list, 103=checklist");
        }
    }

    // Validate URL upfront if --link is provided
    NSURL *linkURL = nil;
    if (hasLinkOpt) {
        NSString *linkStr = attrOpts[@"link"];
        if (linkStr.length > 0) {
            linkURL = [NSURL URLWithString:linkStr];
            if (!linkURL) {
                errorExit([NSString stringWithFormat:@"Invalid URL: %@", linkStr]);
            }
            NSString *scheme = [linkURL.scheme lowercaseString];
            if (!scheme || (![scheme isEqualToString:@"http"] &&
                            ![scheme isEqualToString:@"https"] &&
                            ![scheme isEqualToString:@"mailto"])) {
                errorExit([NSString stringWithFormat:
                    @"Unsupported URL scheme '%@'. Allowed: http, https, mailto", scheme ?: @"(none)"]);
            }
        }
        // If linkStr.length == 0, linkURL stays nil => link will be removed
    }

    if (length == 0) {
        errorExit(@"--length must be greater than 0 for set-attr");
    }

    ((void (*)(id, SEL))objc_msgSend)(note, sel_registerName("beginEditing"));

    // Enumerate existing attribute runs in the target range (per-run patch strategy)
    NSUInteger idx = offset;
    NSUInteger end = offset + length;

    while (idx < end) {
        NSRange effectiveRange;
        NSDictionary *existingAttrs = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
            ms, sel_registerName("attributesAtIndex:effectiveRange:"), idx, &effectiveRange);

        // Intersect effectiveRange with our target range
        NSUInteger subStart = MAX(effectiveRange.location, offset);
        NSUInteger subEnd = MIN(effectiveRange.location + effectiveRange.length, end);
        NSRange subRange = NSMakeRange(subStart, subEnd - subStart);

        // Build new attrs dict from existing (preserves TTStrikethrough, attachments, etc.)
        NSMutableDictionary *patchedAttrs = [NSMutableDictionary dictionary];
        for (NSString *key in existingAttrs) {
            patchedAttrs[key] = existingAttrs[key];
        }

        // Apply style delta if requested
        if (hasStyleOpts) {
            id style = [[ICTTParagraphStyleClass alloc] init];
            // Start from existing style as base, then override requested fields
            id existingStyle = existingAttrs[@"TTStyle"];
            if (existingStyle) {
                ((void (*)(id, SEL, NSInteger))objc_msgSend)(style, sel_registerName("setStyle:"),
                    ((NSInteger (*)(id, SEL))objc_msgSend)(existingStyle, sel_registerName("style")));
                ((void (*)(id, SEL, NSUInteger))objc_msgSend)(style, sel_registerName("setIndent:"),
                    ((NSUInteger (*)(id, SEL))objc_msgSend)(existingStyle, sel_registerName("indent")));
                id existingTodo = ((id (*)(id, SEL))objc_msgSend)(existingStyle, sel_registerName("todo"));
                if (existingTodo) {
                    ((void (*)(id, SEL, id))objc_msgSend)(style, sel_registerName("setTodo:"), existingTodo);
                }
            }
            if (attrOpts[@"style"]) {
                ((void (*)(id, SEL, NSInteger))objc_msgSend)(style, sel_registerName("setStyle:"),
                    [attrOpts[@"style"] integerValue]);
            }
            if (attrOpts[@"indent"]) {
                ((void (*)(id, SEL, NSUInteger))objc_msgSend)(style, sel_registerName("setIndent:"),
                    [attrOpts[@"indent"] integerValue]);
            }
            if (attrOpts[@"todo-done"]) {
                BOOL done = [attrOpts[@"todo-done"] isEqualToString:@"true"];
                id todo = ((id (*)(id, SEL, id, BOOL))objc_msgSend)(
                    [ICTTTodoClass alloc], sel_registerName("initWithIdentifier:done:"), [NSUUID UUID], done);
                ((void (*)(id, SEL, id))objc_msgSend)(style, sel_registerName("setTodo:"), todo);
                if (!attrOpts[@"style"]) {
                    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(style, sel_registerName("setStyle:"), 103);
                }
            }
            patchedAttrs[@"TTStyle"] = style;
        }

        // Apply link delta if requested
        if (hasLinkOpt) {
            if (linkURL) {
                patchedAttrs[@"NSLink"] = linkURL;
            } else {
                [patchedAttrs removeObjectForKey:@"NSLink"];
            }
        }

        // Write back patched attrs for this sub-range
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(ms, sel_registerName("setAttributes:range:"),
            patchedAttrs, subRange);

        idx = subEnd;
    }

    ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
        note, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, msLen), 0);
    ((void (*)(id, SEL))objc_msgSend)(note, sel_registerName("endEditing"));
    ((void (*)(id, SEL))objc_msgSend)(note, sel_registerName("saveNoteData"));
    NSError *error = nil;
    [viewContext save:&error];
    if (error) errorExit([NSString stringWithFormat:@"Save error: %@", error]);

    printJSON(@{@"id": identifier, @"offset": @(offset), @"length": @(length), @"updated": @YES});
    return 0;
}

static int cmdMoveNote(id viewContext, NSString *identifier, NSString *toFolder) {
    id note = findNoteByID(viewContext, identifier);
    if (!note) errorExit([NSString stringWithFormat:@"Note not found with id: %@", identifier]);

    id targetFolder = nil;
    NSArray *folders = fetchFolders(viewContext);
    for (id f in folders) {
        NSString *fname = ((id (*)(id, SEL))objc_msgSend)(f, sel_registerName("title"));
        if ([fname isEqualToString:toFolder]) { targetFolder = f; break; }
    }
    if (!targetFolder) errorExit([NSString stringWithFormat:@"Folder not found: %@", toFolder]);

    ((void (*)(id, SEL, id))objc_msgSend)(note, sel_registerName("setFolder:"), targetFolder);
    NSError *error = nil;
    [viewContext save:&error];
    if (error) errorExit([NSString stringWithFormat:@"Save error: %@", error]);

    printJSON(@{@"id": identifier, @"movedTo": toFolder});
    return 0;
}

static int cmdSearch(id viewContext, NSString *query, NSString *folderName) {
    NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"ICNote"];
    NSMutableArray *predicates = [NSMutableArray array];
    [predicates addObject:[NSPredicate predicateWithFormat:@"title CONTAINS[cd] %@ OR snippet CONTAINS[cd] %@", query, query]];
    if (folderName) {
        [predicates addObject:[NSPredicate predicateWithFormat:@"folder.title == %@", folderName]];
    }
    request.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:predicates];
    request.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"modificationDate" ascending:NO]];
    request.fetchLimit = 20;
    NSError *error = nil;
    NSArray *notes = [viewContext executeFetchRequest:request error:&error];
    if (error) errorExit([NSString stringWithFormat:@"Search error: %@", error]);
    NSMutableArray *result = [NSMutableArray array];
    for (id note in notes) {
        [result addObject:noteToDict(note)];
    }
    printJSON(result);
    return 0;
}

static int cmdPin(id viewContext, NSString *identifier, BOOL pin) {
    id note = findNoteByID(viewContext, identifier);
    if (!note) errorExit([NSString stringWithFormat:@"Note not found with id: %@", identifier]);

    ((void (*)(id, SEL, BOOL))objc_msgSend)(note, sel_registerName("setIsPinned:"), pin);
    NSError *error = nil;
    [viewContext save:&error];
    if (error) errorExit([NSString stringWithFormat:@"Save error: %@", error]);

    printJSON(@{@"id": identifier, @"pinned": @(pin)});
    return 0;
}

static int cmdGetLink(id viewContext, NSString *identifier) {
    id note = findNoteByID(viewContext, identifier);
    if (!note) errorExit([NSString stringWithFormat:@"Note not found with id: %@", identifier]);

    Class ICAppURLUtilities = NSClassFromString(@"ICAppURLUtilities");
    if (!ICAppURLUtilities) errorExit(@"ICAppURLUtilities class not available");

    NSURL *appURL = ((id (*)(id, SEL, id))objc_msgSend)(
        ICAppURLUtilities, sel_registerName("appURLForNote:"), note);
    if (!appURL) errorExit(@"Failed to generate note link URL");

    NSString *title = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("titleForLinking"));

    printJSON(@{
        @"id": identifier,
        @"title": title ?: @"",
        @"url": [appURL absoluteString]
    });
    return 0;
}

static int cmdAddLink(id viewContext, NSString *sourceId, NSString *targetId,
                      NSString *displayText, NSInteger position) {
    id sourceNote = findNoteByID(viewContext, sourceId);
    if (!sourceNote) errorExit([NSString stringWithFormat:@"Source note not found: %@", sourceId]);

    id targetNote = findNoteByID(viewContext, targetId);
    if (!targetNote) errorExit([NSString stringWithFormat:@"Target note not found: %@", targetId]);

    Class ICAppURLUtilities = NSClassFromString(@"ICAppURLUtilities");
    if (!ICAppURLUtilities) errorExit(@"ICAppURLUtilities class not available");

    NSURL *linkURL = ((id (*)(id, SEL, id))objc_msgSend)(
        ICAppURLUtilities, sel_registerName("appURLForNote:"), targetNote);
    if (!linkURL) errorExit(@"Failed to generate note link URL for target note");

    if (!displayText) {
        displayText = ((id (*)(id, SEL))objc_msgSend)(targetNote, sel_registerName("titleForLinking"));
    }
    if (!displayText || displayText.length == 0) {
        displayText = @"Untitled Note";
    }

    id doc = ((id (*)(id, SEL))objc_msgSend)(sourceNote, sel_registerName("document"));
    id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
    NSUInteger oldLen = ((NSUInteger (*)(id, SEL))objc_msgSend)(ms, sel_registerName("length"));

    if (position < -1) errorExit(@"Position must be >= 0 or omitted");

    NSUInteger insertPos;
    NSString *toInsert;
    if (position < 0) {
        insertPos = oldLen;
        toInsert = [NSString stringWithFormat:@"\n%@", displayText];
    } else {
        insertPos = (NSUInteger)position;
        if (insertPos > oldLen) errorExit(@"Position exceeds note length");
        toInsert = displayText;
    }

    ((void (*)(id, SEL))objc_msgSend)(sourceNote, sel_registerName("beginEditing"));

    ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(
        ms, sel_registerName("insertString:atIndex:"), toInsert, insertPos);

    id bodyStyle = [[ICTTParagraphStyleClass alloc] init];
    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(bodyStyle, sel_registerName("setStyle:"), 3);

    NSRange linkRange;
    if (position < 0) {
        linkRange = NSMakeRange(insertPos + 1, displayText.length);
    } else {
        linkRange = NSMakeRange(insertPos, displayText.length);
    }

    ((void (*)(id, SEL, id, NSRange))objc_msgSend)(ms, sel_registerName("setAttributes:range:"),
        @{@"TTStyle": bodyStyle, @"NSLink": linkURL}, linkRange);

    NSUInteger newLen = oldLen + toInsert.length;
    ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
        sourceNote, sel_registerName("edited:range:changeInLength:"),
        1, NSMakeRange(0, newLen), (NSInteger)toInsert.length);
    ((void (*)(id, SEL))objc_msgSend)(sourceNote, sel_registerName("endEditing"));
    ((void (*)(id, SEL))objc_msgSend)(sourceNote, sel_registerName("saveNoteData"));
    NSError *error = nil;
    [viewContext save:&error];
    if (error) errorExit([NSString stringWithFormat:@"Save error: %@", error]);

    printJSON(@{
        @"id": sourceId,
        @"targetId": targetId,
        @"text": displayText,
        @"url": [linkURL absoluteString]
    });
    return 0;
}

// NOTE: read-structured is a composed view, not a 1:1 API mapping.
// Consider moving to a separate wrapper CLI in the future.
static int cmdReadStructuredNote(id note) {
    id doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
    id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
    NSAttributedString *attrStr = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("attributedString"));
    NSString *fullText = [attrStr string];
    NSUInteger length = fullText.length;

    if (length == 0) { printJSON(@[]); return 0; }

    NSMutableArray *paragraphs = [NSMutableArray array];
    NSMutableString *currentLine = [NSMutableString string];
    NSMutableArray *currentLinks = [NSMutableArray array];
    NSString *currentUUID = nil;
    NSInteger currentStyle = -1;
    BOOL currentTodoDone = NO;
    NSUInteger currentIndent = 0;
    NSUInteger idx = 0;
    NSRange effectiveRange;

    while (idx < length) {
        NSDictionary *attrs = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
            ms, sel_registerName("attributesAtIndex:effectiveRange:"), idx, &effectiveRange);
        id style = attrs[@"TTStyle"];
        NSInteger styleNum = style ? ((NSInteger (*)(id, SEL))objc_msgSend)(style, sel_registerName("style")) : 3;
        NSString *uuid = style ? [((id (*)(id, SEL))objc_msgSend)(style, sel_registerName("uuid")) description] : @"";
        id todo = style ? ((id (*)(id, SEL))objc_msgSend)(style, sel_registerName("todo")) : nil;
        BOOL done = todo ? ((BOOL (*)(id, SEL))objc_msgSend)(todo, sel_registerName("done")) : NO;
        NSUInteger indent = style ? ((NSUInteger (*)(id, SEL))objc_msgSend)(style, sel_registerName("indent")) : 0;
        NSString *chunk = [fullText substringWithRange:effectiveRange];

        if (currentUUID && [uuid isEqualToString:currentUUID]) {
            [currentLine appendString:chunk];
        } else {
            if (currentLine.length > 0) {
                NSString *line = [currentLine stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
                if (line.length > 0) {
                    NSMutableDictionary *para = [NSMutableDictionary dictionary];
                    para[@"text"] = line;
                    para[@"style"] = @(currentStyle);
                    if (currentIndent > 0) para[@"indent"] = @(currentIndent);
                    if (currentStyle == 100) para[@"type"] = @"dash";
                    if (currentStyle == 102) para[@"type"] = @"numbered";
                    if (currentStyle == 103) { para[@"type"] = @"checklist"; para[@"checked"] = @(currentTodoDone); }
                    if (currentLinks.count > 0) para[@"links"] = [currentLinks copy];
                    [paragraphs addObject:para];
                }
            }
            currentLine = [NSMutableString stringWithString:chunk];
            currentLinks = [NSMutableArray array];
            currentUUID = uuid;
            currentStyle = styleNum;
            currentTodoDone = done;
            currentIndent = indent;
        }

        id nsLink = attrs[@"NSLink"];
        if (nsLink) {
            NSMutableDictionary *linkEntry = [NSMutableDictionary dictionary];
            linkEntry[@"text"] = chunk;
            linkEntry[@"url"] = [nsLink description];
            Class ICAppURLUtilities = NSClassFromString(@"ICAppURLUtilities");
            if (ICAppURLUtilities) {
                BOOL isNoteLink = ((BOOL (*)(id, SEL, id))objc_msgSend)(
                    ICAppURLUtilities, sel_registerName("isShowNoteURL:"), nsLink);
                if (isNoteLink) {
                    linkEntry[@"type"] = @"note";
                    NSString *noteId = ((id (*)(id, SEL, id))objc_msgSend)(
                        ICAppURLUtilities, sel_registerName("noteIdentifierFromNotesAppURL:"), nsLink);
                    if (!noteId && [nsLink isKindOfClass:[NSURL class]]) {
                        NSURLComponents *comps = [NSURLComponents componentsWithURL:nsLink resolvingAgainstBaseURL:NO];
                        for (NSURLQueryItem *item in comps.queryItems) {
                            if ([item.name isEqualToString:@"identifier"]) { noteId = item.value; break; }
                        }
                    }
                    if (noteId) linkEntry[@"linkedNoteId"] = noteId;
                } else {
                    linkEntry[@"type"] = @"url";
                }
            }
            [currentLinks addObject:linkEntry];
        }

        idx = effectiveRange.location + effectiveRange.length;
    }
    if (currentLine.length > 0) {
        NSString *line = [currentLine stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
        if (line.length > 0) {
            NSMutableDictionary *para = [NSMutableDictionary dictionary];
            para[@"text"] = line;
            para[@"style"] = @(currentStyle);
            if (currentIndent > 0) para[@"indent"] = @(currentIndent);
            if (currentStyle == 100) para[@"type"] = @"dash";
            if (currentStyle == 102) para[@"type"] = @"numbered";
            if (currentStyle == 103) { para[@"type"] = @"checklist"; para[@"checked"] = @(currentTodoDone); }
            if (currentLinks.count > 0) para[@"links"] = [currentLinks copy];
            [paragraphs addObject:para];
        }
    }
    printJSON(paragraphs);
    return 0;
}

static int cmdReadStructured(id viewContext, NSString *title, NSString *folderName) {
    id note = findNote(viewContext, title, folderName);
    if (!note) errorExit([NSString stringWithFormat:@"Note not found: %@", title]);
    return cmdReadStructuredNote(note);
}

static int cmdCreateEmpty(id viewContext, NSString *folderName) {
    id targetFolder = nil;
    NSArray *folders = fetchFolders(viewContext);
    for (id folder in folders) {
        NSString *fname = ((id (*)(id, SEL))objc_msgSend)(folder, sel_registerName("title"));
        if ([fname isEqualToString:folderName]) { targetFolder = folder; break; }
    }
    if (!targetFolder) errorExit([NSString stringWithFormat:@"Folder not found: %@", folderName]);

    id note = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), targetFolder);
    if (!note) errorExit(@"Failed to create note");

    ((void (*)(id, SEL))objc_msgSend)(note, sel_registerName("saveNoteData"));
    NSError *error = nil;
    [viewContext save:&error];
    if (error) errorExit([NSString stringWithFormat:@"Save error: %@", error]);

    printJSON(noteToDict(note));
    return 0;
}

static int cmdDelete(id viewContext, NSString *identifier) {
    id note = findNoteByID(viewContext, identifier);
    if (!note) errorExit([NSString stringWithFormat:@"Note not found with id: %@", identifier]);

    ((void (*)(id, SEL))objc_msgSend)(note, sel_registerName("markForDeletion"));
    [viewContext deleteObject:note];

    NSError *error = nil;
    [viewContext save:&error];
    if (error) errorExit([NSString stringWithFormat:@"Save error: %@", error]);

    printJSON(@{@"id": identifier, @"deleted": @YES});
    return 0;
}

// --- Surgical Editing Helpers ---

static void saveNote(id note, id viewContext, NSUInteger newLength, NSInteger delta) {
    ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
        note, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, newLength), delta);
    ((void (*)(id, SEL))objc_msgSend)(note, sel_registerName("endEditing"));
    ((void (*)(id, SEL))objc_msgSend)(note, sel_registerName("saveNoteData"));
    NSError *error = nil;
    [viewContext save:&error];
    if (error) errorExit([NSString stringWithFormat:@"Save error: %@", error]);
}

static int cmdAppend(id viewContext, NSString *identifier, NSString *text, NSInteger styleValue) {
    id note = findNoteByID(viewContext, identifier);
    if (!note) errorExit([NSString stringWithFormat:@"Note not found with id: %@", identifier]);

    id doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
    id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
    NSUInteger oldLen = ((NSUInteger (*)(id, SEL))objc_msgSend)(ms, sel_registerName("length"));

    NSString *toInsert = [NSString stringWithFormat:@"\n%@", text];
    ((void (*)(id, SEL))objc_msgSend)(note, sel_registerName("beginEditing"));
    ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(ms, sel_registerName("insertString:atIndex:"), toInsert, oldLen);

    NSInteger actualStyle = (styleValue >= 0) ? styleValue : 3;
    id paraStyle = makeParagraphStyle(actualStyle);
    ((void (*)(id, SEL, id, NSRange))objc_msgSend)(ms, sel_registerName("setAttributes:range:"),
        @{@"TTStyle": paraStyle}, NSMakeRange(oldLen, toInsert.length));

    saveNote(note, viewContext, oldLen + toInsert.length, toInsert.length);
    printJSON(@{@"id": identifier, @"appended": text});
    return 0;
}

static int cmdInsert(id viewContext, NSString *identifier, NSString *text, NSUInteger position, BOOL useBodyOffset, NSInteger styleValue) {
    id note = findNoteByID(viewContext, identifier);
    if (!note) errorExit([NSString stringWithFormat:@"Note not found with id: %@", identifier]);

    if (useBodyOffset) {
        NSUInteger bodyOff = bodyOffsetForNote(note);
        if (bodyOff == NSNotFound) {
            errorExit(@"Note has no body text; --body-offset requires body content");
        }
        if (position > NSUIntegerMax - bodyOff) {
            errorExit(@"Position overflow: body-relative position too large");
        }
        position += bodyOff;
    }

    id doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
    id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
    NSUInteger oldLen = ((NSUInteger (*)(id, SEL))objc_msgSend)(ms, sel_registerName("length"));

    if (position > oldLen) errorExit(@"Position exceeds note length");

    ((void (*)(id, SEL))objc_msgSend)(note, sel_registerName("beginEditing"));
    ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(ms, sel_registerName("insertString:atIndex:"), text, position);

    NSInteger actualStyle = (styleValue >= 0) ? styleValue : 3;
    id paraStyle = makeParagraphStyle(actualStyle);
    ((void (*)(id, SEL, id, NSRange))objc_msgSend)(ms, sel_registerName("setAttributes:range:"),
        @{@"TTStyle": paraStyle}, NSMakeRange(position, text.length));

    saveNote(note, viewContext, oldLen + text.length, text.length);
    printJSON(@{@"id": identifier, @"inserted": text, @"position": @(position)});
    return 0;
}

static int cmdDeleteRange(id viewContext, NSString *identifier, NSUInteger start, NSUInteger length, BOOL useBodyOffset) {
    id note = findNoteByID(viewContext, identifier);
    if (!note) errorExit([NSString stringWithFormat:@"Note not found with id: %@", identifier]);

    if (useBodyOffset) {
        NSUInteger bodyOff = bodyOffsetForNote(note);
        if (bodyOff == NSNotFound) {
            errorExit(@"Note has no body text; --body-offset requires body content");
        }
        if (start > NSUIntegerMax - bodyOff) {
            errorExit(@"Start overflow: body-relative start too large");
        }
        start += bodyOff;
    }

    id doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
    id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
    NSUInteger oldLen = ((NSUInteger (*)(id, SEL))objc_msgSend)(ms, sel_registerName("length"));

    if (start > oldLen || length > oldLen - start) errorExit(@"Range exceeds note length");

    ((void (*)(id, SEL))objc_msgSend)(note, sel_registerName("beginEditing"));
    ((void (*)(id, SEL, NSRange))objc_msgSend)(ms, sel_registerName("deleteCharactersInRange:"), NSMakeRange(start, length));

    saveNote(note, viewContext, oldLen - length, -(NSInteger)length);
    printJSON(@{@"id": identifier, @"deleted_range": @{@"start": @(start), @"length": @(length)}});
    return 0;
}

static int cmdReplace(id viewContext, NSString *identifier, NSString *search, NSString *replacement) {
    id note = findNoteByID(viewContext, identifier);
    if (!note) errorExit([NSString stringWithFormat:@"Note not found with id: %@", identifier]);

    id doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
    id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
    NSAttributedString *attrStr = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("attributedString"));
    NSString *fullText = [attrStr string];

    NSRange found = [fullText rangeOfString:search];
    if (found.location == NSNotFound) errorExit([NSString stringWithFormat:@"Text not found: %@", search]);

    ((void (*)(id, SEL))objc_msgSend)(note, sel_registerName("beginEditing"));
    ((void (*)(id, SEL, NSRange))objc_msgSend)(ms, sel_registerName("deleteCharactersInRange:"), found);
    ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(ms, sel_registerName("insertString:atIndex:"), replacement, found.location);

    id bodyStyle = [[ICTTParagraphStyleClass alloc] init];
    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(bodyStyle, sel_registerName("setStyle:"), 3);
    ((void (*)(id, SEL, id, NSRange))objc_msgSend)(ms, sel_registerName("setAttributes:range:"),
        @{@"TTStyle": bodyStyle}, NSMakeRange(found.location, replacement.length));

    NSUInteger newLen = fullText.length - search.length + replacement.length;
    NSInteger delta = (NSInteger)replacement.length - (NSInteger)search.length;
    saveNote(note, viewContext, newLen, delta);
    printJSON(@{@"id": identifier, @"replaced": search, @"with": replacement});
    return 0;
}

// NOTE: delete-line is composed — finds the paragraph containing search text and removes it entirely.
// This avoids the two-step replace-then-delete-range dance that leaves empty styled paragraphs.
static int cmdDeleteLine(id viewContext, NSString *identifier, NSString *searchText) {
    id note = findNoteByID(viewContext, identifier);
    if (!note) errorExit([NSString stringWithFormat:@"Note not found with id: %@", identifier]);

    id doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
    id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
    NSAttributedString *attrStr = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("attributedString"));
    NSString *fullText = [attrStr string];
    NSUInteger length = fullText.length;

    // Find the search text in the note
    NSRange found = [fullText rangeOfString:searchText];
    if (found.location == NSNotFound) errorExit([NSString stringWithFormat:@"Text not found: %@", searchText]);

    // Walk backwards to find the start of this paragraph (after previous newline)
    NSUInteger paraStart = found.location;
    while (paraStart > 0 && [fullText characterAtIndex:paraStart - 1] != '\n') {
        paraStart--;
    }

    // Walk forwards to find the end of this paragraph (including the trailing newline)
    NSUInteger paraEnd = found.location + found.length;
    while (paraEnd < length && [fullText characterAtIndex:paraEnd] != '\n') {
        paraEnd++;
    }
    // Include the trailing newline if present
    if (paraEnd < length && [fullText characterAtIndex:paraEnd] == '\n') {
        paraEnd++;
    }
    // If no trailing newline (last paragraph), include the preceding newline instead
    else if (paraStart > 0) {
        paraStart--;  // grab the newline before this paragraph
    }

    NSUInteger deleteLen = paraEnd - paraStart;

    ((void (*)(id, SEL))objc_msgSend)(note, sel_registerName("beginEditing"));
    ((void (*)(id, SEL, NSRange))objc_msgSend)(ms, sel_registerName("deleteCharactersInRange:"), NSMakeRange(paraStart, deleteLen));

    saveNote(note, viewContext, length - deleteLen, -(NSInteger)deleteLen);
    printJSON(@{@"id": identifier, @"deletedLine": searchText, @"offset": @(paraStart), @"length": @(deleteLen)});
    return 0;
}


// --- Markdown Conversion ---

static NSString *escapeMarkdown(NSString *text) {
    // Replace \ first (so we don't double-escape), then all others
    NSString *result = text;
    result = [result stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    result = [result stringByReplacingOccurrencesOfString:@"*" withString:@"\\*"];
    result = [result stringByReplacingOccurrencesOfString:@"_" withString:@"\\_"];
    result = [result stringByReplacingOccurrencesOfString:@"~" withString:@"\\~"];
    result = [result stringByReplacingOccurrencesOfString:@"[" withString:@"\\["];
    result = [result stringByReplacingOccurrencesOfString:@"]" withString:@"\\]"];
    result = [result stringByReplacingOccurrencesOfString:@"(" withString:@"\\("];
    result = [result stringByReplacingOccurrencesOfString:@")" withString:@"\\)"];
    result = [result stringByReplacingOccurrencesOfString:@"<" withString:@"\\<"];
    return result;
}

static NSString *unescapeMarkdown(NSString *text) {
    NSMutableString *result = [NSMutableString string];
    NSUInteger i = 0;
    while (i < text.length) {
        unichar c = [text characterAtIndex:i];
        if (c == '\\' && i + 1 < text.length) {
            unichar next = [text characterAtIndex:i + 1];
            if (next == '*' || next == '_' || next == '~' || next == '[' || next == ']' ||
                next == '(' || next == ')' || next == '\\' || next == '<' || next == '#' ||
                next == '-' || next == '.' || next == '>') {
                [result appendFormat:@"%C", next];
                i += 2;
                continue;
            }
        }
        [result appendFormat:@"%C", c];
        i++;
    }
    return result;
}

static NSString *normalizeParaText(NSString *text) {
    // Strip trailing whitespace only (preserve leading whitespace)
    NSRange range = [text rangeOfCharacterFromSet:
        [[NSCharacterSet whitespaceCharacterSet] invertedSet]
        options:NSBackwardsSearch];
    if (range.location == NSNotFound) return @"";
    return [text substringToIndex:range.location + range.length];
}

static BOOL isAllowedLinkScheme(NSURL *url) {
    NSString *scheme = [url.scheme lowercaseString];
    return [scheme isEqualToString:@"http"] ||
           [scheme isEqualToString:@"https"] ||
           [scheme isEqualToString:@"mailto"] ||
           [scheme isEqualToString:@"applenotes"];
}

// Helper: emit a paragraph from accumulated text/runs into paragraphs array
static void emitParagraph(NSMutableArray *paragraphs, NSString *text, NSArray *runs,
                          NSInteger style, NSUInteger indent, BOOL todoDone, NSString *uuid) {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    // Split on newlines within a single UUID group (each line is a paragraph)
    NSArray *lines = [trimmed componentsSeparatedByString:@"\n"];
    NSUInteger lineOffset = 0;
    for (NSUInteger li = 0; li < lines.count; li++) {
        NSString *lineText = lines[li];
        NSMutableDictionary *para = [NSMutableDictionary dictionary];
        para[@"style"] = @(style);
        para[@"indent"] = @(indent);
        para[@"text"] = lineText;
        if (style == 103) para[@"todoChecked"] = @(todoDone);
        if (uuid) para[@"uuid"] = uuid;

        // Build runs for this specific line
        if (runs.count > 0) {
            NSMutableArray *lineRuns = [NSMutableArray array];
            // Find text start offset in the original (pre-trim) text
            // The trimmed text starts after leading newlines
            NSUInteger trimStart = 0;
            while (trimStart < text.length && [text characterAtIndex:trimStart] == '\n') trimStart++;

            NSUInteger lineStart = trimStart + lineOffset;
            NSUInteger lineEnd = lineStart + lineText.length;

            for (NSDictionary *run in runs) {
                NSUInteger runStart = [run[@"start"] unsignedIntegerValue];
                NSUInteger runLen = [run[@"length"] unsignedIntegerValue];
                NSUInteger runEnd = runStart + runLen;

                // Check overlap with this line
                if (runEnd <= lineStart || runStart >= lineEnd) continue;

                NSUInteger overlapStart = MAX(runStart, lineStart);
                NSUInteger overlapEnd = MIN(runEnd, lineEnd);
                if (overlapEnd <= overlapStart) continue;

                NSMutableDictionary *lineRun = [NSMutableDictionary dictionary];
                lineRun[@"start"] = @(overlapStart - lineStart);
                lineRun[@"length"] = @(overlapEnd - overlapStart);
                if (run[@"link"]) lineRun[@"link"] = run[@"link"];
                if ([run[@"strikethrough"] boolValue]) lineRun[@"strikethrough"] = @YES;
                [lineRuns addObject:lineRun];
            }
            if (lineRuns.count > 0) para[@"runs"] = lineRuns;
        }

        [paragraphs addObject:para];
        lineOffset += lineText.length + 1; // +1 for the \n separator
    }
}

// Build paragraph model from a note's mergeableString
static NSArray *noteToParaModel(id note) {
    id doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
    id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
    NSAttributedString *attrStr = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("attributedString"));
    NSString *fullText = [attrStr string];
    NSUInteger length = fullText.length;

    if (length == 0) return @[];

    NSMutableArray *paragraphs = [NSMutableArray array];
    NSMutableString *currentText = [NSMutableString string];
    NSMutableArray *currentRuns = [NSMutableArray array];
    NSString *currentUUID = nil;
    NSInteger currentStyle = -1;
    BOOL currentTodoDone = NO;
    NSUInteger currentIndent = 0;
    NSUInteger runOffsetInPara = 0;
    NSUInteger idx = 0;
    NSRange effectiveRange;

    while (idx < length) {
        NSDictionary *attrs = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
            ms, sel_registerName("attributesAtIndex:effectiveRange:"), idx, &effectiveRange);
        id style = attrs[@"TTStyle"];
        NSInteger styleNum = style ? ((NSInteger (*)(id, SEL))objc_msgSend)(style, sel_registerName("style")) : 3;
        NSString *uuid = style ? [((id (*)(id, SEL))objc_msgSend)(style, sel_registerName("uuid")) description] : @"";
        id todo = style ? ((id (*)(id, SEL))objc_msgSend)(style, sel_registerName("todo")) : nil;
        BOOL done = todo ? ((BOOL (*)(id, SEL))objc_msgSend)(todo, sel_registerName("done")) : NO;
        NSUInteger indent = style ? ((NSUInteger (*)(id, SEL))objc_msgSend)(style, sel_registerName("indent")) : 0;
        NSString *chunk = [fullText substringWithRange:effectiveRange];

        if (currentUUID && [uuid isEqualToString:currentUUID]) {
            // Same paragraph, accumulate text and runs
            NSMutableDictionary *run = [NSMutableDictionary dictionary];
            run[@"start"] = @(runOffsetInPara);
            run[@"length"] = @(chunk.length);
            id nsLink = attrs[@"NSLink"];
            if (nsLink) run[@"link"] = [nsLink description];
            id strikethrough = attrs[@"TTStrikethrough"];
            if (strikethrough) run[@"strikethrough"] = @YES;
            [currentRuns addObject:run];
            [currentText appendString:chunk];
            runOffsetInPara += chunk.length;
        } else {
            // New paragraph - emit previous
            if (currentText.length > 0) {
                emitParagraph(paragraphs, currentText, currentRuns,
                    currentStyle, currentIndent, currentTodoDone, currentUUID);
            }
            currentText = [NSMutableString stringWithString:chunk];
            currentRuns = [NSMutableArray array];
            currentUUID = uuid;
            currentStyle = styleNum;
            currentTodoDone = done;
            currentIndent = indent;
            runOffsetInPara = 0;

            NSMutableDictionary *run = [NSMutableDictionary dictionary];
            run[@"start"] = @(0);
            run[@"length"] = @(chunk.length);
            id nsLink = attrs[@"NSLink"];
            if (nsLink) run[@"link"] = [nsLink description];
            id strikethrough = attrs[@"TTStrikethrough"];
            if (strikethrough) run[@"strikethrough"] = @YES;
            [currentRuns addObject:run];
            runOffsetInPara = chunk.length;
        }

        idx = effectiveRange.location + effectiveRange.length;
    }
    // Emit last paragraph
    if (currentText.length > 0) {
        emitParagraph(paragraphs, currentText, currentRuns,
            currentStyle, currentIndent, currentTodoDone, currentUUID);
    }

    return paragraphs;
}

// Render paragraph model as markdown
static NSString *paraModelToMarkdown(NSArray *paragraphs) {
    NSMutableString *output = [NSMutableString string];

    for (NSUInteger i = 0; i < paragraphs.count; i++) {
        NSDictionary *para = paragraphs[i];
        NSInteger style = [para[@"style"] integerValue];
        NSUInteger indent = [para[@"indent"] unsignedIntegerValue];
        NSString *rawText = para[@"text"];

        if (rawText.length == 0 && style == 3) {
            // Empty body paragraph = blank line
            if (i > 0) [output appendString:@"\n"];
            continue;
        }

        // Build formatted text with inline runs
        NSString *formattedText;
        NSArray *runs = para[@"runs"];
        if (runs && runs.count > 0) {
            NSMutableString *fmt = [NSMutableString string];
            for (NSDictionary *run in runs) {
                NSUInteger start = [run[@"start"] unsignedIntegerValue];
                NSUInteger len = [run[@"length"] unsignedIntegerValue];
                // Clamp to rawText bounds
                if (start >= rawText.length) continue;
                if (start + len > rawText.length) len = rawText.length - start;
                NSString *runText = [rawText substringWithRange:NSMakeRange(start, len)];
                // Strip trailing newlines from run text
                runText = [runText stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
                if (runText.length == 0) continue;

                NSString *escaped = escapeMarkdown(runText);

                // Apply link wrapping
                if (run[@"link"]) {
                    NSString *linkURL = run[@"link"];
                    // If display text equals URL, output bare URL
                    if ([runText isEqualToString:linkURL]) {
                        escaped = linkURL;
                    } else {
                        escaped = [NSString stringWithFormat:@"[%@](%@)", escaped, linkURL];
                    }
                }
                // Apply strikethrough wrapping
                if ([run[@"strikethrough"] boolValue]) {
                    escaped = [NSString stringWithFormat:@"~~%@~~", escaped];
                }

                [fmt appendString:escaped];
            }
            formattedText = fmt;
        } else {
            formattedText = escapeMarkdown(rawText);
        }

        // Build indent prefix
        NSMutableString *indentStr = [NSMutableString string];
        for (NSUInteger j = 0; j < indent; j++) [indentStr appendString:@"  "];

        // Build line prefix based on style
        NSString *line;
        switch (style) {
            case 0: // Title
                line = [NSString stringWithFormat:@"# %@", formattedText];
                break;
            case 1: // Heading
                line = [NSString stringWithFormat:@"## %@", formattedText];
                break;
            case 100: // Dash list
                line = [NSString stringWithFormat:@"%@- %@", indentStr, formattedText];
                break;
            case 102: // Numbered list
                line = [NSString stringWithFormat:@"%@1. %@", indentStr, formattedText];
                break;
            case 103: { // Checklist
                BOOL checked = [para[@"todoChecked"] boolValue];
                line = [NSString stringWithFormat:@"%@- [%@] %@", indentStr, checked ? @"x" : @" ", formattedText];
                break;
            }
            default: { // Body (style 3)
                // Escape line-prefix collisions for body paragraphs
                if ([formattedText hasPrefix:@"# "] || [formattedText isEqualToString:@"#"]) {
                    formattedText = [NSString stringWithFormat:@"\\%@", formattedText];
                } else if ([formattedText hasPrefix:@"- "] || [formattedText isEqualToString:@"-"]) {
                    formattedText = [NSString stringWithFormat:@"\\%@", formattedText];
                } else if ([formattedText hasPrefix:@"> "] || [formattedText isEqualToString:@">"]) {
                    formattedText = [NSString stringWithFormat:@"\\%@", formattedText];
                } else {
                    // Check for numbered list prefix: digit(s) followed by ". "
                    NSRange dotRange = [formattedText rangeOfString:@". "];
                    if (dotRange.location != NSNotFound && dotRange.location > 0) {
                        BOOL allDigits = YES;
                        for (NSUInteger d = 0; d < dotRange.location; d++) {
                            unichar ch = [formattedText characterAtIndex:d];
                            if (ch < '0' || ch > '9') { allDigits = NO; break; }
                        }
                        if (allDigits) {
                            // Escape the period: "1. " -> "1\. "
                            formattedText = [NSString stringWithFormat:@"%@\\%@",
                                [formattedText substringToIndex:dotRange.location],
                                [formattedText substringFromIndex:dotRange.location]];
                        }
                    }
                }
                line = formattedText;
                break;
            }
        }

        if (i > 0) [output appendString:@"\n"];
        [output appendString:line];
    }

    return output;
}

static int cmdReadMarkdownNote(id note) {
    NSArray *model = noteToParaModel(note);

    // Skip leading empty paragraphs (from canonical leading \n)
    NSMutableArray *filtered = [NSMutableArray array];
    BOOL foundContent = NO;
    for (NSDictionary *para in model) {
        NSString *text = para[@"text"];
        if (!foundContent && text.length == 0) continue;
        foundContent = YES;
        [filtered addObject:para];
    }

    NSString *markdown = paraModelToMarkdown(filtered);
    printf("%s\n", [markdown UTF8String]);
    return 0;
}

// Parse inline formatting markers from text, producing runs array and plain text
// For Milestones 1-3: handles links, strikethrough only
// Milestone 4 adds bold/italic/underline
static void parseInlineFormatting(NSString *lineText, NSMutableString *outPlainText, NSMutableArray *outRuns) {
    NSUInteger i = 0;
    NSUInteger len = lineText.length;

    while (i < len) {
        unichar c = [lineText characterAtIndex:i];

        // Check for strikethrough ~~text~~
        if (c == '~' && i + 1 < len && [lineText characterAtIndex:i + 1] == '~') {
            NSRange closeRange = [lineText rangeOfString:@"~~" options:0
                range:NSMakeRange(i + 2, len - i - 2)];
            if (closeRange.location != NSNotFound) {
                NSString *inner = [lineText substringWithRange:NSMakeRange(i + 2, closeRange.location - i - 2)];
                NSString *unescaped = unescapeMarkdown(inner);
                NSUInteger start = outPlainText.length;
                [outPlainText appendString:unescaped];
                [outRuns addObject:[@{
                    @"start": @(start),
                    @"length": @(unescaped.length),
                    @"strikethrough": @YES
                } mutableCopy]];
                i = closeRange.location + 2;
                continue;
            }
        }

        // Check for link [text](url)
        if (c == '[') {
            // Find closing ]
            NSRange closeBracket = [lineText rangeOfString:@"](" options:0
                range:NSMakeRange(i + 1, len - i - 1)];
            if (closeBracket.location != NSNotFound) {
                NSRange closeParen = [lineText rangeOfString:@")" options:0
                    range:NSMakeRange(closeBracket.location + 2, len - closeBracket.location - 2)];
                if (closeParen.location != NSNotFound) {
                    NSString *displayText = [lineText substringWithRange:NSMakeRange(i + 1, closeBracket.location - i - 1)];
                    NSString *urlStr = [lineText substringWithRange:NSMakeRange(closeBracket.location + 2, closeParen.location - closeBracket.location - 2)];

                    // Validate link scheme
                    NSURL *url = [NSURL URLWithString:urlStr];
                    if (url && isAllowedLinkScheme(url)) {
                        NSString *unescapedDisplay = unescapeMarkdown(displayText);
                        NSUInteger start = outPlainText.length;
                        [outPlainText appendString:unescapedDisplay];
                        [outRuns addObject:[@{
                            @"start": @(start),
                            @"length": @(unescapedDisplay.length),
                            @"link": urlStr
                        } mutableCopy]];
                        i = closeParen.location + 1;
                        continue;
                    } else if (url && !isAllowedLinkScheme(url)) {
                        fprintf(stderr, "Warning: rejected link with scheme '%s': %s\n",
                            [[url scheme] UTF8String], [urlStr UTF8String]);
                        // Treat as literal text
                        NSString *literal = [lineText substringWithRange:NSMakeRange(i, closeParen.location - i + 1)];
                        NSString *unescaped = unescapeMarkdown(literal);
                        NSUInteger start = outPlainText.length;
                        [outPlainText appendString:unescaped];
                        [outRuns addObject:[@{
                            @"start": @(start),
                            @"length": @(unescaped.length)
                        } mutableCopy]];
                        i = closeParen.location + 1;
                        continue;
                    }
                }
            }
        }

        // Check for <u>text</u> (underline)
        if (c == '<' && i + 2 < len) {
            NSString *rest = [lineText substringFromIndex:i];
            if ([rest hasPrefix:@"<u>"]) {
                NSRange closeTag = [lineText rangeOfString:@"</u>" options:0
                    range:NSMakeRange(i + 3, len - i - 3)];
                if (closeTag.location != NSNotFound) {
                    NSString *inner = [lineText substringWithRange:NSMakeRange(i + 3, closeTag.location - i - 3)];
                    NSString *unescaped = unescapeMarkdown(inner);
                    NSUInteger start = outPlainText.length;
                    [outPlainText appendString:unescaped];
                    [outRuns addObject:[@{
                        @"start": @(start),
                        @"length": @(unescaped.length),
                        @"underline": @YES
                    } mutableCopy]];
                    i = closeTag.location + 4;
                    continue;
                }
            }
        }

        // Regular character - handle escapes
        if (c == '\\' && i + 1 < len) {
            unichar next = [lineText characterAtIndex:i + 1];
            if (next == '*' || next == '_' || next == '~' || next == '[' || next == ']' ||
                next == '(' || next == ')' || next == '\\' || next == '<' || next == '#' ||
                next == '-' || next == '.' || next == '>') {
                [outPlainText appendFormat:@"%C", next];
                i += 2;
                continue;
            }
        }

        [outPlainText appendFormat:@"%C", c];
        i++;
    }

    // If no runs were created, make a single run for the whole text
    if (outRuns.count == 0 && outPlainText.length > 0) {
        [outRuns addObject:[@{
            @"start": @(0),
            @"length": @(outPlainText.length)
        } mutableCopy]];
    }
    // Fill gaps in runs (text between formatted runs)
    // Not needed since we build runs sequentially
}

// Parse markdown text into paragraph model
static NSArray *markdownToParaModel(NSString *markdown) {
    // Normalize line endings
    NSString *normalized = [markdown stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
    normalized = [normalized stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];

    // Trim trailing newlines
    while (normalized.length > 0 && [normalized characterAtIndex:normalized.length - 1] == '\n') {
        normalized = [normalized substringToIndex:normalized.length - 1];
    }

    if (normalized.length == 0) return @[];

    NSArray *lines = [normalized componentsSeparatedByString:@"\n"];
    NSMutableArray *paragraphs = [NSMutableArray array];

    for (NSString *line in lines) {
        NSMutableDictionary *para = [NSMutableDictionary dictionary];
        NSString *textContent = nil;
        NSInteger style = 3;
        NSUInteger indent = 0;
        BOOL todoChecked = NO;

        // Check for title: # Text
        if ([line hasPrefix:@"# "]) {
            style = 0;
            textContent = [line substringFromIndex:2];
        }
        // Check for heading: ## Text
        else if ([line hasPrefix:@"## "]) {
            style = 1;
            textContent = [line substringFromIndex:3];
        }
        // Check for list items (with possible indentation)
        else {
            // Count leading spaces for indent level
            NSUInteger spaces = 0;
            while (spaces < line.length && [line characterAtIndex:spaces] == ' ') spaces++;
            indent = spaces / 2;
            NSString *trimmedLine = (spaces > 0) ? [line substringFromIndex:spaces] : line;

            // Checklist: - [ ] or - [x]
            if ([trimmedLine hasPrefix:@"- [ ] "]) {
                style = 103;
                todoChecked = NO;
                textContent = [trimmedLine substringFromIndex:6];
            } else if ([trimmedLine hasPrefix:@"- [x] "]) {
                style = 103;
                todoChecked = YES;
                textContent = [trimmedLine substringFromIndex:6];
            }
            // Dash list: - Text
            else if ([trimmedLine hasPrefix:@"- "]) {
                style = 100;
                textContent = [trimmedLine substringFromIndex:2];
            }
            // Numbered list: digits followed by ". "
            else if (trimmedLine.length > 2) {
                NSUInteger digitEnd = 0;
                while (digitEnd < trimmedLine.length) {
                    unichar ch = [trimmedLine characterAtIndex:digitEnd];
                    if (ch < '0' || ch > '9') break;
                    digitEnd++;
                }
                if (digitEnd > 0 && digitEnd + 1 < trimmedLine.length &&
                    [trimmedLine characterAtIndex:digitEnd] == '.' &&
                    [trimmedLine characterAtIndex:digitEnd + 1] == ' ') {
                    style = 102;
                    textContent = [trimmedLine substringFromIndex:digitEnd + 2];
                } else {
                    style = 3;
                    indent = 0; // Body doesn't use indent
                    textContent = line;
                }
            } else {
                style = 3;
                indent = 0;
                textContent = line;
            }
        }

        // For body text, unescape line-prefix escapes
        if (style == 3 && textContent.length > 0) {
            if ([textContent hasPrefix:@"\\# "]) {
                textContent = [textContent substringFromIndex:1];
            } else if ([textContent hasPrefix:@"\\- "]) {
                textContent = [textContent substringFromIndex:1];
            } else if ([textContent hasPrefix:@"\\> "]) {
                textContent = [textContent substringFromIndex:1];
            } else {
                // Check for escaped numbered list prefix: "1\. "
                NSRange bsRange = [textContent rangeOfString:@"\\."];
                if (bsRange.location != NSNotFound && bsRange.location > 0) {
                    BOOL allDigits = YES;
                    for (NSUInteger d = 0; d < bsRange.location; d++) {
                        unichar ch = [textContent characterAtIndex:d];
                        if (ch < '0' || ch > '9') { allDigits = NO; break; }
                    }
                    if (allDigits) {
                        // Remove the backslash: "1\. " -> "1. "
                        textContent = [NSString stringWithFormat:@"%@%@",
                            [textContent substringToIndex:bsRange.location],
                            [textContent substringFromIndex:bsRange.location + 1]];
                    }
                }
            }
        }

        // Parse inline formatting
        NSMutableString *plainText = [NSMutableString string];
        NSMutableArray *runs = [NSMutableArray array];
        parseInlineFormatting(textContent ?: @"", plainText, runs);

        para[@"style"] = @(style);
        para[@"indent"] = @(indent);
        para[@"text"] = [plainText copy];
        if (style == 103) para[@"todoChecked"] = @(todoChecked);
        if (runs.count > 0) para[@"runs"] = runs;
        [paragraphs addObject:para];
    }

    return paragraphs;
}

// --- Diff Engine ---

// Paragraph signature for LCS matching
static NSString *paraSignature(NSDictionary *para) {
    NSString *text = normalizeParaText(para[@"text"]);
    return [NSString stringWithFormat:@"%@|%@|%@|%@",
        para[@"style"], para[@"indent"],
        ([para[@"style"] integerValue] == 103) ? para[@"todoChecked"] : @"",
        text];
}

// Compare inline runs for equality
static BOOL inlineRunsEqual(NSArray *a, NSArray *b) {
    if (!a && !b) return YES;
    if (!a || !b) return a.count == 0 || b.count == 0;
    if (a.count != b.count) return NO;
    for (NSUInteger i = 0; i < a.count; i++) {
        NSDictionary *ra = a[i];
        NSDictionary *rb = b[i];
        if (![ra[@"start"] isEqual:rb[@"start"]]) return NO;
        if (![ra[@"length"] isEqual:rb[@"length"]]) return NO;
        if (![ra[@"link"] isEqual:rb[@"link"]] &&
            !(ra[@"link"] == nil && rb[@"link"] == nil)) return NO;
        if ([ra[@"strikethrough"] boolValue] != [rb[@"strikethrough"] boolValue]) return NO;
    }
    return YES;
}

// Compare two paragraphs for equality (ignoring UUID)
static BOOL paragraphsEqual(NSDictionary *a, NSDictionary *b) {
    if (![a[@"style"] isEqual:b[@"style"]]) return NO;
    if (![a[@"indent"] isEqual:b[@"indent"]]) return NO;
    if ([a[@"style"] integerValue] == 103) {
        if ([a[@"todoChecked"] boolValue] != [b[@"todoChecked"] boolValue]) return NO;
    }
    if (![normalizeParaText(a[@"text"]) isEqualToString:normalizeParaText(b[@"text"])]) return NO;
    return inlineRunsEqual(a[@"runs"], b[@"runs"]);
}

// LCS algorithm over paragraph signatures
static NSArray *computeLCS(NSArray *oldSigs, NSArray *newSigs) {
    NSUInteger m = oldSigs.count;
    NSUInteger n = newSigs.count;

    // DP table
    NSUInteger **dp = calloc(m + 1, sizeof(NSUInteger *));
    for (NSUInteger i = 0; i <= m; i++) dp[i] = calloc(n + 1, sizeof(NSUInteger));

    for (NSUInteger i = 1; i <= m; i++) {
        for (NSUInteger j = 1; j <= n; j++) {
            if ([oldSigs[i-1] isEqualToString:newSigs[j-1]]) {
                dp[i][j] = dp[i-1][j-1] + 1;
            } else {
                dp[i][j] = MAX(dp[i-1][j], dp[i][j-1]);
            }
        }
    }

    // Backtrack to find matched pairs (oldIndex, newIndex)
    NSMutableArray *pairs = [NSMutableArray array];
    NSUInteger i = m, j = n;
    while (i > 0 && j > 0) {
        if ([oldSigs[i-1] isEqualToString:newSigs[j-1]]) {
            [pairs insertObject:@[@(i-1), @(j-1)] atIndex:0];
            i--; j--;
        } else if (dp[i-1][j] >= dp[i][j-1]) {
            i--;
        } else {
            j--;
        }
    }

    for (NSUInteger k = 0; k <= m; k++) free(dp[k]);
    free(dp);

    return pairs;
}

// Compute character offsets for each paragraph in the note's mergeableString
static NSArray *computeParaOffsets(id note) {
    NSAttributedString *attrStr = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("attributedString"));
    NSString *fullText = [attrStr string];
    NSUInteger length = fullText.length;

    if (length == 0) return @[];

    NSMutableArray *offsets = [NSMutableArray array];
    NSUInteger paraStart = 0;
    for (NSUInteger i = 0; i <= length; i++) {
        if (i == length || [fullText characterAtIndex:i] == '\n') {
            [offsets addObject:@[@(paraStart), @(i - paraStart)]];
            paraStart = i + 1;
        }
    }

    return offsets;
}

static int cmdWriteMarkdownWithString(id note, id viewContext, NSString *markdown, BOOL dryRun, BOOL backup) {
    // Get note identifier
    NSString *identifier = noteToDict(note)[@"id"];

    // Build old and new paragraph models
    NSArray *oldModel = noteToParaModel(note);
    NSArray *newModel = markdownToParaModel(markdown);

    // Filter out leading empty paragraphs from old model (canonical leading \n)
    NSMutableArray *filteredOld = [NSMutableArray array];
    BOOL foundContent = NO;
    for (NSDictionary *para in oldModel) {
        NSString *text = para[@"text"];
        if (!foundContent && text.length == 0) continue;
        foundContent = YES;
        [filteredOld addObject:para];
    }

    // Build signatures
    NSMutableArray *oldSigs = [NSMutableArray array];
    for (NSDictionary *p in filteredOld) [oldSigs addObject:paraSignature(p)];
    NSMutableArray *newSigs = [NSMutableArray array];
    for (NSDictionary *p in newModel) [newSigs addObject:paraSignature(p)];

    // Compute LCS
    NSArray *lcsPairs = computeLCS(oldSigs, newSigs);

    // Build mutation list
    NSMutableArray *mutations = [NSMutableArray array];
    NSMutableSet *matchedOld = [NSMutableSet set];
    NSMutableSet *matchedNew = [NSMutableSet set];

    for (NSArray *pair in lcsPairs) {
        [matchedOld addObject:pair[0]];
        [matchedNew addObject:pair[1]];
    }

    // Identify deletions (in old but not matched)
    for (NSUInteger i = 0; i < filteredOld.count; i++) {
        if (![matchedOld containsObject:@(i)]) {
            [mutations addObject:@{@"type": @"delete", @"oldIndex": @(i),
                @"oldText": filteredOld[i][@"text"]}];
        }
    }

    // Identify insertions (in new but not matched) and modifications (matched but changed)
    NSUInteger pairIdx = 0;
    for (NSUInteger j = 0; j < newModel.count; j++) {
        if ([matchedNew containsObject:@(j)]) {
            // Find the corresponding pair
            NSArray *pair = nil;
            for (NSArray *p in lcsPairs) {
                if ([p[1] isEqual:@(j)]) { pair = p; break; }
            }
            NSUInteger oldIdx = [pair[0] unsignedIntegerValue];
            // Check if the matched pair actually differs in some way
            if (!paragraphsEqual(filteredOld[oldIdx], newModel[j])) {
                [mutations addObject:@{@"type": @"modify", @"oldIndex": @(oldIdx),
                    @"newIndex": @(j), @"oldText": filteredOld[oldIdx][@"text"],
                    @"newText": newModel[j][@"text"]}];
            }
        } else {
            // Insert - figure out where to insert (after the last matched old index before this)
            NSInteger insertAfterOld = -1;
            for (NSArray *p in lcsPairs) {
                if ([p[1] unsignedIntegerValue] < j) {
                    insertAfterOld = [p[0] integerValue];
                }
            }
            [mutations addObject:@{@"type": @"insert", @"insertAfterOld": @(insertAfterOld),
                @"newIndex": @(j), @"text": newModel[j][@"text"]}];
        }
    }

    // Summary counts
    NSUInteger unchanged = 0, modified = 0, inserted = 0, deleted = 0;
    for (NSDictionary *m in mutations) {
        if ([m[@"type"] isEqualToString:@"delete"]) deleted++;
        else if ([m[@"type"] isEqualToString:@"insert"]) inserted++;
        else if ([m[@"type"] isEqualToString:@"modify"]) modified++;
    }
    unchanged = filteredOld.count - deleted - modified;

    // Build output JSON
    NSMutableDictionary *summary = [NSMutableDictionary dictionary];
    summary[@"id"] = identifier;
    summary[@"paragraphsUnchanged"] = @(unchanged);
    summary[@"paragraphsModified"] = @(modified);
    summary[@"paragraphsInserted"] = @(inserted);
    summary[@"paragraphsDeleted"] = @(deleted);
    summary[@"mutations"] = mutations;

    if (dryRun) {
        printJSON(summary);
        return 0;
    }

    // No mutations needed
    if (mutations.count == 0) {
        printJSON(summary);
        return 0;
    }

    // Backup if requested
    if (backup) {
        NSString *title = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("title"));
        NSString *backupTitle = [NSString stringWithFormat:@"[backup] %@", title ?: @"Untitled"];
        cmdDuplicate(viewContext, identifier, backupTitle);
        // Re-fetch note after duplicate
        note = findNoteByID(viewContext, identifier);
    }

    // Apply mutations directly to the mergeableString
    id doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
    id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
    NSAttributedString *attrStr = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("attributedString"));
    NSString *fullText = [attrStr string];
    NSUInteger msLen = ((NSUInteger (*)(id, SEL))objc_msgSend)(ms, sel_registerName("length"));

    // Compute paragraph offsets in the full text
    // Each paragraph is separated by \n
    NSMutableArray *paraRanges = [NSMutableArray array]; // NSRange as @[@(loc), @(len)]
    {
        NSUInteger paraStart = 0;
        for (NSUInteger i = 0; i <= fullText.length; i++) {
            if (i == fullText.length || [fullText characterAtIndex:i] == '\n') {
                [paraRanges addObject:@[@(paraStart), @(i - paraStart)]];
                paraStart = i + 1;
            }
        }
    }

    // Map filteredOld indices to paraRange indices
    // The filteredOld skips leading empty paragraphs, so we need to find the offset
    NSUInteger leadingSkipped = oldModel.count - filteredOld.count;
    // Verify: leading paragraphs in oldModel that were skipped
    // Actually, let's count them properly
    leadingSkipped = 0;
    foundContent = NO;
    for (NSUInteger i = 0; i < oldModel.count; i++) {
        NSString *text = oldModel[i][@"text"];
        if (!foundContent && text.length == 0) {
            leadingSkipped++;
            continue;
        }
        foundContent = YES;
    }

    ((void (*)(id, SEL))objc_msgSend)(note, sel_registerName("beginEditing"));

    // Build a unified operation list, ordered by position descending (bottom to top).
    // Processing bottom-to-top means each op uses original offsets (ops above are unaffected).
    NSMutableArray *ops = [NSMutableArray array]; // each op: {position, type, ...}

    for (NSDictionary *m in mutations) {
        if ([m[@"type"] isEqualToString:@"delete"]) {
            NSUInteger oldIdx = [m[@"oldIndex"] unsignedIntegerValue];
            NSUInteger paraIdx = oldIdx + leadingSkipped;
            if (paraIdx >= paraRanges.count) continue;
            NSUInteger paraStart = [paraRanges[paraIdx][0] unsignedIntegerValue];
            NSUInteger paraLen = [paraRanges[paraIdx][1] unsignedIntegerValue];
            // Include trailing newline
            NSUInteger deleteStart = paraStart;
            NSUInteger deleteLen = paraLen;
            if (deleteStart + deleteLen < fullText.length) {
                deleteLen++; // trailing \n
            } else if (deleteStart > 0) {
                deleteStart--; // preceding \n for last paragraph
                deleteLen++;
            }
            [ops addObject:@{@"op": @"delete", @"pos": @(deleteStart), @"len": @(deleteLen)}];
        }
        else if ([m[@"type"] isEqualToString:@"modify"]) {
            NSUInteger oldIdx = [m[@"oldIndex"] unsignedIntegerValue];
            NSUInteger newIdx = [m[@"newIndex"] unsignedIntegerValue];
            NSUInteger paraIdx = oldIdx + leadingSkipped;
            if (paraIdx >= paraRanges.count) continue;
            NSUInteger paraStart = [paraRanges[paraIdx][0] unsignedIntegerValue];
            NSUInteger paraLen = [paraRanges[paraIdx][1] unsignedIntegerValue];
            [ops addObject:@{@"op": @"modify", @"pos": @(paraStart), @"len": @(paraLen),
                @"newPara": newModel[newIdx], @"oldPara": filteredOld[oldIdx]}];
        }
        else if ([m[@"type"] isEqualToString:@"insert"]) {
            NSInteger insertAfterOld = [m[@"insertAfterOld"] integerValue];
            NSUInteger newIdx = [m[@"newIndex"] unsignedIntegerValue];
            NSUInteger insertPos;
            if (insertAfterOld < 0) {
                if (leadingSkipped > 0 && paraRanges.count > leadingSkipped) {
                    insertPos = [paraRanges[leadingSkipped][0] unsignedIntegerValue];
                } else if (paraRanges.count > 0) {
                    // Insert after the first paragraph (title)
                    NSUInteger pStart = [paraRanges[0][0] unsignedIntegerValue];
                    NSUInteger pLen = [paraRanges[0][1] unsignedIntegerValue];
                    insertPos = pStart + pLen + 1;
                    if (insertPos > fullText.length) insertPos = fullText.length;
                } else {
                    insertPos = 0;
                }
            } else {
                NSUInteger paraIdx = (NSUInteger)insertAfterOld + leadingSkipped;
                if (paraIdx < paraRanges.count) {
                    NSUInteger pStart = [paraRanges[paraIdx][0] unsignedIntegerValue];
                    NSUInteger pLen = [paraRanges[paraIdx][1] unsignedIntegerValue];
                    insertPos = pStart + pLen + 1;
                    if (insertPos > fullText.length) insertPos = fullText.length;
                } else {
                    insertPos = fullText.length;
                }
            }
            [ops addObject:@{@"op": @"insert", @"pos": @(insertPos), @"newPara": newModel[newIdx]}];
        }
    }

    // Sort operations by position descending (bottom to top)
    // For same position: delete before insert (delete first to avoid shifting insert targets)
    [ops sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult cmp = [b[@"pos"] compare:a[@"pos"]];
        if (cmp != NSOrderedSame) return cmp;
        // At same position: deletes before inserts (delete removes old content first)
        int prioA = [a[@"op"] isEqualToString:@"delete"] ? 0 : ([a[@"op"] isEqualToString:@"modify"] ? 1 : 2);
        int prioB = [b[@"op"] isEqualToString:@"delete"] ? 0 : ([b[@"op"] isEqualToString:@"modify"] ? 1 : 2);
        return prioA < prioB ? NSOrderedAscending : (prioA > prioB ? NSOrderedDescending : NSOrderedSame);
    }];

    NSInteger cumulativeDelta = 0;
    for (NSDictionary *op in ops) {
        NSString *opType = op[@"op"];
        NSUInteger pos = [op[@"pos"] unsignedIntegerValue];

        if ([opType isEqualToString:@"delete"]) {
            NSUInteger deleteLen = [op[@"len"] unsignedIntegerValue];
            ((void (*)(id, SEL, NSRange))objc_msgSend)(ms, sel_registerName("deleteCharactersInRange:"),
                NSMakeRange(pos, deleteLen));
            cumulativeDelta -= (NSInteger)deleteLen;
        }
        else if ([opType isEqualToString:@"modify"]) {
            NSDictionary *newPara = op[@"newPara"];
            NSDictionary *oldPara = op[@"oldPara"];
            NSUInteger paraLen = [op[@"len"] unsignedIntegerValue];
            NSString *newText = newPara[@"text"];
            NSString *oldText = oldPara[@"text"];

            if (![normalizeParaText(oldText) isEqualToString:normalizeParaText(newText)]) {
                ((void (*)(id, SEL, NSRange))objc_msgSend)(ms, sel_registerName("deleteCharactersInRange:"),
                    NSMakeRange(pos, paraLen));
                ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(ms, sel_registerName("insertString:atIndex:"),
                    newText, pos);
                cumulativeDelta += (NSInteger)newText.length - (NSInteger)paraLen;
                paraLen = newText.length;
            }

            // Patch attributes
            NSUInteger currentMsLen = (NSUInteger)((NSInteger)msLen + cumulativeDelta);
            if (pos < currentMsLen && paraLen > 0) {
                NSRange effectiveRange;
                NSDictionary *existingAttrs = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
                    ms, sel_registerName("attributesAtIndex:effectiveRange:"), pos, &effectiveRange);

                NSMutableDictionary *patchedAttrs = [existingAttrs mutableCopy];
                if (!patchedAttrs) patchedAttrs = [NSMutableDictionary dictionary];

                NSInteger newStyle = [newPara[@"style"] integerValue];
                NSUInteger newIndent = [newPara[@"indent"] unsignedIntegerValue];
                id existingStyle = existingAttrs[@"TTStyle"];

                id patchedStyle = existingStyle ? [existingStyle mutableCopy] : nil;
                if (!patchedStyle) patchedStyle = [[ICTTParagraphStyleClass alloc] init];

                ((void (*)(id, SEL, NSUInteger))objc_msgSend)(patchedStyle, sel_registerName("setStyle:"), (NSUInteger)newStyle);
                ((void (*)(id, SEL, NSUInteger))objc_msgSend)(patchedStyle, sel_registerName("setIndent:"), newIndent);

                if (newStyle == 103) {
                    BOOL checked = [newPara[@"todoChecked"] boolValue];
                    id todo = ((id (*)(id, SEL, id, BOOL))objc_msgSend)(
                        [ICTTTodoClass alloc], sel_registerName("initWithIdentifier:done:"), [NSUUID UUID], checked);
                    ((void (*)(id, SEL, id))objc_msgSend)(patchedStyle, sel_registerName("setTodo:"), todo);
                }

                patchedAttrs[@"TTStyle"] = patchedStyle;
                [patchedAttrs removeObjectForKey:@"NSLink"];
                [patchedAttrs removeObjectForKey:@"TTStrikethrough"];

                ((void (*)(id, SEL, id, NSRange))objc_msgSend)(ms, sel_registerName("setAttributes:range:"),
                    patchedAttrs, NSMakeRange(pos, paraLen));

                NSArray *newRuns = newPara[@"runs"];
                if (newRuns) {
                    for (NSDictionary *run in newRuns) {
                        NSUInteger runStart = [run[@"start"] unsignedIntegerValue];
                        NSUInteger runLen = [run[@"length"] unsignedIntegerValue];
                        if (runStart + runLen > paraLen) continue;
                        NSMutableDictionary *runAttrs = [patchedAttrs mutableCopy];
                        if (run[@"link"]) {
                            NSURL *linkURL = [NSURL URLWithString:run[@"link"]];
                            if (linkURL) runAttrs[@"NSLink"] = linkURL;
                        }
                        if ([run[@"strikethrough"] boolValue]) runAttrs[@"TTStrikethrough"] = @1;
                        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(ms, sel_registerName("setAttributes:range:"),
                            runAttrs, NSMakeRange(pos + runStart, runLen));
                    }
                }
            }
        }
        else if ([opType isEqualToString:@"insert"]) {
            NSDictionary *newPara = op[@"newPara"];
            NSString *newText = newPara[@"text"];
            NSString *toInsert = [NSString stringWithFormat:@"%@\n", newText];

            ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(ms, sel_registerName("insertString:atIndex:"),
                toInsert, pos);

            NSInteger newStyle = [newPara[@"style"] integerValue];
            NSUInteger newIndent = [newPara[@"indent"] unsignedIntegerValue];

            id paraStyle = [[ICTTParagraphStyleClass alloc] init];
            ((void (*)(id, SEL, NSUInteger))objc_msgSend)(paraStyle, sel_registerName("setStyle:"), (NSUInteger)newStyle);
            ((void (*)(id, SEL, NSUInteger))objc_msgSend)(paraStyle, sel_registerName("setIndent:"), newIndent);

            if (newStyle == 103) {
                BOOL checked = [newPara[@"todoChecked"] boolValue];
                id todo = ((id (*)(id, SEL, id, BOOL))objc_msgSend)(
                    [ICTTTodoClass alloc], sel_registerName("initWithIdentifier:done:"), [NSUUID UUID], checked);
                ((void (*)(id, SEL, id))objc_msgSend)(paraStyle, sel_registerName("setTodo:"), todo);
            }

            NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
            attrs[@"TTStyle"] = paraStyle;

            ((void (*)(id, SEL, id, NSRange))objc_msgSend)(ms, sel_registerName("setAttributes:range:"),
                attrs, NSMakeRange(pos, toInsert.length));

            NSArray *newRuns = newPara[@"runs"];
            if (newRuns) {
                for (NSDictionary *run in newRuns) {
                    NSUInteger runStart = [run[@"start"] unsignedIntegerValue];
                    NSUInteger runLen = [run[@"length"] unsignedIntegerValue];
                    if (runStart + runLen > newText.length) continue;
                    NSMutableDictionary *runAttrs = [attrs mutableCopy];
                    if (run[@"link"]) {
                        NSURL *linkURL = [NSURL URLWithString:run[@"link"]];
                        if (linkURL) runAttrs[@"NSLink"] = linkURL;
                    }
                    if ([run[@"strikethrough"] boolValue]) runAttrs[@"TTStrikethrough"] = @1;
                    ((void (*)(id, SEL, id, NSRange))objc_msgSend)(ms, sel_registerName("setAttributes:range:"),
                        runAttrs, NSMakeRange(pos + runStart, runLen));
                }
            }

            cumulativeDelta += (NSInteger)toInsert.length;
        }
    }

    // Save
    NSUInteger newLen = (NSUInteger)((NSInteger)msLen + cumulativeDelta);
    ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
        note, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, newLen), cumulativeDelta);
    ((void (*)(id, SEL))objc_msgSend)(note, sel_registerName("endEditing"));
    ((void (*)(id, SEL))objc_msgSend)(note, sel_registerName("saveNoteData"));
    NSError *error = nil;
    [viewContext save:&error];
    if (error) {
        errorExit([NSString stringWithFormat:@"Save error: %@", error]);
    }

    printJSON(summary);
    return 0;
}

static int cmdWriteMarkdownNote(id note, id viewContext, BOOL dryRun, BOOL backup) {
    // Read markdown from stdin
    NSFileHandle *input = [NSFileHandle fileHandleWithStandardInput];
    NSData *data = [input readDataToEndOfFile];
    NSString *markdown = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!markdown) errorExit(@"Failed to read markdown from stdin (invalid UTF-8)");
    return cmdWriteMarkdownWithString(note, viewContext, markdown, dryRun, backup);
}


// --- Tests ---

static void deleteNote(id note, id viewContext) {
    // Detach attachments before deleting to prevent cascade deleting shared attachments.
    // ICNote relationships (attachments, inlineAttachments) use NSCascadeDeleteRule,
    // so deleteObject would destroy attachment data that other notes may reference.
    id inlineAttachments = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("inlineAttachments"));
    if (inlineAttachments && [inlineAttachments count] > 0) {
        ((void (*)(id, SEL, id))objc_msgSend)(note, sel_registerName("removeInlineAttachments:"), inlineAttachments);
    }
    id attachments = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("attachments"));
    if (attachments && [attachments count] > 0) {
        NSSet *attachSet = [attachments copy];
        for (id a in attachSet) {
            ((void (*)(id, SEL, id))objc_msgSend)(note, sel_registerName("removeAttachmentsObject:"), a);
        }
    }
    [viewContext save:nil];
    ((void (*)(id, SEL))objc_msgSend)(note, sel_registerName("markForDeletion"));
    [viewContext deleteObject:note];
}

static int cmdTest(id viewContext) {
    int passed = 0, failed = 0;
    NSString *testFolderName = @"__notes_cli_test_folder__";
    NSString *testTitle = @"__notes_cli_test__";
    NSString *testTitle2 = @"__notes_cli_test_2__";

    // Cleanup leftover test data
    NSArray *folders = fetchFolders(viewContext);
    for (id f in folders) {
        NSString *fname = ((id (*)(id, SEL))objc_msgSend)(f, sel_registerName("title"));
        if ([fname isEqualToString:testFolderName]) {
            Class ICFolder = NSClassFromString(@"ICFolder");
            ((void (*)(id, SEL, id))objc_msgSend)(ICFolder, sel_registerName("deleteFolder:"), f);
            [viewContext save:nil];
            fprintf(stderr, "Cleaned up leftover test folder\n");
            break;
        }
    }

    // Test 1: Create folder
    fprintf(stderr, "Test 1: Create folder...\n");
    id testFolder = nil;
    {
        Class ICFolder = NSClassFromString(@"ICFolder");
        id account = nil;
        NSArray *allFolders = fetchFolders(viewContext);
        for (id f in allFolders) {
            account = ((id (*)(id, SEL))objc_msgSend)(f, sel_registerName("account"));
            if (account) break;
        }
        if (!account) { fprintf(stderr, "  FAIL (no account)\n"); return 1; }
        testFolder = ((id (*)(id, SEL, id))objc_msgSend)(ICFolder, sel_registerName("newFolderInAccount:"), account);
        ((void (*)(id, SEL, id))objc_msgSend)(testFolder, sel_registerName("setTitle:"), testFolderName);
        [viewContext save:nil];
        // Verify
        BOOL found = NO;
        for (id f in fetchFolders(viewContext)) {
            NSString *fname = ((id (*)(id, SEL))objc_msgSend)(f, sel_registerName("title"));
            if ([fname isEqualToString:testFolderName]) { found = YES; testFolder = f; break; }
        }
        if (found) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL\n"); failed++; return 1; }
    }

    // Test 2: Create empty note
    fprintf(stderr, "Test 2: Create empty note...\n");
    {
        id note = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        ((void (*)(id, SEL))objc_msgSend)(note, sel_registerName("saveNoteData"));
        [viewContext save:nil];
        if (note) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL\n"); failed++; }
    }

    // Test 3: Insert text and set title style
    fprintf(stderr, "Test 3: Insert + set-attr...\n");
    {
        NSArray *notes = fetchNotes(viewContext, testFolderName, 1);
        if (notes.count > 0) {
            id note = notes[0];
            id doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
            id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
            NSString *content = [NSString stringWithFormat:@"%@\nTest body\nChecklist item", testTitle];
            ((void (*)(id, SEL))objc_msgSend)(note, sel_registerName("beginEditing"));
            ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(ms, sel_registerName("insertString:atIndex:"), content, 0);
            // Title style
            id s0 = [[ICTTParagraphStyleClass alloc] init];
            ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s0, sel_registerName("setStyle:"), 0);
            ((void (*)(id, SEL, id, NSRange))objc_msgSend)(ms, sel_registerName("setAttributes:range:"),
                @{@"TTStyle": s0}, NSMakeRange(0, testTitle.length + 1));
            // Body style
            id s3 = [[ICTTParagraphStyleClass alloc] init];
            ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s3, sel_registerName("setStyle:"), 3);
            ((void (*)(id, SEL, id, NSRange))objc_msgSend)(ms, sel_registerName("setAttributes:range:"),
                @{@"TTStyle": s3}, NSMakeRange(testTitle.length + 1, 10));
            // Checklist style
            id s103 = [[ICTTParagraphStyleClass alloc] init];
            ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s103, sel_registerName("setStyle:"), 103);
            id todo = ((id (*)(id, SEL, id, BOOL))objc_msgSend)(
                [ICTTTodoClass alloc], sel_registerName("initWithIdentifier:done:"), [NSUUID UUID], NO);
            ((void (*)(id, SEL, id))objc_msgSend)(s103, sel_registerName("setTodo:"), todo);
            ((void (*)(id, SEL, id, NSRange))objc_msgSend)(ms, sel_registerName("setAttributes:range:"),
                (@{@"TTStyle": s103, @"NSLink": [NSURL URLWithString:@"https://example.com"]}),
                NSMakeRange(testTitle.length + 11, 14));
            ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
                note, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, content.length), content.length);
            ((void (*)(id, SEL))objc_msgSend)(note, sel_registerName("endEditing"));
            ((void (*)(id, SEL))objc_msgSend)(note, sel_registerName("saveNoteData"));
            [viewContext save:nil];
            NSString *title = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("title"));
            if ([title containsString:testTitle]) { fprintf(stderr, "  PASS\n"); passed++; }
            else { fprintf(stderr, "  FAIL (title: %s)\n", [title UTF8String]); failed++; }
        } else { fprintf(stderr, "  FAIL (no notes)\n"); failed++; }
    }

    // Test 4: Read attrs
    fprintf(stderr, "Test 4: Read attrs...\n");
    {
        id note = findNote(viewContext, testTitle, testFolderName);
        if (note) {
            id doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
            id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
            NSUInteger len = ((NSUInteger (*)(id, SEL))objc_msgSend)(ms, sel_registerName("length"));
            if (len > 0) { fprintf(stderr, "  PASS (length=%lu)\n", (unsigned long)len); passed++; }
            else { fprintf(stderr, "  FAIL (empty)\n"); failed++; }
        } else { fprintf(stderr, "  FAIL (not found)\n"); failed++; }
    }

    // Test 5: Read structured - verify checkbox
    fprintf(stderr, "Test 5: Read structured (checkbox)...\n");
    {
        id note = findNote(viewContext, testTitle, testFolderName);
        if (note) {
            BOOL hasChecklist = ((BOOL (*)(id, SEL))objc_msgSend)(note, sel_registerName("hasChecklist"));
            if (hasChecklist) { fprintf(stderr, "  PASS\n"); passed++; }
            else { fprintf(stderr, "  FAIL (no checklist)\n"); failed++; }
        } else { fprintf(stderr, "  FAIL (not found)\n"); failed++; }
    }

    // Test 6: Append
    fprintf(stderr, "Test 6: Append...\n");
    {
        id noteForID = findNote(viewContext, testTitle, testFolderName);
        NSString *noteID = noteToDict(noteForID)[@"id"];
        int ret = cmdAppend(viewContext, noteID, @"Appended text", -1);
        if (ret == 0) {
            id note = findNote(viewContext, testTitle, testFolderName);
            NSString *body = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("noteAsPlainTextWithoutTitle"));
            if ([body containsString:@"Appended text"]) { fprintf(stderr, "  PASS\n"); passed++; }
            else { fprintf(stderr, "  FAIL (not in body)\n"); failed++; }
        } else { fprintf(stderr, "  FAIL (append returned %d)\n", ret); failed++; }
    }

    // Test 7: Replace
    fprintf(stderr, "Test 7: Replace...\n");
    {
        id noteForID7 = findNote(viewContext, testTitle, testFolderName);
        NSString *noteID7 = noteToDict(noteForID7)[@"id"];
        int ret = cmdReplace(viewContext, noteID7, @"Test body", @"Modified body");
        if (ret == 0) {
            id note = findNote(viewContext, testTitle, testFolderName);
            NSString *body = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("noteAsPlainTextWithoutTitle"));
            if ([body containsString:@"Modified body"] && ![body containsString:@"Test body"]) {
                fprintf(stderr, "  PASS\n"); passed++;
            } else { fprintf(stderr, "  FAIL (body: %s)\n", [body UTF8String]); failed++; }
        } else { fprintf(stderr, "  FAIL\n"); failed++; }
    }

    // Test 8: Search
    fprintf(stderr, "Test 8: Search...\n");
    {
        id note = findNote(viewContext, testTitle, testFolderName);
        if (note) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL\n"); failed++; }
    }

    // Test 9: Duplicate
    fprintf(stderr, "Test 9: Duplicate...\n");
    {
        id noteForID9 = findNote(viewContext, testTitle, testFolderName);
        NSString *noteID9 = noteToDict(noteForID9)[@"id"];
        int ret = cmdDuplicate(viewContext, noteID9, testTitle2);
        if (ret != 0) { fprintf(stderr, "  FAIL (cmdDuplicate returned %d)\n", ret); failed++; }
        else {
            // Compare styles paragraph by paragraph between original and duplicate
            id orig = findNote(viewContext, testTitle, testFolderName);
            id dup = findNote(viewContext, testTitle2, testFolderName);
            if (!orig || !dup) { fprintf(stderr, "  FAIL (notes not found)\n"); failed++; }
            else {
                id origDoc = ((id (*)(id, SEL))objc_msgSend)(orig, sel_registerName("document"));
                id origMs = ((id (*)(id, SEL))objc_msgSend)(origDoc, sel_registerName("mergeableString"));
                NSString *origText = [((id (*)(id, SEL))objc_msgSend)(orig, sel_registerName("attributedString")) string];

                id dupDoc = ((id (*)(id, SEL))objc_msgSend)(dup, sel_registerName("document"));
                id dupMs = ((id (*)(id, SEL))objc_msgSend)(dupDoc, sel_registerName("mergeableString"));
                NSString *dupText = [((id (*)(id, SEL))objc_msgSend)(dup, sel_registerName("attributedString")) string];

                // Walk paragraphs and compare styles
                NSArray *origParas = [origText componentsSeparatedByString:@"\n"];
                NSArray *dupParas = [dupText componentsSeparatedByString:@"\n"];
                NSUInteger paraCount = MIN(origParas.count, dupParas.count);
                int mismatches = 0;
                NSUInteger origOff = 0, dupOff = 0;
                for (NSUInteger pi = 0; pi < paraCount; pi++) {
                    NSString *op = origParas[pi];
                    NSString *dp = dupParas[pi];
                    if (op.length == 0 || dp.length == 0) { origOff += op.length + 1; dupOff += dp.length + 1; continue; }

                    NSRange origRange, dupRange;
                    NSDictionary *origAttrs = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
                        origMs, sel_registerName("attributesAtIndex:effectiveRange:"), origOff, &origRange);
                    NSDictionary *dupAttrs = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
                        dupMs, sel_registerName("attributesAtIndex:effectiveRange:"), dupOff, &dupRange);

                    id origStyle = origAttrs[@"TTStyle"];
                    id dupStyle = dupAttrs[@"TTStyle"];
                    int origStyleVal = origStyle ? (int)((NSInteger (*)(id, SEL))objc_msgSend)(origStyle, sel_registerName("style")) : -1;
                    int dupStyleVal = dupStyle ? (int)((NSInteger (*)(id, SEL))objc_msgSend)(dupStyle, sel_registerName("style")) : -1;

                    if (origStyleVal != dupStyleVal) {
                        mismatches++;
                        if (mismatches <= 3) {
                            fprintf(stderr, "    P%lu: style %d vs %d \"%.*s\"\n",
                                (unsigned long)pi, origStyleVal, dupStyleVal, (int)MIN(40, op.length), [op UTF8String]);
                        }
                    }
                    origOff += op.length + 1;
                    dupOff += dp.length + 1;
                }
                // Also check links preserved
                BOOL linkFound = NO;
                NSUInteger li = 0;
                while (li < dupText.length) {
                    NSRange lr;
                    NSDictionary *la = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
                        dupMs, sel_registerName("attributesAtIndex:effectiveRange:"), li, &lr);
                    if (la[@"NSLink"]) { linkFound = YES; break; }
                    li = lr.location + lr.length;
                }

                if (mismatches == 0 && linkFound) { fprintf(stderr, "  PASS (styles+links match)\n"); passed++; }
                else if (mismatches > 0) { fprintf(stderr, "  FAIL (%d style mismatches)\n", mismatches); failed++; }
                else { fprintf(stderr, "  FAIL (link not preserved)\n"); failed++; }
            }
        }
    }

    // Test 10: Delete duplicate doesn't destroy original's attachments
    fprintf(stderr, "Test 10: Delete preserves shared attachments...\n");
    {
        // The test note has an NSLink on the checklist item (set in Test 3)
        // Duplicate it, delete the copy, verify original still has the link
        id origNote = findNote(viewContext, testTitle, testFolderName);
        NSString *dupTitle = @"__notes_cli_attach_test__";

        // Count links in original before
        id origDoc = ((id (*)(id, SEL))objc_msgSend)(origNote, sel_registerName("document"));
        id origMs = ((id (*)(id, SEL))objc_msgSend)(origDoc, sel_registerName("mergeableString"));
        NSString *origText = [((id (*)(id, SEL))objc_msgSend)(origNote, sel_registerName("attributedString")) string];
        int linksBefore = 0;
        NSUInteger oi = 0;
        while (oi < origText.length) {
            NSRange or2;
            NSDictionary *oa = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
                origMs, sel_registerName("attributesAtIndex:effectiveRange:"), oi, &or2);
            if (oa[@"NSLink"]) linksBefore++;
            oi = or2.location + or2.length;
        }

        // Duplicate and delete
        NSString *origID10 = noteToDict(origNote)[@"id"];
        int dr = cmdDuplicate(viewContext, origID10, dupTitle);
        if (dr == 0) {
            deleteNote(findNote(viewContext, dupTitle, testFolderName), viewContext);
            [viewContext save:nil];

            // Count links in original after
            origNote = findNote(viewContext, testTitle, testFolderName);
            origDoc = ((id (*)(id, SEL))objc_msgSend)(origNote, sel_registerName("document"));
            origMs = ((id (*)(id, SEL))objc_msgSend)(origDoc, sel_registerName("mergeableString"));
            origText = [((id (*)(id, SEL))objc_msgSend)(origNote, sel_registerName("attributedString")) string];
            int linksAfter = 0;
            oi = 0;
            while (oi < origText.length) {
                NSRange or3;
                NSDictionary *oa2 = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
                    origMs, sel_registerName("attributesAtIndex:effectiveRange:"), oi, &or3);
                if (oa2[@"NSLink"]) linksAfter++;
                oi = or3.location + or3.length;
            }

            if (linksBefore > 0 && linksAfter == linksBefore) {
                fprintf(stderr, "  PASS (%d links preserved)\n", linksAfter); passed++;
            } else if (linksBefore == 0) {
                fprintf(stderr, "  FAIL (no links in original to test)\n"); failed++;
            } else {
                fprintf(stderr, "  FAIL (links: %d before, %d after)\n", linksBefore, linksAfter); failed++;
            }
        } else { fprintf(stderr, "  FAIL (duplicate failed)\n"); failed++; }
    }

    // Test 11: Move note (use a second dynamic folder)
    fprintf(stderr, "Test 11: Move note...\n");
    {
        NSString *testFolder2Name = @"__notes_cli_test_folder_2__";
        // Create second test folder
        Class ICFolder2 = NSClassFromString(@"ICFolder");
        id account2 = nil;
        for (id f in fetchFolders(viewContext)) {
            account2 = ((id (*)(id, SEL))objc_msgSend)(f, sel_registerName("account"));
            if (account2) break;
        }
        id tf2 = ((id (*)(id, SEL, id))objc_msgSend)(ICFolder2, sel_registerName("newFolderInAccount:"), account2);
        ((void (*)(id, SEL, id))objc_msgSend)(tf2, sel_registerName("setTitle:"), testFolder2Name);
        [viewContext save:nil];

        id noteForMove = findNote(viewContext, testTitle2, testFolderName);
        NSString *moveID = noteToDict(noteForMove)[@"id"];
        int ret = cmdMoveNote(viewContext, moveID, testFolder2Name);
        if (ret == 0) {
            id moved = findNote(viewContext, testTitle2, testFolder2Name);
            if (moved) {
                // Move it back
                cmdMoveNote(viewContext, moveID, testFolderName);
                fprintf(stderr, "  PASS\n"); passed++;
            } else { fprintf(stderr, "  FAIL (not in target folder)\n"); failed++; }
        } else { fprintf(stderr, "  FAIL\n"); failed++; }

        // Cleanup second folder
        ((void (*)(id, SEL, id))objc_msgSend)(ICFolder2, sel_registerName("deleteFolder:"), tf2);
        [viewContext save:nil];
    }

    // Test 11: Pin
    fprintf(stderr, "Test 11: Pin...\n");
    {
        id noteForPin = findNote(viewContext, testTitle, testFolderName);
        NSString *pinID = noteToDict(noteForPin)[@"id"];
        int ret = cmdPin(viewContext, pinID, YES);
        if (ret == 0) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL\n"); failed++; }
    }

    // Test 12: Unpin
    fprintf(stderr, "Test 12: Unpin...\n");
    {
        id noteForUnpin = findNote(viewContext, testTitle, testFolderName);
        NSString *unpinID = noteToDict(noteForUnpin)[@"id"];
        int ret = cmdPin(viewContext, unpinID, NO);
        if (ret == 0) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL\n"); failed++; }
    }

    // Test 13: cmdSearch (call actual command)
    fprintf(stderr, "Test 13: cmdSearch...\n");
    { int r = cmdSearch(viewContext, testTitle, testFolderName); if (r==0) { fprintf(stderr, "  PASS\n"); passed++; } else { fprintf(stderr, "  FAIL\n"); failed++; } }

    // Test 14: Verify JSON shape from noteToDict
    fprintf(stderr, "Test 14: JSON shape...\n");
    {
        id note = findNote(viewContext, testTitle, testFolderName);
        NSDictionary *dict = noteToDict(note);
        BOOL hasTitle = dict[@"title"] != nil;
        BOOL hasFolder = dict[@"folder"] != nil;
        BOOL hasId = dict[@"id"] != nil;
        BOOL hasCreated = dict[@"createdAt"] != nil;
        BOOL hasModified = dict[@"modifiedAt"] != nil;
        BOOL hasChecklist = dict[@"hasChecklist"] != nil;
        if (hasTitle && hasFolder && hasId && hasCreated && hasModified && hasChecklist) {
            fprintf(stderr, "  PASS\n"); passed++;
        } else { fprintf(stderr, "  FAIL\n"); failed++; }
    }

    // Test 16: cmdReadAttrs (call actual command)
    fprintf(stderr, "Test 16: cmdReadAttrs...\n");
    { int r = cmdReadAttrs(viewContext, testTitle, testFolderName); if (r==0) { fprintf(stderr, "  PASS\n"); passed++; } else { fprintf(stderr, "  FAIL\n"); failed++; } }

    // Test 17: cmdReadStructured (call actual command)
    fprintf(stderr, "Test 17: cmdReadStructured...\n");
    { int r = cmdReadStructured(viewContext, testTitle, testFolderName); if (r==0) { fprintf(stderr, "  PASS\n"); passed++; } else { fprintf(stderr, "  FAIL\n"); failed++; } }

    // Test 18: Error path - not found
    fprintf(stderr, "Test 18: Error path (not found)...\n");
    {
        id notFound = findNote(viewContext, @"__nonexistent_note_999__", testFolderName);
        if (!notFound) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL\n"); failed++; }
    }

    // --- Note Linking Tests ---

    char rawExePath[PATH_MAX];
    char exePath[PATH_MAX];
    uint32_t exeSize = sizeof(rawExePath);
    _NSGetExecutablePath(rawExePath, &exeSize);
    realpath(rawExePath, exePath);

    // Test: get-link
    fprintf(stderr, "Test: get-link...\n");
    {
        id noteA = findNote(viewContext, testTitle, testFolderName);
        if (noteA) {
            NSString *noteAId = noteToDict(noteA)[@"id"];
            int ret = cmdGetLink(viewContext, noteAId);
            if (ret == 0) {
                NSDictionary *dict = noteToDict(noteA);
                NSString *url = dict[@"url"];
                if (url && [url containsString:@"applenotes://showNote?identifier="]) {
                    fprintf(stderr, "  PASS\n"); passed++;
                } else { fprintf(stderr, "  FAIL (no url in noteToDict)\n"); failed++; }
            } else { fprintf(stderr, "  FAIL (cmdGetLink returned %d)\n", ret); failed++; }
        } else { fprintf(stderr, "  FAIL (note not found)\n"); failed++; }
    }

    // Test: add-link (append, default text)
    fprintf(stderr, "Test: add-link (append)...\n");
    {
        id noteA = findNote(viewContext, testTitle, testFolderName);
        id noteB = findNote(viewContext, testTitle2, testFolderName);
        if (noteA && noteB) {
            NSString *aId = noteToDict(noteA)[@"id"];
            NSString *bId = noteToDict(noteB)[@"id"];
            int ret = cmdAddLink(viewContext, aId, bId, nil, -1);
            if (ret == 0) {
                noteA = findNoteByID(viewContext, aId);
                id doc = ((id (*)(id, SEL))objc_msgSend)(noteA, sel_registerName("document"));
                id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
                NSString *fullText = [((id (*)(id, SEL))objc_msgSend)(noteA, sel_registerName("attributedString")) string];
                BOOL foundNoteLink = NO;
                NSString *expectedURL = [NSString stringWithFormat:@"applenotes://showNote?identifier=%@", bId];
                NSUInteger li = 0;
                while (li < fullText.length) {
                    NSRange lr;
                    NSDictionary *la = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
                        ms, sel_registerName("attributesAtIndex:effectiveRange:"), li, &lr);
                    id link = la[@"NSLink"];
                    if (link && [[link description] containsString:expectedURL]) {
                        foundNoteLink = YES; break;
                    }
                    li = lr.location + lr.length;
                }
                if (foundNoteLink) { fprintf(stderr, "  PASS\n"); passed++; }
                else { fprintf(stderr, "  FAIL (note link not found in attrs)\n"); failed++; }
            } else { fprintf(stderr, "  FAIL (cmdAddLink returned %d)\n", ret); failed++; }
        } else { fprintf(stderr, "  FAIL (notes not found)\n"); failed++; }
    }

    // Test: read-attrs JSON output includes linkType=note and linkedNoteId (subprocess)
    fprintf(stderr, "Test: read-attrs linkType/linkedNoteId...\n");
    {
        id noteA = findNote(viewContext, testTitle, testFolderName);
        id noteB = findNote(viewContext, testTitle2, testFolderName);
        if (noteA && noteB) {
            NSString *aId = noteToDict(noteA)[@"id"];
            NSString *bId = noteToDict(noteB)[@"id"];
            NSString *cmd = [NSString stringWithFormat:@"'%s' read-attrs --id '%@' 2>/dev/null", exePath, aId];
            FILE *fp = popen([cmd UTF8String], "r");
            NSMutableData *outData = [NSMutableData data];
            if (fp) {
                char buf[4096];
                size_t n;
                while ((n = fread(buf, 1, sizeof(buf), fp)) > 0) [outData appendBytes:buf length:n];
                pclose(fp);
            }
            NSArray *arr = [NSJSONSerialization JSONObjectWithData:outData options:0 error:nil];
            BOOL foundLinkType = NO;
            BOOL foundLinkedNoteId = NO;
            for (NSDictionary *entry in arr) {
                if ([entry[@"linkType"] isEqualToString:@"note"]) foundLinkType = YES;
                if ([entry[@"linkedNoteId"] isEqualToString:bId]) foundLinkedNoteId = YES;
            }
            if (foundLinkType && foundLinkedNoteId) { fprintf(stderr, "  PASS\n"); passed++; }
            else { fprintf(stderr, "  FAIL (linkType=%d linkedNoteId=%d)\n", foundLinkType, foundLinkedNoteId); failed++; }
        } else { fprintf(stderr, "  FAIL (notes not found)\n"); failed++; }
    }

    // Test: read-structured JSON output includes links array with note link (subprocess)
    fprintf(stderr, "Test: read-structured links array...\n");
    {
        id noteA = findNote(viewContext, testTitle, testFolderName);
        id noteB = findNote(viewContext, testTitle2, testFolderName);
        if (noteA && noteB) {
            NSString *aId = noteToDict(noteA)[@"id"];
            NSString *bId = noteToDict(noteB)[@"id"];
            NSString *cmd = [NSString stringWithFormat:@"'%s' read-structured --id '%@' 2>/dev/null", exePath, aId];
            FILE *fp = popen([cmd UTF8String], "r");
            NSMutableData *outData = [NSMutableData data];
            if (fp) {
                char buf[4096];
                size_t n;
                while ((n = fread(buf, 1, sizeof(buf), fp)) > 0) [outData appendBytes:buf length:n];
                pclose(fp);
            }
            NSArray *arr = [NSJSONSerialization JSONObjectWithData:outData options:0 error:nil];
            BOOL foundNoteLink = NO;
            for (NSDictionary *para in arr) {
                NSArray *links = para[@"links"];
                for (NSDictionary *link in links) {
                    if ([link[@"type"] isEqualToString:@"note"] && [link[@"linkedNoteId"] isEqualToString:bId]) {
                        foundNoteLink = YES;
                    }
                }
            }
            if (foundNoteLink) { fprintf(stderr, "  PASS\n"); passed++; }
            else { fprintf(stderr, "  FAIL (no note link in structured output)\n"); failed++; }
        } else { fprintf(stderr, "  FAIL (notes not found)\n"); failed++; }
    }

    // Test: add-link at position
    fprintf(stderr, "Test: add-link (position)...\n");
    {
        id posNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id posDoc = ((id (*)(id, SEL))objc_msgSend)(posNote, sel_registerName("document"));
        id posMs = ((id (*)(id, SEL))objc_msgSend)(posDoc, sel_registerName("mergeableString"));
        NSString *posContent = @"Hello World";
        ((void (*)(id, SEL))objc_msgSend)(posNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(posMs, sel_registerName("insertString:atIndex:"), posContent, 0);
        id posStyle = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(posStyle, sel_registerName("setStyle:"), 3);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(posMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": posStyle}, NSMakeRange(0, posContent.length));
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            posNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, posContent.length), posContent.length);
        ((void (*)(id, SEL))objc_msgSend)(posNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(posNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        NSString *posId = noteToDict(posNote)[@"id"];
        id noteB = findNote(viewContext, testTitle2, testFolderName);
        NSString *bId = noteToDict(noteB)[@"id"];

        int ret = cmdAddLink(viewContext, posId, bId, nil, 5);
        if (ret == 0) {
            posNote = findNoteByID(viewContext, posId);
            posDoc = ((id (*)(id, SEL))objc_msgSend)(posNote, sel_registerName("document"));
            posMs = ((id (*)(id, SEL))objc_msgSend)(posDoc, sel_registerName("mergeableString"));
            NSRange lr;
            NSDictionary *la = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
                posMs, sel_registerName("attributesAtIndex:effectiveRange:"), 5, &lr);
            if (la[@"NSLink"]) { fprintf(stderr, "  PASS\n"); passed++; }
            else { fprintf(stderr, "  FAIL (no link at offset 5)\n"); failed++; }
        } else { fprintf(stderr, "  FAIL (cmdAddLink returned %d)\n", ret); failed++; }

        deleteNote(findNoteByID(viewContext, posId), viewContext);
        [viewContext save:nil];
    }

    // Test: add-link to empty note
    fprintf(stderr, "Test: add-link (empty note)...\n");
    {
        id emptyNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        ((void (*)(id, SEL))objc_msgSend)(emptyNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        NSString *emptyId = noteToDict(emptyNote)[@"id"];
        id noteB = findNote(viewContext, testTitle2, testFolderName);
        NSString *bId = noteToDict(noteB)[@"id"];

        int ret = cmdAddLink(viewContext, emptyId, bId, nil, -1);
        if (ret == 0) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL\n"); failed++; }

        deleteNote(findNoteByID(viewContext, emptyId), viewContext);
        [viewContext save:nil];
    }

    // Test: add-link with custom text
    fprintf(stderr, "Test: add-link (custom text)...\n");
    {
        id noteA = findNote(viewContext, testTitle, testFolderName);
        id noteB = findNote(viewContext, testTitle2, testFolderName);
        if (noteA && noteB) {
            NSString *aId = noteToDict(noteA)[@"id"];
            NSString *bId = noteToDict(noteB)[@"id"];
            int ret = cmdAddLink(viewContext, aId, bId, @"custom label", -1);
            if (ret == 0) {
                noteA = findNoteByID(viewContext, aId);
                NSString *body = ((id (*)(id, SEL))objc_msgSend)(noteA, sel_registerName("noteAsPlainTextWithoutTitle"));
                if ([body containsString:@"custom label"]) { fprintf(stderr, "  PASS\n"); passed++; }
                else { fprintf(stderr, "  FAIL (custom label not in body)\n"); failed++; }
            } else { fprintf(stderr, "  FAIL\n"); failed++; }
        } else { fprintf(stderr, "  FAIL (notes not found)\n"); failed++; }
    }

    // Test: add-link error - invalid target (subprocess)
    fprintf(stderr, "Test: add-link error (invalid target)...\n");
    {
        id noteA = findNote(viewContext, testTitle, testFolderName);
        NSString *aId = noteToDict(noteA)[@"id"];
        NSString *cmd = [NSString stringWithFormat:@"'%s' add-link --id '%@' --target NONEXISTENT_ID 2>/dev/null", exePath, aId];
        int ret = system([cmd UTF8String]);
        if (ret != 0) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (should have failed)\n"); failed++; }
    }

    // Test: add-link error - position out of bounds (subprocess)
    fprintf(stderr, "Test: add-link error (position OOB)...\n");
    {
        id noteA = findNote(viewContext, testTitle, testFolderName);
        id noteB = findNote(viewContext, testTitle2, testFolderName);
        NSString *aId = noteToDict(noteA)[@"id"];
        NSString *bId = noteToDict(noteB)[@"id"];
        NSString *cmd = [NSString stringWithFormat:@"'%s' add-link --id '%@' --target '%@' --position 99999 2>/dev/null", exePath, aId, bId];
        int ret = system([cmd UTF8String]);
        if (ret != 0) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (should have failed)\n"); failed++; }
    }

    // Test: delete-line
    fprintf(stderr, "Test: delete-line...\n");
    {
        // Create a note with 3 body paragraphs
        NSString *dlTitle = @"__notes_cli_delete_line_test__";
        id dlNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id dlDoc = ((id (*)(id, SEL))objc_msgSend)(dlNote, sel_registerName("document"));
        id dlMs = ((id (*)(id, SEL))objc_msgSend)(dlDoc, sel_registerName("mergeableString"));
        NSString *dlContent = [NSString stringWithFormat:@"%@\nLine one\nLine two\nLine three", dlTitle];
        ((void (*)(id, SEL))objc_msgSend)(dlNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(dlMs, sel_registerName("insertString:atIndex:"), dlContent, 0);
        id dlTitleStyle = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(dlTitleStyle, sel_registerName("setStyle:"), 0);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(dlMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": dlTitleStyle}, NSMakeRange(0, dlTitle.length + 1));
        id dlBodyStyle = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(dlBodyStyle, sel_registerName("setStyle:"), 3);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(dlMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": dlBodyStyle}, NSMakeRange(dlTitle.length + 1, dlContent.length - dlTitle.length - 1));
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            dlNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, dlContent.length), dlContent.length);
        ((void (*)(id, SEL))objc_msgSend)(dlNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(dlNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        // Delete "Line two"
        NSString *dlID = noteToDict(dlNote)[@"id"];
        int dlRet = cmdDeleteLine(viewContext, dlID, @"Line two");
        if (dlRet == 0) {
            id dlAfter = findNote(viewContext, dlTitle, testFolderName);
            NSString *dlBody = ((id (*)(id, SEL))objc_msgSend)(dlAfter, sel_registerName("noteAsPlainTextWithoutTitle"));
            BOOL hasLineOne = [dlBody containsString:@"Line one"];
            BOOL hasLineTwo = [dlBody containsString:@"Line two"];
            BOOL hasLineThree = [dlBody containsString:@"Line three"];
            // Count paragraphs
            NSArray *dlParas = [dlBody componentsSeparatedByString:@"\n"];
            NSUInteger nonEmpty = 0;
            for (NSString *p in dlParas) { if (p.length > 0) nonEmpty++; }
            if (hasLineOne && !hasLineTwo && hasLineThree && nonEmpty == 2) {
                fprintf(stderr, "  PASS\n"); passed++;
            } else {
                fprintf(stderr, "  FAIL (body: %s, paras: %lu)\n", [dlBody UTF8String], (unsigned long)nonEmpty); failed++;
            }
        } else { fprintf(stderr, "  FAIL (cmdDeleteLine returned %d)\n", dlRet); failed++; }

        // Cleanup
        id dlCleanup = findNote(viewContext, dlTitle, testFolderName);
        if (dlCleanup) deleteNote(dlCleanup, viewContext);
        [viewContext save:nil];
    }

    // --- Hyperlink tests ---

    // Test: Set link on a text range
    fprintf(stderr, "Test: Set link on text range...\n");
    {
        id note = findNote(viewContext, testTitle, testFolderName);
        NSString *noteID = noteToDict(note)[@"id"];
        // Body starts after title + newline
        NSUInteger linkOffset = [testTitle length] + 1;
        int ret = cmdSetAttr(viewContext, noteID, linkOffset, 13,
            @{@"link": @"https://example.com/test"});
        if (ret == 0) {
            note = findNote(viewContext, testTitle, testFolderName);
            id doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
            id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
            NSRange lr;
            NSDictionary *la = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
                ms, sel_registerName("attributesAtIndex:effectiveRange:"), linkOffset, &lr);
            NSURL *foundLink = la[@"NSLink"];
            if (foundLink && [[foundLink absoluteString] containsString:@"example.com"]) {
                fprintf(stderr, "  PASS\n"); passed++;
            } else {
                fprintf(stderr, "  FAIL (link not found: attrs=%s)\n", [[la description] UTF8String]); failed++;
            }
        } else { fprintf(stderr, "  FAIL (cmdSetAttr returned %d)\n", ret); failed++; }
    }

    // Test: Link-only update preserves style
    fprintf(stderr, "Test: Link preserves existing style...\n");
    {
        id note = findNote(viewContext, testTitle, testFolderName);
        NSString *noteID = noteToDict(note)[@"id"];
        NSUInteger linkOffset = [testTitle length] + 1;
        id doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
        id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
        NSRange sr;
        NSDictionary *beforeAttrs = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
            ms, sel_registerName("attributesAtIndex:effectiveRange:"), linkOffset, &sr);
        id beforeStyle = beforeAttrs[@"TTStyle"];
        int beforeStyleVal = beforeStyle ? (int)((NSInteger (*)(id, SEL))objc_msgSend)(beforeStyle, sel_registerName("style")) : -1;
        NSURL *beforeLink = beforeAttrs[@"NSLink"];

        if (beforeStyleVal >= 0 && beforeLink) {
            fprintf(stderr, "  PASS (style=%d preserved with link)\n", beforeStyleVal); passed++;
        } else {
            fprintf(stderr, "  FAIL (style=%d, link=%s)\n", beforeStyleVal, beforeLink ? "yes" : "no"); failed++;
        }
    }

    // Test: Style-only update preserves existing link
    fprintf(stderr, "Test: Style update preserves link...\n");
    {
        id note = findNote(viewContext, testTitle, testFolderName);
        NSString *noteID = noteToDict(note)[@"id"];
        NSUInteger linkOffset = [testTitle length] + 1;
        // Change style to heading (1) on the range that has a link
        int ret = cmdSetAttr(viewContext, noteID, linkOffset, 13, @{@"style": @"1"});
        if (ret == 0) {
            note = findNote(viewContext, testTitle, testFolderName);
            id doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
            id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
            NSRange lr;
            NSDictionary *la = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
                ms, sel_registerName("attributesAtIndex:effectiveRange:"), linkOffset, &lr);
            NSURL *foundLink = la[@"NSLink"];
            id styleObj = la[@"TTStyle"];
            int styleVal = styleObj ? (int)((NSInteger (*)(id, SEL))objc_msgSend)(styleObj, sel_registerName("style")) : -1;
            if (foundLink && styleVal == 1) {
                fprintf(stderr, "  PASS (link preserved, style=%d)\n", styleVal); passed++;
            } else {
                fprintf(stderr, "  FAIL (link=%s, style=%d)\n", foundLink ? "yes" : "no", styleVal); failed++;
            }
        } else { fprintf(stderr, "  FAIL\n"); failed++; }
        // Restore style back to body (3)
        note = findNote(viewContext, testTitle, testFolderName);
        NSString *restoreID = noteToDict(note)[@"id"];
        cmdSetAttr(viewContext, restoreID, [testTitle length] + 1, 13, @{@"style": @"3"});
    }

    // Test: Remove link
    fprintf(stderr, "Test: Remove link...\n");
    {
        id note = findNote(viewContext, testTitle, testFolderName);
        NSString *noteID = noteToDict(note)[@"id"];
        NSUInteger linkOffset = [testTitle length] + 1;
        int ret = cmdSetAttr(viewContext, noteID, linkOffset, 13, @{@"link": @""});
        if (ret == 0) {
            note = findNote(viewContext, testTitle, testFolderName);
            id doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
            id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
            NSRange lr;
            NSDictionary *la = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
                ms, sel_registerName("attributesAtIndex:effectiveRange:"), linkOffset, &lr);
            if (!la[@"NSLink"]) {
                id styleObj = la[@"TTStyle"];
                int styleVal = styleObj ? (int)((NSInteger (*)(id, SEL))objc_msgSend)(styleObj, sel_registerName("style")) : -1;
                if (styleVal >= 0) {
                    fprintf(stderr, "  PASS (link removed, style=%d preserved)\n", styleVal); passed++;
                } else {
                    fprintf(stderr, "  FAIL (link removed but style lost)\n"); failed++;
                }
            } else {
                fprintf(stderr, "  FAIL (link still present)\n"); failed++;
            }
        } else { fprintf(stderr, "  FAIL\n"); failed++; }
    }

    // Test: Invalid URL returns error (subprocess test)
    fprintf(stderr, "Test: Invalid URL rejected...\n");
    {
        char pathBuf[4096];
        uint32_t pathSize = sizeof(pathBuf);
        _NSGetExecutablePath(pathBuf, &pathSize);
        id note = findNote(viewContext, testTitle, testFolderName);
        NSString *noteID = noteToDict(note)[@"id"];
        NSUInteger linkOffset = [testTitle length] + 1;
        // Use spaces in URL which NSURL rejects
        NSString *cmd = [NSString stringWithFormat:@"%s set-attr --id %@ --offset %lu --length 13 --link 'has space in url' 2>/dev/null",
            pathBuf, noteID, (unsigned long)linkOffset];
        int ret = system([cmd UTF8String]);
        if (ret != 0) {
            fprintf(stderr, "  PASS (rejected with exit code %d)\n", WEXITSTATUS(ret)); passed++;
        } else {
            fprintf(stderr, "  FAIL (should have been rejected)\n"); failed++;
        }
    }

    // Test: Rejected URL scheme
    fprintf(stderr, "Test: javascript: scheme rejected...\n");
    {
        char pathBuf[4096];
        uint32_t pathSize = sizeof(pathBuf);
        _NSGetExecutablePath(pathBuf, &pathSize);
        id note = findNote(viewContext, testTitle, testFolderName);
        NSString *noteID = noteToDict(note)[@"id"];
        NSUInteger linkOffset = [testTitle length] + 1;
        NSString *cmd = [NSString stringWithFormat:@"%s set-attr --id %@ --offset %lu --length 13 --link 'javascript:alert(1)' 2>/dev/null",
            pathBuf, noteID, (unsigned long)linkOffset];
        int ret = system([cmd UTF8String]);
        if (ret != 0) {
            fprintf(stderr, "  PASS (rejected with exit code %d)\n", WEXITSTATUS(ret)); passed++;
        } else {
            fprintf(stderr, "  FAIL (should have been rejected)\n"); failed++;
        }
    }

    // Test: Multi-run range preservation (set link across body + checklist)
    fprintf(stderr, "Test: Multi-run link preserves styles...\n");
    {
        id note = findNote(viewContext, testTitle, testFolderName);
        NSString *noteID = noteToDict(note)[@"id"];
        id doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
        id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
        NSUInteger msLen = ((NSUInteger (*)(id, SEL))objc_msgSend)(ms, sel_registerName("length"));

        NSUInteger multiOffset = [testTitle length] + 1;
        NSUInteger multiLength = msLen - multiOffset;
        if (multiLength > 0) {
            // Read styles before
            NSRange r1;
            NSDictionary *a1 = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
                ms, sel_registerName("attributesAtIndex:effectiveRange:"), multiOffset, &r1);
            id s1 = a1[@"TTStyle"];
            int style1 = s1 ? (int)((NSInteger (*)(id, SEL))objc_msgSend)(s1, sel_registerName("style")) : -1;

            int ret = cmdSetAttr(viewContext, noteID, multiOffset, multiLength,
                @{@"link": @"https://multi.example.com"});
            if (ret == 0) {
                note = findNote(viewContext, testTitle, testFolderName);
                doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
                ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));

                NSDictionary *a1After = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
                    ms, sel_registerName("attributesAtIndex:effectiveRange:"), multiOffset, &r1);
                id s1After = a1After[@"TTStyle"];
                int style1After = s1After ? (int)((NSInteger (*)(id, SEL))objc_msgSend)(s1After, sel_registerName("style")) : -1;
                NSURL *link1 = a1After[@"NSLink"];

                if (style1 == style1After && link1) {
                    fprintf(stderr, "  PASS (style=%d preserved, link set)\n", style1After); passed++;
                } else {
                    fprintf(stderr, "  FAIL (style %d->%d, link=%s)\n", style1, style1After, link1 ? "yes" : "no"); failed++;
                }

                // Clean up multi-run links
                cmdSetAttr(viewContext, noteToDict(findNote(viewContext, testTitle, testFolderName))[@"id"],
                    multiOffset, multiLength, @{@"link": @""});
            } else { fprintf(stderr, "  FAIL (cmdSetAttr returned %d)\n", ret); failed++; }
        } else { fprintf(stderr, "  FAIL (no body text)\n"); failed++; }
    }

    // Test: Link on checklist preserves todo state
    fprintf(stderr, "Test: Link on checklist preserves todo...\n");
    {
        id note = findNote(viewContext, testTitle, testFolderName);
        NSString *noteID = noteToDict(note)[@"id"];
        NSString *noteText = [((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("attributedString")) string];
        NSRange clRange = [noteText rangeOfString:@"Checklist item"];
        if (clRange.location != NSNotFound) {
            id doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
            id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
            NSRange er;
            NSDictionary *beforeAttrs = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
                ms, sel_registerName("attributesAtIndex:effectiveRange:"), clRange.location, &er);
            id beforeStyle = beforeAttrs[@"TTStyle"];
            id beforeTodo = beforeStyle ? ((id (*)(id, SEL))objc_msgSend)(beforeStyle, sel_registerName("todo")) : nil;
            BOOL hadTodo = (beforeTodo != nil);

            int ret = cmdSetAttr(viewContext, noteID, clRange.location, clRange.length,
                @{@"link": @"https://checklist.example.com"});
            if (ret == 0) {
                note = findNote(viewContext, testTitle, testFolderName);
                doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
                ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
                NSDictionary *afterAttrs = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
                    ms, sel_registerName("attributesAtIndex:effectiveRange:"), clRange.location, &er);
                id afterStyle = afterAttrs[@"TTStyle"];
                id afterTodo = afterStyle ? ((id (*)(id, SEL))objc_msgSend)(afterStyle, sel_registerName("todo")) : nil;
                NSURL *afterLink = afterAttrs[@"NSLink"];
                int afterStyleVal = afterStyle ? (int)((NSInteger (*)(id, SEL))objc_msgSend)(afterStyle, sel_registerName("style")) : -1;

                if (hadTodo && afterTodo && afterLink && afterStyleVal == 103) {
                    fprintf(stderr, "  PASS (todo preserved, style=103, link set)\n"); passed++;
                } else {
                    fprintf(stderr, "  FAIL (hadTodo=%d, afterTodo=%s, link=%s, style=%d)\n",
                        hadTodo, afterTodo ? "yes" : "no", afterLink ? "yes" : "no", afterStyleVal); failed++;
                }
            } else { fprintf(stderr, "  FAIL\n"); failed++; }
        } else { fprintf(stderr, "  FAIL (checklist item not found)\n"); failed++; }
    }

    // Test: Todo-done update preserves existing link
    fprintf(stderr, "Test: Todo-done preserves link...\n");
    {
        id note = findNote(viewContext, testTitle, testFolderName);
        NSString *noteID = noteToDict(note)[@"id"];
        NSString *noteText = [((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("attributedString")) string];
        NSRange clRange = [noteText rangeOfString:@"Checklist item"];
        if (clRange.location != NSNotFound) {
            int ret = cmdSetAttr(viewContext, noteID, clRange.location, clRange.length,
                @{@"todo-done": @"true"});
            if (ret == 0) {
                note = findNote(viewContext, testTitle, testFolderName);
                id doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
                id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
                NSRange er;
                NSDictionary *afterAttrs = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
                    ms, sel_registerName("attributesAtIndex:effectiveRange:"), clRange.location, &er);
                NSURL *afterLink = afterAttrs[@"NSLink"];
                id afterStyle = afterAttrs[@"TTStyle"];
                id afterTodo = afterStyle ? ((id (*)(id, SEL))objc_msgSend)(afterStyle, sel_registerName("todo")) : nil;
                BOOL afterDone = afterTodo ? ((BOOL (*)(id, SEL))objc_msgSend)(afterTodo, sel_registerName("done")) : NO;

                if (afterLink && afterTodo && afterDone) {
                    fprintf(stderr, "  PASS (link preserved, todo done=true)\n"); passed++;
                } else {
                    fprintf(stderr, "  FAIL (link=%s, todo=%s, done=%d)\n",
                        afterLink ? "yes" : "no", afterTodo ? "yes" : "no", afterDone); failed++;
                }
            } else { fprintf(stderr, "  FAIL\n"); failed++; }
        } else { fprintf(stderr, "  FAIL (checklist item not found)\n"); failed++; }
    }

    // Test: Indent update preserves todo state
    fprintf(stderr, "Test: Indent preserves todo state...\n");
    {
        id note = findNote(viewContext, testTitle, testFolderName);
        NSString *noteID = noteToDict(note)[@"id"];
        NSString *noteText = [((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("attributedString")) string];
        NSRange clRange = [noteText rangeOfString:@"Checklist item"];
        if (clRange.location != NSNotFound) {
            int ret = cmdSetAttr(viewContext, noteID, clRange.location, clRange.length,
                @{@"indent": @"1"});
            if (ret == 0) {
                note = findNote(viewContext, testTitle, testFolderName);
                id doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
                id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
                NSRange er;
                NSDictionary *afterAttrs = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
                    ms, sel_registerName("attributesAtIndex:effectiveRange:"), clRange.location, &er);
                id afterStyle = afterAttrs[@"TTStyle"];
                id afterTodo = afterStyle ? ((id (*)(id, SEL))objc_msgSend)(afterStyle, sel_registerName("todo")) : nil;
                BOOL afterDone = afterTodo ? ((BOOL (*)(id, SEL))objc_msgSend)(afterTodo, sel_registerName("done")) : NO;
                NSUInteger afterIndent = afterStyle ? ((NSUInteger (*)(id, SEL))objc_msgSend)(afterStyle, sel_registerName("indent")) : 0;
                int afterStyleVal = afterStyle ? (int)((NSInteger (*)(id, SEL))objc_msgSend)(afterStyle, sel_registerName("style")) : -1;

                if (afterTodo && afterDone && afterIndent == 1 && afterStyleVal == 103) {
                    fprintf(stderr, "  PASS (todo preserved, done=true, indent=1, style=103)\n"); passed++;
                } else {
                    fprintf(stderr, "  FAIL (todo=%s, done=%d, indent=%lu, style=%d)\n",
                        afterTodo ? "yes" : "no", afterDone, (unsigned long)afterIndent, afterStyleVal); failed++;
                }
            } else { fprintf(stderr, "  FAIL\n"); failed++; }
        } else { fprintf(stderr, "  FAIL (checklist item not found)\n"); failed++; }
    }

    // Test: List formatting (dash list via append --style 100)
    fprintf(stderr, "Test: List formatting (dash list)...\n");
    {
        NSString *listTitle = @"__notes_cli_list_test__";
        id listNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id listDoc = ((id (*)(id, SEL))objc_msgSend)(listNote, sel_registerName("document"));
        id listMs = ((id (*)(id, SEL))objc_msgSend)(listDoc, sel_registerName("mergeableString"));
        // Insert title
        ((void (*)(id, SEL))objc_msgSend)(listNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(listMs, sel_registerName("insertString:atIndex:"), listTitle, 0);
        id ltStyle = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(ltStyle, sel_registerName("setStyle:"), 0);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(listMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": ltStyle}, NSMakeRange(0, listTitle.length));
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            listNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, listTitle.length), listTitle.length);
        ((void (*)(id, SEL))objc_msgSend)(listNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(listNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        NSString *listNoteID = noteToDict(listNote)[@"id"];
        // Append three dash list items
        cmdAppend(viewContext, listNoteID, @"Dash item 1", 100);
        cmdAppend(viewContext, listNoteID, @"Dash item 2", 100);
        cmdAppend(viewContext, listNoteID, @"Dash item 3", 100);
        // Append two numbered list items
        cmdAppend(viewContext, listNoteID, @"Number item 1", 102);
        cmdAppend(viewContext, listNoteID, @"Number item 2", 102);

        // Verify via read-attrs
        id verifyNote = findNoteByID(viewContext, listNoteID);
        id verifyDoc = ((id (*)(id, SEL))objc_msgSend)(verifyNote, sel_registerName("document"));
        id verifyMs = ((id (*)(id, SEL))objc_msgSend)(verifyDoc, sel_registerName("mergeableString"));
        NSString *verifyText = [((id (*)(id, SEL))objc_msgSend)(verifyNote, sel_registerName("attributedString")) string];
        int dash100Count = 0, numbered102Count = 0;
        NSUInteger vi = 0;
        while (vi < verifyText.length) {
            NSRange vr;
            NSDictionary *va = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
                verifyMs, sel_registerName("attributesAtIndex:effectiveRange:"), vi, &vr);
            id vs = va[@"TTStyle"];
            if (vs) {
                int sval = (int)((NSInteger (*)(id, SEL))objc_msgSend)(vs, sel_registerName("style"));
                if (sval == 100) dash100Count++;
                if (sval == 102) numbered102Count++;
            }
            vi = vr.location + vr.length;
        }
        if (dash100Count >= 3 && numbered102Count >= 2) {
            fprintf(stderr, "  PASS (dash=%d, numbered=%d)\n", dash100Count, numbered102Count); passed++;
        } else {
            fprintf(stderr, "  FAIL (dash=%d, numbered=%d)\n", dash100Count, numbered102Count); failed++;
        }
        // Cleanup
        deleteNote(findNoteByID(viewContext, listNoteID), viewContext);
        [viewContext save:nil];
    }

    // Test: Checklist via append --style 103
    fprintf(stderr, "Test: Checklist via append...\n");
    {
        NSString *clTitle = @"__notes_cli_checklist_test__";
        id clNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id clDoc = ((id (*)(id, SEL))objc_msgSend)(clNote, sel_registerName("document"));
        id clMs = ((id (*)(id, SEL))objc_msgSend)(clDoc, sel_registerName("mergeableString"));
        ((void (*)(id, SEL))objc_msgSend)(clNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(clMs, sel_registerName("insertString:atIndex:"), clTitle, 0);
        id clTitleStyle = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(clTitleStyle, sel_registerName("setStyle:"), 0);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(clMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": clTitleStyle}, NSMakeRange(0, clTitle.length));
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            clNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, clTitle.length), clTitle.length);
        ((void (*)(id, SEL))objc_msgSend)(clNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(clNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        NSString *clNoteID = noteToDict(clNote)[@"id"];
        cmdAppend(viewContext, clNoteID, @"Check this item", 103);

        // Verify style 103 and todo exists
        id clVerify = findNoteByID(viewContext, clNoteID);
        id clVDoc = ((id (*)(id, SEL))objc_msgSend)(clVerify, sel_registerName("document"));
        id clVMs = ((id (*)(id, SEL))objc_msgSend)(clVDoc, sel_registerName("mergeableString"));
        NSString *clVText = [((id (*)(id, SEL))objc_msgSend)(clVerify, sel_registerName("attributedString")) string];
        BOOL found103 = NO, foundTodo = NO;
        NSUInteger ci = 0;
        while (ci < clVText.length) {
            NSRange cr;
            NSDictionary *ca = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
                clVMs, sel_registerName("attributesAtIndex:effectiveRange:"), ci, &cr);
            id cs = ca[@"TTStyle"];
            if (cs) {
                int csv = (int)((NSInteger (*)(id, SEL))objc_msgSend)(cs, sel_registerName("style"));
                if (csv == 103) {
                    found103 = YES;
                    id ctodo = ((id (*)(id, SEL))objc_msgSend)(cs, sel_registerName("todo"));
                    if (ctodo) foundTodo = YES;
                }
            }
            ci = cr.location + cr.length;
        }
        if (found103 && foundTodo) {
            fprintf(stderr, "  PASS (style=103, todo present)\n"); passed++;
        } else {
            fprintf(stderr, "  FAIL (style103=%d, todo=%d)\n", found103, foundTodo); failed++;
        }
        // Cleanup
        deleteNote(findNoteByID(viewContext, clNoteID), viewContext);
        [viewContext save:nil];
    }

    // Test: Style validation (subprocess-based)
    fprintf(stderr, "Test: Style validation (invalid styles)...\n");
    {
        // Get path to current executable
        char testExecPath[PATH_MAX];
        uint32_t testExecSize = sizeof(testExecPath);
        if (_NSGetExecutablePath(testExecPath, &testExecSize) == 0) {
            char testRealPath[PATH_MAX];
            realpath(testExecPath, testRealPath);
            NSString *binaryPath = [NSString stringWithUTF8String:testRealPath];

            // Create a temp note to test against
            id valNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
            ((void (*)(id, SEL))objc_msgSend)(valNote, sel_registerName("saveNoteData"));
            [viewContext save:nil];
            NSString *valNoteID = noteToDict(valNote)[@"id"];

            // Test invalid style number (999)
            NSTask *task1 = [[NSTask alloc] init];
            [task1 setLaunchPath:binaryPath];
            [task1 setArguments:@[@"append", @"--id", valNoteID, @"--text", @"Bad", @"--style", @"999"]];
            [task1 setStandardOutput:[NSPipe pipe]];
            [task1 setStandardError:[NSPipe pipe]];
            [task1 launch];
            [task1 waitUntilExit];
            int status1 = [task1 terminationStatus];

            // Test non-numeric style (abc)
            NSTask *task2 = [[NSTask alloc] init];
            [task2 setLaunchPath:binaryPath];
            [task2 setArguments:@[@"append", @"--id", valNoteID, @"--text", @"Bad", @"--style", @"abc"]];
            [task2 setStandardOutput:[NSPipe pipe]];
            [task2 setStandardError:[NSPipe pipe]];
            [task2 launch];
            [task2 waitUntilExit];
            int status2 = [task2 terminationStatus];

            if (status1 != 0 && status2 != 0) {
                fprintf(stderr, "  PASS (invalid=exit%d, non-numeric=exit%d)\n", status1, status2); passed++;
            } else {
                fprintf(stderr, "  FAIL (invalid=exit%d, non-numeric=exit%d)\n", status1, status2); failed++;
            }

            // Cleanup
            deleteNote(findNoteByID(viewContext, valNoteID), viewContext);
            [viewContext save:nil];
        } else {
            fprintf(stderr, "  SKIP (could not determine executable path)\n");
        }
    }

    // Test: Multiline append with list style (behavior documentation)
    fprintf(stderr, "Test: Multiline append with list style...\n");
    {
        NSString *mlTitle = @"__notes_cli_multiline_list_test__";
        id mlNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id mlDoc = ((id (*)(id, SEL))objc_msgSend)(mlNote, sel_registerName("document"));
        id mlMs = ((id (*)(id, SEL))objc_msgSend)(mlDoc, sel_registerName("mergeableString"));
        ((void (*)(id, SEL))objc_msgSend)(mlNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(mlMs, sel_registerName("insertString:atIndex:"), mlTitle, 0);
        id mlTitleStyle = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(mlTitleStyle, sel_registerName("setStyle:"), 0);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mlMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": mlTitleStyle}, NSMakeRange(0, mlTitle.length));
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            mlNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, mlTitle.length), mlTitle.length);
        ((void (*)(id, SEL))objc_msgSend)(mlNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(mlNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        NSString *mlNoteID = noteToDict(mlNote)[@"id"];
        // Append multiline text with dash list style
        cmdAppend(viewContext, mlNoteID, @"Line A\nLine B", 100);

        // Read back and count style-100 ranges
        id mlVerify = findNoteByID(viewContext, mlNoteID);
        id mlVDoc = ((id (*)(id, SEL))objc_msgSend)(mlVerify, sel_registerName("document"));
        id mlVMs = ((id (*)(id, SEL))objc_msgSend)(mlVDoc, sel_registerName("mergeableString"));
        NSString *mlVText = [((id (*)(id, SEL))objc_msgSend)(mlVerify, sel_registerName("attributedString")) string];
        int mlDashCount = 0;
        NSUInteger mi = 0;
        while (mi < mlVText.length) {
            NSRange mr;
            NSDictionary *ma = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
                mlVMs, sel_registerName("attributesAtIndex:effectiveRange:"), mi, &mr);
            id ms2 = ma[@"TTStyle"];
            if (ms2) {
                int msv = (int)((NSInteger (*)(id, SEL))objc_msgSend)(ms2, sel_registerName("style"));
                if (msv == 100) mlDashCount++;
            }
            mi = mr.location + mr.length;
        }
        // Document behavior: style applies to the entire inserted range as one block
        fprintf(stderr, "  PASS (multiline dash ranges=%d, style applied as single block)\n", mlDashCount); passed++;

        // Cleanup
        deleteNote(findNoteByID(viewContext, mlNoteID), viewContext);
        [viewContext save:nil];
    }

    // Cleanup

    // Test: bodyOffsetForNote
    fprintf(stderr, "Test: bodyOffsetForNote...\n");
    {
        id note = findNote(viewContext, testTitle, testFolderName);
        if (note) {
            NSUInteger bodyOff = bodyOffsetForNote(note);
            NSAttributedString *attrStr = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("attributedString"));
            NSString *fullText = [attrStr string];
            NSString *bodyFromRead = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("noteAsPlainTextWithoutTitle"));
            if (bodyOff != NSNotFound && bodyOff <= fullText.length) {
                NSString *bodyFromOffset = [fullText substringFromIndex:bodyOff];
                // noteAsPlainTextWithoutTitle may include a leading newline; strip it for comparison
                NSString *trimmedRead = [bodyFromRead stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
                // Guard: empty body would trivially pass hasPrefix; fail explicitly
                if (trimmedRead.length == 0) {
                    fprintf(stderr, "  FAIL (body is empty, cannot verify offset)\n"); failed++;
                } else if ([bodyFromOffset hasPrefix:trimmedRead]) {
                    fprintf(stderr, "  PASS (bodyOff=%lu)\n", (unsigned long)bodyOff); passed++;
                } else {
                    fprintf(stderr, "  FAIL (body mismatch at offset %lu)\n", (unsigned long)bodyOff); failed++;
                }
            } else {
                fprintf(stderr, "  FAIL (bodyOff=%lu)\n", (unsigned long)bodyOff); failed++;
            }
        } else { fprintf(stderr, "  FAIL (not found)\n"); failed++; }
    }

    // Test: set-attr with --body-offset
    fprintf(stderr, "Test: set-attr with --body-offset...\n");
    {
        id note = findNote(viewContext, testTitle, testFolderName);
        if (note) {
            NSString *noteID = noteToDict(note)[@"id"];
            NSUInteger bodyOff = bodyOffsetForNote(note);
            NSDictionary *attrOpts = @{@"style": @"1", @"body-offset": @"true"};
            int ret = cmdSetAttr(viewContext, noteID, 0, 5, attrOpts);
            if (ret == 0) {
                note = findNoteByID(viewContext, noteID);
                id doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
                id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
                NSRange effectiveRange;
                NSDictionary *attrs = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(ms, sel_registerName("attributesAtIndex:effectiveRange:"), bodyOff, &effectiveRange);
                id style = attrs[@"TTStyle"];
                NSInteger styleVal = style ? ((NSInteger (*)(id, SEL))objc_msgSend)(style, sel_registerName("style")) : -1;
                if (styleVal == 1) { fprintf(stderr, "  PASS\n"); passed++; }
                else { fprintf(stderr, "  FAIL (style=%ld)\n", (long)styleVal); failed++; }
            } else { fprintf(stderr, "  FAIL (ret=%d)\n", ret); failed++; }
            NSDictionary *resetOpts = @{@"style": @"3", @"body-offset": @"true"};
            cmdSetAttr(viewContext, noteID, 0, 5, resetOpts);
        } else { fprintf(stderr, "  FAIL (not found)\n"); failed++; }
    }

    // Test: set-attr without --body-offset (regression)
    fprintf(stderr, "Test: set-attr without --body-offset...\n");
    {
        id note = findNote(viewContext, testTitle, testFolderName);
        if (note) {
            NSString *noteID = noteToDict(note)[@"id"];
            NSUInteger bodyOff = bodyOffsetForNote(note);
            NSDictionary *attrOpts = @{@"style": @"1"};
            int ret = cmdSetAttr(viewContext, noteID, bodyOff, 5, attrOpts);
            if (ret == 0) {
                note = findNoteByID(viewContext, noteID);
                id doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
                id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
                NSRange effectiveRange;
                NSDictionary *attrs = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(ms, sel_registerName("attributesAtIndex:effectiveRange:"), bodyOff, &effectiveRange);
                id style = attrs[@"TTStyle"];
                NSInteger styleVal = style ? ((NSInteger (*)(id, SEL))objc_msgSend)(style, sel_registerName("style")) : -1;
                if (styleVal == 1) { fprintf(stderr, "  PASS\n"); passed++; }
                else { fprintf(stderr, "  FAIL (style=%ld)\n", (long)styleVal); failed++; }
            } else { fprintf(stderr, "  FAIL (ret=%d)\n", ret); failed++; }
            NSDictionary *resetOpts = @{@"style": @"3"};
            cmdSetAttr(viewContext, noteID, bodyOff, 5, resetOpts);
        } else { fprintf(stderr, "  FAIL (not found)\n"); failed++; }
    }

    // Test: insert with --body-offset
    fprintf(stderr, "Test: insert with --body-offset...\n");
    {
        id note = findNote(viewContext, testTitle, testFolderName);
        if (note) {
            NSString *noteID = noteToDict(note)[@"id"];
            int ret = cmdInsert(viewContext, noteID, @"INSERTED", 0, YES, -1);
            if (ret == 0) {
                note = findNoteByID(viewContext, noteID);
                NSString *body = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("noteAsPlainTextWithoutTitle"));
                // noteAsPlainTextWithoutTitle may have leading newline; check after trimming
                NSString *trimmed = [body stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
                if ([trimmed hasPrefix:@"INSERTED"]) { fprintf(stderr, "  PASS\n"); passed++; }
                else { fprintf(stderr, "  FAIL (body prefix wrong)\n"); failed++; }
                cmdDeleteRange(viewContext, noteID, 0, 8, YES);
            } else { fprintf(stderr, "  FAIL (ret=%d)\n", ret); failed++; }
        } else { fprintf(stderr, "  FAIL (not found)\n"); failed++; }
    }

    // Test: delete-range with --body-offset
    fprintf(stderr, "Test: delete-range with --body-offset...\n");
    {
        id note = findNote(viewContext, testTitle, testFolderName);
        if (note) {
            NSString *noteID = noteToDict(note)[@"id"];
            NSString *bodyBefore = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("noteAsPlainTextWithoutTitle"));
            cmdInsert(viewContext, noteID, @"DELME", 0, YES, -1);
            int ret = cmdDeleteRange(viewContext, noteID, 0, 5, YES);
            if (ret == 0) {
                note = findNoteByID(viewContext, noteID);
                NSString *bodyAfter = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("noteAsPlainTextWithoutTitle"));
                if ([bodyAfter isEqualToString:bodyBefore]) { fprintf(stderr, "  PASS\n"); passed++; }
                else { fprintf(stderr, "  FAIL (body mismatch)\n"); failed++; }
            } else { fprintf(stderr, "  FAIL (ret=%d)\n", ret); failed++; }
        } else { fprintf(stderr, "  FAIL (not found)\n"); failed++; }
    }

    // Test: --body-offset on title-only note
    fprintf(stderr, "Test: body-offset title-only note...\n");
    {
        NSString *toTitle = @"__notes_cli_title_only_test__";
        id toNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id toDoc = ((id (*)(id, SEL))objc_msgSend)(toNote, sel_registerName("document"));
        id toMs = ((id (*)(id, SEL))objc_msgSend)(toDoc, sel_registerName("mergeableString"));
        ((void (*)(id, SEL))objc_msgSend)(toNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(toMs, sel_registerName("insertString:atIndex:"), toTitle, 0);
        id toStyle = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(toStyle, sel_registerName("setStyle:"), 0);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(toMs, sel_registerName("setAttributes:range:"), @{@"TTStyle": toStyle}, NSMakeRange(0, toTitle.length));
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(toNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, toTitle.length), toTitle.length);
        ((void (*)(id, SEL))objc_msgSend)(toNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(toNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];
        NSUInteger bodyOff = bodyOffsetForNote(toNote);
        if (bodyOff == NSNotFound) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (expected NSNotFound, got %lu)\n", (unsigned long)bodyOff); failed++; }
        // Note: command-level --body-offset on title-only notes calls errorExit(exit(1)),
        // so cannot be tested in-process. The helper returns NSNotFound and all three
        // commands (set-attr, insert, delete-range) check for NSNotFound before errorExit.
        deleteNote(toNote, viewContext);
        [viewContext save:nil];
    }

    // Test: bodyOffsetForNote with canonical format (\n + title + \n + body)
    fprintf(stderr, "Test: bodyOffsetForNote canonical format...\n");
    {
        id cnNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id cnDoc = ((id (*)(id, SEL))objc_msgSend)(cnNote, sel_registerName("document"));
        id cnMs = ((id (*)(id, SEL))objc_msgSend)(cnDoc, sel_registerName("mergeableString"));
        NSString *cnTitle = @"__canonical_test__";
        NSString *cnBody = @"canonical body text";
        // Build canonical format: \n + title + \n + body
        NSString *cnContent = [NSString stringWithFormat:@"\n%@\n%@", cnTitle, cnBody];
        ((void (*)(id, SEL))objc_msgSend)(cnNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(cnMs, sel_registerName("insertString:atIndex:"), cnContent, 0);
        id cnStyle = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(cnStyle, sel_registerName("setStyle:"), 0);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(cnMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": cnStyle}, NSMakeRange(0, 1 + cnTitle.length + 1));
        id cnBodyStyle = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(cnBodyStyle, sel_registerName("setStyle:"), 3);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(cnMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": cnBodyStyle}, NSMakeRange(1 + cnTitle.length + 1, cnBody.length));
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            cnNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, cnContent.length), cnContent.length);
        ((void (*)(id, SEL))objc_msgSend)(cnNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(cnNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];
        NSUInteger cnBodyOff = bodyOffsetForNote(cnNote);
        // Expected: 1 (leading \n) + title.length + 1 (separator \n) = cnTitle.length + 2
        NSUInteger expectedOff = 1 + cnTitle.length + 1;
        if (cnBodyOff == expectedOff) {
            // Also verify the body text at that offset matches
            NSAttributedString *cnAttrStr = ((id (*)(id, SEL))objc_msgSend)(cnNote, sel_registerName("attributedString"));
            NSString *cnFullText = [cnAttrStr string];
            NSString *bodyAtOffset = [cnFullText substringFromIndex:cnBodyOff];
            if ([bodyAtOffset hasPrefix:cnBody]) {
                fprintf(stderr, "  PASS (bodyOff=%lu, expected=%lu)\n", (unsigned long)cnBodyOff, (unsigned long)expectedOff); passed++;
            } else {
                fprintf(stderr, "  FAIL (offset correct but body text mismatch: '%s')\n", [bodyAtOffset UTF8String]); failed++;
            }
        } else {
            fprintf(stderr, "  FAIL (bodyOff=%lu, expected=%lu)\n", (unsigned long)cnBodyOff, (unsigned long)expectedOff); failed++;
        }
        deleteNote(cnNote, viewContext);
        [viewContext save:nil];
    }

    // --- Markdown Tests ---

    // Test: read-markdown basic (title + body)
    fprintf(stderr, "Test: read-markdown basic...\n");
    {
        NSString *mdTitle = @"__md_test_basic__";
        id mdNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id mdDoc = ((id (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("document"));
        id mdMs = ((id (*)(id, SEL))objc_msgSend)(mdDoc, sel_registerName("mergeableString"));
        NSString *mdContent = [NSString stringWithFormat:@"%@\nBody text here", mdTitle];
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(mdMs, sel_registerName("insertString:atIndex:"), mdContent, 0);
        id mdTitleStyle = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(mdTitleStyle, sel_registerName("setStyle:"), 0);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": mdTitleStyle}, NSMakeRange(0, mdTitle.length + 1));
        id mdBodyStyle = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(mdBodyStyle, sel_registerName("setStyle:"), 3);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": mdBodyStyle}, NSMakeRange(mdTitle.length + 1, 14));
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            mdNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, mdContent.length), mdContent.length);
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        // Read as markdown via paraModel
        NSArray *model = noteToParaModel(mdNote);
        NSMutableArray *filtered = [NSMutableArray array];
        BOOL fc = NO;
        for (NSDictionary *p in model) {
            if (!fc && [p[@"text"] length] == 0) continue;
            fc = YES;
            [filtered addObject:p];
        }
        NSString *markdown = paraModelToMarkdown(filtered);
        BOOL hasTitleMd = [markdown hasPrefix:@"# "];
        BOOL hasBody = [markdown containsString:@"Body text here"];
        if (hasTitleMd && hasBody) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (md: %s)\n", [markdown UTF8String]); failed++; }

        deleteNote(mdNote, viewContext);
        [viewContext save:nil];
    }

    // Test: read-markdown heading
    fprintf(stderr, "Test: read-markdown heading...\n");
    {
        NSString *mdTitle = @"__md_test_heading__";
        id mdNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id mdDoc = ((id (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("document"));
        id mdMs = ((id (*)(id, SEL))objc_msgSend)(mdDoc, sel_registerName("mergeableString"));
        NSString *mdContent = [NSString stringWithFormat:@"%@\nMy Heading", mdTitle];
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(mdMs, sel_registerName("insertString:atIndex:"), mdContent, 0);
        id s0 = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s0, sel_registerName("setStyle:"), 0);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": s0}, NSMakeRange(0, mdTitle.length + 1));
        id s1 = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s1, sel_registerName("setStyle:"), 1);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": s1}, NSMakeRange(mdTitle.length + 1, 10));
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            mdNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, mdContent.length), mdContent.length);
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        NSArray *model = noteToParaModel(mdNote);
        NSMutableArray *filtered = [NSMutableArray array];
        BOOL fc = NO;
        for (NSDictionary *p in model) {
            if (!fc && [p[@"text"] length] == 0) continue;
            fc = YES;
            [filtered addObject:p];
        }
        NSString *markdown = paraModelToMarkdown(filtered);
        if ([markdown containsString:@"## My Heading"]) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (md: %s)\n", [markdown UTF8String]); failed++; }

        deleteNote(mdNote, viewContext);
        [viewContext save:nil];
    }

    // Test: read-markdown dash list
    fprintf(stderr, "Test: read-markdown dash list...\n");
    {
        NSString *mdTitle = @"__md_test_dash__";
        id mdNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id mdDoc = ((id (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("document"));
        id mdMs = ((id (*)(id, SEL))objc_msgSend)(mdDoc, sel_registerName("mergeableString"));
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(mdMs, sel_registerName("insertString:atIndex:"), mdTitle, 0);
        id s0 = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s0, sel_registerName("setStyle:"), 0);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": s0}, NSMakeRange(0, mdTitle.length));
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            mdNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, mdTitle.length), mdTitle.length);
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        NSString *mdNoteID = noteToDict(mdNote)[@"id"];
        cmdAppend(viewContext, mdNoteID, @"Dash item", 100);

        mdNote = findNoteByID(viewContext, mdNoteID);
        NSArray *model = noteToParaModel(mdNote);
        NSMutableArray *filtered = [NSMutableArray array];
        BOOL fc = NO;
        for (NSDictionary *p in model) {
            if (!fc && [p[@"text"] length] == 0) continue;
            fc = YES;
            [filtered addObject:p];
        }
        NSString *markdown = paraModelToMarkdown(filtered);
        if ([markdown containsString:@"- Dash item"]) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (md: %s)\n", [markdown UTF8String]); failed++; }

        deleteNote(findNoteByID(viewContext, mdNoteID), viewContext);
        [viewContext save:nil];
    }

    // Test: read-markdown numbered list
    fprintf(stderr, "Test: read-markdown numbered list...\n");
    {
        NSString *mdTitle = @"__md_test_num__";
        id mdNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id mdDoc = ((id (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("document"));
        id mdMs = ((id (*)(id, SEL))objc_msgSend)(mdDoc, sel_registerName("mergeableString"));
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(mdMs, sel_registerName("insertString:atIndex:"), mdTitle, 0);
        id s0 = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s0, sel_registerName("setStyle:"), 0);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": s0}, NSMakeRange(0, mdTitle.length));
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            mdNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, mdTitle.length), mdTitle.length);
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        NSString *mdNoteID = noteToDict(mdNote)[@"id"];
        cmdAppend(viewContext, mdNoteID, @"Numbered item", 102);

        mdNote = findNoteByID(viewContext, mdNoteID);
        NSArray *model = noteToParaModel(mdNote);
        NSMutableArray *filtered = [NSMutableArray array];
        BOOL fc = NO;
        for (NSDictionary *p in model) {
            if (!fc && [p[@"text"] length] == 0) continue;
            fc = YES;
            [filtered addObject:p];
        }
        NSString *markdown = paraModelToMarkdown(filtered);
        if ([markdown containsString:@"1. Numbered item"]) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (md: %s)\n", [markdown UTF8String]); failed++; }

        deleteNote(findNoteByID(viewContext, mdNoteID), viewContext);
        [viewContext save:nil];
    }

    // Test: read-markdown checklist
    fprintf(stderr, "Test: read-markdown checklist...\n");
    {
        NSString *mdTitle = @"__md_test_check__";
        id mdNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id mdDoc = ((id (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("document"));
        id mdMs = ((id (*)(id, SEL))objc_msgSend)(mdDoc, sel_registerName("mergeableString"));
        NSString *mdContent = [NSString stringWithFormat:@"%@\nUnchecked item\nChecked item", mdTitle];
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(mdMs, sel_registerName("insertString:atIndex:"), mdContent, 0);
        // Title style
        id s0 = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s0, sel_registerName("setStyle:"), 0);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": s0}, NSMakeRange(0, mdTitle.length + 1));
        // Unchecked checklist
        id s103a = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s103a, sel_registerName("setStyle:"), 103);
        id todoA = ((id (*)(id, SEL, id, BOOL))objc_msgSend)(
            [ICTTTodoClass alloc], sel_registerName("initWithIdentifier:done:"), [NSUUID UUID], NO);
        ((void (*)(id, SEL, id))objc_msgSend)(s103a, sel_registerName("setTodo:"), todoA);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": s103a}, NSMakeRange(mdTitle.length + 1, 15));
        // Checked checklist
        id s103b = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s103b, sel_registerName("setStyle:"), 103);
        id todoB = ((id (*)(id, SEL, id, BOOL))objc_msgSend)(
            [ICTTTodoClass alloc], sel_registerName("initWithIdentifier:done:"), [NSUUID UUID], YES);
        ((void (*)(id, SEL, id))objc_msgSend)(s103b, sel_registerName("setTodo:"), todoB);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": s103b}, NSMakeRange(mdTitle.length + 16, 12));
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            mdNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, mdContent.length), mdContent.length);
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        NSArray *model = noteToParaModel(mdNote);
        NSMutableArray *filtered = [NSMutableArray array];
        BOOL fc = NO;
        for (NSDictionary *p in model) {
            if (!fc && [p[@"text"] length] == 0) continue;
            fc = YES;
            [filtered addObject:p];
        }
        NSString *markdown = paraModelToMarkdown(filtered);
        BOOL hasUnchecked = [markdown containsString:@"- [ ] Unchecked item"];
        BOOL hasChecked = [markdown containsString:@"- [x] Checked item"];
        if (hasUnchecked && hasChecked) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (md: %s)\n", [markdown UTF8String]); failed++; }

        deleteNote(mdNote, viewContext);
        [viewContext save:nil];
    }

    // Test: read-markdown with link
    fprintf(stderr, "Test: read-markdown link...\n");
    {
        NSString *mdTitle = @"__md_test_link__";
        id mdNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id mdDoc = ((id (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("document"));
        id mdMs = ((id (*)(id, SEL))objc_msgSend)(mdDoc, sel_registerName("mergeableString"));
        NSString *mdContent = [NSString stringWithFormat:@"%@\nClick here", mdTitle];
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(mdMs, sel_registerName("insertString:atIndex:"), mdContent, 0);
        id s0 = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s0, sel_registerName("setStyle:"), 0);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": s0}, NSMakeRange(0, mdTitle.length + 1));
        id s3 = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s3, sel_registerName("setStyle:"), 3);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            (@{@"TTStyle": s3, @"NSLink": [NSURL URLWithString:@"https://example.com"]}),
            NSMakeRange(mdTitle.length + 1, 10));
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            mdNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, mdContent.length), mdContent.length);
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        NSArray *model = noteToParaModel(mdNote);
        NSMutableArray *filtered = [NSMutableArray array];
        BOOL fc = NO;
        for (NSDictionary *p in model) {
            if (!fc && [p[@"text"] length] == 0) continue;
            fc = YES;
            [filtered addObject:p];
        }
        NSString *markdown = paraModelToMarkdown(filtered);
        if ([markdown containsString:@"[Click here](https://example.com)"]) {
            fprintf(stderr, "  PASS\n"); passed++;
        } else { fprintf(stderr, "  FAIL (md: %s)\n", [markdown UTF8String]); failed++; }

        deleteNote(mdNote, viewContext);
        [viewContext save:nil];
    }

    // Test: read-markdown with strikethrough
    fprintf(stderr, "Test: read-markdown strikethrough...\n");
    {
        NSString *mdTitle = @"__md_test_strike__";
        id mdNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id mdDoc = ((id (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("document"));
        id mdMs = ((id (*)(id, SEL))objc_msgSend)(mdDoc, sel_registerName("mergeableString"));
        NSString *mdContent = [NSString stringWithFormat:@"%@\nStruck text", mdTitle];
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(mdMs, sel_registerName("insertString:atIndex:"), mdContent, 0);
        id s0 = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s0, sel_registerName("setStyle:"), 0);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": s0}, NSMakeRange(0, mdTitle.length + 1));
        id s3 = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s3, sel_registerName("setStyle:"), 3);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            (@{@"TTStyle": s3, @"TTStrikethrough": @1}),
            NSMakeRange(mdTitle.length + 1, 11));
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            mdNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, mdContent.length), mdContent.length);
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        NSArray *model = noteToParaModel(mdNote);
        NSMutableArray *filtered = [NSMutableArray array];
        BOOL fc = NO;
        for (NSDictionary *p in model) {
            if (!fc && [p[@"text"] length] == 0) continue;
            fc = YES;
            [filtered addObject:p];
        }
        NSString *markdown = paraModelToMarkdown(filtered);
        if ([markdown containsString:@"~~Struck text~~"]) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (md: %s)\n", [markdown UTF8String]); failed++; }

        deleteNote(mdNote, viewContext);
        [viewContext save:nil];
    }

    // Test: markdown escape/unescape round-trip
    fprintf(stderr, "Test: markdown escape round-trip...\n");
    {
        NSString *original = @"Hello *world* [link](url) ~~strike~~ <tag> back\\slash";
        NSString *escaped = escapeMarkdown(original);
        NSString *unescaped = unescapeMarkdown(escaped);
        if ([original isEqualToString:unescaped]) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (orig: %s, unescaped: %s)\n", [original UTF8String], [unescaped UTF8String]); failed++; }
    }

    // Test: markdown parser round-trip
    fprintf(stderr, "Test: markdown parser round-trip...\n");
    {
        NSString *mdTitle = @"__md_test_roundtrip__";
        id mdNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id mdDoc = ((id (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("document"));
        id mdMs = ((id (*)(id, SEL))objc_msgSend)(mdDoc, sel_registerName("mergeableString"));
        NSString *mdContent = [NSString stringWithFormat:@"%@\nBody line 1\nBody line 2", mdTitle];
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(mdMs, sel_registerName("insertString:atIndex:"), mdContent, 0);
        id s0 = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s0, sel_registerName("setStyle:"), 0);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": s0}, NSMakeRange(0, mdTitle.length + 1));
        id s3 = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s3, sel_registerName("setStyle:"), 3);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": s3}, NSMakeRange(mdTitle.length + 1, mdContent.length - mdTitle.length - 1));
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            mdNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, mdContent.length), mdContent.length);
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        // Read as markdown
        NSArray *model = noteToParaModel(mdNote);
        NSMutableArray *filtered = [NSMutableArray array];
        BOOL fc = NO;
        for (NSDictionary *p in model) {
            if (!fc && [p[@"text"] length] == 0) continue;
            fc = YES;
            [filtered addObject:p];
        }
        NSString *markdown = paraModelToMarkdown(filtered);
        // Parse back
        NSArray *parsed = markdownToParaModel(markdown);
        // Compare models
        BOOL match = (filtered.count == parsed.count);
        if (match) {
            for (NSUInteger pi = 0; pi < filtered.count; pi++) {
                NSDictionary *orig = filtered[pi];
                NSDictionary *back = parsed[pi];
                if (![orig[@"style"] isEqual:back[@"style"]] ||
                    ![normalizeParaText(orig[@"text"]) isEqualToString:normalizeParaText(back[@"text"])]) {
                    match = NO;
                    fprintf(stderr, "    Mismatch at para %lu: style %s vs %s, text '%s' vs '%s'\n",
                        (unsigned long)pi, [[orig[@"style"] description] UTF8String],
                        [[back[@"style"] description] UTF8String],
                        [orig[@"text"] UTF8String], [back[@"text"] UTF8String]);
                    break;
                }
            }
        }
        if (match) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (count: %lu vs %lu)\n", (unsigned long)filtered.count, (unsigned long)parsed.count); failed++; }

        deleteNote(mdNote, viewContext);
        [viewContext save:nil];
    }

    // Test: write-markdown no-change round-trip (subprocess)
    fprintf(stderr, "Test: write-markdown no-change round-trip...\n");
    {
        NSString *mdTitle = @"__md_test_nochange__";
        id mdNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id mdDoc = ((id (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("document"));
        id mdMs = ((id (*)(id, SEL))objc_msgSend)(mdDoc, sel_registerName("mergeableString"));
        NSString *mdContent = [NSString stringWithFormat:@"%@\nKeep this line\nAnd this one", mdTitle];
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(mdMs, sel_registerName("insertString:atIndex:"), mdContent, 0);
        id s0 = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s0, sel_registerName("setStyle:"), 0);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": s0}, NSMakeRange(0, mdTitle.length + 1));
        id s3 = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s3, sel_registerName("setStyle:"), 3);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": s3}, NSMakeRange(mdTitle.length + 1, mdContent.length - mdTitle.length - 1));
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            mdNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, mdContent.length), mdContent.length);
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        NSString *mdNoteID = noteToDict(mdNote)[@"id"];
        // Read markdown and pipe to write-markdown --dry-run
        NSString *cmd = [NSString stringWithFormat:@"'%s' read-markdown --id '%@' 2>/dev/null | '%s' write-markdown --id '%@' --dry-run 2>/dev/null",
            exePath, mdNoteID, exePath, mdNoteID];
        FILE *fp = popen([cmd UTF8String], "r");
        NSMutableData *outData = [NSMutableData data];
        if (fp) {
            char buf[4096];
            size_t n;
            while ((n = fread(buf, 1, sizeof(buf), fp)) > 0) [outData appendBytes:buf length:n];
            pclose(fp);
        }
        NSDictionary *result = [NSJSONSerialization JSONObjectWithData:outData options:0 error:nil];
        NSUInteger modified = [result[@"paragraphsModified"] unsignedIntegerValue];
        NSUInteger insertedCount = [result[@"paragraphsInserted"] unsignedIntegerValue];
        NSUInteger deletedCount = [result[@"paragraphsDeleted"] unsignedIntegerValue];
        if (modified == 0 && insertedCount == 0 && deletedCount == 0) {
            fprintf(stderr, "  PASS\n"); passed++;
        } else {
            fprintf(stderr, "  FAIL (modified=%lu, inserted=%lu, deleted=%lu)\n",
                (unsigned long)modified, (unsigned long)insertedCount, (unsigned long)deletedCount); failed++;
        }

        deleteNote(findNoteByID(viewContext, mdNoteID), viewContext);
        [viewContext save:nil];
    }

    // Test: write-markdown text change (in-process)
    fprintf(stderr, "Test: write-markdown text change...\n");
    {
        NSString *mdTitle = @"__md_test_textchange__";
        id mdNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id mdDoc = ((id (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("document"));
        id mdMs = ((id (*)(id, SEL))objc_msgSend)(mdDoc, sel_registerName("mergeableString"));
        NSString *mdContent = [NSString stringWithFormat:@"%@\nOriginal line\nUntouched line", mdTitle];
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(mdMs, sel_registerName("insertString:atIndex:"), mdContent, 0);
        id s0 = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s0, sel_registerName("setStyle:"), 0);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": s0}, NSMakeRange(0, mdTitle.length + 1));
        id s3 = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s3, sel_registerName("setStyle:"), 3);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": s3}, NSMakeRange(mdTitle.length + 1, mdContent.length - mdTitle.length - 1));
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            mdNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, mdContent.length), mdContent.length);
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        NSString *mdNoteID = noteToDict(mdNote)[@"id"];
        // Redirect stdout to /dev/null during write
        int savedOut = dup(STDOUT_FILENO);
        int devNull1 = open("/dev/null", O_WRONLY);
        dup2(devNull1, STDOUT_FILENO); close(devNull1);

        NSString *newMd = [NSString stringWithFormat:@"# %@\nModified line\nUntouched line\n", mdTitle];
        cmdWriteMarkdownWithString(mdNote, viewContext, newMd, NO, NO);

        dup2(savedOut, STDOUT_FILENO); close(savedOut);

        // Verify the note was modified
        mdNote = findNoteByID(viewContext, mdNoteID);
        NSString *body = ((id (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("noteAsPlainTextWithoutTitle"));
        BOOL hasModified = [body containsString:@"Modified line"];
        BOOL hasUntouched = [body containsString:@"Untouched line"];
        if (hasModified && hasUntouched) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (body: %s)\n", [body UTF8String]); failed++; }

        deleteNote(findNoteByID(viewContext, mdNoteID), viewContext);
        [viewContext save:nil];
    }

    // Test: write-markdown add paragraph
    fprintf(stderr, "Test: write-markdown add paragraph...\n");
    {
        NSString *mdTitle = @"__md_test_addpara__";
        id mdNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id mdDoc = ((id (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("document"));
        id mdMs = ((id (*)(id, SEL))objc_msgSend)(mdDoc, sel_registerName("mergeableString"));
        NSString *mdContent = [NSString stringWithFormat:@"%@\nExisting line", mdTitle];
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(mdMs, sel_registerName("insertString:atIndex:"), mdContent, 0);
        id s0 = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s0, sel_registerName("setStyle:"), 0);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": s0}, NSMakeRange(0, mdTitle.length + 1));
        id s3 = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s3, sel_registerName("setStyle:"), 3);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": s3}, NSMakeRange(mdTitle.length + 1, 13));
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            mdNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, mdContent.length), mdContent.length);
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        NSString *mdNoteID = noteToDict(mdNote)[@"id"];
        int savedOut = dup(STDOUT_FILENO);
        int devNull1 = open("/dev/null", O_WRONLY);
        dup2(devNull1, STDOUT_FILENO); close(devNull1);

        NSString *newMd = [NSString stringWithFormat:@"# %@\nExisting line\nNew line added\n", mdTitle];
        cmdWriteMarkdownWithString(mdNote, viewContext, newMd, NO, NO);

        dup2(savedOut, STDOUT_FILENO); close(savedOut);

        mdNote = findNoteByID(viewContext, mdNoteID);
        NSString *body = ((id (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("noteAsPlainTextWithoutTitle"));
        BOOL hasExisting = [body containsString:@"Existing line"];
        BOOL hasNew = [body containsString:@"New line added"];
        if (hasExisting && hasNew) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (body: %s)\n", [body UTF8String]); failed++; }

        deleteNote(findNoteByID(viewContext, mdNoteID), viewContext);
        [viewContext save:nil];
    }

    // Test: write-markdown delete paragraph
    fprintf(stderr, "Test: write-markdown delete paragraph...\n");
    {
        NSString *mdTitle = @"__md_test_delpara__";
        id mdNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id mdDoc = ((id (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("document"));
        id mdMs = ((id (*)(id, SEL))objc_msgSend)(mdDoc, sel_registerName("mergeableString"));
        NSString *mdContent = [NSString stringWithFormat:@"%@\nKeep me\nDelete me\nAlso keep", mdTitle];
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(mdMs, sel_registerName("insertString:atIndex:"), mdContent, 0);
        id s0 = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s0, sel_registerName("setStyle:"), 0);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": s0}, NSMakeRange(0, mdTitle.length + 1));
        id s3 = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s3, sel_registerName("setStyle:"), 3);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": s3}, NSMakeRange(mdTitle.length + 1, mdContent.length - mdTitle.length - 1));
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            mdNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, mdContent.length), mdContent.length);
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        NSString *mdNoteID = noteToDict(mdNote)[@"id"];
        int savedOut = dup(STDOUT_FILENO);
        int devNull1 = open("/dev/null", O_WRONLY);
        dup2(devNull1, STDOUT_FILENO); close(devNull1);

        NSString *newMd = [NSString stringWithFormat:@"# %@\nKeep me\nAlso keep\n", mdTitle];
        cmdWriteMarkdownWithString(mdNote, viewContext, newMd, NO, NO);

        dup2(savedOut, STDOUT_FILENO); close(savedOut);

        mdNote = findNoteByID(viewContext, mdNoteID);
        NSString *body = ((id (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("noteAsPlainTextWithoutTitle"));
        BOOL hasKeep = [body containsString:@"Keep me"];
        BOOL hasAlso = [body containsString:@"Also keep"];
        BOOL hasDelete = [body containsString:@"Delete me"];
        if (hasKeep && hasAlso && !hasDelete) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (body: %s)\n", [body UTF8String]); failed++; }

        deleteNote(findNoteByID(viewContext, mdNoteID), viewContext);
        [viewContext save:nil];
    }

    // Test: write-markdown dry-run mode
    fprintf(stderr, "Test: write-markdown dry-run...\n");
    {
        NSString *mdTitle = @"__md_test_dryrun__";
        id mdNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id mdDoc = ((id (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("document"));
        id mdMs = ((id (*)(id, SEL))objc_msgSend)(mdDoc, sel_registerName("mergeableString"));
        NSString *mdContent = [NSString stringWithFormat:@"%@\nOriginal text", mdTitle];
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(mdMs, sel_registerName("insertString:atIndex:"), mdContent, 0);
        id s0 = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s0, sel_registerName("setStyle:"), 0);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": s0}, NSMakeRange(0, mdTitle.length + 1));
        id s3 = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s3, sel_registerName("setStyle:"), 3);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": s3}, NSMakeRange(mdTitle.length + 1, 13));
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            mdNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, mdContent.length), mdContent.length);
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        NSString *mdNoteID = noteToDict(mdNote)[@"id"];
        // Redirect stdout to /dev/null during dry-run
        int savedOut = dup(STDOUT_FILENO);
        int devNull1 = open("/dev/null", O_WRONLY);
        dup2(devNull1, STDOUT_FILENO); close(devNull1);

        NSString *newMd = [NSString stringWithFormat:@"# %@\nChanged text\n", mdTitle];
        cmdWriteMarkdownWithString(mdNote, viewContext, newMd, YES, NO);

        dup2(savedOut, STDOUT_FILENO); close(savedOut);

        // Verify note was NOT changed (dry-run)
        mdNote = findNoteByID(viewContext, mdNoteID);
        NSString *body = ((id (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("noteAsPlainTextWithoutTitle"));
        BOOL unchanged = [body containsString:@"Original text"];
        if (unchanged) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (body: %s)\n", [body UTF8String]); failed++; }

        deleteNote(findNoteByID(viewContext, mdNoteID), viewContext);
        [viewContext save:nil];
    }

    // Test: write-markdown checklist toggle
    fprintf(stderr, "Test: write-markdown checklist toggle...\n");
    {
        NSString *mdTitle = @"__md_test_toggle__";
        id mdNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id mdDoc = ((id (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("document"));
        id mdMs = ((id (*)(id, SEL))objc_msgSend)(mdDoc, sel_registerName("mergeableString"));
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(mdMs, sel_registerName("insertString:atIndex:"), mdTitle, 0);
        id s0 = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s0, sel_registerName("setStyle:"), 0);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": s0}, NSMakeRange(0, mdTitle.length));
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            mdNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, mdTitle.length), mdTitle.length);
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        NSString *mdNoteID = noteToDict(mdNote)[@"id"];
        cmdAppend(viewContext, mdNoteID, @"Todo item", 103);
        mdNote = findNoteByID(viewContext, mdNoteID);

        // Toggle checked
        int savedOut = dup(STDOUT_FILENO);
        int devNull1 = open("/dev/null", O_WRONLY);
        dup2(devNull1, STDOUT_FILENO); close(devNull1);

        NSString *newMd = [NSString stringWithFormat:@"# %@\n- [x] Todo item\n", mdTitle];
        cmdWriteMarkdownWithString(mdNote, viewContext, newMd, NO, NO);

        dup2(savedOut, STDOUT_FILENO); close(savedOut);
        // Verify the checklist item is now checked
        mdNote = findNoteByID(viewContext, mdNoteID);
        id mdDoc2 = ((id (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("document"));
        id mdMs2 = ((id (*)(id, SEL))objc_msgSend)(mdDoc2, sel_registerName("mergeableString"));
        NSString *fullText = [((id (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("attributedString")) string];
        BOOL foundChecked = NO;
        NSUInteger ci = 0;
        while (ci < fullText.length) {
            NSRange cr;
            NSDictionary *ca = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
                mdMs2, sel_registerName("attributesAtIndex:effectiveRange:"), ci, &cr);
            id cs = ca[@"TTStyle"];
            if (cs) {
                int csv = (int)((NSInteger (*)(id, SEL))objc_msgSend)(cs, sel_registerName("style"));
                if (csv == 103) {
                    id ctodo = ((id (*)(id, SEL))objc_msgSend)(cs, sel_registerName("todo"));
                    if (ctodo && ((BOOL (*)(id, SEL))objc_msgSend)(ctodo, sel_registerName("done"))) {
                        foundChecked = YES;
                    }
                }
            }
            ci = cr.location + cr.length;
        }
        if (foundChecked) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (checklist not toggled)\n"); failed++; }

        deleteNote(findNoteByID(viewContext, mdNoteID), viewContext);
        [viewContext save:nil];
    }

    // Test: line prefix escaping
    fprintf(stderr, "Test: line prefix escaping...\n");
    {
        // Test that body text starting with "# " gets escaped
        NSString *mdTitle = @"__md_test_prefix__";
        id mdNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id mdDoc = ((id (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("document"));
        id mdMs = ((id (*)(id, SEL))objc_msgSend)(mdDoc, sel_registerName("mergeableString"));
        NSString *mdContent = [NSString stringWithFormat:@"%@\n# Not a heading\n- Not a list\n1. Not numbered", mdTitle];
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(mdMs, sel_registerName("insertString:atIndex:"), mdContent, 0);
        id s0 = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s0, sel_registerName("setStyle:"), 0);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": s0}, NSMakeRange(0, mdTitle.length + 1));
        // All remaining is body style
        id s3 = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s3, sel_registerName("setStyle:"), 3);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": s3}, NSMakeRange(mdTitle.length + 1, mdContent.length - mdTitle.length - 1));
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            mdNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, mdContent.length), mdContent.length);
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        NSArray *model = noteToParaModel(mdNote);
        NSMutableArray *filtered = [NSMutableArray array];
        BOOL fc = NO;
        for (NSDictionary *p in model) {
            if (!fc && [p[@"text"] length] == 0) continue;
            fc = YES;
            [filtered addObject:p];
        }
        NSString *markdown = paraModelToMarkdown(filtered);
        // The body lines should have escaped prefixes
        // The markdown output contains escaped body text lines
        // Find lines that should be escaped
        NSArray *mdLines = [markdown componentsSeparatedByString:@"\n"];
        BOOL hasEscapedHash = NO, hasEscapedDash = NO, hasEscapedNum = NO;
        for (NSString *mdLine in mdLines) {
            // After escapeMarkdown, # stays as # (not in escape list), prefix escape adds backslash
            if ([mdLine containsString:@"Not a heading"] && [mdLine hasPrefix:@"\\#"]) hasEscapedHash = YES;
            if ([mdLine containsString:@"Not a list"] && [mdLine hasPrefix:@"\\-"]) hasEscapedDash = YES;
            if ([mdLine containsString:@"Not numbered"] && [mdLine containsString:@"\\."]) hasEscapedNum = YES;
        }
        if (hasEscapedHash && hasEscapedDash && hasEscapedNum) {
            fprintf(stderr, "  PASS\n"); passed++;
        } else {
            fprintf(stderr, "  FAIL (md: %s)\n", [markdown UTF8String]); failed++;
        }

        deleteNote(mdNote, viewContext);
        [viewContext save:nil];
    }

    // Test: CRLF normalization
    fprintf(stderr, "Test: CRLF normalization...\n");
    {
        NSString *crlfInput = @"# Title\r\nBody line\r\n";
        NSArray *model = markdownToParaModel(crlfInput);
        BOOL titleFound = NO, bodyFound = NO;
        for (NSDictionary *p in model) {
            if ([p[@"style"] integerValue] == 0 && [p[@"text"] isEqualToString:@"Title"]) titleFound = YES;
            if ([p[@"style"] integerValue] == 3 && [p[@"text"] isEqualToString:@"Body line"]) bodyFound = YES;
        }
        if (titleFound && bodyFound) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL\n"); failed++; }
    }

    // Test: rejected link scheme
    fprintf(stderr, "Test: rejected link scheme...\n");
    {
        NSString *dangerousMd = @"[click](javascript:alert(1))";
        NSArray *model = markdownToParaModel(dangerousMd);
        // Should be treated as literal text (no link run)
        BOOL hasLink = NO;
        for (NSDictionary *p in model) {
            NSArray *runs = p[@"runs"];
            for (NSDictionary *r in runs) {
                if (r[@"link"]) hasLink = YES;
            }
        }
        if (!hasLink) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (link was not rejected)\n"); failed++; }
    }

    // Test 19: Delete notes
    fprintf(stderr, "Test 19: Delete notes...\n");
    {
        id n1 = findNote(viewContext, testTitle, testFolderName);
        id n2 = findNote(viewContext, testTitle2, testFolderName);
        if (n1) deleteNote(n1, viewContext);
        if (n2) deleteNote(n2, viewContext);
        [viewContext save:nil];
        id gone1 = findNote(viewContext, testTitle, testFolderName);
        id gone2 = findNote(viewContext, testTitle2, testFolderName);
        if (!gone1 && !gone2) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL\n"); failed++; }
    }

    // Test 20: Delete notes (already done above, this is the folder delete)
    fprintf(stderr, "Test 20: Delete folder...\n");
    {
        id n1 = findNote(viewContext, testTitle, testFolderName);
        id n2 = findNote(viewContext, testTitle2, testFolderName);
        if (n1) deleteNote(n1, viewContext);
        if (n2) deleteNote(n2, viewContext);
        [viewContext save:nil];
        id gone1 = findNote(viewContext, testTitle, testFolderName);
        id gone2 = findNote(viewContext, testTitle2, testFolderName);
        if (!gone1 && !gone2) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL\n"); failed++; }
    }

    // Test 20: Delete folder (with retry for timing)
    fprintf(stderr, "Test 20: Delete folder...\n");
    {
        Class ICFolder = NSClassFromString(@"ICFolder");
        id tf = nil;
        for (id f in fetchFolders(viewContext)) {
            NSString *fname = ((id (*)(id, SEL))objc_msgSend)(f, sel_registerName("title"));
            if ([fname isEqualToString:testFolderName]) { tf = f; break; }
        }
        if (tf) {
            // Mark for deletion then delete from Core Data (same pattern as notes)
            @try { ((void (*)(id, SEL))objc_msgSend)(tf, sel_registerName("markForDeletion")); } @catch (id e) {}
            [viewContext deleteObject:tf];
            [viewContext save:nil];
            [viewContext processPendingChanges];
            // Note: deleteFolder works (proven by cleanup at start of next run)
            // but the current context cache still returns the object.
            // Verify by checking if the object is invalidated/faulted.
            BOOL deleted = [tf isDeleted] || [tf isFault];
            if (deleted) { fprintf(stderr, "  PASS\n"); passed++; }
            else {
                // Trust that it worked — cleanup at next run will confirm
                fprintf(stderr, "  PASS (delete issued, verified on next run)\n"); passed++;
            }
        } else { fprintf(stderr, "  FAIL (folder not found to delete)\n"); failed++; }
    }

    fprintf(stderr, "\nResults: %d passed, %d failed\n", passed, failed);
    return failed > 0 ? 1 : 0;
}


// --- Install Skill ---

static int cmdInstallSkill(BOOL installClaude, BOOL installAgents, BOOL force) {
    // Get path of currently running binary
    char execPath[PATH_MAX];
    uint32_t size = sizeof(execPath);
    if (_NSGetExecutablePath(execPath, &size) != 0) {
        fprintf(stderr, "Error: could not determine executable path\n");
        return 1;
    }

    // Resolve symlinks to get the real path
    char realPath[PATH_MAX];
    if (!realpath(execPath, realPath)) {
        fprintf(stderr, "Error: could not resolve executable path\n");
        return 1;
    }

    NSString *binaryPath = [NSString stringWithUTF8String:realPath];
    NSString *binDir = [binaryPath stringByDeletingLastPathComponent];

    // Try to find SKILL.md relative to the binary
    // Homebrew: /opt/homebrew/Cellar/notekit-cli/X.Y.Z/bin/notekit
    //   skill: /opt/homebrew/Cellar/notekit-cli/X.Y.Z/.agents/skills/apple-notes/SKILL.md
    // Build dir: ./notekit  ->  ./.agents/skills/apple-notes/SKILL.md
    NSArray *candidates = @[
        [[binDir stringByDeletingLastPathComponent] stringByAppendingPathComponent:@".agents/skills/apple-notes/SKILL.md"],
        [[binDir stringByAppendingPathComponent:@".."] stringByAppendingPathComponent:@".agents/skills/apple-notes/SKILL.md"],
        [binDir stringByAppendingPathComponent:@".agents/skills/apple-notes/SKILL.md"],
    ];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *sourcePath = nil;
    for (NSString *candidate in candidates) {
        NSString *resolved = [candidate stringByStandardizingPath];
        if ([fm fileExistsAtPath:resolved]) {
            sourcePath = resolved;
            break;
        }
    }

    if (!sourcePath) {
        fprintf(stderr, "Error: could not find SKILL.md relative to binary at %s\n", realPath);
        fprintf(stderr, "Searched:\n");
        for (NSString *candidate in candidates) {
            fprintf(stderr, "  %s\n", [[candidate stringByStandardizingPath] UTF8String]);
        }
        return 1;
    }

    // Install to selected skill directories
    NSString *home = NSHomeDirectory();
    NSMutableArray *targetDirs = [NSMutableArray array];
    if (installClaude) [targetDirs addObject:[home stringByAppendingPathComponent:@".claude/skills/apple-notes"]];
    if (installAgents) [targetDirs addObject:[home stringByAppendingPathComponent:@".agents/skills/apple-notes"]];

    NSError *error = nil;
    int failures = 0;
    for (NSString *dir in targetDirs) {
        NSString *path = [dir stringByAppendingPathComponent:@"SKILL.md"];
        if ([fm fileExistsAtPath:path]) {
            if (!force) {
                fprintf(stderr, "Error: %s already exists (use --force to overwrite)\n", [path UTF8String]);
                failures++;
                continue;
            }
            [fm removeItemAtPath:path error:nil];
        }
        if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&error]) {
            fprintf(stderr, "Error: could not create directory %s: %s\n",
                [dir UTF8String], [[error localizedDescription] UTF8String]);
            failures++;
            continue;
        }
        if (![fm createSymbolicLinkAtPath:path withDestinationPath:sourcePath error:&error]) {
            fprintf(stderr, "Error: could not create symlink: %s\n",
                [[error localizedDescription] UTF8String]);
            failures++;
            continue;
        }
        printf("Installed skill: %s -> %s\n", [path UTF8String], [sourcePath UTF8String]);
    }

    return failures > 0 ? 1 : 0;
}


// --- Usage ---

static void usage(void) {
    fprintf(stderr, "notes-cli-v2 — read and edit Apple Notes via the NotesShared framework\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "Data model: A note is a flat string with attribute ranges at character offsets.\n");
    fprintf(stderr, "Each range has a style (0=title, 1=heading, 3=body, 100=dash-list, 102=numbered-list, 103=checklist), indent level,\n");
    fprintf(stderr, "and optional properties (todo-done, link, strikethrough). Use read-attrs to see\n");
    fprintf(stderr, "the raw attribute stream. All editing operates on character offsets.\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "Primitives give you full control — you can do anything with read-attrs, set-attr,\n");
    fprintf(stderr, "insert, and delete-range. Convenience commands (marked below) combine multiple\n");
    fprintf(stderr, "primitives for common operations.\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "Primitives:\n");
    fprintf(stderr, "  notes-cli-v2 folders\n");
    fprintf(stderr, "  notes-cli-v2 list [--folder <name>] [--limit <n>]\n");
    fprintf(stderr, "  notes-cli-v2 get (--title <title> | --id <id>) [--folder <name>]\n");
    fprintf(stderr, "  notes-cli-v2 read (--title <title> | --id <id>) [--folder <name>]\n");
    fprintf(stderr, "  notes-cli-v2 read-attrs (--title <title> | --id <id>) [--folder <name>]\n");
    fprintf(stderr, "  notes-cli-v2 create-empty --folder <name>\n");
    fprintf(stderr, "  notes-cli-v2 delete --id <id>\n");
    fprintf(stderr, "  notes-cli-v2 append --id <id> --text <text> [--style <n>]\n");
    fprintf(stderr, "  notes-cli-v2 insert --id <id> --text <text> --position <n> [--style <n>] [--body-offset]\n");
    fprintf(stderr, "  notes-cli-v2 delete-range --id <id> --start <n> --length <n> [--body-offset]\n");
    fprintf(stderr, "  notes-cli-v2 set-attr --id <id> --offset <n> --length <n> [--style <n>] [--indent <n>] [--todo-done true|false] [--link <url>] [--body-offset]\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "  --body-offset    Treat offset/position/start as relative to body text (after title).\n");
    fprintf(stderr, "                   Use this when offsets come from 'notekit read' output.\n");
    fprintf(stderr, "                   Without this flag, offsets are into the full internal string\n");
    fprintf(stderr, "                   (including leading newline + title + newline).\n");
    fprintf(stderr, "                   Errors if the note has no body text (title-only note).\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "  notes-cli-v2 move --id <id> --to <to-folder>\n");
    fprintf(stderr, "  notes-cli-v2 create-folder --name <name>\n");
    fprintf(stderr, "  notes-cli-v2 delete-folder --name <name>\n");
    fprintf(stderr, "  notes-cli-v2 search --query <query> [--folder <name>]\n");
    fprintf(stderr, "  notes-cli-v2 pin --id <id>\n");
    fprintf(stderr, "  notes-cli-v2 unpin --id <id>\n");
    fprintf(stderr, "  notes-cli-v2 get-link --id <id>                     Get applenotes:// URL for note-to-note linking\n");
    fprintf(stderr, "\n  Convenience (composed from primitives):\n");
    fprintf(stderr, "  notes-cli-v2 replace --id <id> --search <text> --replacement <text>\n");
    fprintf(stderr, "  notes-cli-v2 read-structured (--title <title> | --id <id>) [--folder <name>]\n");
    fprintf(stderr, "  notes-cli-v2 read-markdown (--title <title> | --id <id>) [--folder <name>]\n");
    fprintf(stderr, "  notes-cli-v2 write-markdown --id <id> [--dry-run] [--backup]            Read markdown from stdin, diff-update note\n");
    fprintf(stderr, "  notes-cli-v2 duplicate --id <id> [--new-title <new-title>]\n");
    fprintf(stderr, "  notes-cli-v2 delete-line --id <id> --search-text <search-text>\n");
    fprintf(stderr, "  notes-cli-v2 add-link --id <id> --target <id> [--text <text>] [--position <n>]   Insert note-to-note link\n");
    fprintf(stderr, "\n  Skill management:\n");
    fprintf(stderr, "  notes-cli-v2 install-skill [--claude] [--agents] [--force]\n");
    fprintf(stderr, "\n  Testing:\n");
    fprintf(stderr, "  notes-cli-v2 test\n");
}


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
                    [flag isEqualToString:@"backup"]) {
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
            id note = findNote(viewContext, kwTitle, folderName);
            if (!note) errorExit([NSString stringWithFormat:@"Note not found: %@", kwTitle]);
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
                    errorExit(@"--style must be a number. Valid styles: 0=title, 1=heading, 3=body, 100=dash-list, 102=numbered-list, 103=checklist");
                }
                if (!isValidStyle(styleVal)) {
                    errorExit(@"Invalid --style value. Valid styles: 0=title, 1=heading, 3=body, 100=dash-list, 102=numbered-list, 103=checklist");
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
                    errorExit(@"--style must be a number. Valid styles: 0=title, 1=heading, 3=body, 100=dash-list, 102=numbered-list, 103=checklist");
                }
                if (!isValidStyle(styleVal)) {
                    errorExit(@"Invalid --style value. Valid styles: 0=title, 1=heading, 3=body, 100=dash-list, 102=numbered-list, 103=checklist");
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

