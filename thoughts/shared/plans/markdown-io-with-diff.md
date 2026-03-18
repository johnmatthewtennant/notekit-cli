# Plan: Markdown Input/Output Format Support with Diff-Based Updates

## Research Session

Session: `f9262730-1dfc-4b43-a9a1-6ecea86fa404/subagents/agent-a9cef94b9b2503a21`

## Problem

Agents and users interacting with notekit-cli must currently use low-level primitives (character offsets, style numbers, UUID-based paragraph grouping) to read and edit note content. This is error-prone, requires multiple commands for simple operations, and means every consumer must understand the internal Apple Notes data model.

The goal is to add two high-level capabilities:
1. **Read a note as markdown** -- convert Apple Notes styled text to standard markdown
2. **Write markdown back** -- convert markdown to styled Apple Notes using a diff approach that only mutates paragraphs that actually changed

The diff approach is critical because:
- It preserves note version history for collaboration
- It avoids overwriting content that was incorrectly parsed during read (safety net for imperfect conversion)
- It prevents data loss from round-trip conversion in sections that weren't modified
- Goal: `read-markdown` then `write-markdown` with no changes = zero mutations to the note

## Apple Notes Attribute Model (Complete Reference)

### Paragraph-level attributes (TTStyle)

| Style | Name | Markdown equivalent |
|-------|------|-------------------|
| 0 | Title | `# ` (H1, first line only) |
| 1 | Heading | `## ` (H2) |
| 3 | Body | Plain text (default) |
| 100 | Dash list | `- ` (unordered list) |
| 102 | Numbered list | `1. ` (ordered list) |
| 103 | Checklist | `- [ ] ` / `- [x] ` |

Additional TTStyle properties:
- **indent** (0-based): nesting level for lists. Each indent level = 2 spaces of indentation in markdown.
- **todo** (on style 103 only): has `done` boolean for checked/unchecked state.
- **blockQuoteLevel**: exists in the framework but not yet tested/exposed. Maps to `> ` prefix.
- **uuid**: unique per paragraph, used for CRDT merging. Must be preserved on write -- never overwrite, only patch.

### Inline attributes (character-level)

| Key | Values | Markdown equivalent |
|-----|--------|-------------------|
| ICTTFont | `bold`, `italic`, `bolditalic` via fontHints | `**text**`, `*text*`, `***text***` |
| NSLink | URL | `[text](url)` |
| TTUnderline | 1 | No standard markdown; use `<u>text</u>` or skip |
| TTStrikethrough | 1 | `~~text~~` |
| TTTimestamp | integer | Internal CRDT timestamp. Ignore on read, preserve on write. |
| TTHints | integer | Internal. Correlates with ICTTFont. Ignore. |

### ICTTFont details

Properties: `fontName` (nullable string), `pointSize` (double), `fontHints` (unsigned int).
Constructor: `initWithName:size:hints:`.

The `fontHints` value encodes bold/italic:
- 0 = normal
- 1 = bold (observed on headings/titles -- this is the paragraph-level font, not inline bold)
- Need empirical testing to confirm inline bold/italic hint values

### Note internal structure

A note's full text in the mergeableString is: `\n` + title + `\n` + body.
- The leading `\n` is always present in canonical notes.
- Title is paragraph style 0.
- Body starts after the title's trailing `\n`.

## Architecture Decision: Single File vs. Separate Wrapper

All existing notekit-cli commands live in a single `notekit.m` file. The markdown conversion logic is substantially more complex than any existing command. Two options:

**Option A: Keep everything in notekit.m** -- Consistent with current pattern, but file is already ~2000 lines. Adding 500+ lines of markdown conversion makes it unwieldy.

**Option B: Separate markdown module** -- Create `markdown.m` (or `markdown.h`/`markdown.m`) with pure conversion functions. Link into the same binary. Keeps notekit.m focused on CLI plumbing.

**Decision: Option A (single file).** The codebase has no header files or multi-file build system. Adding that complexity is not justified yet. The markdown functions can be placed in their own section with clear comment delimiters, similar to how `// --- Surgical Editing Helpers ---` and `// --- Tests ---` sections already work.

## Phase 1: Read as Markdown (`read-markdown`)

### 1.1 New command: `read-markdown`

```
notekit read-markdown (--title <title> | --id <id>) [--folder <name>]
```

Outputs the note content as markdown to stdout. The title becomes an H1 heading.

### 1.2 Conversion rules (Notes -> Markdown)

Walk the mergeableString attribute runs and convert to markdown line by line:

**Paragraph styles:**
- Style 0 (title): `# Title Text`
- Style 1 (heading): `## Heading Text`
- Style 3 (body): `Text` (no prefix)
- Style 100 (dash list): `- Item text` (with indent: `  - Item text` per indent level using 2-space indent)
- Style 102 (numbered list): `1. Item text` (with indent: `  1. Item text`). Number is always `1.` -- markdown renderers auto-number.
- Style 103 (checklist): `- [ ] Item text` or `- [x] Item text` based on todo.done

**Inline formatting (Milestone 4 -- deferred from initial ship):**
- ICTTFont with bold hints on body text: `**text**`
- ICTTFont with italic hints on body text: `*text*`
- ICTTFont with bold+italic hints: `***text***`
- NSLink: `[display text](url)`. Special case: if display text equals the URL, output bare URL.
- TTStrikethrough: `~~text~~`
- TTUnderline: Output as `<u>text</u>` (HTML in markdown). This is lossy but underline has no standard markdown syntax.

**Markdown escaping (CRITICAL for round-trip fidelity):**

When emitting plain text content, characters that have special meaning in markdown must be backslash-escaped to prevent the markdown parser from misinterpreting them as formatting. The following characters must be escaped in text output:

| Character | Escaped form | Context |
|-----------|-------------|---------|
| `*` | `\*` | Would trigger bold/italic |
| `_` | `\_` | Would trigger bold/italic (underscore variant) |
| `~` | `\~` | Would trigger strikethrough |
| `[` | `\[` | Would start a link |
| `]` | `\]` | Would end link text |
| `(` | `\(` | Would start link URL (only after `]`) |
| `)` | `\)` | Would end link URL |
| `\` | `\\` | The escape character itself |
| `<` | `\<` | Would start HTML tag (e.g., `<u>`) |

**Implementation:** Apply escaping to each text run BEFORE wrapping with formatting markers. Text inside formatting markers (bold, italic, link display text) is also escaped. Text inside link URLs is NOT escaped.

```objc
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
```

**Line-prefix escaping:** If a body paragraph's text starts with characters that would be interpreted as a paragraph-level prefix (e.g., `# `, `- `, `1. `), the prefix characters must be escaped. Specifically:
- Lines starting with `# ` -> `\# ` (escape the `#`)
- Lines starting with `- ` -> `\- ` (escape the `-`)
- Lines matching `^\d+\. ` -> `1\. ` (escape the period: `1\.` prevents list parsing)
- Lines starting with `> ` -> `\> ` (escape the `>`)

**Paragraph grouping:** The mergeableString uses UUID-based runs. Multiple attribute runs with the same UUID belong to the same paragraph. Collect all runs for a paragraph, apply inline formatting to the text, then emit the paragraph with the appropriate prefix.

**Edge cases:**
- Empty paragraphs: emit as blank lines
- Leading newline: skip the canonical leading `\n`
- Paragraphs with mixed inline styles (e.g., `Hello **bold** world`): enumerate runs within the paragraph and wrap each styled run

### 1.3 Implementation: `cmdReadMarkdown`

```objc
static int cmdReadMarkdownNote(id note) {
    // 1. Get mergeableString and full text
    // 2. Walk attribute runs, group by UUID into paragraphs
    // 3. For each paragraph:
    //    a. Determine paragraph style from TTStyle
    //    b. Build inline-formatted text by walking runs within the paragraph
    //       - Escape markdown special chars in plain text runs
    //       - Wrap formatted runs with markers (bold, italic, etc.)
    //    c. Emit paragraph prefix + formatted text
    // 4. Output to stdout
}
```

The function reuses the same attribute enumeration pattern as `cmdReadStructuredNote` but outputs markdown text instead of JSON.

### 1.4 Inline formatting detection (Milestone 4)

To detect bold/italic, the implementation must:
1. Read `ICTTFont` from the attribute dict (key: `@"ICTTFont"` -- not currently read by any command)
2. Call `fontHints` on the ICTTFont object
3. Map hint values to bold/italic

**Pre-implementation research needed:** Before implementing, the implementer must create a test note in Apple Notes with known bold and italic text, then read-attrs (with ICTTFont logging) to confirm the exact fontHints values for:
- Normal body text (no font attr, or hints=0)
- Bold body text
- Italic body text
- Bold+italic body text
- Heading text (style 1 -- has ICTTFont with hints=1 and size 24; this is NOT inline bold, it's the heading font)

The implementer should add temporary debug logging to `cmdReadAttrsNote` to dump ICTTFont objects, similar to the `/tmp/inspect-attrs.m` tool used during research. This can be removed after confirming the values.

**Important:** ICTTFont on headings/titles (style 0, 1) should be ignored for bold/italic detection -- those fonts are intrinsic to the paragraph style, not user-applied inline formatting. Only ICTTFont on style 3 (body), 100 (dash), 102 (numbered), 103 (checklist) paragraphs should be treated as inline formatting.

### 1.5 Note-to-note links

When `NSLink` is an `applenotes://` URL (detected via `ICAppURLUtilities isShowNoteURL:`), output as `[display text](applenotes://showNote?identifier=<id>)`. The consumer can resolve the note ID to a title if needed, but the raw URL is the lossless representation.

## Phase 2: Structured Paragraph Model (Internal)

### 2.1 Paragraph data structure

Before implementing write-markdown, define an internal paragraph representation that both read and write use. This ensures round-trip fidelity.

```objc
typedef struct {
    NSInteger style;          // 0, 1, 3, 100, 102, 103
    NSUInteger indent;        // 0-based
    BOOL todoChecked;         // only meaningful for style 103
    NSString *text;           // plain text content (no markdown prefixes, no escaping)
    NSArray *inlineRuns;      // array of {range, bold, italic, strikethrough, underline, link}
    NSString *uuid;           // paragraph UUID from TTStyle (for identity matching in diff)
} NoteParagraph;
```

In practice, use NSDictionary/NSArray since Objective-C structs with object types are cumbersome. The exact shape:

```objc
@{
    @"style": @(3),
    @"indent": @(0),
    @"todoChecked": @NO,       // only for style 103
    @"text": @"Hello world",   // plain text, no markdown syntax
    @"uuid": @"...",           // TTStyle UUID (nil for paragraphs from markdown input)
    @"runs": @[
        @{@"start": @(0), @"length": @(5)},                              // normal "Hello"
        @{@"start": @(6), @"length": @(5), @"bold": @YES},               // bold "world"
    ]
}
```

### 2.2 Parse note to paragraph model

```objc
static NSArray *noteToParaModel(id note)
```

Walks the mergeableString, groups runs by UUID, and builds the paragraph model. This function is shared between `read-markdown` (which renders to markdown) and `write-markdown` (which diffs against the new markdown).

### 2.3 Parse markdown to paragraph model

```objc
static NSArray *markdownToParaModel(NSString *markdown)
```

Parses markdown text and produces the same paragraph model format. Parsing rules (inverse of 1.2):
- `# Title` -> style 0
- `## Heading` -> style 1
- `- Item` -> style 100
- `  - Item` -> style 100, indent 1 (count leading spaces / 2)
- `1. Item` -> style 102 (match `^\d+\.\s`)
- `- [ ] Item` -> style 103, todoChecked=NO
- `- [x] Item` -> style 103, todoChecked=YES
- `**text**` -> bold run
- `*text*` -> italic run
- `~~text~~` -> strikethrough run
- `[text](url)` -> link run
- `<u>text</u>` -> underline run
- Everything else -> style 3 body

**Markdown unescaping:** The parser must reverse the escaping applied by `read-markdown`. Any `\X` sequence where `X` is one of the escaped characters (`*`, `_`, `~`, `[`, `]`, `(`, `)`, `\`, `<`) is unescaped to the literal character `X`. Unescaping is applied AFTER inline parsing, to the plain text content only (not to formatting markers).

```objc
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
```

**CRLF normalization:** Before parsing, normalize all line endings to LF (`\n`). Replace `\r\n` with `\n`, then replace any remaining `\r` with `\n`.

**Markdown parsing approach:** Line-by-line processing, not a full markdown AST parser. This is intentional -- Apple Notes paragraphs map 1:1 to lines, and we don't need to handle complex markdown features (tables, code blocks, images, footnotes, etc.). A simple line-by-line regex-based parser is sufficient and much more maintainable than pulling in a markdown library.

**Inline parsing:** Within each line's text content (after stripping the paragraph prefix), scan for inline markers using a simple state machine or regex. Order of precedence: links first (because `[` and `]` can contain other formatting), then bold+italic (`***`), then bold (`**`), then italic (`*`), then strikethrough (`~~`).

## Phase 3: Diff Engine

### 3.1 Diff strategy

The diff compares two paragraph models (current note vs. incoming markdown) and produces a minimal set of mutations.

**Matching algorithm:** Use an LCS (Longest Common Subsequence) / patience diff algorithm over paragraph signatures, not naive text matching. This correctly handles duplicate lines and paragraph reordering.

**Paragraph signature:** Each paragraph is represented by a composite key for LCS matching:
```
signature = (style, indent, todoChecked, normalizedText)
```
Where `normalizedText` is the plain text with trailing whitespace stripped. For numbered lists, the number prefix is excluded from the signature (since markdown auto-numbers).

**LCS-based matching procedure:**
1. Compute LCS of old and new paragraph signature sequences.
2. Paragraphs in the LCS are "matched" -- they appear in both old and new in the same relative order.
3. Paragraphs in old but not in LCS -> deleted.
4. Paragraphs in new but not in LCS -> inserted.
5. For matched pairs where signatures are equal but inline runs differ -> attribute-only update.

**Duplicate signatures:** When the same signature appears multiple times (e.g., multiple empty body paragraphs), the standard forward-pass LCS algorithm produces a stable, deterministic matching. It may not always produce the minimal diff when paragraphs are reordered among duplicates, but it will always produce a *correct* diff (the resulting note will match the intended markdown). Optimizing for minimal diffs among duplicate paragraphs is not a goal -- correctness is sufficient.

### 3.2 Mutation types and attribute patching

All mutations operate directly on the mergeableString within a single `beginEditing`/`endEditing` transaction. The diff engine does NOT shell out to `set-attr`, `insert`, or `delete-range` CLI commands. This is more efficient (single save), provides atomicity, and allows per-run attribute patching.

**Per-run attribute patching (CRITICAL for CRDT safety):**

When updating attributes on matched paragraphs, the engine must NOT create fresh attribute dictionaries. Instead:
1. Read existing attributes for the run via `attributesAtIndex:effectiveRange:`
2. Clone the existing dict (`mutableCopy`)
3. Patch only the keys that changed (TTStyle, NSLink, ICTTFont, etc.)
4. Preserve ALL unknown/unhandled keys (TTTimestamp, TTHints, future keys)
5. Write back with `setAttributes:range:`

This ensures CRDT metadata (timestamps, UUIDs) and any attributes the plan does not explicitly handle are preserved.

```objc
// Pseudocode for attribute patching
NSMutableDictionary *patched = [existingAttrs mutableCopy];
// Only set TTStyle if paragraph style/indent/todo changed
if (styleChanged) {
    id newStyle = [existingStyle mutableCopy]; // preserve UUID
    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(newStyle, sel_registerName("setStyle:"), newStyleValue);
    patched[@"TTStyle"] = newStyle;
}
// Only set NSLink if link changed
if (linkChanged) {
    if (newLinkURL) patched[@"NSLink"] = newLinkURL;
    else [patched removeObjectForKey:@"NSLink"];
}
// TTTimestamp, TTHints, etc. are untouched -- preserved from existingAttrs
```

**Important:** When patching TTStyle, use `mutableCopy` of the existing TTStyle object (not `alloc init`) to preserve the paragraph's UUID. Only override the specific properties that changed (style, indent, todo).

**Mutation types for each matched pair (old paragraph, new paragraph):**
- **Text identical, formatting identical:** No mutation (skip).
- **Text identical, formatting changed:** Per-run attribute patching on the existing text range.
- **Text changed:** Use `deleteCharactersInRange:` to remove old text, `insertString:atIndex:` to insert new text, then apply attributes with per-run patching.

**Insertions:** Use `insertString:atIndex:` at the correct offset, then apply attributes.
**Deletions:** Use `deleteCharactersInRange:` to remove the paragraph (including its trailing newline).

### 3.3 Offset tracking

As mutations are applied, character offsets shift. The diff engine must track cumulative offset deltas:

```
cumulativeDelta = 0
for each mutation in order (top to bottom):
    adjustedOffset = originalOffset + cumulativeDelta
    apply mutation at adjustedOffset
    cumulativeDelta += (insertedChars - deletedChars)
```

### 3.4 Round-trip identity: the "no mutation" guarantee

When `read-markdown` output is fed directly back to `write-markdown` without changes, the diff must produce zero mutations. This requires:

**Whitespace canonicalization:** Before comparing paragraph models, normalize:
- Strip trailing whitespace from each paragraph's text
- Collapse multiple consecutive blank lines into one (matching Apple Notes behavior)
- Normalize CRLF to LF (done in markdown parsing phase)
- Trim trailing blank lines from the end of the document

**Comparison function:**
```objc
static BOOL paragraphsEqual(NSDictionary *a, NSDictionary *b) {
    // Compare style, indent, todoChecked, normalizedText, and inline runs
    // Ignore UUID (markdown input has no UUID)
    // Ignore numbered list auto-numbers
    return [a[@"style"] isEqual:b[@"style"]] &&
           [a[@"indent"] isEqual:b[@"indent"]] &&
           (![a[@"style"] isEqual:@(103)] || [a[@"todoChecked"] isEqual:b[@"todoChecked"]]) &&
           [normalizeText(a[@"text"]) isEqualToString:normalizeText(b[@"text"])] &&
           inlineRunsEqual(a[@"runs"], b[@"runs"]);
}

static NSString *normalizeText(NSString *text) {
    // Strip trailing whitespace ONLY (preserve leading whitespace)
    NSRange range = [text rangeOfCharacterFromSet:
        [[NSCharacterSet whitespaceCharacterSet] invertedSet]
        options:NSBackwardsSearch];
    if (range.location == NSNotFound) return @"";
    return [text substringToIndex:range.location + range.length];
}
```

## Phase 4: Write Markdown (`write-markdown`)

### 4.1 New command: `write-markdown`

```
notekit write-markdown --id <id> [--dry-run] [--backup]
```

Reads markdown from stdin, diffs against the current note content, and applies minimal mutations.

**Default behavior:** `write-markdown` applies changes (mutates the note). This is consistent with other notekit mutating commands (`append`, `insert`, `replace`, `set-attr`) which all apply immediately.

- `--dry-run`: Output the mutation plan as JSON without applying any changes. The note is not modified. Useful for previewing what would change before committing.
- `--backup`: Before applying changes, duplicate the note (using existing `cmdDuplicate` logic) as a safety backup. The backup note's title is prefixed with `[backup] `.

**Output:** JSON summary of what changed:
```json
{
    "id": "...",
    "paragraphsUnchanged": 5,
    "paragraphsModified": 2,
    "paragraphsInserted": 1,
    "paragraphsDeleted": 0,
    "mutations": [
        {"type": "replace", "paragraph": 3, "oldText": "...", "newText": "..."},
        {"type": "insert", "paragraph": 6, "text": "..."},
        {"type": "setAttr", "paragraph": 2, "attr": "style", "value": 1}
    ]
}
```

### 4.2 Command flow

```
1. Read note -> noteToParaModel(note) -> oldModel
2. Read markdown from stdin -> normalize CRLF -> markdownToParaModel(markdown) -> newModel
3. Diff oldModel vs newModel (LCS) -> mutations[]
4. If --dry-run: output mutation plan as JSON, exit
5. If --backup: duplicate note before modifying
6. beginEditing
7. Apply mutations in order (offset-adjusted) with per-run attribute patching
8. endEditing + saveNoteData + save context
9. Output summary
```

### 4.3 Stdin reading

```objc
NSFileHandle *input = [NSFileHandle fileHandleWithStandardInput];
NSData *data = [input readDataToEndOfFile];
NSString *markdown = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
if (!markdown) errorExit(@"Failed to read markdown from stdin (invalid UTF-8)");
```

### 4.4 Failure handling and atomicity

All mutations are applied within a single `beginEditing`/`endEditing` transaction. If any mutation step encounters an error (e.g., offset out of bounds):

1. Call `endEditing` to close the editing session
2. Do NOT call `saveNoteData` or `[viewContext save:]`
3. Output an error JSON with the mutation index that failed and the error message
4. Exit with non-zero status

Because Core Data changes are not persisted until `save:` is called, failing to save effectively rolls back all mutations. The `--backup` flag provides an additional safety net for users who want a restorable copy.

### 4.5 Link scheme validation

When the markdown parser encounters a link `[text](url)`, validate the URL scheme before applying it as an `NSLink` attribute:

**Allowed schemes:** `http`, `https`, `mailto`, `applenotes`

**Rejected schemes:** Everything else (including `javascript:`, `file:`, `data:`, etc.)

If a link has a rejected scheme, treat the entire `[text](url)` as literal text (unescape it) and log a warning to stderr. Do not error out -- the rest of the note should still be processed.

```objc
static BOOL isAllowedLinkScheme(NSURL *url) {
    NSString *scheme = [url.scheme lowercaseString];
    return [scheme isEqualToString:@"http"] ||
           [scheme isEqualToString:@"https"] ||
           [scheme isEqualToString:@"mailto"] ||
           [scheme isEqualToString:@"applenotes"];
}
```

## Phase 5: Prerequisites and Dependencies

### 5.1 Inline formatting in write path (Milestone 4 -- deferred)

Currently, `set-attr` can set TTStyle (paragraph style, indent, todo) and NSLink, but cannot set:
- ICTTFont (bold/italic)
- TTStrikethrough
- TTUnderline

The write-markdown command (Milestone 3) ships WITHOUT inline formatting support. It handles paragraph-level styles (title, heading, body, lists, checklists) and links only. This is the high-value subset.

Milestone 4 adds inline formatting (bold, italic, strikethrough, underline) by directly calling the mergeableString API (`setAttributes:range:`) with per-run attribute patching.

### 5.2 ICTTFont creation for bold/italic (Milestone 4)

To set bold/italic on a text range, the implementer must:
1. Load the `ICTTFont` class (add to `loadFramework()`)
2. Create an ICTTFont instance with `initWithName:size:hints:` (name can be nil, size 0 for "inherit default", hints for bold/italic)
3. Set it as `@"ICTTFont"` in the attribute dict

**Pre-implementation research needed:** Test ICTTFont creation with various hint values to confirm which values produce bold, italic, and bold+italic rendering in Apple Notes.

### 5.3 Offset mismatch fix (PR #4)

The fix-offset-mismatch PR adds `--body-offset` to `set-attr`, `insert`, and `delete-range`. The diff engine works with full-string offsets internally (since it reads from the mergeableString directly), so it does not depend on the `--body-offset` feature. However, the `bodyOffsetForNote` helper from that PR is useful and should be reused if available.

### 5.4 List formatting support (PR #3)

The add-list-formatting PR adds `--style` to `append` and `insert`, plus `read-structured` type labels. The markdown feature builds on top of this: `read-markdown` needs to recognize styles 100/102 and emit the correct markdown prefixes. If PR #3 is not merged, these style values are still readable via `read-attrs` (they already work), so this is a soft dependency.

## Phase 6: Tests

### 6.1 Read-markdown tests

1. **Title and body**: Create note with title (style 0) and body (style 3), read as markdown, verify `# Title\n\nBody text`.
2. **Heading**: Create note with heading (style 1), verify `## Heading`.
3. **Dash list**: Create note with dash list items (style 100), verify `- Item`.
4. **Numbered list**: Create note with numbered list (style 102), verify `1. Item`.
5. **Checklist unchecked**: Create note with checklist (style 103, done=NO), verify `- [ ] Item`.
6. **Checklist checked**: Create note with checklist (style 103, done=YES), verify `- [x] Item`.
7. **Indented list**: Create note with indented list items, verify `  - Item`.
8. **Hyperlink**: Create note with NSLink, verify `[text](url)`.
9. **Strikethrough**: Create note with TTStrikethrough, verify `~~text~~`.
10. **Round-trip identity**: Read note as markdown, parse back to paragraph model, compare to original paragraph model. Must be identical.
11. **Literal markdown characters**: Create note with text containing `*`, `_`, `[`, `]`, `~~` as literal characters. Read as markdown, verify they are backslash-escaped. Parse back, verify text matches original.
12. **Line prefix collision**: Create body paragraph starting with `# `, `- `, `1. `. Verify prefix is escaped in markdown output.

### 6.2 Write-markdown tests (diff)

13. **No-change round-trip**: Read note as markdown, write it back, verify zero mutations reported.
14. **Text change**: Modify one paragraph's text in markdown, write back, verify only that paragraph is mutated.
15. **Style change**: Change a body paragraph to a heading in markdown, write back, verify style is updated.
16. **Add paragraph**: Add a new line in markdown, write back, verify it's inserted at the correct position.
17. **Delete paragraph**: Remove a line from markdown, write back, verify it's deleted.
18. **Mixed changes**: Modify, add, and delete paragraphs in a single write, verify correct minimal mutations.
19. **Checklist toggle**: Change `- [ ]` to `- [x]`, verify only the todo-done attribute changes.
20. **Dry-run mode**: Verify `--dry-run` outputs mutation plan without modifying the note.
21. **Duplicate paragraph text**: Note with two identical body paragraphs. Modify only the second one. Verify the first is unchanged.
22. **Paragraph reordering**: Swap two paragraphs in markdown. Verify the diff correctly identifies the reorder (delete + insert, not modifying unrelated paragraphs).

### 6.3 Edge case tests

23. **Empty note**: Read-markdown on empty note, verify empty output or just title.
24. **Title-only note**: Note with only a title line.
25. **Note with links**: Both regular URLs and note-to-note links (`applenotes://`). Round-trip through write-markdown.
26. **Unicode text**: CJK characters, emoji, combining characters.
27. **Very long note**: Performance sanity check.
28. **CRLF input**: Write-markdown with `\r\n` line endings, verify normalization works.
29. **Trailing whitespace**: Paragraphs with trailing spaces, verify no false diffs.
30. **Rejected link scheme**: Markdown with `[click](javascript:alert(1))`, verify it is treated as literal text and a warning is emitted.
31. **Mixed inline overlaps (Milestone 4)**: `[**text**](url)`, `~~**x**~~` -- verify nested formatting round-trips correctly.

## Implementation Order

### Milestone 1: Read-markdown (Phases 1 + 2.2)
- Add `noteToParaModel` helper
- Add `escapeMarkdown` / `unescapeMarkdown` helpers
- Add `cmdReadMarkdown` command (paragraph-level styles + links + strikethrough, NO bold/italic)
- Add read-markdown tests (6.1: tests 1-12)
- Does not require any PRs to be merged first
- Deliverable: `notekit read-markdown --id <id>` works

### Milestone 2: Markdown parser + round-trip (Phase 2.3)
- Add `markdownToParaModel` parser with CRLF normalization and unescaping
- Add round-trip identity test (test 10)
- Add link scheme validation
- Deliverable: markdown parsing produces equivalent paragraph models

### Milestone 3: Diff engine + write-markdown (Phases 3 + 4)
- Add LCS-based diff algorithm
- Add `cmdWriteMarkdown` command
- Apply by default, `--dry-run` for preview
- Add per-run attribute patching (preserves CRDT metadata)
- Add `--backup` flag
- Add write-markdown tests (6.2 + 6.3: tests 13-30)
- Does NOT require ICTTFont/bold/italic -- paragraph-level styling only
- Deliverable: `notekit write-markdown --id <id> [--dry-run] < file.md` works

### Milestone 4: Inline formatting (bold/italic/strikethrough/underline)
- Confirm ICTTFont hint values empirically (research task)
- Add ICTTFont reading in read-markdown
- Add ICTTFont creation in write-markdown
- Add TTStrikethrough/TTUnderline support in write path
- Add inline formatting tests (test 31)
- This is explicitly deferred -- Milestone 3 ships without inline formatting

## Files to Modify

| File | Change |
|------|--------|
| `notekit.m` -- top of file | Add `ICTTFontClass` to `loadFramework()` (Milestone 4) |
| `notekit.m` -- new section | Add `// --- Markdown Conversion ---` section with: `escapeMarkdown`, `unescapeMarkdown`, `noteToParaModel`, `markdownToParaModel`, `diffParaModels`, `applyMutations`, `cmdReadMarkdownNote`, `cmdWriteMarkdownNote` |
| `notekit.m` -- `usage()` | Add `read-markdown` and `write-markdown` commands |
| `notekit.m` -- `main()` | Add command routing for `read-markdown` and `write-markdown`; add `dry-run` and `backup` to boolean flags |
| `notekit.m` -- `cmdTest()` | Add markdown read/write/round-trip tests |
| `.agents/skills/apple-notes/SKILL.md` | Add markdown commands to examples |

## Estimated Effort

Large feature -- approximately 700-900 lines of new code across all milestones. The diff engine (Phase 3 / Milestone 3) is the most complex component.

Milestone 1 alone (read-markdown) is a medium change (~250 lines) and delivers immediate value.

## Risk Assessment

- **Medium risk:** ICTTFont bold/italic detection is based on observed patterns, not documented API. Need empirical confirmation. Mitigated by deferring to Milestone 4.
- **Low risk:** Paragraph-level style mapping is well-understood (styles 0/1/3/100/102/103 are proven in existing code).
- **Low risk:** The diff engine operates within a single `beginEditing`/`endEditing` transaction. No save on error = effective rollback.
- **Low risk:** Markdown escaping/unescaping is well-defined with explicit character list and tests.
- **Medium risk:** LCS diff with duplicate paragraphs may produce suboptimal (but correct) diffs. Correctness is guaranteed; minimality among duplicates is not a goal.
- **Low risk:** `--backup` flag provides user-initiated safety net for destructive write operations.

## Out of Scope

- **Tables**: Apple Notes tables use a separate `ICTable` class, not paragraph styles. Complex to support, low priority.
- **Images/attachments**: Stored as `ICAttachment` objects, not text attributes. Would need a separate attachment export feature.
- **Code blocks**: Apple Notes has a monospace style (style value TBD). Can be added later if the style value is discovered.
- **Block quotes**: The `blockQuoteLevel` property exists on ICTTParagraphStyle but has not been tested. Can be added when confirmed.
- **Full markdown spec compliance**: This is a pragmatic subset tailored to Apple Notes capabilities, not a full CommonMark implementation.
