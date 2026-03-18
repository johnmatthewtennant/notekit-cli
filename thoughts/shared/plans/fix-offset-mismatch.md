# Fix set-attr offset mismatch bug

Session: 39E9C7BA-E0D5-48E7-958E-0BEFC86CF702

## Problem

When a user runs `notekit read` to find a text offset and then `notekit set-attr` to style that range, the style lands on the wrong text. The offsets from `read` don't match what `set-attr` expects.

## Root cause

The internal text representation of an Apple Note (the "mergeableString") stores the **full** note text including a leading newline character (`\n`), the title text, and then another newline before the body. For example, a note with title "My Note" and body "Hello world" is stored internally as:

```
\nMy Note\nHello world
```

The three relevant commands use inconsistent coordinate spaces:

| Command | Data source | Includes title? | Offset base |
|---------|-------------|-----------------|-------------|
| `read` | `noteAsPlainTextWithoutTitle` | **No** | Body-only (offset 0 = first char of body) |
| `read-attrs` | `attributedString` via `mergeableString` | **Yes** | Full string (offset 0 = leading `\n`) |
| `set-attr` | `mergeableString` | **Yes** | Full string (offset 0 = leading `\n`) |
| `insert` | `mergeableString` | **Yes** | Full string |
| `delete-range` | `mergeableString` | **Yes** | Full string |

So `read` returns body text starting at offset 0 (no title, no leading newline), but `set-attr` expects offsets into the full string which includes `\n` + title + `\n` before the body. The offset of any text in the `read` output is off by `1 + title.length + 1` characters from what `set-attr` expects.

### Code references (notekit.m)

- **`cmdReadNote`** (line 199-203): Uses `noteAsPlainTextWithoutTitle` -- strips the title entirely
- **`cmdReadAttrsNote`** (line 211-267): Uses `attributedString` and `mergeableString` -- includes leading newline + title + newline + body. Offsets are into the full string.
- **`cmdSetAttr`** (line 408-450): Uses `mergeableString` -- offsets are into the full string.
- **`cmdInsert`** (line 651-671): Uses `mergeableString` -- offsets are into the full string.
- **`cmdDeleteRange`** (line 674-689): Uses `mergeableString` -- offsets are into the full string.

## Fix approach

### Phased delivery

**Phase 1 (this change):** Add `--body-offset` flag to mutating commands (`set-attr`, `insert`, `delete-range`). This is fully backwards-compatible -- existing callers are unaffected, and the common workflow of `read` then `set-attr --body-offset` works correctly.

**Phase 2 (follow-up):** Add optional metadata to read commands (`read --json`, `read-attrs --include-body-offset`). Kept separate to avoid mixing breaking/non-breaking changes.

### Why `--body-offset` flag (Option B)

Add a `--body-offset` flag to `set-attr`, `insert`, and `delete-range` that automatically adjusts offsets to account for the title. When `--body-offset` is passed, the command computes the title length and adds the appropriate offset (leading newline + title + trailing newline) to all user-supplied offsets before applying them.

This is backwards-compatible (existing callers using full-string offsets from `read-attrs` still work) and makes the common workflow of `read` -> find text -> `set-attr` work correctly.

### `--body-offset` contract

The `--body-offset` flag means: "the offset/position/start I am providing is relative to the first character of the body text (the text after the title)." Specifically:

- Body-relative offset 0 = the first character of the body (same as offset 0 in `notekit read` output)
- The note **must have body text** for `--body-offset` to be valid. If the note is title-only (no body), the command errors with "Note has no body text; --body-offset requires body content"
- Without `--body-offset`, all commands behave exactly as before (full-string offsets)

## Implementation plan

### Step 0: Verify stored string format and decide helper strategy

Before implementing, the implementer must confirm the exact stored string format for notes created through two paths:

1. **The test harness** (`cmdTest`): Inspect how test notes are constructed (around line 839). Current tests build notes by inserting text into a `create-empty` note via `mergeableString` operations. Check whether the resulting string has a leading newline before the title.
2. **Real Apple Notes**: Create a note manually in Apple Notes (or use existing notes), then inspect the full string via `read-attrs` to confirm the canonical format is `"\n" + title + "\n" + body`.

**Decision tree after verification:**

- **Branch A: Both paths produce canonical format** (`\n` + title + `\n` + body). Proceed with the helper as designed below. Update test fixtures if needed to match.
- **Branch B: Formats differ** (e.g., test harness produces `title + \n + body` without leading newline, but real notes have `\n + title + \n + body`). In this case:
  - Make `bodyOffsetForNote` handle both shapes silently: scan for the first `\n` that separates title from body, regardless of whether a leading `\n` exists. No runtime warning -- the dual-shape handling is documented in the code comment only.
  - Update tests to exercise both shapes.

This verification is critical because `bodyOffsetForNote` must work correctly for all notes the user might encounter.

### Step 1: Add a helper function to compute body offset

Add a helper function that takes a note and returns the offset where the body starts in the mergeableString. Reuse the logic from `cmdDuplicate` (lines 339-344), with added robustness:

```objc
// Returns the character offset where the body starts in the full mergeableString
// (after leading \n + title + \n)
// Returns NSNotFound if the note has no body (title-only note).
static NSUInteger bodyOffsetForNote(id note) {
    NSAttributedString *attrStr = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("attributedString"));
    NSString *fullText = [attrStr string];
    NSUInteger length = fullText.length;

    // Guard: empty note
    if (length == 0) return NSNotFound;

    // Apple Notes canonical format: exactly one leading \n, then title, then \n, then body.
    // Also handles non-canonical format (no leading \n) for test-created notes.
    NSUInteger idx = 0;

    // Skip leading newline if present (canonical format)
    if (idx < length && [fullText characterAtIndex:idx] == 0x0A) idx++;

    // Skip title text (all non-newline characters)
    while (idx < length && [fullText characterAtIndex:idx] != 0x0A) idx++;

    // Skip the newline after title
    if (idx < length && [fullText characterAtIndex:idx] == 0x0A) idx++;

    // If idx >= length, the note has no body (title-only)
    if (idx >= length) return NSNotFound;

    return idx;
}
```

**Note:** The "Skip leading newline if present" line handles both Branch A and Branch B from Step 0. If the leading newline exists, it's skipped; if not, we start scanning from the title directly.

Place this near the other helper functions (around line 100).

### Step 2: Add `--body-offset` flag to `set-attr`

In `cmdSetAttr` (line 408), add a check for the `body-offset` flag in `attrOpts`. If present, compute the body offset and add it to the user-supplied offset, with safe bounds checking:

```objc
static int cmdSetAttr(id viewContext, NSString *identifier,
                      NSUInteger offset, NSUInteger length, NSDictionary *attrOpts) {
    id note = findNoteByID(viewContext, identifier);
    if (!note) errorExit(...);

    // NEW: adjust offset if --body-offset flag is set
    if (attrOpts[@"body-offset"]) {
        NSUInteger bodyOff = bodyOffsetForNote(note);
        if (bodyOff == NSNotFound) {
            errorExit(@"Note has no body text; --body-offset requires body content");
        }
        // Safe overflow check: ensure offset + bodyOff doesn't wrap
        if (offset > NSUIntegerMax - bodyOff) {
            errorExit(@"Offset overflow: body-relative offset too large");
        }
        offset += bodyOff;
    }

    // Existing bounds check (already present, but ensure it uses safe arithmetic):
    id doc = ...;
    id ms = ...;
    NSUInteger msLen = ((NSUInteger (*)(id, SEL))objc_msgSend)(ms, sel_registerName("length"));
    if (offset > msLen || length > msLen - offset) {
        errorExit(@"Offset/length out of range");
    }

    // ... rest unchanged
}
```

### Step 3: Add `--body-offset` flag to `insert`

In `cmdInsert` (line 651), accept an additional parameter. Change signature to accept a `BOOL useBodyOffset` parameter:

```objc
static int cmdInsert(id viewContext, NSString *identifier, NSString *text, NSUInteger position, BOOL useBodyOffset) {
    id note = findNoteByID(viewContext, identifier);
    if (!note) errorExit(...);

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

    // Existing bounds check
    id doc = ...;
    id ms = ...;
    NSUInteger msLen = ((NSUInteger (*)(id, SEL))objc_msgSend)(ms, sel_registerName("length"));
    if (position > msLen) {
        errorExit(@"Position out of range");
    }

    // ... rest unchanged
}
```

Update the call site in main (around line 1561) to pass the flag from opts.

### Step 4: Add `--body-offset` flag to `delete-range`

Same pattern as insert:

```objc
static int cmdDeleteRange(id viewContext, NSString *identifier, NSUInteger start, NSUInteger length, BOOL useBodyOffset) {
    id note = findNoteByID(viewContext, identifier);
    if (!note) errorExit(...);

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

    // Existing bounds check (use safe arithmetic)
    id doc = ...;
    id ms = ...;
    NSUInteger msLen = ((NSUInteger (*)(id, SEL))objc_msgSend)(ms, sel_registerName("length"));
    if (start > msLen || length > msLen - start) {
        errorExit(@"Start/length out of range");
    }

    // ... rest unchanged
}
```

### Step 5: Parse `--body-offset` as a boolean flag

In the argument parsing section (around line 1420), add `body-offset` to the list of boolean flags:

```objc
if ([flag isEqualToString:@"help"] ||
    [flag isEqualToString:@"claude"] ||
    [flag isEqualToString:@"agents"] ||
    [flag isEqualToString:@"force"] ||
    [flag isEqualToString:@"body-offset"]) {  // ADD THIS
    opts[flag] = @"true";
}
```

### Step 6: Update usage text

Update the help text (around line 1382) to document the `--body-offset` flag:

```
notekit set-attr --id <id> --offset <n> --length <n> [--style <n>] [--indent <n>] [--todo-done true|false] [--body-offset]
notekit insert --id <id> --text <text> --position <n> [--body-offset]
notekit delete-range --id <id> --start <n> --length <n> [--body-offset]
```

Add a note in the help text:
```
  --body-offset    Treat offset/position/start as relative to body text (after title).
                   Use this when offsets come from 'notekit read' output.
                   Errors if the note has no body text (title-only note).
```

### Step 7: Update the skill documentation

The notekit skill file (if it exists) should document that `--body-offset` should be used when offsets come from `read` output, and raw offsets from `read-attrs` should be used without the flag.

### Step 8: Add tests

Add test cases to the existing test function (around line 800+). Tests should create notes using the existing test harness mechanism (`create-empty` + `insert` via mergeableString operations, which is how `cmdTest` already works):

1. **bodyOffsetForNote correctness:** Create a test note with a known title and body, verify `bodyOffsetForNote` returns the expected value. Log the actual stored string bytes to confirm the format (Branch A vs Branch B from Step 0).
2. **set-attr with --body-offset:** Apply a style using body-relative offset 0, verify via read-attrs that the style is at the correct full-string position (bodyOffset).
3. **set-attr without --body-offset:** Verify existing behavior is unchanged -- full-string offsets work as before (regression test).
4. **insert with --body-offset:** Insert text at body-relative position 0, verify it appears at the start of the body (not in the title).
5. **insert without --body-offset:** Verify existing behavior is unchanged (regression test).
6. **delete-range with --body-offset:** Delete a range using body-relative offsets, verify the correct body text is removed.
7. **delete-range without --body-offset:** Verify existing behavior is unchanged (regression test).
8. **Edge case -- title-only note:** Create a note with title but no body, use --body-offset, verify it errors with "Note has no body text; --body-offset requires body content".
9. **Edge case -- overflow:** Pass a very large offset (e.g., NSUIntegerMax) with --body-offset, verify it errors cleanly rather than wrapping.

### Step 9: Build and manual verification

```bash
cd ~/Development/notekit-cli && make
```

Run the built-in tests:
```bash
notekit test
```

Then verify with a real note:
```bash
# Get a note's body text and find a known string's position
notekit read --id <test-note-id>
# Get the attrs to see full-string offsets
notekit read-attrs --id <test-note-id>
# Apply a heading style using body-relative offset
notekit set-attr --id <test-note-id> --offset <position-from-read> --length <len> --style 1 --body-offset
# Verify with read-attrs that the style landed on the correct text
notekit read-attrs --id <test-note-id>
```

## Files to modify

- `/Users/jtennant/Development/notekit-cli/notekit.m` -- All changes are in this single file

## Risk assessment

- **Low risk:** The `--body-offset` flag is opt-in, so existing callers are unaffected
- **Low risk:** The body offset calculation reuses proven logic from `cmdDuplicate`
- **Low risk:** Safe arithmetic checks prevent integer overflow in adjusted offsets
- **Low risk:** Explicit "no body" error prevents silent misbehavior on title-only notes
- **Low risk:** Helper handles both canonical and non-canonical note formats
- **No breaking changes:** Default output formats for all commands remain unchanged

## Out of scope (Phase 2)

These are deferred to a follow-up change to keep this PR focused and non-breaking:

- `read --json` mode outputting `{"body": "...", "bodyOffset": N}`
- `read-attrs --include-body-offset` flag wrapping output in `{"bodyOffset": N, "ranges": [...]}`
