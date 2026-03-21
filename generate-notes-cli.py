#!/usr/bin/env python3
"""
Generate notekit-generated.m from NotesShared private API.

USAGE:
    python3 generate-notes-cli.py > notekit-generated.m
    # Then: make notekit

MAINTENANCE:
    This generator produces notekit-generated.m — the foundation layer of
    notekit: framework loading, helpers, Core Data queries, note serialization,
    and basic CRUD commands.

    Handwritten code (markdown I/O, diff engine, install-skill, tests, usage,
    main) lives in notekit-handwritten.m, notekit-tests.m, and notekit.m.

    To add a new READ property:
        1. Add to NOTE_READ_PROPS below
        2. Regenerate: python3 generate-notes-cli.py > notekit-generated.m && make notekit

    To add a new framework class:
        1. Add to FRAMEWORK_CLASSES below
        2. Regenerate

    To discover new properties/methods:
        make notes-inspect && ./notes-inspect 2>&1 | less

    Architecture:
        notes-inspect.m          → dumps ObjC runtime properties/methods
        generate-notes-cli.py    → generates notekit-generated.m (this file)
        notekit-generated.m      → AUTO-GENERATED, do not edit manually
        notekit-handwritten.m    → manually maintained features
        notekit-tests.m          → manually maintained tests
        notekit.m                → hub file (#includes + main)
"""

# --- Configuration ---

# Properties to expose on ICNote (read)
NOTE_READ_PROPS = {
    "title":               ("title",         "string"),
    "noteAsPlainTextWithoutTitle": ("body",  "string"),
    "folderName":          ("folder",        "string"),
    "creationDate":        ("createdAt",     "date"),
    "modificationDate":    ("modifiedAt",    "date"),
    "hasChecklist":        ("hasChecklist",  "bool"),
    "isPinned":            ("isPinned",      "bool"),
    "hasTags":             ("hasTags",       "bool"),
    "identifier":          ("id",            "string"),
    "snippet":             ("snippet",       "string"),
}

# Classes to load from NotesShared.framework
FRAMEWORK_CLASSES = [
    "ICNoteContext",
    "ICNote",
    "ICTTParagraphStyle",
    "ICTTTodo",
    "ICTTAttachment",
]


def generate_framework_loading():
    lines = ['// --- Framework Loading ---', '']
    for cls in FRAMEWORK_CLASSES:
        lines.append(f'static Class {cls}Class;')
    lines.append('')
    lines.append('static void loadFramework(void) {')
    lines.append('    [[NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/NotesShared.framework"] load];')
    for cls in FRAMEWORK_CLASSES:
        lines.append(f'    {cls}Class = NSClassFromString(@"{cls}");')
    lines.append('}')
    lines.append('')
    lines.append('static id getViewContext(void) {')
    lines.append('    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(ICNoteContextClass, sel_registerName("startSharedContextWithOptions:"), 0);')
    lines.append('    id context = ((id (*)(id, SEL))objc_msgSend)(ICNoteContextClass, sel_registerName("sharedContext"));')
    lines.append('    id container = ((id (*)(id, SEL))objc_msgSend)(context, sel_registerName("persistentContainer"));')
    lines.append('    // Check if persistent stores loaded — if empty, Core Data could not open')
    lines.append('    // the SQLite database (typically a Full Disk Access / sandbox denial).')
    lines.append('    // Core Data logs errors to stderr but does not propagate an NSError,')
    lines.append('    // so fetch requests succeed with empty results instead of failing.')
    lines.append('    id coordinator = ((id (*)(id, SEL))objc_msgSend)(container, sel_registerName("persistentStoreCoordinator"));')
    lines.append('    NSArray *stores = ((id (*)(id, SEL))objc_msgSend)(coordinator, sel_registerName("persistentStores"));')
    lines.append('    if (!stores || stores.count == 0) {')
    lines.append('        fprintf(stderr, "\\nError: Notes access denied.\\n\\n");')
    lines.append('        fprintf(stderr, "notekit requires Full Disk Access to read Apple Notes.\\n\\n");')
    lines.append('        fprintf(stderr, "1. Open System Settings > Privacy & Security > Full Disk Access\\n");')
    lines.append('        fprintf(stderr, "2. Add your terminal app (e.g. iTerm, Terminal, Ghostty)\\n\\n");')
    lines.append('        fprintf(stderr, "If you previously denied access, reset and re-grant:\\n");')
    lines.append('        fprintf(stderr, "   tccutil reset SystemPolicyAllFiles <bundle-id>\\n\\n");')
    lines.append('        fprintf(stderr, "   Find your terminal\'s bundle ID:\\n");')
    lines.append('        fprintf(stderr, "   osascript -e \'id of app \\"iTerm\\"\'  (replace iTerm with your terminal app name)\\n\\n");')
    lines.append('        fprintf(stderr, "Then retry: notekit folders\\n");')
    lines.append('        exit(1);')
    lines.append('    }')
    lines.append('    return ((id (*)(id, SEL))objc_msgSend)(container, sel_registerName("viewContext"));')
    lines.append('}')
    return '\n'.join(lines)


def generate_helpers():
    return '''// --- Helpers ---

static void errorExit(NSString *msg) {
    fprintf(stderr, "Error: %s\\n", [msg UTF8String]);
    exit(1);
}

// Recursively check an NSError chain for a specific domain+code pair.
// Inspects the error itself, NSUnderlyingError, and NSDetailedErrors.
static BOOL errorChainContains(NSError *error, NSString *domain, NSInteger code) {
    if (!error) return NO;
    if ([[error domain] isEqualToString:domain] && [error code] == code) return YES;
    // Check single underlying error
    NSError *underlying = [[error userInfo] objectForKey:@"NSUnderlyingError"];
    if (errorChainContains(underlying, domain, code)) return YES;
    // Check detailed errors array (Core Data batch errors)
    NSArray *detailed = [[error userInfo] objectForKey:@"NSDetailedErrors"];
    for (NSError *detail in detailed) {
        if (errorChainContains(detail, domain, code)) return YES;
    }
    return NO;
}

// Check if a Core Data error is a permission/sandbox denial and print
// actionable troubleshooting steps. Returns YES if it handled the error
// (and exited), NO if the error is unrelated to permissions.
static BOOL checkNotesAccessError(NSError *error) {
    if (!error) return NO;
    // NSCocoaErrorDomain 256 = NSFileReadNoPermissionError (sandbox / Full Disk Access)
    BOOL isSandbox = errorChainContains(error, @"NSCocoaErrorDomain", 256);
    // NSSQLiteErrorDomain 23 = SQLITE_AUTH (sandbox denied at SQLite level)
    if (!isSandbox) isSandbox = errorChainContains(error, @"NSSQLiteErrorDomain", 23);
    // NSCocoaErrorDomain 4097 = NSXPCConnectionInterrupted — only treat as
    // permission denied when the description mentions access/permission to
    // avoid false positives from transient XPC failures.
    BOOL isPermDenied = NO;
    if (errorChainContains(error, @"NSCocoaErrorDomain", 4097)) {
        NSString *desc = [[error localizedDescription] lowercaseString];
        if ([desc containsString:@"permission"] || [desc containsString:@"denied"] ||
            [desc containsString:@"access"]) {
            isPermDenied = YES;
        }
    }
    if (!isSandbox && !isPermDenied) return NO;

    fprintf(stderr, "Error: Notes access denied.\\n\\n");
    fprintf(stderr, "notekit requires Full Disk Access to read Apple Notes.\\n\\n");
    fprintf(stderr, "1. Open System Settings > Privacy & Security > Full Disk Access\\n");
    fprintf(stderr, "2. Add your terminal app (e.g. iTerm, Terminal, Ghostty)\\n\\n");
    fprintf(stderr, "If you previously denied access, reset and re-grant:\\n");
    fprintf(stderr, "   tccutil reset SystemPolicyAllFiles <bundle-id>\\n\\n");
    fprintf(stderr, "   Find your terminal\'s bundle ID:\\n");
    fprintf(stderr, "   osascript -e \'id of app \\"iTerm\\"\'  (replace iTerm with your terminal app name)\\n\\n");
    fprintf(stderr, "Then retry: notekit folders\\n");
    exit(1);
    return YES; // unreachable, silences compiler warning
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
    return style == 0 || style == 1 || style == 3 || style == 4 || style == 100 || style == 102 || style == 103;
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
    printf("%s\\n", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
}'''


def generate_fetch_helpers():
    return '''// --- Fetch Helpers ---

// Predicate helpers to exclude soft-deleted items from Core Data queries.
// markedForDeletion is set by ICFolder/ICNote.markForDeletion when items
// are moved to Recently Deleted. folderType=1 is the Recently Deleted
// system folder container itself.
static NSPredicate *activeFolderPredicate(void) {
    return [NSPredicate predicateWithFormat:@"markedForDeletion == NO AND folderType != 1"];
}

static NSPredicate *activeNotePredicate(void) {
    return [NSPredicate predicateWithFormat:@"markedForDeletion == NO AND folder.markedForDeletion == NO"];
}

static NSArray *fetchFolders(id viewContext) {
    NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"ICFolder"];
    request.predicate = activeFolderPredicate();
    NSError *error = nil;
    NSArray *folders = [viewContext executeFetchRequest:request error:&error];
    if (error) {
        checkNotesAccessError(error);
        errorExit([NSString stringWithFormat:@"Failed to fetch folders: %@", error]);
    }
    return folders;
}

static NSArray *fetchNotes(id viewContext, NSString *folderName, NSUInteger limit) {
    NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"ICNote"];
    NSMutableArray *predicates = [NSMutableArray array];
    [predicates addObject:activeNotePredicate()];
    if (folderName) {
        [predicates addObject:[NSPredicate predicateWithFormat:@"folder.title == %@", folderName]];
    }
    request.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:predicates];
    request.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"modificationDate" ascending:NO]];
    if (limit > 0) request.fetchLimit = limit;
    NSError *error = nil;
    NSArray *notes = [viewContext executeFetchRequest:request error:&error];
    if (error) {
        checkNotesAccessError(error);
        errorExit([NSString stringWithFormat:@"Failed to fetch notes: %@", error]);
    }
    return notes;
}

static NSDictionary *noteToDict(id note); // forward declaration

static NSArray *findNotes(id viewContext, NSString *title, NSString *folderName) {
    NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"ICNote"];
    NSMutableArray *predicates = [NSMutableArray array];
    [predicates addObject:activeNotePredicate()];
    [predicates addObject:[NSPredicate predicateWithFormat:@"title CONTAINS %@", title]];
    if (folderName) {
        [predicates addObject:[NSPredicate predicateWithFormat:@"folder.title == %@", folderName]];
    }
    request.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:predicates];
    NSError *error = nil;
    NSArray *notes = [viewContext executeFetchRequest:request error:&error];
    if (error) {
        checkNotesAccessError(error);
        errorExit([NSString stringWithFormat:@"Failed to find notes: %@", error]);
    }
    if (notes.count == 0) return @[];
    return notes;
}

static id findNote(id viewContext, NSString *title, NSString *folderName) {
    NSArray *notes = findNotes(viewContext, title, folderName);
    if (notes.count == 0) return nil;
    return notes[0];
}

// Returns exactly one note matching title, or exits with an error listing all matches.
// Use this for commands that operate on a single note (read, read-attrs, etc.)
// to avoid silently acting on the wrong note when multiple match.
static id requireSingleNote(id viewContext, NSString *title, NSString *folderName) {
    NSArray *notes = findNotes(viewContext, title, folderName);
    if (notes.count == 0) errorExit([NSString stringWithFormat:@"Note not found: %@", title]);
    if (notes.count == 1) return notes[0];
    NSMutableString *msg = [NSMutableString stringWithFormat:
        @"Multiple notes match \\"%@\\". Use --id to specify:\\n", title];
    for (id note in notes) {
        NSDictionary *d = noteToDict(note);
        [msg appendFormat:@"  %@  %@\\n", d[@"id"], d[@"title"]];
    }
    errorExit(msg);
    return nil; // unreachable
}

static id findNoteByID(id viewContext, NSString *identifier) {
    NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"ICNote"];
    request.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:@[
        activeNotePredicate(),
        [NSPredicate predicateWithFormat:@"identifier == %@", identifier]
    ]];
    request.fetchLimit = 1;
    NSError *error = nil;
    NSArray *notes = [viewContext executeFetchRequest:request error:&error];
    if (error) {
        checkNotesAccessError(error);
        errorExit([NSString stringWithFormat:@"Failed to find note by ID: %@", error]);
    }
    if (notes.count == 0) return nil;
    return notes[0];
}
// Returns the character offset where the body starts in the full mergeableString
// (after leading \\n + title + \\n)
// Returns NSNotFound if the note has no body (title-only note).
// Handles both canonical format (\\n + title + \\n + body) and non-canonical
// format (title + \\n + body) for test-created notes.
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
}'''


def generate_note_to_dict():
    lines = [
        '// --- Note Serialization (generated from NOTE_READ_PROPS) ---',
        '',
        'static NSDictionary *noteToDict(id note) {',
        '    NSMutableDictionary *dict = [NSMutableDictionary dictionary];',
        '',
    ]

    for prop, (json_key, type_hint) in NOTE_READ_PROPS.items():
        if type_hint == "string":
            lines.append(f'    @try {{')
            lines.append(f'        NSString *val = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("{prop}"));')
            lines.append(f'        if (val) dict[@"{json_key}"] = val;')
            lines.append(f'    }} @catch (NSException *e) {{}}')
        elif type_hint == "bool":
            lines.append(f'    @try {{')
            lines.append(f'        BOOL val = ((BOOL (*)(id, SEL))objc_msgSend)(note, sel_registerName("{prop}"));')
            lines.append(f'        dict[@"{json_key}"] = @(val);')
            lines.append(f'    }} @catch (NSException *e) {{}}')
        elif type_hint == "date":
            lines.append(f'    @try {{')
            lines.append(f'        NSDate *val = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("{prop}"));')
            lines.append(f'        if (val) dict[@"{json_key}"] = dateToISO(val);')
            lines.append(f'    }} @catch (NSException *e) {{}}')
        lines.append('')

    # URL property (not data-driven, but always included)
    lines.append('    @try {')
    lines.append('        Class ICAppURLUtilities = NSClassFromString(@"ICAppURLUtilities");')
    lines.append('        if (ICAppURLUtilities) {')
    lines.append('            NSURL *appURL = ((id (*)(id, SEL, id))objc_msgSend)(')
    lines.append('                ICAppURLUtilities, sel_registerName("appURLForNote:"), note);')
    lines.append('            if (appURL) dict[@"url"] = [appURL absoluteString];')
    lines.append('        }')
    lines.append('    } @catch (NSException *e) {}')
    lines.append('')
    lines.append('    return dict;')
    lines.append('}')
    return '\n'.join(lines)


def generate_commands():
    return '''
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
    NSArray *notes = findNotes(viewContext, title, folderName);
    if (notes.count == 0) errorExit([NSString stringWithFormat:@"Note not found: %@", title]);
    if (notes.count == 1) return cmdGetNote(notes[0]);
    NSMutableArray *results = [NSMutableArray array];
    for (id note in notes) {
        [results addObject:noteToDict(note)];
    }
    printJSON(results);
    return 0;
}

static int cmdReadNote(id note) {
    NSString *body = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("noteAsPlainTextWithoutTitle"));
    if (body) printf("%s\\n", [body UTF8String]);
    return 0;
}

static int cmdRead(id viewContext, NSString *title, NSString *folderName) {
    id note = requireSingleNote(viewContext, title, folderName);
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

        id ttHints = attrs[@"TTHints"];
        if (ttHints) {
            NSUInteger hints = [ttHints unsignedIntegerValue];
            if (hints & 1) entry[@"bold"] = @YES;
            if (hints & 2) entry[@"italic"] = @YES;
        }
        id ttUnderline = attrs[@"TTUnderline"];
        if (ttUnderline) entry[@"underline"] = @YES;

        id attachment = attrs[@"NSAttachment"];
        if (attachment) entry[@"hasAttachment"] = @YES;

        [ranges addObject:entry];
        idx = effectiveRange.location + effectiveRange.length;
    }

    printJSON(ranges);
    return 0;
}

static int cmdReadAttrs(id viewContext, NSString *title, NSString *folderName) {
    id note = requireSingleNote(viewContext, title, folderName);
    return cmdReadAttrsNote(note);
}

static int cmdCreateFolder(id viewContext, NSString *name, NSString *parentName) {
    NSArray *folders = fetchFolders(viewContext);

    // If --parent specified, find the parent folder and use its account
    id parentFolder = nil;
    if (parentName) {
        NSInteger matchCount = 0;
        for (id f in folders) {
            NSString *fname = ((id (*)(id, SEL))objc_msgSend)(f, sel_registerName("title"));
            if ([fname isEqualToString:parentName]) { parentFolder = f; matchCount++; }
        }
        if (!parentFolder) errorExit([NSString stringWithFormat:@"Parent folder not found: %@", parentName]);
        if (matchCount > 1) errorExit([NSString stringWithFormat:@"Multiple folders named '%@' found — cannot determine parent unambiguously", parentName]);
    }

    // Get account: prefer parent's account when nesting, otherwise first available
    id account = nil;
    if (parentFolder) {
        account = ((id (*)(id, SEL))objc_msgSend)(parentFolder, sel_registerName("account"));
    }
    if (!account) {
        for (id f in folders) {
            account = ((id (*)(id, SEL))objc_msgSend)(f, sel_registerName("account"));
            if (account) break;
        }
    }
    if (!account) errorExit(@"No account found");

    Class ICFolder = NSClassFromString(@"ICFolder");
    id newFolder = ((id (*)(id, SEL, id))objc_msgSend)(ICFolder, sel_registerName("newFolderInAccount:"), account);
    if (!newFolder) errorExit(@"Failed to create folder");
    ((void (*)(id, SEL, id))objc_msgSend)(newFolder, sel_registerName("setTitle:"), name);

    // Set parent folder relationship for nesting
    if (parentFolder) {
        ((void (*)(id, SEL, id))objc_msgSend)(newFolder, sel_registerName("setParent:"), parentFolder);
    }

    NSError *error = nil;
    [viewContext save:&error];
    if (error) errorExit([NSString stringWithFormat:@"Save error: %@", error]);

    NSMutableDictionary *output = [NSMutableDictionary dictionaryWithDictionary:@{@"name": name, @"created": @YES}];
    if (parentName) output[@"parent"] = parentName;
    printJSON(output);
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

    // markForDeletion soft-deletes (moves to Recently Deleted) without
    // triggering aggressive CloudKit sync that can corrupt shared folder state.
    ((void (*)(id, SEL))objc_msgSend)(targetFolder, sel_registerName("markForDeletion"));
    [viewContext deleteObject:targetFolder];

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
    BOOL hasStrikethroughOpt = (attrOpts[@"strikethrough"] != nil);

    // Validate --strikethrough upfront if provided
    if (hasStrikethroughOpt) {
        NSString *val = attrOpts[@"strikethrough"];
        if (![val isEqualToString:@"true"] && ![val isEqualToString:@"false"]) {
            errorExit(@"--strikethrough must be 'true' or 'false'");
        }
    }

    // Validate --style upfront if provided
    if (attrOpts[@"style"]) {
        NSInteger styleVal;
        if (!isStrictInteger(attrOpts[@"style"], &styleVal)) {
            errorExit(@"--style must be a number. Valid styles: 0=title, 1=heading, 3=body, 4=code-block, 100=dash-list, 102=numbered-list, 103=checklist");
        }
        if (!isValidStyle(styleVal)) {
            errorExit(@"Invalid --style value. Valid styles: 0=title, 1=heading, 3=body, 4=code-block, 100=dash-list, 102=numbered-list, 103=checklist");
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

    // Get the full plain string for paragraph-boundary splitting when applying links.
    // ICTTMergeableString's setAttributes:range: can bleed link attributes into
    // adjacent paragraphs when the range crosses a '\\n' character.  We split any
    // write that would cross a newline so each setAttributes:range: call stays
    // within a single paragraph.
    // Note: [ms string] returns the underlying NSMutableAttributedString, not a
    // plain NSString; call -string on that attributed string to get the raw text.
    id msAS = ((id (*)(id, SEL))objc_msgSend)(ms, sel_registerName("string"));
    NSString *msStr = (msAS && [msAS respondsToSelector:@selector(string)]) ? [msAS string] : (NSString *)msAS;

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

        // When a link operation is in play, further split the sub-range at every
        // newline so that setAttributes:range: never crosses a paragraph boundary.
        // For style-only operations (no link) the existing per-attribute-run loop
        // is sufficient; paragraph styles are intentionally paragraph-scoped and
        // ICTTMergeableString handles that correctly.
        NSUInteger segStart = subStart;
        while (segStart < subEnd) {
            // Find the next newline within [segStart, subEnd)
            NSRange searchRange = NSMakeRange(segStart, subEnd - segStart);
            NSRange nlRange = (hasLinkOpt && msStr)
                ? [msStr rangeOfString:@"\\n" options:0 range:searchRange]
                : NSMakeRange(NSNotFound, 0);

            // segEnd: stop just after the newline (inclusive) or at subEnd
            NSUInteger segEnd = (nlRange.location != NSNotFound)
                ? nlRange.location + 1  // include the '\\n' in this segment
                : subEnd;

            NSRange segRange = NSMakeRange(segStart, segEnd - segStart);

            // Re-fetch attributes at segStart so TTStyle reflects the paragraph
            // that owns this segment (important when segStart != subStart, i.e.
            // we have crossed into a new paragraph mid-run).
            NSDictionary *segAttrs = (segStart == subStart)
                ? existingAttrs
                : ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
                      ms, sel_registerName("attributesAtIndex:effectiveRange:"), segStart, &effectiveRange);

            // Build new attrs dict from existing (preserves TTStrikethrough, attachments, etc.)
            NSMutableDictionary *patchedAttrs = [NSMutableDictionary dictionary];
            for (NSString *key in segAttrs) {
                patchedAttrs[key] = segAttrs[key];
            }

            // Apply style delta if requested
            if (hasStyleOpts) {
                id style = [[ICTTParagraphStyleClass alloc] init];
                // Start from existing style as base, then override requested fields
                id existingStyle = segAttrs[@"TTStyle"];
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

            // Apply strikethrough delta if requested
            if (hasStrikethroughOpt) {
                if ([attrOpts[@"strikethrough"] isEqualToString:@"true"]) {
                    patchedAttrs[@"TTStrikethrough"] = @1;
                } else {
                    [patchedAttrs removeObjectForKey:@"TTStrikethrough"];
                }
            }

            // Write back patched attrs for this segment (never crosses a '\\n')
            ((void (*)(id, SEL, id, NSRange))objc_msgSend)(ms, sel_registerName("setAttributes:range:"),
                patchedAttrs, segRange);

            segStart = segEnd;
        }

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
    [predicates addObject:activeNotePredicate()];
    [predicates addObject:[NSPredicate predicateWithFormat:@"title CONTAINS[cd] %@ OR snippet CONTAINS[cd] %@", query, query]];
    if (folderName) {
        [predicates addObject:[NSPredicate predicateWithFormat:@"folder.title == %@", folderName]];
    }
    request.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:predicates];
    request.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"modificationDate" ascending:NO]];
    request.fetchLimit = 20;
    NSError *error = nil;
    NSArray *notes = [viewContext executeFetchRequest:request error:&error];
    if (error) {
        checkNotesAccessError(error);
        errorExit([NSString stringWithFormat:@"Search error: %@", error]);
    }
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
        toInsert = [NSString stringWithFormat:@"\\n%@", displayText];
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

static int cmdAddNoteLink(id viewContext, NSString *sourceId, NSString *targetId, NSInteger position) {
    id sourceNote = findNoteByID(viewContext, sourceId);
    if (!sourceNote) errorExit([NSString stringWithFormat:@"Source note not found: %@", sourceId]);

    id targetNote = findNoteByID(viewContext, targetId);
    if (!targetNote) errorExit([NSString stringWithFormat:@"Target note not found: %@", targetId]);

    Class ICInlineAttachmentClass = NSClassFromString(@"ICInlineAttachment");
    if (!ICInlineAttachmentClass) errorExit(@"ICInlineAttachment class not available");

    id doc = ((id (*)(id, SEL))objc_msgSend)(sourceNote, sel_registerName("document"));
    id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
    NSUInteger oldLen = ((NSUInteger (*)(id, SEL))objc_msgSend)(ms, sel_registerName("length"));

    if (position < -1) errorExit(@"Position must be >= 0 or omitted");

    NSUInteger insertPos;
    BOOL prependNewline;
    if (position < 0) {
        insertPos = oldLen;
        prependNewline = YES;
    } else {
        insertPos = (NSUInteger)position;
        if (insertPos > oldLen) errorExit(@"Position exceeds note length");
        prependNewline = NO;
    }

    ((void (*)(id, SEL))objc_msgSend)(sourceNote, sel_registerName("beginEditing"));

    // Insert newline separator if appending
    if (prependNewline) {
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(
            ms, sel_registerName("insertString:atIndex:"), @"\\n", insertPos);
        insertPos += 1;
    }

    // Insert U+FFFC replacement character at position
    ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(
        ms, sel_registerName("insertString:atIndex:"), @"\\uFFFC", insertPos);

    // Apply body style to the U+FFFC character
    id bodyStyle = [[ICTTParagraphStyleClass alloc] init];
    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(bodyStyle, sel_registerName("setStyle:"), 3);
    ((void (*)(id, SEL, id, NSRange))objc_msgSend)(ms, sel_registerName("setAttributes:range:"),
        @{@"TTStyle": bodyStyle}, NSMakeRange(insertPos, 1));

    // Create the ICInlineAttachment
    NSString *attUUID = [[NSUUID UUID] UUIDString];
    id attachment = ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(
        ICInlineAttachmentClass,
        sel_registerName("newLinkAttachmentWithIdentifier:toNote:fromNote:parentAttachment:"),
        attUUID, targetNote, sourceNote, nil);
    if (!attachment) errorExit(@"Failed to create ICInlineAttachment");

    ((void (*)(id, SEL, id))objc_msgSend)(sourceNote, sel_registerName("addInlineAttachmentsObject:"), attachment);

    NSUInteger insertedLen = prependNewline ? 2 : 1;
    NSUInteger newLen = oldLen + insertedLen;
    ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
        sourceNote, sel_registerName("edited:range:changeInLength:"),
        1, NSMakeRange(0, newLen), (NSInteger)insertedLen);
    ((void (*)(id, SEL))objc_msgSend)(sourceNote, sel_registerName("endEditing"));
    ((void (*)(id, SEL))objc_msgSend)(sourceNote, sel_registerName("saveNoteData"));
    NSError *error = nil;
    [viewContext save:&error];
    if (error) errorExit([NSString stringWithFormat:@"Save error: %@", error]);

    NSString *displayText = ((id (*)(id, SEL))objc_msgSend)(attachment, sel_registerName("displayText"));

    printJSON(@{
        @"id": sourceId,
        @"targetId": targetId,
        @"text": displayText ?: @""
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
    id note = requireSingleNote(viewContext, title, folderName);
    return cmdReadStructuredNote(note);
}'''


def main():
    output = []
    output.append('// AUTO-GENERATED by generate-notes-cli.py — do not edit manually')
    output.append('// Regenerate: python3 generate-notes-cli.py > notekit-generated.m && make notekit')
    output.append('')
    output.append(generate_framework_loading())
    output.append('')
    output.append(generate_helpers())
    output.append('')
    output.append(generate_fetch_helpers())
    output.append('')
    output.append('')
    output.append(generate_note_to_dict())
    output.append('')
    output.append(generate_commands())
    output.append('')

    print('\n'.join(output))


if __name__ == '__main__':
    main()
