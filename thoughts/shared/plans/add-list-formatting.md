# Plan: Add List Item Formatting Support to notekit-cli

## Research Session

Session: (marker 8409CEC9-A621-4C10-9097-9BA6B6A97106)

## Context

Apple Notes supports three list types as paragraph styles via the `ICTTParagraphStyle` class in the NotesShared framework. Through empirical testing (creating notes with HTML lists via AppleScript and reading back with `read-attrs`), the style values are:

| Style | Meaning |
|-------|---------|
| 0 | Title |
| 1 | Heading |
| 3 | Body (default) |
| 100 | Dash list (unordered/bullet) |
| 102 | Numbered list (ordered) |
| 103 | Checklist |

Each list item is a separate paragraph (newline-delimited). List items use the `indent` property (0-based) for nesting. Each paragraph with a list style gets its own UUID in the `TTStyle`. Numbered lists auto-number based on consecutive paragraphs with style 102 at the same indent level.

### Current State

The codebase already handles list styles in several places:

1. **`set-attr` command** (`cmdSetAttr`, ~line 408) -- accepts `--style <n>` and sets it on a range. This already works for setting style 100 or 102, since it just calls `setStyle:` with whatever integer is passed. However, consumers don't know about these values.

2. **`read-attrs` command** (`cmdReadAttrsNote`, ~line 211) -- already reads and outputs the `style` integer for every range. Styles 100/102 will show up correctly.

3. **`read-structured` command** (`cmdReadStructuredNote`, ~line 509) -- groups text by UUID and outputs style numbers. Currently only special-cases style 103 (checklist) to add `"checked"`. Does not label styles 100/102 with a type name.

4. **`append` and `insert` commands** -- always hardcode style 3 (body) on inserted text. There is no way to append/insert text as a list item.

5. **Usage text** (~line 1362) -- documents styles as `0=title, 1=heading, 3=body, 103=checklist`. Missing 100 (dash) and 102 (numbered).

### What Works Already (No Changes Needed)

- `set-attr --style 100` already works to convert a paragraph to a dash list item
- `set-attr --style 102` already works to convert a paragraph to a numbered list item
- `read-attrs` already returns these style values correctly

### Gap Analysis

The gaps are:
1. **Discoverability** -- Users and agents don't know style 100/102 exist (not in usage text or SKILL.md)
2. **`read-structured` doesn't label list types** -- Only checklist (103) gets special treatment; dash and numbered lists don't get a `"type"` field
3. **No convenience for appending list items** -- `append` always uses style 3. Appending a dash or numbered list item requires: append text, then read-attrs to find offset, then set-attr with style 100/102. A `--style` flag on `append` would simplify this.
4. **`insert` also hardcodes style 3** -- same issue as append
5. **No style input validation** -- `set-attr` accepts any integer for `--style`, including values that may corrupt note data

## What Needs to Change

### Phase 1: Documentation, read-structured labels, and SKILL.md

#### 1.1 Update usage text

**File:** `notekit.m`, function `usage()` (~line 1362)

Change the data model description from:
```
Each range has a style (0=title, 1=heading, 3=body, 103=checklist), indent level,
```
to:
```
Each range has a style (0=title, 1=heading, 3=body, 100=dash-list, 102=numbered-list, 103=checklist), indent level,
```

#### 1.2 Update `read-structured` to label list types (non-breaking)

**File:** `notekit.m`, function `cmdReadStructuredNote()` (~line 509)

Currently at ~line 548, only style 103 gets special treatment:
```objc
if (currentStyle == 103) para[@"checked"] = @(currentTodoDone);
```

Add type labels for all list styles. This is a non-breaking addition (new fields only):
```objc
if (currentStyle == 100) para[@"type"] = @"dash";
if (currentStyle == 102) para[@"type"] = @"numbered";
if (currentStyle == 103) { para[@"type"] = @"checklist"; para[@"checked"] = @(currentTodoDone); }
```

Apply this at both emit sites (~line 548 and ~line 567).

**Important:** Do NOT change the grouping/splitting behavior of `read-structured` in this phase. The existing UUID-based grouping will remain unchanged. Splitting list items by newline is a separate concern that would change output shape for existing consumers and should be addressed in a future change behind an opt-in flag if needed.

#### 1.3 Update SKILL.md

**File:** `.agents/skills/apple-notes/SKILL.md`

The SKILL.md has hardcoded "Basic usage" examples (line 13+) that are independent of the auto-executed `--help` output. Update these examples to:
- Use current flag-based syntax (not positional)
- Add list-style usage examples showing `--style 100`, `--style 102`

### Phase 2: Convenience flags on append/insert with validation

#### 2.0 Add style validation helpers

**File:** `notekit.m`

Add two validation functions:

1. **Strict numeric parsing** -- `integerValue` in Objective-C silently returns `0` for non-numeric strings like `"abc"`. Since `0` is a valid style (title), this would silently corrupt notes. Add a helper that validates the raw string is numeric before conversion:
```objc
static BOOL isStrictInteger(NSString *str, NSInteger *outValue) {
    NSScanner *scanner = [NSScanner scannerWithString:str];
    NSInteger value;
    if ([scanner scanInteger:&value] && [scanner isAtEnd]) {
        if (outValue) *outValue = value;
        return YES;
    }
    return NO;
}
```

2. **Style allowlist**:
```objc
static BOOL isValidStyle(NSInteger style) {
    return style == 0 || style == 1 || style == 3 || style == 100 || style == 102 || style == 103;
}
```

Use both in `cmdAppend`, `cmdInsert`, and `cmdSetAttr`: first check `isStrictInteger` to reject non-numeric input, then check `isValidStyle` to reject unknown style numbers. Error messages should list valid styles.

For `cmdSetAttr`, this is a new validation (currently accepts any integer). Add it there too for consistency.

#### 2.1 Add `--style` flag to `append`

**File:** `notekit.m`, function `cmdAppend()` (~line 629)

Currently hardcodes style 3:
```objc
id bodyStyle = [[ICTTParagraphStyleClass alloc] init];
((void (*)(id, SEL, NSUInteger))objc_msgSend)(bodyStyle, sel_registerName("setStyle:"), 3);
```

Change the function signature to accept an optional style parameter:
```objc
static int cmdAppend(id viewContext, NSString *identifier, NSString *text, NSInteger styleValue)
```

If `styleValue` is provided (non-negative), validate it with `isValidStyle()` and use it instead of 3. Default to 3 when not specified (-1).

**Checklist handling:** When `styleValue == 103`, the function must also create and attach a todo object (with `done=false`), using `ICTTTodoClass` (the class loaded at line 14) with `initWithIdentifier:done:` which requires a UUID string, matching the existing checklist creation pattern at ~line 866-868. The todo must be set on the paragraph style via `setTodo:`. Without this, the checklist circle will not render in Apple Notes. Use the `makeParagraphStyle()` helper (section 2.3) which encapsulates this logic.

**File:** `notekit.m`, `main()` (~line 1550)

Update the `append` command handler to parse and pass `--style` from opts:
```objc
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
```

**Note:** When appending with style 100/102/103, the function should also set a unique UUID on the new paragraph's TTStyle so it gets its own list bullet/number. The current approach of creating a new `ICTTParagraphStyle` instance already does this (each `alloc init` produces a new UUID).

**Leading newline behavior:** `cmdAppend` always prepends `\n` to the text (~line 637). For the first append to an empty note (created with `create-empty`), this creates a leading blank paragraph. This is pre-existing behavior and should not be changed in this PR. If it causes issues with list items specifically, it can be addressed in a follow-up.

#### 2.2 Add `--style` flag to `insert`

**File:** `notekit.m`, function `cmdInsert()` (~line 651)

Same change as append -- accept an optional style parameter, validate it, and use it instead of hardcoded 3. Include the same checklist `TTTodo` handling when `styleValue == 103`.

#### 2.3 Shared helper (recommended refactor)

Extract a shared helper to reduce duplication between append, insert, and set-attr. Use the existing `ICTTTodoClass` (not `TTTodoClass`) with `initWithIdentifier:done:` which requires a UUID, matching the pattern at ~line 866-868:
```objc
static id makeParagraphStyle(NSInteger style) {
    id paraStyle = [[ICTTParagraphStyleClass alloc] init];
    ((void (*)(id, SEL, NSUInteger))objc_msgSend)(paraStyle, sel_registerName("setStyle:"), (NSUInteger)style);
    if (style == 103) {
        id todo = ((id (*)(id, SEL, id, BOOL))objc_msgSend)(
            [ICTTTodoClass alloc],
            sel_registerName("initWithIdentifier:done:"),
            [[NSUUID UUID] UUIDString], NO);
        ((void (*)(id, SEL, id))objc_msgSend)(paraStyle, sel_registerName("setTodo:"), todo);
    }
    return paraStyle;
}
```

This helper creates a properly-configured paragraph style for any valid style value, including the todo object with a unique identifier for checklists. Use it in `cmdAppend`, `cmdInsert`, and optionally `cmdSetAttr`.

#### 2.4 Update usage text for append/insert

**File:** `notekit.m`, function `usage()`

Update:
```
notekit append --id <id> --text <text> [--style <n>]
notekit insert --id <id> --text <text> --position <n> [--style <n>]
```

### Phase 3: Tests

#### 3.1 Add list formatting test to `cmdTest()`

**File:** `notekit.m`, function `cmdTest()` (~line 789)

Add a test that:
1. Creates a note with title text
2. Appends three lines with style 100 (dash list)
3. Appends two lines with style 102 (numbered list)
4. Reads back with `read-attrs` and verifies styles are 100/102
5. Reads back with `read-structured` and verifies:
   - `"type"` field is `"dash"` or `"numbered"` as appropriate
6. Cleans up

#### 3.2 Add checklist via append test

Add a test that:
1. Appends text with `--style 103`
2. Verifies `read-structured` returns `"type": "checklist"` and `"checked": false`
3. Verifies the checklist item renders with a circle in Apple Notes (manual verification step)

#### 3.3 Add style validation test (subprocess-based)

Since `errorExit()` calls `exit(1)` directly, negative-path tests cannot be run in-process within `cmdTest()` without terminating the test harness. Use subprocess invocation instead:

Add a test that uses `NSTask` (or `fork`/`exec`) to run the `notekit` binary as a subprocess:
1. Run `notekit append --id <test-note-id> --text "Bad" --style 999` as a subprocess and verify exit code is non-zero
2. Run `notekit append --id <test-note-id> --text "Bad" --style abc` as a subprocess and verify exit code is non-zero
3. Verify that valid styles (0, 1, 3, 100, 102, 103) do not error (these are already covered by the in-process tests in 3.1 and 3.2)

The subprocess test needs the path to the current `notekit` binary. Use `_NSGetExecutablePath` or pass it via argv[0] to determine the binary path at runtime.

#### 3.4 Multiline append behavior test

Add a test that documents the current behavior when `--text` contains newlines:
1. Append text with embedded `\n` and `--style 100`
2. Read back with `read-attrs` to confirm what style is applied to each paragraph
3. Document whether the style applies to only the first paragraph or all paragraphs

This test is primarily for documenting behavior, not enforcing a specific outcome. If multiline text with list styles produces unexpected results, note it as a known limitation.

## Implementation Order

1. Phase 1.1 + 1.2 + 1.3 (documentation + read-structured labels + SKILL.md) -- smallest diff, non-breaking
2. Phase 2 (append/insert --style with validation and checklist support) -- convenience improvement
3. Phase 3 (tests) -- validate everything works

## Verification Steps

1. Build: `make`
2. Run tests: `./notekit test` -- all existing tests should still pass, plus new list tests
3. Manual test:
   ```bash
   # Create a note
   notekit create-empty --folder Notes
   # Insert title
   notekit insert --id <id> --text "List Test" --position 0
   notekit set-attr --id <id> --offset 0 --length 9 --style 0
   # Append dash list items
   notekit append --id <id> --text "Buy milk" --style 100
   notekit append --id <id> --text "Buy eggs" --style 100
   # Append numbered list items
   notekit append --id <id> --text "Step one" --style 102
   notekit append --id <id> --text "Step two" --style 102
   # Append checklist item
   notekit append --id <id> --text "Check this" --style 103
   # Test invalid style (should error)
   notekit append --id <id> --text "Bad" --style 999
   # Verify
   notekit read-attrs --id <id>
   notekit read-structured --id <id>
   # Open in Apple Notes and confirm lists render correctly
   ```

## Summary of Files to Change

| File | Change |
|------|--------|
| `notekit.m` -- `usage()` | Add styles 100, 102 to data model description; add `--style` to append/insert usage |
| `notekit.m` -- top-level | Add `isValidStyle()` helper and `makeParagraphStyle()` helper |
| `notekit.m` -- `cmdReadStructuredNote()` | Add `"type"` field for list styles (non-breaking, both emit sites) |
| `notekit.m` -- `cmdAppend()` | Accept optional `--style` parameter with validation and checklist support |
| `notekit.m` -- `cmdInsert()` | Accept optional `--style` parameter with validation and checklist support |
| `notekit.m` -- `cmdSetAttr()` | Add style validation |
| `notekit.m` -- `main()` | Parse and validate `--style` for append/insert |
| `notekit.m` -- `cmdTest()` | Add list formatting, checklist, validation, and multiline tests |
| `.agents/skills/apple-notes/SKILL.md` | Update hardcoded examples to use flag syntax and show list styles |

## Estimated Effort

Medium change -- approximately 100-150 lines of new/modified code in `notekit.m` plus SKILL.md updates. The framework already supports these styles; the work is exposing them ergonomically through the CLI with proper validation and checklist support.

## Out of Scope (Future Work)

- **List item splitting in `read-structured`**: Splitting grouped paragraphs by newline for list styles would change output shape. Defer to a future PR, possibly behind `--split-list-items` flag.
- **Leading newline fix for empty notes**: `append` always prepends `\n`. If this causes issues with list items on empty notes, address separately.
- **`--todo-done` flag**: For checklist items, the initial implementation always sets `done=false`. A `--todo-done` flag could be added later if needed.
