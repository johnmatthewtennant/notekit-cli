# Plan: Add Note-to-Note Linking Support to notekit-cli

## Research Session

Session marker: `B39E13BE-11A3-4150-947B-3BC9B0956DB6`

## Context

Apple Notes supports first-party note-to-note linking. When you type `>>` in the Notes app, it shows a note picker and inserts a clickable link to another note. Under the hood, this uses the same `NSLink` attribute mechanism as regular hyperlinks, but with an `applenotes://` URL scheme instead of `https://`.

### How Note Links Work Internally

1. **URL format:** `applenotes://showNote?identifier=<NOTE_UUID>`
2. **Official API:** `ICAppURLUtilities` class method `appURLForNote:` generates the canonical URL
3. **Storage:** Links are stored as `NSLink` NSURL attributes on text ranges in the CRDT mergeable string, identical to regular web links
4. **Display text:** The link text is whatever text the range covers (typically the target note's title)
5. **`titleForLinking`:** ICNote has a `titleForLinking` property that returns the note's title suitable for use as link display text (currently identical to `title`)

### Key Discovery: Note Links = Regular Links with Special URLs

There is no special "note link" class or attribute. A note-to-note link is simply an `NSLink` attribute with an `applenotes://showNote?identifier=UUID` URL. The Notes app recognizes this URL scheme and navigates to the target note when clicked.

### Relevant Framework Classes

- **`ICAppURLUtilities`** (class methods):
  - `appURLForNote:` -- returns `applenotes://showNote?identifier=<id>` URL
  - `appURLForNote:inFolder:` -- URL with folder context
  - `appURLForNote:paragraphID:` -- URL to a specific paragraph
  - `noteIdentifierFromNotesAppURL:` -- extracts note ID from an applenotes:// URL
  - `isShowNoteURL:` -- checks if a URL is a note link
  - `predicateForNotesMentionedInURL:` -- CoreData predicate to find the linked note

### Dependencies

This plan is self-contained. It does not require the hyperlink support plan (`add-hyperlink-support.md`). The `add-link` command handles its own attribute setting internally. If hyperlink support is later added (enabling `set-attr --link`), users will get an additional way to set note links on existing text, but that is additive and not required for this plan.

## What Needs to Change

### Phase 1: `get-link` Command (Read)

Add a command to get the `applenotes://` URL for a note, so agents can construct note links.

**File:** `notekit.m`

Add a new command `get-link`:

```
notekit get-link --id <note-id>
```

Output:

```json
{
  "id": "2ED98BBA-F665-4516-9B3F-E2BB954CD570",
  "title": "My Note Title",
  "url": "applenotes://showNote?identifier=2ED98BBA-F665-4516-9B3F-E2BB954CD570"
}
```

Implementation:

```objc
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
```

Add to `main()` command dispatch:

```objc
} else if ([command isEqualToString:@"get-link"]) {
    if (!opts[@"id"]) errorExit(@"get-link requires --id");
    return cmdGetLink(viewContext, opts[@"id"]);
}
```

Add to `usage()`:

```
get-link --id <id>                     Get applenotes:// URL for note-to-note linking
```

### Phase 2: `add-link` Command (Write)

Add a convenience command that inserts a note-to-note link into a note. This combines text insertion with link attribute setting.

**File:** `notekit.m`

```
notekit add-link --id <source-note-id> --target <target-note-id> [--text <display-text>] [--position <n>]
```

If `--text` is omitted, use the target note's `titleForLinking`. If `--position` is omitted, append to the end (sentinel value -1).

**Append formatting contract:** When appending (position < 0), a newline is prepended before the link text so the link appears on its own line. The NSLink attribute is applied only to the display text, not the newline.

Implementation:

```objc
static int cmdAddLink(id viewContext, NSString *sourceId, NSString *targetId,
                      NSString *displayText, NSInteger position) {
    id sourceNote = findNoteByID(viewContext, sourceId);
    if (!sourceNote) errorExit([NSString stringWithFormat:@"Source note not found: %@", sourceId]);

    id targetNote = findNoteByID(viewContext, targetId);
    if (!targetNote) errorExit([NSString stringWithFormat:@"Target note not found: %@", targetId]);

    // Get the link URL
    Class ICAppURLUtilities = NSClassFromString(@"ICAppURLUtilities");
    if (!ICAppURLUtilities) errorExit(@"ICAppURLUtilities class not available");

    NSURL *linkURL = ((id (*)(id, SEL, id))objc_msgSend)(
        ICAppURLUtilities, sel_registerName("appURLForNote:"), targetNote);
    if (!linkURL) errorExit(@"Failed to generate note link URL for target note");

    // Get display text
    if (!displayText) {
        displayText = ((id (*)(id, SEL))objc_msgSend)(targetNote, sel_registerName("titleForLinking"));
    }
    if (!displayText || displayText.length == 0) {
        displayText = @"Untitled Note";
    }

    // Get mergeable string
    id doc = ((id (*)(id, SEL))objc_msgSend)(sourceNote, sel_registerName("document"));
    id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
    NSUInteger oldLen = ((NSUInteger (*)(id, SEL))objc_msgSend)(ms, sel_registerName("length"));

    // Validate position
    if (position < -1) errorExit(@"Position must be >= 0 or omitted");

    // Determine insertion position
    NSUInteger insertPos;
    NSString *toInsert;
    if (position < 0) {
        // Append
        insertPos = oldLen;
        toInsert = [NSString stringWithFormat:@"\n%@", displayText];
    } else {
        insertPos = (NSUInteger)position;
        if (insertPos > oldLen) errorExit(@"Position exceeds note length");
        toInsert = displayText;
    }

    ((void (*)(id, SEL))objc_msgSend)(sourceNote, sel_registerName("beginEditing"));

    // Insert the text
    ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(
        ms, sel_registerName("insertString:atIndex:"), toInsert, insertPos);

    // Set attributes: body style + link
    id bodyStyle = [[ICTTParagraphStyleClass alloc] init];
    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(bodyStyle, sel_registerName("setStyle:"), 3);

    NSRange linkRange;
    if (position < 0) {
        // Skip the leading newline for the link attribute
        linkRange = NSMakeRange(insertPos + 1, displayText.length);
    } else {
        linkRange = NSMakeRange(insertPos, displayText.length);
    }

    ((void (*)(id, SEL, id, NSRange))objc_msgSend)(ms, sel_registerName("setAttributes:range:"),
        @{@"TTStyle": bodyStyle, @"NSLink": linkURL}, linkRange);

    // Save
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
```

Add to `main()` command dispatch:

```objc
} else if ([command isEqualToString:@"add-link"]) {
    if (!opts[@"id"]) errorExit(@"add-link requires --id");
    if (!opts[@"target"]) errorExit(@"add-link requires --target");
    NSInteger position = opts[@"position"] ? [opts[@"position"] integerValue] : -1;
    return cmdAddLink(viewContext, opts[@"id"], opts[@"target"], opts[@"text"], position);
}
```

Add to `usage()` under the "Convenience" section:

```
add-link --id <id> --target <id> [--text <text>] [--position <n>]   Insert note-to-note link
```

### Phase 3: Expose Note Links in Read Output

Enhance `noteToDict()` to include the note's `applenotes://` URL, making it easy for agents to get link URLs from any list/get/search command.

**File:** `notekit.m`, function `noteToDict()`

Add after the existing property reads:

```objc
@try {
    Class ICAppURLUtilities = NSClassFromString(@"ICAppURLUtilities");
    if (ICAppURLUtilities) {
        NSURL *appURL = ((id (*)(id, SEL, id))objc_msgSend)(
            ICAppURLUtilities, sel_registerName("appURLForNote:"), note);
        if (appURL) dict[@"url"] = [appURL absoluteString];
    }
} @catch (NSException *e) {}
```

This means every note returned by `list`, `get`, `search`, etc. will include a `url` field that can be used directly for note-to-note linking. The URL contains the note's stable identifier which is already exposed in the `id` field, so this does not increase information exposure. The `@try/@catch` and nil checks ensure graceful degradation if `ICAppURLUtilities` is unavailable on older macOS versions.

### Phase 4: Detect Note Links in `read-attrs` and `read-structured`

Enhance the attribute reading commands to identify when an `NSLink` is a note link vs a web link.

#### 4a: Changes to `cmdReadAttrsNote()`

**File:** `notekit.m`, in `cmdReadAttrsNote()` (around line 252)

Currently:
```objc
id nsLink = attrs[@"NSLink"];
if (nsLink) entry[@"link"] = [nsLink description];
```

Change to:
```objc
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
            if (noteId) entry[@"linkedNoteId"] = noteId;
        } else {
            entry[@"linkType"] = @"url";
        }
    }
}
```

#### 4b: Changes to `cmdReadStructuredNote()`

**File:** `notekit.m`, in `cmdReadStructuredNote()` (around line 509)

The `read-structured` command aggregates text into paragraph-level entries. To surface links, track link attributes encountered during the attribute walk and add them to the paragraph output.

Add link tracking variable alongside the existing paragraph state:

```objc
NSMutableArray *currentLinks = [NSMutableArray array];
```

Inside the attribute loop (after extracting `chunk`), check for NSLink:

```objc
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
            if (noteId) linkEntry[@"linkedNoteId"] = noteId;
        } else {
            linkEntry[@"type"] = @"url";
        }
    }
    [currentLinks addObject:linkEntry];
}
```

When emitting a paragraph (both in the UUID-boundary block and the final flush), add:

```objc
if (currentLinks.count > 0) para[@"links"] = [currentLinks copy];
```

And reset `currentLinks` when starting a new paragraph:

```objc
currentLinks = [NSMutableArray array];
```

This produces output like:

```json
[
  {"text": "See also", "style": 3},
  {"text": "Meeting Notes", "style": 3, "links": [
    {"text": "Meeting Notes", "url": "applenotes://showNote?identifier=ABC", "type": "note", "linkedNoteId": "ABC"}
  ]}
]
```

### Phase 5: Tests

Add tests to `cmdTest()` covering both happy paths and edge cases:

**Happy path tests:**

1. Create two test notes (A and B)
2. Use `cmdGetLink` to get the URL for note B -- verify it returns valid `applenotes://showNote?identifier=<B_id>` URL
3. Use `cmdAddLink` to append a link from A -> B (default append, no position)
4. Read back note A's attributes via `cmdReadAttrsNote` and verify:
   - `NSLink` attribute is present with `applenotes://showNote?identifier=<B_id>` URL
   - `linkType` is `"note"`
   - `linkedNoteId` equals B's identifier

**Edge case tests (in-process):**

5. **Insert at position:** Create note C with text "Hello World". Use `cmdAddLink` with `--position 5` to insert a link in the middle. Verify the link text appears at offset 5 and link attribute is correctly placed.
6. **Empty source note:** Create an empty note D via `create-empty`. Use `cmdAddLink` to append a link to it. Verify it works (the prepended newline should handle gracefully with empty content).
7. **Custom display text:** Use `cmdAddLink` with `--text "custom label"` and verify the link text is "custom label" not the target note's title.

**Error-case tests (subprocess):**

Since `errorExit()` calls `exit(1)`, error cases cannot be tested in-process without terminating the test harness. Use `system()` to shell out to the compiled binary and check exit codes.

The subprocess must use the current executable path, not bare `notekit`, to be reliable in local builds and CI. Resolve the path at the start of `cmdTest()` using `_NSGetExecutablePath` (the codebase already uses this pattern in the `install-skill` command around line 1245):

```objc
char exePath[PATH_MAX];
uint32_t exeSize = sizeof(exePath);
_NSGetExecutablePath(exePath, &exeSize);
realpath(exePath, exePath);
```

Then construct subprocess commands using the resolved path:

8. **Invalid target ID:** Run `system("<exePath> add-link --id VALID_ID --target NONEXISTENT_ID 2>/dev/null")` and assert exit code != 0.
9. **Position out of bounds:** Run `system("<exePath> add-link --id VALID_ID --target VALID_TARGET --position 99999 2>/dev/null")` and assert exit code != 0.

**Web link detection test (deferred):**

10. **Note link vs web link detection:** This test requires setting a regular web URL (`https://`) as an `NSLink` attribute on text. Since `set-attr --link` is not yet implemented, this test should be added when hyperlink support lands. The detection code in Phase 4 will be exercised by the note-link happy-path tests; web-link detection is a correctness gap to backfill later.

**Cleanup:** Delete all test notes created during these tests.

## Usage Examples (for agents)

### Link two notes together

```bash
# Get the target note's link URL
notekit get-link --id "TARGET_NOTE_ID"
# => {"id": "...", "title": "Meeting Notes", "url": "applenotes://showNote?identifier=..."}

# Insert a link in the source note
notekit add-link --id "SOURCE_NOTE_ID" --target "TARGET_NOTE_ID"
# Appends "Meeting Notes" as a clickable link

# Or with custom text
notekit add-link --id "SOURCE_NOTE_ID" --target "TARGET_NOTE_ID" --text "See meeting notes"

# Or at a specific position
notekit add-link --id "SOURCE_NOTE_ID" --target "TARGET_NOTE_ID" --position 42
```

### Build a table of contents note

```bash
# Create an index note
notekit create-empty --folder "Projects"
# For each related note, add a link:
notekit add-link --id "$INDEX_ID" --target "$NOTE1_ID"
notekit add-link --id "$INDEX_ID" --target "$NOTE2_ID"
notekit add-link --id "$INDEX_ID" --target "$NOTE3_ID"
```

## Summary of Files to Change

| File | Change |
|------|--------|
| `notekit.m` -- new `cmdGetLink()` | Get applenotes:// URL for a note |
| `notekit.m` -- new `cmdAddLink()` | Insert note-to-note link text with NSLink attribute |
| `notekit.m` -- `noteToDict()` | Add `url` field to all note JSON output |
| `notekit.m` -- `cmdReadAttrsNote()` | Detect note links vs web links, add `linkType` and `linkedNoteId` |
| `notekit.m` -- `cmdReadStructuredNote()` | Add paragraph-level `links` array with type/linkedNoteId |
| `notekit.m` -- `usage()` | Add get-link and add-link usage lines |
| `notekit.m` -- `main()` | Add command dispatch for get-link and add-link (with position parsing) |
| `notekit.m` -- `cmdTest()` | Add note-to-note linking tests (happy path + edge cases) |

## Estimated Effort

Medium change -- approximately 150-200 lines of new code in `notekit.m`. The framework already supports note links natively through `NSLink` + `applenotes://` URLs. The `ICAppURLUtilities` class provides all needed URL generation and parsing. No new framework classes or complex CRDT operations needed beyond what `cmdInsert` and `cmdSetAttr` already do.
