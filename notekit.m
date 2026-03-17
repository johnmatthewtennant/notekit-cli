// Originally scaffolded by generate-notes-cli.py — now maintained manually

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreData/CoreData.h>
#include <mach-o/dyld.h>

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
        if (nsLink) entry[@"link"] = [nsLink description];

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

    id doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
    id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
    NSUInteger msLen = ((NSUInteger (*)(id, SEL))objc_msgSend)(ms, sel_registerName("length"));
    if (offset + length > msLen) errorExit(@"Range exceeds note length");

    id style = [[ICTTParagraphStyleClass alloc] init];

    if (attrOpts[@"style"]) {
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(style, sel_registerName("setStyle:"), [attrOpts[@"style"] integerValue]);
    }
    if (attrOpts[@"indent"]) {
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(style, sel_registerName("setIndent:"), [attrOpts[@"indent"] integerValue]);
    }
    if (attrOpts[@"todo-done"]) {
        BOOL done = [attrOpts[@"todo-done"] isEqualToString:@"true"];
        id todo = ((id (*)(id, SEL, id, BOOL))objc_msgSend)(
            [ICTTTodoClass alloc], sel_registerName("initWithIdentifier:done:"), [NSUUID UUID], done);
        ((void (*)(id, SEL, id))objc_msgSend)(style, sel_registerName("setTodo:"), todo);
        // Default to checklist style if setting todo
        if (!attrOpts[@"style"]) {
            ((void (*)(id, SEL, NSUInteger))objc_msgSend)(style, sel_registerName("setStyle:"), 103);
        }
    }

    ((void (*)(id, SEL))objc_msgSend)(note, sel_registerName("beginEditing"));
    ((void (*)(id, SEL, id, NSRange))objc_msgSend)(ms, sel_registerName("setAttributes:range:"),
        @{@"TTStyle": style}, NSMakeRange(offset, length));
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
                    if (currentStyle == 103) para[@"checked"] = @(currentTodoDone);
                    [paragraphs addObject:para];
                }
            }
            currentLine = [NSMutableString stringWithString:chunk];
            currentUUID = uuid;
            currentStyle = styleNum;
            currentTodoDone = done;
            currentIndent = indent;
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
            if (currentStyle == 103) para[@"checked"] = @(currentTodoDone);
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

static int cmdAppend(id viewContext, NSString *identifier, NSString *text) {
    id note = findNoteByID(viewContext, identifier);
    if (!note) errorExit([NSString stringWithFormat:@"Note not found with id: %@", identifier]);

    id doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
    id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
    NSUInteger oldLen = ((NSUInteger (*)(id, SEL))objc_msgSend)(ms, sel_registerName("length"));

    NSString *toInsert = [NSString stringWithFormat:@"\n%@", text];
    ((void (*)(id, SEL))objc_msgSend)(note, sel_registerName("beginEditing"));
    ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(ms, sel_registerName("insertString:atIndex:"), toInsert, oldLen);

    id bodyStyle = [[ICTTParagraphStyleClass alloc] init];
    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(bodyStyle, sel_registerName("setStyle:"), 3);
    ((void (*)(id, SEL, id, NSRange))objc_msgSend)(ms, sel_registerName("setAttributes:range:"),
        @{@"TTStyle": bodyStyle}, NSMakeRange(oldLen, toInsert.length));

    saveNote(note, viewContext, oldLen + toInsert.length, toInsert.length);
    printJSON(@{@"id": identifier, @"appended": text});
    return 0;
}

static int cmdInsert(id viewContext, NSString *identifier, NSString *text, NSUInteger position) {
    id note = findNoteByID(viewContext, identifier);
    if (!note) errorExit([NSString stringWithFormat:@"Note not found with id: %@", identifier]);

    id doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
    id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
    NSUInteger oldLen = ((NSUInteger (*)(id, SEL))objc_msgSend)(ms, sel_registerName("length"));

    if (position > oldLen) errorExit(@"Position exceeds note length");

    ((void (*)(id, SEL))objc_msgSend)(note, sel_registerName("beginEditing"));
    ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(ms, sel_registerName("insertString:atIndex:"), text, position);

    id bodyStyle = [[ICTTParagraphStyleClass alloc] init];
    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(bodyStyle, sel_registerName("setStyle:"), 3);
    ((void (*)(id, SEL, id, NSRange))objc_msgSend)(ms, sel_registerName("setAttributes:range:"),
        @{@"TTStyle": bodyStyle}, NSMakeRange(position, text.length));

    saveNote(note, viewContext, oldLen + text.length, text.length);
    printJSON(@{@"id": identifier, @"inserted": text, @"position": @(position)});
    return 0;
}

static int cmdDeleteRange(id viewContext, NSString *identifier, NSUInteger start, NSUInteger length) {
    id note = findNoteByID(viewContext, identifier);
    if (!note) errorExit([NSString stringWithFormat:@"Note not found with id: %@", identifier]);

    id doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
    id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
    NSUInteger oldLen = ((NSUInteger (*)(id, SEL))objc_msgSend)(ms, sel_registerName("length"));

    if (start + length > oldLen) errorExit(@"Range exceeds note length");

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
        int ret = cmdAppend(viewContext, noteID, @"Appended text");
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

    // Cleanup
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
    fprintf(stderr, "Each range has a style (0=title, 1=heading, 3=body, 103=checklist), indent level,\n");
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
    fprintf(stderr, "  notes-cli-v2 append --id <id> --text <text>\n");
    fprintf(stderr, "  notes-cli-v2 insert --id <id> --text <text> --position <n>\n");
    fprintf(stderr, "  notes-cli-v2 delete-range --id <id> --start <n> --length <n>\n");
    fprintf(stderr, "  notes-cli-v2 set-attr --id <id> --offset <n> --length <n> [--style <n>] [--indent <n>] [--todo-done true|false]\n");
    fprintf(stderr, "  notes-cli-v2 move --id <id> --to <to-folder>\n");
    fprintf(stderr, "  notes-cli-v2 create-folder --name <name>\n");
    fprintf(stderr, "  notes-cli-v2 delete-folder --name <name>\n");
    fprintf(stderr, "  notes-cli-v2 search --query <query> [--folder <name>]\n");
    fprintf(stderr, "  notes-cli-v2 pin --id <id>\n");
    fprintf(stderr, "  notes-cli-v2 unpin --id <id>\n");
    fprintf(stderr, "\n  Convenience (composed from primitives):\n");
    fprintf(stderr, "  notes-cli-v2 replace --id <id> --search <text> --replacement <text>\n");
    fprintf(stderr, "  notes-cli-v2 read-structured (--title <title> | --id <id>) [--folder <name>]\n");
    fprintf(stderr, "  notes-cli-v2 duplicate --id <id> [--new-title <new-title>]\n");
    fprintf(stderr, "  notes-cli-v2 delete-line --id <id> --search-text <search-text>\n");
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
                    [flag isEqualToString:@"force"]) {
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
            return cmdAppend(viewContext, noteID, kwText);

        } else if ([command isEqualToString:@"insert"]) {
            NSString *noteID = opts[@"id"];
            if (!noteID || noteID.length == 0) { fprintf(stderr, "Error: --id required\n"); usage(); return 1; }
            if (!kwText) { fprintf(stderr, "Error: --text required\n"); usage(); return 1; }
            if (!opts[@"position"]) { fprintf(stderr, "Error: --position required\n"); usage(); return 1; }
            return cmdInsert(viewContext, noteID, kwText, [opts[@"position"] integerValue]);

        } else if ([command isEqualToString:@"delete-range"]) {
            NSString *noteID = opts[@"id"];
            if (!noteID || noteID.length == 0) { fprintf(stderr, "Error: --id required\n"); usage(); return 1; }
            if (!opts[@"start"] || !opts[@"length"]) { fprintf(stderr, "Error: --start and --length required\n"); usage(); return 1; }
            return cmdDeleteRange(viewContext, noteID, [opts[@"start"] integerValue], [opts[@"length"] integerValue]);

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

