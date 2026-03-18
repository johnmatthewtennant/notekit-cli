# Plan: Add Hyperlink Support to notekit-cli

## Research Session

Session: `f9262730-1dfc-4b43-a9a1-6ecea86fa404`
Project path: `~/.claude/projects/-Users-jtennant-Development/f9262730-1dfc-4b43-a9a1-6ecea86fa404.jsonl`

## Context

Apple Notes stores hyperlinks as an `NSLink` attribute on text ranges in the mergeable attributed string. The notekit-cli codebase already:

1. **Reads** `NSLink` in `cmdReadAttrsNote()` (line 252-253 of `notekit.m`) -- outputs it as `"link"` in the JSON
2. **Preserves** `NSLink` during `cmdDuplicate()` (line 364-365) -- copies all attributes including links
3. **Sets** `NSLink` in test code (line 871) -- `@{@"TTStyle": s103, @"NSLink": [NSURL URLWithString:@"https://example.com"]}`

The gap: `cmdSetAttr()` (line 408-450) only sets `TTStyle` attributes (style, indent, todo-done). It builds a single `@{@"TTStyle": style}` dict and calls `setAttributes:range:`. It does not support setting `NSLink`.

## What Needs to Change

### 1. Modify `cmdSetAttr()` to support `--link` (per-run patch strategy)

**File:** `notekit.m`, function `cmdSetAttr` (line 408)

The current implementation builds a single attribute dict and calls `setAttributes:range:` on the entire target range. This is lossy: if the target range spans multiple existing attribute runs (each with different styles, links, strikethrough, etc.), a single `setAttributes:range:` call flattens them all.

**New approach -- per-run patch strategy:**

Instead of building one new attribute dict for the whole range, enumerate existing attribute runs within the target range, clone each run's attributes, apply only the requested deltas, and write back per-run.

```objc
// In cmdSetAttr, after the range check:

BOOL hasStyleOpts = (attrOpts[@"style"] || attrOpts[@"indent"] || attrOpts[@"todo-done"]);
BOOL hasLinkOpt = (attrOpts[@"link"] != nil);

// Validate URL upfront if --link is provided
NSURL *linkURL = nil;
if (hasLinkOpt) {
    NSString *linkStr = attrOpts[@"link"];
    if (linkStr.length > 0) {
        // Validate URL scheme (allow http, https, mailto only)
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

// Disallow zero-length ranges
if (length == 0) {
    errorExit(@"--length must be greater than 0 for set-attr");
}

// Enumerate existing attribute runs in the target range
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

    // Clone existing attrs (preserves TTStrikethrough, attachments, etc.)
    NSMutableDictionary *patchedAttrs = [existingAttrs mutableCopy];

    // Apply style delta if requested
    if (hasStyleOpts) {
        id style = [[ICTTParagraphStyleClass alloc] init];
        // Start from existing style as base, then override requested fields
        id existingStyle = existingAttrs[@"TTStyle"];
        if (existingStyle) {
            // Copy ALL existing values as defaults (style, indent, todo)
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(style, sel_registerName("setStyle:"),
                ((NSInteger (*)(id, SEL))objc_msgSend)(existingStyle, sel_registerName("style")));
            ((void (*)(id, SEL, NSUInteger))objc_msgSend)(style, sel_registerName("setIndent:"),
                ((NSUInteger (*)(id, SEL))objc_msgSend)(existingStyle, sel_registerName("indent")));
            // Preserve existing todo state by default
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
            // Default to checklist style if setting todo and no explicit --style
            if (!attrOpts[@"style"]) {
                ((void (*)(id, SEL, NSUInteger))objc_msgSend)(style, sel_registerName("setStyle:"), 103);
            }
        }
        patchedAttrs[@"TTStyle"] = style;
    }
    // If no style opts, existing TTStyle is preserved via the clone

    // Apply link delta if requested
    if (hasLinkOpt) {
        if (linkURL) {
            patchedAttrs[@"NSLink"] = linkURL;
        } else {
            // Remove link (--link "")
            [patchedAttrs removeObjectForKey:@"NSLink"];
        }
    }
    // If no link opt, existing NSLink is preserved via the clone

    // Write back patched attrs for this sub-range
    ((void (*)(id, SEL, id, NSRange))objc_msgSend)(ms, sel_registerName("setAttributes:range:"),
        patchedAttrs, subRange);

    idx = subEnd;
}
```

This approach:
- **Preserves all existing attributes** (TTStrikethrough, attachments, any future attrs) by cloning the existing dict
- **Handles multi-run ranges** correctly by iterating per attribute run
- **Only overrides explicitly requested keys** (TTStyle if style flags given, NSLink if --link given)
- **Validates URLs** before making any mutations, preventing nil-insertion crashes
- **Enforces URL scheme allowlist** (http, https, mailto) to prevent dangerous schemes like javascript: or file:
- **Rejects zero-length ranges** to avoid invalid attributesAtIndex: calls

### 2. Update usage text

**File:** `notekit.m`, function `usage()` (line 1382)

Add `[--link <url>]` to the `set-attr` usage line:

```
set-attr --id <id> --offset <n> --length <n> [--style <n>] [--indent <n>] [--todo-done true|false] [--link <url>]
```

Also update the data model description (line 1364) -- it already mentions "link" so this is fine as-is.

### 3. Update option parsing

**File:** `notekit.m`, in the `main()` argument parsing section

The argument parser stores all `--key value` pairs in an `opts` dictionary, so `--link <url>` will automatically be available as `opts[@"link"]`. No changes needed to the parser for `--link`.

Drop the `--remove-link` idea entirely. The `--link ""` approach works for link removal, and adding `--remove-link` would require updating the boolean flag parser and handling conflicts with `--link`. Not worth the complexity for this release.

### 4. Update README

**File:** `README.md`

Update the `set-attr` line in the CLI section to include `[--link <url>]`:

```
notekit set-attr --id <id> --offset <n> --length <n> [--style <n>] [--indent <n>] [--todo-done true|false] [--link <url>]
```

### 5. Add tests for hyperlink setting

**File:** `notekit.m`, in `cmdTest()` function

Add a test that covers the following cases:

1. **Set link on a text range** -- Create a note with body text, set `NSLink` via the new code path, read back attributes and verify `NSLink` is present with the correct URL.

2. **Link-only update preserves style** -- Set a link on a range that already has a non-default style (e.g., style=3 body). Verify the style/indent are unchanged after the link is set.

3. **Style-only update preserves existing link** -- Set style on a range that already has a link. Verify the link is still present after the style change.

4. **Remove link** -- Set `--link ""` on a range with a link. Verify `NSLink` is no longer present, and that other attributes (TTStyle) are preserved.

5. **Invalid URL returns error** -- Attempt to set a link with an invalid URL (e.g., `"not a url %%%"`). Verify the function returns an error without mutating the note. (This test may need to be structured differently since `errorExit` calls `exit()` -- consider testing URL validation logic separately or wrapping in a subprocess.)

6. **Rejected URL scheme** -- Attempt to set a link with `javascript:alert(1)`. Verify it is rejected.

7. **Multi-run range preservation** -- Create a range with two different styles (e.g., first half body, second half heading). Set a link across both. Verify both sub-ranges retain their original styles and both get the link.

8. **Link on checklist preserves todo state** -- Create a checklist item (style=103 with todo). Set a link on that range. Verify the checklist style and todoDone state are preserved alongside the new link.

9. **Todo-done update preserves existing link** -- Set a link on a checklist item. Then update `--todo-done true` on the same range. Verify the link is still present after the todo state change.

10. **Style/indent update on checklist preserves todo state** -- Create a checklist item with `--todo-done false`. Then update only `--indent 1` (no `--todo-done`). Verify the todo object and its done state are preserved unchanged.

## Verification Steps

1. Build: `make` (or `clang notekit.m ...`)
2. Run tests: `notekit test`
3. Manual test:
   - Create a note: `notekit create-empty --folder Notes`
   - Insert text: `notekit insert --id <id> --text "Click here for info" --position 0`
   - Set link: `notekit set-attr --id <id> --offset 0 --length 19 --link "https://example.com"`
   - Verify: `notekit read-attrs --id <id>` -- should show `"link": "https://example.com/"` on that range
   - Open the note in Apple Notes and confirm the text is a clickable hyperlink
   - Remove link: `notekit set-attr --id <id> --offset 0 --length 19 --link ""`
   - Verify: `notekit read-attrs --id <id>` -- should no longer show `"link"`

## Summary of Files to Change

| File | Change |
|------|--------|
| `notekit.m` -- `cmdSetAttr()` | Rewrite to per-run patch strategy with `--link` support, URL validation, scheme allowlist |
| `notekit.m` -- `usage()` | Add `--link` to set-attr usage line |
| `notekit.m` -- `cmdTest()` | Add 10 test cases (set link, preserve style, preserve link, remove link, invalid URL, bad scheme, multi-run, checklist+link, todo-done+link, indent preserves todo) |
| `README.md` | Add `--link` to set-attr syntax in CLI section |

## Estimated Effort

Medium change -- approximately 80-100 lines of new/modified code. The per-run patch strategy is more code than the original single-dict approach, but it is significantly safer and avoids data loss edge cases. The framework already supports `NSLink`; we just need to expose it through the `set-attr` CLI command with proper safety guards.
