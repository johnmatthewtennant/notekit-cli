#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreData/CoreData.h>

// --- Helpers ---

static Class ICNoteContextClass;
static Class ICNoteClass;
static Class ICTTParagraphStyleClass;
static Class ICTTTodoClass;

static void loadFrameworks(void) {
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

static id fetchNote(id viewContext, NSString *title, NSString *folder) {
    NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"ICNote"];
    if (folder) {
        request.predicate = [NSPredicate predicateWithFormat:@"title CONTAINS %@ AND folder.title == %@", title, folder];
    } else {
        request.predicate = [NSPredicate predicateWithFormat:@"title CONTAINS %@", title];
    }
    request.fetchLimit = 1;
    NSError *error = nil;
    NSArray *notes = [viewContext executeFetchRequest:request error:&error];
    if (error || notes.count == 0) return nil;
    return notes[0];
}

static id makeStyle(NSInteger styleNum) {
    id s = [[ICTTParagraphStyleClass alloc] init];
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(s, sel_registerName("setStyle:"), styleNum);
    return s;
}

static id makeCheckStyle(BOOL done) {
    id s = makeStyle(103);
    id todo = ((id (*)(id, SEL, id, BOOL))objc_msgSend)(
        [ICTTTodoClass alloc], sel_registerName("initWithIdentifier:done:"), [NSUUID UUID], done);
    ((void (*)(id, SEL, id))objc_msgSend)(s, sel_registerName("setTodo:"), todo);
    return s;
}

// --- Read: Note → Markdown ---

typedef struct {
    NSString *text;
    NSInteger style;
    BOOL todoDone;
    NSString *paragraphUUID;
} ParagraphInfo;

static NSString *noteToMarkdown(id note) {
    id doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
    id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
    NSAttributedString *attrStr = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("attributedString"));
    NSString *fullText = [attrStr string];
    NSUInteger length = fullText.length;

    if (length == 0) return @"";

    NSMutableString *markdown = [NSMutableString string];
    NSMutableString *currentLine = [NSMutableString string];
    NSString *currentUUID = nil;
    NSInteger currentStyle = -1;
    BOOL currentTodoDone = NO;

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

        NSString *chunk = [fullText substringWithRange:effectiveRange];

        // If same paragraph (same UUID), append to current line
        if (currentUUID && [uuid isEqualToString:currentUUID]) {
            [currentLine appendString:chunk];
        } else {
            // Flush previous line
            if (currentLine.length > 0) {
                // Remove trailing newline for processing
                NSString *line = [currentLine stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
                if (line.length > 0) {
                    switch (currentStyle) {
                        case 0: [markdown appendFormat:@"# %@\n", line]; break;
                        case 1: [markdown appendFormat:@"## %@\n", line]; break;
                        case 2: [markdown appendFormat:@"### %@\n", line]; break;
                        case 103:
                            [markdown appendFormat:@"- [%@] %@\n", currentTodoDone ? @"x" : @" ", line];
                            break;
                        default: [markdown appendFormat:@"%@\n", line]; break;
                    }
                } else if ([currentLine containsString:@"\n"]) {
                    [markdown appendString:@"\n"];
                }
            }
            // Start new line
            currentLine = [NSMutableString stringWithString:chunk];
            currentUUID = uuid;
            currentStyle = styleNum;
            currentTodoDone = done;
        }

        idx = effectiveRange.location + effectiveRange.length;
    }

    // Flush last line
    if (currentLine.length > 0) {
        NSString *line = [currentLine stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
        if (line.length > 0) {
            switch (currentStyle) {
                case 0: [markdown appendFormat:@"# %@\n", line]; break;
                case 1: [markdown appendFormat:@"## %@\n", line]; break;
                case 2: [markdown appendFormat:@"### %@\n", line]; break;
                case 103:
                    [markdown appendFormat:@"- [%@] %@\n", currentTodoDone ? @"x" : @" ", line];
                    break;
                default: [markdown appendFormat:@"%@\n", line]; break;
            }
        }
    }

    return markdown;
}

// --- Write: Markdown → Note (section-aware diff) ---

typedef struct {
    NSString *heading;
    NSString *content; // full section including heading line
} MarkdownSection;

static NSArray *parseMarkdownSections(NSString *markdown) {
    NSArray *lines = [markdown componentsSeparatedByString:@"\n"];
    NSMutableArray *sections = [NSMutableArray array];
    NSMutableString *currentContent = nil;
    NSString *currentHeading = nil;

    for (NSString *line in lines) {
        BOOL isHeading = [line hasPrefix:@"# "] || [line hasPrefix:@"## "] || [line hasPrefix:@"### "];

        if (isHeading) {
            // Flush previous section
            if (currentContent) {
                [sections addObject:@{@"heading": currentHeading ?: @"", @"content": [currentContent copy]}];
            }
            currentHeading = line;
            currentContent = [NSMutableString stringWithFormat:@"%@\n", line];
        } else {
            if (!currentContent) {
                currentHeading = @"";
                currentContent = [NSMutableString string];
            }
            if (line.length > 0 || currentContent.length > 0) {
                [currentContent appendFormat:@"%@\n", line];
            }
        }
    }

    // Flush last section
    if (currentContent) {
        [sections addObject:@{@"heading": currentHeading ?: @"", @"content": [currentContent copy]}];
    }

    return sections;
}

static void writeMarkdownLine(id ms, NSString *line, NSUInteger offset) {
    NSString *textToInsert;
    id style;

    if ([line hasPrefix:@"# "]) {
        textToInsert = [[line substringFromIndex:2] stringByAppendingString:@"\n"];
        style = makeStyle(0);
    } else if ([line hasPrefix:@"### "]) {
        textToInsert = [[line substringFromIndex:4] stringByAppendingString:@"\n"];
        style = makeStyle(2);
    } else if ([line hasPrefix:@"## "]) {
        textToInsert = [[line substringFromIndex:3] stringByAppendingString:@"\n"];
        style = makeStyle(1);
    } else if ([line hasPrefix:@"- [x] "] || [line hasPrefix:@"- [X] "]) {
        textToInsert = [[line substringFromIndex:6] stringByAppendingString:@"\n"];
        style = makeCheckStyle(YES);
    } else if ([line hasPrefix:@"- [ ] "]) {
        textToInsert = [[line substringFromIndex:6] stringByAppendingString:@"\n"];
        style = makeCheckStyle(NO);
    } else {
        textToInsert = [line stringByAppendingString:@"\n"];
        style = makeStyle(3);
    }

    ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(ms, sel_registerName("insertString:atIndex:"), textToInsert, offset);
    ((void (*)(id, SEL, id, NSRange))objc_msgSend)(ms, sel_registerName("setAttributes:range:"),
        @{@"TTStyle": style}, NSMakeRange(offset, textToInsert.length));
}

static NSString *sectionContentToPlainText(NSString *sectionContent) {
    // Normalize section content for comparison (strip markdown prefixes)
    NSMutableString *result = [NSMutableString string];
    for (NSString *line in [sectionContent componentsSeparatedByString:@"\n"]) {
        [result appendFormat:@"%@\n", line];
    }
    return result;
}

static void writeSectionContent(id ms, NSString *sectionContent, NSUInteger offset) {
    NSArray *lines = [sectionContent componentsSeparatedByString:@"\n"];
    NSUInteger currentOffset = offset;
    for (NSString *line in lines) {
        if (line.length == 0 && [lines indexOfObject:line] == lines.count - 1) break; // skip trailing empty
        writeMarkdownLine(ms, line, currentOffset);
        // Recalculate offset by checking what we just inserted
        NSUInteger insertedLen = 0;
        if ([line hasPrefix:@"# "]) insertedLen = line.length - 2 + 1;
        else if ([line hasPrefix:@"### "]) insertedLen = line.length - 4 + 1;
        else if ([line hasPrefix:@"## "]) insertedLen = line.length - 3 + 1;
        else if ([line hasPrefix:@"- [x] "] || [line hasPrefix:@"- [X] "]) insertedLen = line.length - 6 + 1;
        else if ([line hasPrefix:@"- [ ] "]) insertedLen = line.length - 6 + 1;
        else insertedLen = line.length + 1;
        currentOffset += insertedLen;
    }
}

typedef struct {
    NSUInteger start;
    NSUInteger end;
    NSString *heading;
} NoteSection;

static NSArray *findNoteSections(id note) {
    id doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
    id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
    NSAttributedString *attrStr = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("attributedString"));
    NSString *text = [attrStr string];
    NSUInteger length = text.length;

    NSMutableArray *sections = [NSMutableArray array];
    NSUInteger idx = 0;
    NSRange effectiveRange;
    NSString *lastUUID = nil;

    while (idx < length) {
        NSDictionary *attrs = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
            ms, sel_registerName("attributesAtIndex:effectiveRange:"), idx, &effectiveRange);

        id style = attrs[@"TTStyle"];
        if (style) {
            NSInteger styleNum = ((NSInteger (*)(id, SEL))objc_msgSend)(style, sel_registerName("style"));
            NSString *uuid = [((id (*)(id, SEL))objc_msgSend)(style, sel_registerName("uuid")) description];

            if ((styleNum == 0 || styleNum == 1 || styleNum == 2) && ![uuid isEqualToString:lastUUID]) {
                [sections addObject:@{
                    @"start": @(effectiveRange.location),
                    @"style": @(styleNum),
                }];
                lastUUID = uuid;
            }
        }
        idx = effectiveRange.location + effectiveRange.length;
    }

    // Set end positions
    NSMutableArray *result = [NSMutableArray array];
    for (NSUInteger i = 0; i < sections.count; i++) {
        NSUInteger start = [sections[i][@"start"] unsignedIntegerValue];
        NSUInteger end = (i + 1 < sections.count) ? [sections[i+1][@"start"] unsignedIntegerValue] : length;
        NSString *sectionText = [text substringWithRange:NSMakeRange(start, end - start)];
        // Extract heading from first line
        NSString *heading = [[sectionText componentsSeparatedByString:@"\n"] firstObject];
        [result addObject:@{@"start": @(start), @"end": @(end), @"heading": heading}];
    }

    return result;
}

static BOOL writeMarkdownToNote(id note, NSString *newMarkdown, id viewContext) {
    NSArray *newSections = parseMarkdownSections(newMarkdown);
    NSString *oldMarkdown = noteToMarkdown(note);
    NSArray *oldSections = parseMarkdownSections(oldMarkdown);

    // Check if anything changed
    if ([oldMarkdown isEqualToString:newMarkdown]) {
        fprintf(stderr, "No changes detected\n");
        return YES;
    }

    // For simplicity and correctness, do a full rewrite using delete + insert
    // Section-level diffing is complex with shifting offsets; full rewrite is safe
    // since we go through the proper CRDT API
    id doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
    id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
    NSUInteger oldLength = ((NSUInteger (*)(id, SEL))objc_msgSend)(ms, sel_registerName("length"));

    ((void (*)(id, SEL))objc_msgSend)(note, sel_registerName("beginEditing"));

    // Delete all
    ((void (*)(id, SEL, NSRange))objc_msgSend)(ms, sel_registerName("deleteCharactersInRange:"), NSMakeRange(0, oldLength));

    // Insert new content line by line with styles
    NSArray *lines = [newMarkdown componentsSeparatedByString:@"\n"];
    NSUInteger offset = 0;
    for (NSString *line in lines) {
        if (line.length == 0 && [lines indexOfObject:line] == (NSInteger)lines.count - 1) break;
        if (line.length == 0) {
            // Empty line
            ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(ms, sel_registerName("insertString:atIndex:"), @"\n", offset);
            ((void (*)(id, SEL, id, NSRange))objc_msgSend)(ms, sel_registerName("setAttributes:range:"),
                @{@"TTStyle": makeStyle(3)}, NSMakeRange(offset, 1));
            offset += 1;
            continue;
        }
        writeMarkdownLine(ms, line, offset);
        // Calculate inserted length
        NSUInteger insertedLen;
        if ([line hasPrefix:@"# "]) insertedLen = line.length - 2 + 1;
        else if ([line hasPrefix:@"### "]) insertedLen = line.length - 4 + 1;
        else if ([line hasPrefix:@"## "]) insertedLen = line.length - 3 + 1;
        else if ([line hasPrefix:@"- [x] "] || [line hasPrefix:@"- [X] "]) insertedLen = line.length - 6 + 1;
        else if ([line hasPrefix:@"- [ ] "]) insertedLen = line.length - 6 + 1;
        else insertedLen = line.length + 1;
        offset += insertedLen;
    }

    NSInteger delta = (NSInteger)offset - (NSInteger)oldLength;
    ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
        note, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, offset), delta);
    ((void (*)(id, SEL))objc_msgSend)(note, sel_registerName("endEditing"));
    ((void (*)(id, SEL))objc_msgSend)(note, sel_registerName("saveNoteData"));

    NSError *error = nil;
    [viewContext save:&error];
    if (error) {
        fprintf(stderr, "Save error: %s\n", [[error description] UTF8String]);
        return NO;
    }
    return YES;
}

// --- List command ---

static void listNotes(id viewContext, NSString *folder) {
    NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"ICNote"];
    if (folder) {
        request.predicate = [NSPredicate predicateWithFormat:@"folder.title == %@", folder];
    }
    request.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"modificationDate" ascending:NO]];
    request.fetchLimit = 50;

    NSError *error = nil;
    NSArray *notes = [viewContext executeFetchRequest:request error:&error];
    if (error) { fprintf(stderr, "Error: %s\n", [[error description] UTF8String]); return; }

    for (id note in notes) {
        NSString *title = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("title"));
        BOOL hasChecklist = ((BOOL (*)(id, SEL))objc_msgSend)(note, sel_registerName("hasChecklist"));
        id folder = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("folder"));
        NSString *folderName = ((id (*)(id, SEL))objc_msgSend)(folder, sel_registerName("title"));
        printf("%s | %s%s\n", [folderName UTF8String], [title UTF8String], hasChecklist ? " [checklist]" : "");
    }
}

// --- Main ---

static void usage(void) {
    fprintf(stderr, "Usage:\n");
    fprintf(stderr, "  notekit read <title> [--folder <folder>]\n");
    fprintf(stderr, "  notekit write <title> [--folder <folder>]  (reads markdown from stdin)\n");
    fprintf(stderr, "  notekit list [--folder <folder>]\n");
    fprintf(stderr, "  notekit test\n");
}

// --- Tests ---

static int runTests(id viewContext) {
    int passed = 0, failed = 0;

    // Find a folder to use
    NSFetchRequest *folderReq = [NSFetchRequest fetchRequestWithEntityName:@"ICNote"];
    folderReq.predicate = [NSPredicate predicateWithFormat:@"title CONTAINS 'Test checkboxes' OR title CONTAINS 'Working memory'"];
    folderReq.fetchLimit = 1;
    NSError *error = nil;
    NSArray *existingNotes = [viewContext executeFetchRequest:folderReq error:&error];
    if (existingNotes.count == 0) {
        fprintf(stderr, "Need at least one existing note to get a folder\n");
        return 1;
    }
    id folder = ((id (*)(id, SEL))objc_msgSend)(existingNotes[0], sel_registerName("folder"));

    // Test 1: Create a note and read it back as markdown
    fprintf(stderr, "Test 1: Create note and read as markdown...\n");
    {
        id note = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), folder);
        id doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
        id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));

        ((void (*)(id, SEL))objc_msgSend)(note, sel_registerName("beginEditing"));

        NSString *content = @"Test Note\nBody text here.\nTask A\nTask B done\nSubsection\nMore body.\nTask C\n";
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(ms, sel_registerName("insertString:atIndex:"), content, 0);

        NSArray *styles = @[makeStyle(0), makeStyle(3), makeCheckStyle(NO), makeCheckStyle(YES), makeStyle(1), makeStyle(3), makeCheckStyle(NO)];
        NSArray *lines = [content componentsSeparatedByString:@"\n"];
        NSUInteger offset = 0;
        for (NSUInteger i = 0; i < lines.count && i < styles.count; i++) {
            NSUInteger lineLen = [lines[i] length] + 1;
            ((void (*)(id, SEL, id, NSRange))objc_msgSend)(ms, sel_registerName("setAttributes:range:"),
                @{@"TTStyle": styles[i]}, NSMakeRange(offset, lineLen));
            offset += lineLen;
        }

        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            note, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, content.length), content.length);
        ((void (*)(id, SEL))objc_msgSend)(note, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(note, sel_registerName("saveNoteData"));
        [viewContext save:&error];

        NSString *md = noteToMarkdown(note);
        NSString *expected = @"# Test Note\nBody text here.\n- [ ] Task A\n- [x] Task B done\n## Subsection\nMore body.\n- [ ] Task C\n";

        if ([md isEqualToString:expected]) {
            fprintf(stderr, "  PASS\n"); passed++;
        } else {
            fprintf(stderr, "  FAIL\n  Expected: %s\n  Got: %s\n", [expected UTF8String], [md UTF8String]); failed++;
        }

        // Test 2: Write modified markdown back
        fprintf(stderr, "Test 2: Write modified markdown back...\n");
        NSString *modified = @"# Test Note\nBody text here.\n- [x] Task A\n- [x] Task B done\n## Subsection\nUpdated body.\n- [ ] Task C\n- [ ] Task D\n";

        BOOL ok = writeMarkdownToNote(note, modified, viewContext);
        if (ok) {
            NSString *readBack = noteToMarkdown(note);
            if ([readBack isEqualToString:modified]) {
                fprintf(stderr, "  PASS\n"); passed++;
            } else {
                fprintf(stderr, "  FAIL (round-trip mismatch)\n  Expected: %s\n  Got: %s\n", [modified UTF8String], [readBack UTF8String]); failed++;
            }
        } else {
            fprintf(stderr, "  FAIL (write error)\n"); failed++;
        }

        // Test 3: No-op write (same content)
        fprintf(stderr, "Test 3: No-op write (same content)...\n");
        {
            NSString *current = noteToMarkdown(note);
            BOOL ok2 = writeMarkdownToNote(note, current, viewContext);
            if (ok2) {
                fprintf(stderr, "  PASS\n"); passed++;
            } else {
                fprintf(stderr, "  FAIL\n"); failed++;
            }
        }

        // Test 4: Parse markdown sections
        fprintf(stderr, "Test 4: Parse markdown sections...\n");
        {
            NSString *md = @"# Title\nBody\n## Section 2\n- [ ] Item\n## Section 3\nMore text\n";
            NSArray *sections = parseMarkdownSections(md);
            if (sections.count == 3) {
                fprintf(stderr, "  PASS (3 sections)\n"); passed++;
            } else {
                fprintf(stderr, "  FAIL (expected 3 sections, got %lu)\n", (unsigned long)sections.count); failed++;
            }
        }

        // Cleanup: delete test note
        ((void (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("deleteNote:"), note);
        [viewContext save:&error];
    }

    fprintf(stderr, "\nResults: %d passed, %d failed\n", passed, failed);
    return failed > 0 ? 1 : 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) { usage(); return 1; }

        loadFrameworks();

        NSString *command = [NSString stringWithUTF8String:argv[1]];

        // Parse --folder option
        NSString *folder = nil;
        NSString *title = nil;

        for (int i = 2; i < argc; i++) {
            NSString *arg = [NSString stringWithUTF8String:argv[i]];
            if ([arg isEqualToString:@"--folder"] && i + 1 < argc) {
                folder = [NSString stringWithUTF8String:argv[++i]];
            } else if (!title) {
                title = arg;
            }
        }

        id viewContext = getViewContext();

        if ([command isEqualToString:@"read"]) {
            if (!title) { fprintf(stderr, "Error: title required\n"); usage(); return 1; }
            id note = fetchNote(viewContext, title, folder);
            if (!note) { fprintf(stderr, "Note not found: %s\n", [title UTF8String]); return 1; }
            printf("%s", [noteToMarkdown(note) UTF8String]);
            return 0;

        } else if ([command isEqualToString:@"write"]) {
            if (!title) { fprintf(stderr, "Error: title required\n"); usage(); return 1; }
            id note = fetchNote(viewContext, title, folder);
            if (!note) { fprintf(stderr, "Note not found: %s\n", [title UTF8String]); return 1; }

            // Read markdown from stdin
            NSFileHandle *input = [NSFileHandle fileHandleWithStandardInput];
            NSData *data = [input readDataToEndOfFile];
            NSString *markdown = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];

            if (writeMarkdownToNote(note, markdown, viewContext)) {
                fprintf(stderr, "Note updated successfully\n");
                return 0;
            } else {
                return 1;
            }

        } else if ([command isEqualToString:@"list"]) {
            listNotes(viewContext, folder);
            return 0;

        } else if ([command isEqualToString:@"test"]) {
            return runTests(viewContext);

        } else {
            fprintf(stderr, "Unknown command: %s\n", [command UTF8String]);
            usage();
            return 1;
        }
    }
}
