// Forward declaration: defined later in this file, used by write commands for readback
static NSString *noteToMarkdownString(id note);
static NSString *syncNoteBody(id note);

static id createEmptyNoteInFolder(id viewContext, NSString *folderName) {
    id targetFolder = nil;
    NSArray *folders = fetchFolders(viewContext);
    for (id folder in folders) {
        if (folderMatchesNameOrPath(folder, folderName)) { targetFolder = folder; break; }
    }
    if (!targetFolder) errorExit([NSString stringWithFormat:@"Folder not found: %@", folderName]);

    id note = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), targetFolder);
    if (!note) errorExit(@"Failed to create note");

    ((void (*)(id, SEL))objc_msgSend)(note, sel_registerName("saveNoteData"));
    NSError *error = nil;
    [viewContext save:&error];
    if (error) errorExit([NSString stringWithFormat:@"Save error: %@", error]);
    return note;
}

static NSDictionary *noteLinkDict(id note) {
    NSString *identifier = noteToDict(note)[@"id"];

    Class ICAppURLUtilities = NSClassFromString(@"ICAppURLUtilities");
    if (!ICAppURLUtilities) errorExit(@"ICAppURLUtilities class not available");

    NSURL *appURL = ((id (*)(id, SEL, id))objc_msgSend)(
        ICAppURLUtilities, sel_registerName("appURLForNote:"), note);
    if (!appURL) errorExit(@"Failed to generate note link URL");

    NSString *title = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("titleForLinking"));

    return @{
        @"id": identifier ?: @"",
        @"title": title ?: @"",
        @"url": [appURL absoluteString] ?: @""
    };
}

static int cmdCreateEmpty(id viewContext, NSString *folderName) {
    id note = createEmptyNoteInFolder(viewContext, folderName);
    NSMutableDictionary *result = [noteToDict(note) mutableCopy];
    result[@"content"] = noteToMarkdownString(note);
    printJSON(result);
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


static int cmdCreate(id viewContext, NSString *folderName, NSString *title, NSString *body, NSInteger styleValue) {
    id targetFolder = nil;
    NSArray *folders = fetchFolders(viewContext);
    for (id folder in folders) {
        if (folderMatchesNameOrPath(folder, folderName)) { targetFolder = folder; break; }
    }
    if (!targetFolder) errorExit([NSString stringWithFormat:@"Folder not found: %@", folderName]);

    id note = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), targetFolder);
    if (!note) errorExit(@"Failed to create note");

    id doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
    id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
    NSUInteger oldLen = ((NSUInteger (*)(id, SEL))objc_msgSend)(ms, sel_registerName("length"));

    ((void (*)(id, SEL))objc_msgSend)(note, sel_registerName("beginEditing"));

    // Insert title
    ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(ms, sel_registerName("insertString:atIndex:"), title, oldLen);
    id titleStyle = makeParagraphStyle(0); // style 0 = title
    ((void (*)(id, SEL, id, NSRange))objc_msgSend)(ms, sel_registerName("setAttributes:range:"),
        @{@"TTStyle": titleStyle}, NSMakeRange(oldLen, title.length));

    NSUInteger currentLen = oldLen + title.length;

    if (body) {
        NSString *toInsert = [NSString stringWithFormat:@"\n%@", body];
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(ms, sel_registerName("insertString:atIndex:"), toInsert, currentLen);
        NSInteger actualStyle = (styleValue >= 0) ? styleValue : 3;
        id bodyStyle = makeParagraphStyle(actualStyle);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(ms, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": bodyStyle}, NSMakeRange(currentLen + 1, body.length));
        currentLen += toInsert.length;
    }

    NSInteger delta = (NSInteger)(currentLen - oldLen);
    saveNote(note, viewContext, currentLen, delta);
    NSMutableDictionary *result = [noteToDict(note) mutableCopy];
    result[@"content"] = noteToMarkdownString(note);
    printJSON(result);
    return 0;
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
    // Apply style only to the text portion (oldLen+1), not the leading '\n'.
    // The '\n' is a paragraph terminator for the preceding paragraph and must
    // keep its existing style; styling it as checklist/list creates a blank
    // styled paragraph before the new item.
    ((void (*)(id, SEL, id, NSRange))objc_msgSend)(ms, sel_registerName("setAttributes:range:"),
        @{@"TTStyle": paraStyle}, NSMakeRange(oldLen + 1, text.length));

    saveNote(note, viewContext, oldLen + toInsert.length, toInsert.length);
    printJSON(@{@"id": identifier, @"appended": text, @"content": noteToMarkdownString(note)});
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
    printJSON(@{@"id": identifier, @"inserted": text, @"position": @(position), @"content": noteToMarkdownString(note)});
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
    printJSON(@{@"id": identifier, @"deleted_range": @{@"start": @(start), @"length": @(length)}, @"content": noteToMarkdownString(note)});
    return 0;
}

static int cmdSearchOffset(id viewContext, NSString *identifier, NSString *searchText, BOOL caseInsensitive) {
    if (searchText.length == 0) errorExit(@"--text must not be empty");
    id note = findNoteByID(viewContext, identifier);
    if (!note) errorExit([NSString stringWithFormat:@"Note not found with id: %@", identifier]);

    NSAttributedString *attrStr = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("attributedString"));
    NSString *fullText = [attrStr string];

    NSStringCompareOptions options = caseInsensitive ? NSCaseInsensitiveSearch : 0;
    NSRange found = [fullText rangeOfString:searchText options:options];
    if (found.location == NSNotFound) {
        fprintf(stderr, "Text not found: %s\n", [searchText UTF8String]);
        return 1;
    }

    NSString *matchedText = [fullText substringWithRange:found];
    printJSON(@{
        @"offset": @(found.location),
        @"length": @(found.length),
        @"end": @(found.location + found.length),
        @"text": matchedText
    });
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
    printJSON(@{@"id": identifier, @"replaced": search, @"with": replacement, @"content": noteToMarkdownString(note)});
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
    printJSON(@{@"id": identifier, @"deletedLine": searchText, @"offset": @(paraStart), @"length": @(deleteLen), @"content": noteToMarkdownString(note)});
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

static NSString *colorHexFromSpanTag(NSString *tag) {
    NSRange colorRange = [tag rangeOfString:@"color:" options:NSCaseInsensitiveSearch];
    if (colorRange.location == NSNotFound) return nil;

    NSUInteger i = colorRange.location + colorRange.length;
    while (i < tag.length && [[NSCharacterSet whitespaceCharacterSet] characterIsMember:[tag characterAtIndex:i]]) i++;

    NSUInteger start = i;
    if (i < tag.length && [tag characterAtIndex:i] == '#') i++;
    NSUInteger hexStart = i;
    while (i < tag.length) {
        unichar ch = [tag characterAtIndex:i];
        BOOL isHex = (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F');
        if (!isHex) break;
        i++;
    }
    NSUInteger hexLen = i - hexStart;
    if (hexLen != 3 && hexLen != 6) return nil;

    NSString *candidate = [tag substringWithRange:NSMakeRange(start, i - start)];
    NSString *normalized = nil;
    if (!parseHexColor(candidate, &normalized, nil)) return nil;
    return normalized;
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
    // Embedded \n within a single UUID group represents a soft line break (U+2028),
    // not a paragraph separator.  Convert them so the round-trip preserves the
    // original paragraph count (the <br> / U+2028 path already handles these).
    NSString *paraText = [trimmed stringByReplacingOccurrencesOfString:@"\n" withString:@"\u2028"];

    NSMutableDictionary *para = [NSMutableDictionary dictionary];
    para[@"style"] = @(style);
    para[@"indent"] = @(indent);
    para[@"text"] = paraText;
    if (style == 103) para[@"todoChecked"] = @(todoDone);
    if (uuid) para[@"uuid"] = uuid;

    // Adjust runs: account for leading newlines that were trimmed
    if (runs.count > 0) {
        NSUInteger trimStart = 0;
        while (trimStart < text.length && [text characterAtIndex:trimStart] == '\n') trimStart++;

        NSMutableArray *adjRuns = [NSMutableArray array];
        for (NSDictionary *run in runs) {
            NSUInteger runStart = [run[@"start"] unsignedIntegerValue];
            NSUInteger runLen = [run[@"length"] unsignedIntegerValue];

            // Skip runs entirely in the trimmed leading region
            if (runStart + runLen <= trimStart) continue;

            NSMutableDictionary *adjRun = [NSMutableDictionary dictionary];
            NSUInteger adjStart = (runStart >= trimStart) ? runStart - trimStart : 0;
            NSUInteger adjLen = (runStart >= trimStart) ? runLen : runLen - (trimStart - runStart);
            // Clamp to paraText length
            if (adjStart >= paraText.length) continue;
            if (adjStart + adjLen > paraText.length) adjLen = paraText.length - adjStart;

            adjRun[@"start"] = @(adjStart);
            adjRun[@"length"] = @(adjLen);
            if (run[@"link"]) adjRun[@"link"] = run[@"link"];
            if (run[@"noteLinkDisplayText"]) adjRun[@"noteLinkDisplayText"] = run[@"noteLinkDisplayText"];
            if ([run[@"strikethrough"] boolValue]) adjRun[@"strikethrough"] = @YES;
            if ([run[@"bold"] boolValue]) adjRun[@"bold"] = @YES;
            if ([run[@"italic"] boolValue]) adjRun[@"italic"] = @YES;
            if ([run[@"underline"] boolValue]) adjRun[@"underline"] = @YES;
            if (run[@"color"]) adjRun[@"color"] = run[@"color"];
            [adjRuns addObject:adjRun];
        }
        if (adjRuns.count > 0) para[@"runs"] = adjRuns;
    }

    [paragraphs addObject:para];
}

// Build paragraph model from a note's mergeableString
static NSArray *noteToParaModel(id note) {
    id doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
    id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
    NSAttributedString *attrStr = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("attributedString"));
    NSString *fullText = [attrStr string];
    NSUInteger length = fullText.length;

    if (length == 0) return @[];

    // Build lookup of note-to-note link attachments by text offset
    // ICInlineAttachment objects with typeUTI = com.apple.notes.inlinetextattachment.link
    // Key: text offset (NSNumber), Value: @{@"displayText": ..., @"url": ...}
    NSMutableDictionary *noteLinksByOffset = [NSMutableDictionary dictionary];
    id inlineAtts = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("inlineAttachments"));
    if (inlineAtts) {
        id viewContext = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("managedObjectContext"));
        for (id att in inlineAtts) {
            NSString *typeUTI = [att respondsToSelector:sel_registerName("typeUTI")] ?
                ((id (*)(id, SEL))objc_msgSend)(att, sel_registerName("typeUTI")) : nil;
            if (![typeUTI isEqualToString:@"com.apple.notes.inlinetextattachment.link"]) continue;
            NSString *displayText = [att respondsToSelector:sel_registerName("displayText")] ?
                ((id (*)(id, SEL))objc_msgSend)(att, sel_registerName("displayText")) : nil;
            if (!displayText || displayText.length == 0) continue;
            // Get offset from rangeInNote
            NSRange rng = {0, 0};
            if ([att respondsToSelector:sel_registerName("rangeInNote")]) {
                rng = ((NSRange (*)(id, SEL))objc_msgSend)(att, sel_registerName("rangeInNote"));
            }
            if (rng.length == 0) continue;
            // Search for the target note by title
            NSString *linkURL = nil;
            if (viewContext) {
                NSFetchRequest *req = [[NSFetchRequest alloc] initWithEntityName:@"ICNote"];
                req.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:@[
                    activeNotePredicate(),
                    [NSPredicate predicateWithFormat:@"title == %@", displayText]
                ]];
                req.fetchLimit = 1;
                NSArray *results = [viewContext executeFetchRequest:req error:nil];
                if (results.count > 0) {
                    NSString *targetId = ((id (*)(id, SEL))objc_msgSend)(results[0], sel_registerName("identifier"));
                    if (targetId) {
                        linkURL = [NSString stringWithFormat:@"applenotes://showNote?identifier=%@", targetId];
                    }
                }
            }
            if (linkURL) {
                noteLinksByOffset[@(rng.location)] = @{@"displayText": displayText, @"url": linkURL};
            }
        }
    }

    // Paragraph boundaries are newline characters (U+000A) in the text — not
    // TTStyle UUID changes. Canonical notes often have one TTStyle UUID
    // covering many paragraphs separated by \n; shared/CRDT notes can have
    // many distinct UUIDs within a single paragraph. Splitting on UUID
    // therefore over-fragments shared notes (issue #48) and previously
    // collapsed real paragraph breaks in canonical notes into soft line
    // breaks. Splitting on \n is the semantic truth in either case.
    NSMutableArray *paragraphs = [NSMutableArray array];
    NSMutableString *currentText = [NSMutableString string];
    NSMutableArray *currentRuns = [NSMutableArray array];
    NSString *currentUUID = nil;
    NSInteger currentStyle = 3;
    BOOL currentTodoDone = NO;
    NSUInteger currentIndent = 0;
    NSUInteger runOffsetInPara = 0;
    BOOL paragraphAttrsCaptured = NO;
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

        // Walk chunk segment-by-segment: each segment is text bounded by \n
        // (or chunk start/end). Segments continue the current paragraph;
        // each \n terminates it.
        NSUInteger chunkPos = 0;
        while (chunkPos < chunk.length) {
            NSRange searchRange = NSMakeRange(chunkPos, chunk.length - chunkPos);
            NSRange newlineRange = [chunk rangeOfString:@"\n" options:0 range:searchRange];
            NSUInteger sliceEnd = (newlineRange.location != NSNotFound) ? newlineRange.location : chunk.length;
            NSUInteger sliceLen = sliceEnd - chunkPos;

            // Capture paragraph-level attrs from the first chunk that
            // contributes to this paragraph. Subsequent chunks (which may
            // have different UUIDs in CRDT notes) keep the same paragraph
            // and only add inline attribute info via per-run entries.
            if (!paragraphAttrsCaptured) {
                currentStyle = styleNum;
                currentTodoDone = done;
                currentIndent = indent;
                currentUUID = uuid;
                paragraphAttrsCaptured = YES;
            }

            if (sliceLen > 0) {
                NSString *sliceText = [chunk substringWithRange:NSMakeRange(chunkPos, sliceLen)];
                NSUInteger sliceGlobalOffset = effectiveRange.location + chunkPos;

                NSMutableDictionary *run = [NSMutableDictionary dictionary];
                run[@"start"] = @(runOffsetInPara);
                run[@"length"] = @(sliceLen);
                id nsLink = attrs[@"NSLink"];
                if (nsLink) run[@"link"] = [nsLink description];
                id nsAttachment = attrs[@"NSAttachment"];
                if (nsAttachment && !nsLink && [sliceText isEqualToString:@"￼"]) {
                    NSDictionary *noteLink = noteLinksByOffset[@(sliceGlobalOffset)];
                    if (noteLink) {
                        run[@"link"] = noteLink[@"url"];
                        run[@"noteLinkDisplayText"] = noteLink[@"displayText"];
                    }
                }
                id strikethrough = attrs[@"TTStrikethrough"];
                if (strikethrough) run[@"strikethrough"] = @YES;
                id ttHints = attrs[@"TTHints"];
                if (ttHints) {
                    NSUInteger hints = [ttHints unsignedIntegerValue];
                    if (hints & 1) run[@"bold"] = @YES;
                    if (hints & 2) run[@"italic"] = @YES;
                }
                id ttUnderline = attrs[@"TTUnderline"];
                if (ttUnderline) run[@"underline"] = @YES;
                NSString *colorHex = hexStringForColor(attrs[@"TTColor"] ?: attrs[NSForegroundColorAttributeName]);
                if (colorHex) run[@"color"] = colorHex;
                [currentRuns addObject:run];
                [currentText appendString:sliceText];
                runOffsetInPara += sliceLen;
            }

            if (newlineRange.location == NSNotFound) break;

            // Hit a paragraph boundary: emit current paragraph and reset.
            emitParagraph(paragraphs, currentText, currentRuns,
                currentStyle, currentIndent, currentTodoDone, currentUUID);
            currentText = [NSMutableString string];
            currentRuns = [NSMutableArray array];
            runOffsetInPara = 0;
            paragraphAttrsCaptured = NO;
            chunkPos = newlineRange.location + 1;
        }

        idx = effectiveRange.location + effectiveRange.length;
    }
    // Emit final paragraph if anything was captured.
    if (paragraphAttrsCaptured) {
        emitParagraph(paragraphs, currentText, currentRuns,
            currentStyle, currentIndent, currentTodoDone, currentUUID);
    }

    return paragraphs;
}

// Whether a paragraph style is a list type (dash/bullet, numbered, checklist).
// Used by the blank-line emit mode to keep adjacent list items tight.
static BOOL paraStyleIsList(NSInteger style) {
    return style == 100 || style == 101 || style == 102 || style == 103;
}

// Render paragraph model as markdown.
//
// When blankLineSeparators is NO (the historical default used by
// read-markdown / write-markdown round-trip), paragraphs are joined with a
// single \n; an extra \n is added before headings unless the previous
// paragraph was a blank body paragraph.  Empty body paragraphs emit their
// own \n so the user-supplied blank-line structure is preserved.
//
// When blankLineSeparators is YES (used by the export pipeline), paragraphs
// are joined with a blank line (\n\n) by default — except between two
// adjacent list-style paragraphs, which stay tight (\n) so the result
// renders as a compact list rather than a loose, paragraph-spaced one.
// Empty body paragraphs are skipped because the blank line is already
// implicit in the regular separator.
static NSString *paraModelToMarkdown(NSArray *paragraphs, BOOL blankLineSeparators) {
    NSMutableString *output = [NSMutableString string];
    NSDictionary *lastEmittedPara = nil;

    for (NSUInteger i = 0; i < paragraphs.count; i++) {
        NSDictionary *para = paragraphs[i];
        NSInteger style = [para[@"style"] integerValue];
        NSUInteger indent = [para[@"indent"] unsignedIntegerValue];
        NSString *rawText = para[@"text"];

        if (rawText.length == 0 && style == 3) {
            // Empty body paragraph = blank line
            if (!blankLineSeparators) {
                if (i > 0) [output appendString:@"\n"];
            }
            // In blank-line mode, skip — the separator before the next
            // non-empty paragraph already provides the blank line.
            continue;
        }

        // Decide and emit the separator before this paragraph.
        if (blankLineSeparators) {
            if (lastEmittedPara) {
                NSInteger prevStyle = [lastEmittedPara[@"style"] integerValue];
                if (paraStyleIsList(style) && paraStyleIsList(prevStyle)) {
                    [output appendString:@"\n"];
                } else {
                    [output appendString:@"\n\n"];
                }
            }
        } else {
            // Tight mode: separator goes before code blocks too (the style==4
            // branch below historically had its own "if (i > 0) \n" — that
            // is now consolidated here).
            if (i > 0) {
                [output appendString:@"\n"];
                if (style == 0 || style == 1 || style == 2) {
                    NSDictionary *prev = paragraphs[i - 1];
                    NSInteger prevStyle = [prev[@"style"] integerValue];
                    NSString *prevText = prev[@"text"];
                    BOOL prevWasBlank = (prevStyle == 3 && prevText.length == 0);
                    if (!prevWasBlank) {
                        [output appendString:@"\n"];
                    }
                }
            }
        }

        // Handle code block paragraphs (style 4) — no markdown escaping
        if (style == 4) {
            // Merge consecutive style-4 paragraphs into a single fenced block.
            // Apple Notes stores each line of a code block as its own paragraph;
            // emitting a fence per line would shatter the block (and any literal
            // backtick lines) into many bogus fences. Join them with newlines and
            // emit one fence sized to the combined content.
            NSMutableString *merged = [NSMutableString stringWithString:rawText];
            NSUInteger j = i + 1;
            for (; j < paragraphs.count; j++) {
                if ([paragraphs[j][@"style"] integerValue] != 4) break;
                [merged appendString:@"\n"];
                [merged appendString:(paragraphs[j][@"text"] ?: @"")];
            }
            i = j - 1;  // outer loop's i++ advances past the consumed paragraphs
            // Replace U+2028 line separators back to newlines
            NSString *codeText = [merged stringByReplacingOccurrencesOfString:@"\u2028" withString:@"\n"];
            // Choose fence that won't conflict with code content
            // Count max run of backticks in code text to determine fence length
            NSUInteger maxBacktickRun = 0;
            NSUInteger currentRun = 0;
            for (NSUInteger ci = 0; ci < codeText.length; ci++) {
                if ([codeText characterAtIndex:ci] == '`') {
                    currentRun++;
                    if (currentRun > maxBacktickRun) maxBacktickRun = currentRun;
                } else {
                    currentRun = 0;
                }
            }
            NSUInteger fenceLen = MAX(3, maxBacktickRun + 1);
            NSMutableString *fence = [NSMutableString string];
            for (NSUInteger fi = 0; fi < fenceLen; fi++) [fence appendString:@"`"];

            [output appendString:fence];
            [output appendString:@"\n"];
            if (codeText.length > 0) {
                [output appendString:codeText];
                [output appendString:@"\n"];
            }
            [output appendString:fence];
            lastEmittedPara = para;
            continue;
        }

        // Build formatted text with inline runs
        NSString *formattedText;
        NSArray *runs = para[@"runs"];
        if (runs && runs.count > 0) {
            NSMutableString *fmt = [NSMutableString string];
            NSUInteger cursor = 0;  // Track position in rawText to fill gaps between runs
            for (NSDictionary *run in runs) {
                NSUInteger start = [run[@"start"] unsignedIntegerValue];
                NSUInteger len = [run[@"length"] unsignedIntegerValue];
                // Clamp to rawText bounds
                if (start >= rawText.length) continue;
                if (start + len > rawText.length) len = rawText.length - start;

                // Fill gap between previous run and this one
                if (start > cursor && cursor < rawText.length) {
                    NSUInteger gapLen = MIN(start - cursor, rawText.length - cursor);
                    NSString *gap = [rawText substringWithRange:NSMakeRange(cursor, gapLen)];
                    gap = [gap stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
                    if (gap.length > 0) [fmt appendString:escapeMarkdown(gap)];
                }

                NSString *runText = [rawText substringWithRange:NSMakeRange(start, len)];

                // For note-to-note links, replace ￼ with the display text
                if (run[@"noteLinkDisplayText"]) {
                    runText = run[@"noteLinkDisplayText"];
                }

                // Temporarily replace U+2028 with a placeholder before escaping
                // (escapeMarkdown would escape the < in <br>)
                runText = [runText stringByReplacingOccurrencesOfString:@"\u2028" withString:@"\x01BR\x01"];
                // Strip trailing hard newlines from run text
                while (runText.length > 0 && [runText characterAtIndex:runText.length - 1] == '\n') {
                    runText = [runText substringToIndex:runText.length - 1];
                }
                if (runText.length == 0) { cursor = start + len; continue; }

                NSString *escaped = escapeMarkdown(runText);
                // Restore <br> from placeholder (after escaping so < isn't escaped)
                escaped = [escaped stringByReplacingOccurrencesOfString:@"\x01BR\x01" withString:@"<br>"];

                // Apply link wrapping
                if (run[@"link"]) {
                    NSString *linkURL = run[@"link"];
                    // If display text equals URL (before escaping), output bare URL
                    if ([runText isEqualToString:linkURL] ||
                        [unescapeMarkdown(escaped) isEqualToString:linkURL]) {
                        escaped = linkURL;
                    } else {
                        escaped = [NSString stringWithFormat:@"[%@](%@)", escaped, linkURL];
                    }
                }
                // Apply strikethrough wrapping
                if ([run[@"strikethrough"] boolValue]) {
                    escaped = [NSString stringWithFormat:@"~~%@~~", escaped];
                }
                // Apply underline wrapping
                if ([run[@"underline"] boolValue]) {
                    escaped = [NSString stringWithFormat:@"<u>%@</u>", escaped];
                }
                // Apply bold/italic wrapping
                BOOL isBold = [run[@"bold"] boolValue];
                BOOL isItalic = [run[@"italic"] boolValue];
                if (isBold && isItalic) {
                    escaped = [NSString stringWithFormat:@"***%@***", escaped];
                } else if (isBold) {
                    escaped = [NSString stringWithFormat:@"**%@**", escaped];
                } else if (isItalic) {
                    escaped = [NSString stringWithFormat:@"*%@*", escaped];
                }
                if (run[@"color"]) {
                    escaped = [NSString stringWithFormat:@"<span style=\"color:%@\">%@</span>", run[@"color"], escaped];
                }

                [fmt appendString:escaped];
                cursor = start + len;
            }
            // Fill trailing text after last run
            if (cursor < rawText.length) {
                NSString *trailing = [rawText substringFromIndex:cursor];
                trailing = [trailing stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
                if (trailing.length > 0) [fmt appendString:escapeMarkdown(trailing)];
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
            case 2: // Subheading
                line = [NSString stringWithFormat:@"### %@", formattedText];
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

        [output appendString:line];
        lastEmittedPara = para;
    }

    return output;
}

// Helper: get a note's content as a markdown string (for readback after writes)
static NSString *noteToMarkdownString(id note) {
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

    return paraModelToMarkdown(filtered, NO);
}

static int cmdReadMarkdownNote(id note) {
    NSString *markdown = noteToMarkdownString(note);
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

        // Check for bold+italic ***text***
        if (c == '*' && i + 2 < len && [lineText characterAtIndex:i + 1] == '*' && [lineText characterAtIndex:i + 2] == '*') {
            NSRange closeRange = [lineText rangeOfString:@"***" options:0
                range:NSMakeRange(i + 3, len - i - 3)];
            if (closeRange.location != NSNotFound && closeRange.location > i + 3) {
                NSString *inner = [lineText substringWithRange:NSMakeRange(i + 3, closeRange.location - i - 3)];
                NSMutableString *innerPlain = [NSMutableString string];
                NSMutableArray *innerRuns = [NSMutableArray array];
                parseInlineFormatting(inner, innerPlain, innerRuns);

                NSUInteger baseOffset = outPlainText.length;
                [outPlainText appendString:innerPlain];

                for (NSMutableDictionary *innerRun in innerRuns) {
                    innerRun[@"start"] = @([innerRun[@"start"] unsignedIntegerValue] + baseOffset);
                    innerRun[@"bold"] = @YES;
                    innerRun[@"italic"] = @YES;
                    [outRuns addObject:innerRun];
                }
                if (innerRuns.count == 0 && innerPlain.length > 0) {
                    [outRuns addObject:[@{
                        @"start": @(baseOffset),
                        @"length": @(innerPlain.length),
                        @"bold": @YES,
                        @"italic": @YES
                    } mutableCopy]];
                }
                i = closeRange.location + 3;
                continue;
            }
        }

        // Check for bold **text**
        if (c == '*' && i + 1 < len && [lineText characterAtIndex:i + 1] == '*') {
            // Make sure it's not *** (already handled above)
            if (!(i + 2 < len && [lineText characterAtIndex:i + 2] == '*')) {
                NSRange closeRange = [lineText rangeOfString:@"**" options:0
                    range:NSMakeRange(i + 2, len - i - 2)];
                if (closeRange.location != NSNotFound && closeRange.location > i + 2) {
                    NSString *inner = [lineText substringWithRange:NSMakeRange(i + 2, closeRange.location - i - 2)];
                    NSMutableString *innerPlain = [NSMutableString string];
                    NSMutableArray *innerRuns = [NSMutableArray array];
                    parseInlineFormatting(inner, innerPlain, innerRuns);

                    NSUInteger baseOffset = outPlainText.length;
                    [outPlainText appendString:innerPlain];

                    for (NSMutableDictionary *innerRun in innerRuns) {
                        innerRun[@"start"] = @([innerRun[@"start"] unsignedIntegerValue] + baseOffset);
                        innerRun[@"bold"] = @YES;
                        [outRuns addObject:innerRun];
                    }
                    if (innerRuns.count == 0 && innerPlain.length > 0) {
                        [outRuns addObject:[@{
                            @"start": @(baseOffset),
                            @"length": @(innerPlain.length),
                            @"bold": @YES
                        } mutableCopy]];
                    }
                    i = closeRange.location + 2;
                    continue;
                }
            }
        }

        // Check for italic *text*
        if (c == '*' && !(i + 1 < len && [lineText characterAtIndex:i + 1] == '*')) {
            NSRange closeRange = [lineText rangeOfString:@"*" options:0
                range:NSMakeRange(i + 1, len - i - 1)];
            if (closeRange.location != NSNotFound && closeRange.location > i + 1) {
                // Make sure the closing * is not part of ** or ***
                BOOL isDouble = (closeRange.location + 1 < len && [lineText characterAtIndex:closeRange.location + 1] == '*');
                if (!isDouble) {
                    NSString *inner = [lineText substringWithRange:NSMakeRange(i + 1, closeRange.location - i - 1)];
                    NSMutableString *innerPlain = [NSMutableString string];
                    NSMutableArray *innerRuns = [NSMutableArray array];
                    parseInlineFormatting(inner, innerPlain, innerRuns);

                    NSUInteger baseOffset = outPlainText.length;
                    [outPlainText appendString:innerPlain];

                    for (NSMutableDictionary *innerRun in innerRuns) {
                        innerRun[@"start"] = @([innerRun[@"start"] unsignedIntegerValue] + baseOffset);
                        innerRun[@"italic"] = @YES;
                        [outRuns addObject:innerRun];
                    }
                    if (innerRuns.count == 0 && innerPlain.length > 0) {
                        [outRuns addObject:[@{
                            @"start": @(baseOffset),
                            @"length": @(innerPlain.length),
                            @"italic": @YES
                        } mutableCopy]];
                    }
                    i = closeRange.location + 1;
                    continue;
                }
            }
        }

        // Check for strikethrough ~~text~~
        if (c == '~' && i + 1 < len && [lineText characterAtIndex:i + 1] == '~') {
            NSRange closeRange = [lineText rangeOfString:@"~~" options:0
                range:NSMakeRange(i + 2, len - i - 2)];
            if (closeRange.location != NSNotFound) {
                NSString *inner = [lineText substringWithRange:NSMakeRange(i + 2, closeRange.location - i - 2)];
                // Recursively parse inner text for links and other formatting
                NSMutableString *innerPlain = [NSMutableString string];
                NSMutableArray *innerRuns = [NSMutableArray array];
                parseInlineFormatting(inner, innerPlain, innerRuns);

                NSUInteger baseOffset = outPlainText.length;
                [outPlainText appendString:innerPlain];

                // Add strikethrough to all inner runs
                for (NSMutableDictionary *innerRun in innerRuns) {
                    innerRun[@"start"] = @([innerRun[@"start"] unsignedIntegerValue] + baseOffset);
                    innerRun[@"strikethrough"] = @YES;
                    [outRuns addObject:innerRun];
                }
                // If no inner runs, create one for the whole text
                if (innerRuns.count == 0 && innerPlain.length > 0) {
                    [outRuns addObject:[@{
                        @"start": @(baseOffset),
                        @"length": @(innerPlain.length),
                        @"strikethrough": @YES
                    } mutableCopy]];
                }
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

        // Check for bare URL (http://, https://, mailto:)
        if ((c == 'h' || c == 'm') && i + 4 < len) {
            NSString *rest = [lineText substringFromIndex:i];
            NSString *scheme = nil;
            if ([rest hasPrefix:@"https://"]) scheme = @"https://";
            else if ([rest hasPrefix:@"http://"]) scheme = @"http://";
            else if ([rest hasPrefix:@"mailto:"]) scheme = @"mailto:";

            if (scheme) {
                // Find end of URL: consume until whitespace or end of string
                // Track balanced parentheses so URLs like https://en.wikipedia.org/wiki/Foo_(bar) work
                NSUInteger urlEnd = i + scheme.length;
                NSInteger parenDepth = 0;
                while (urlEnd < len) {
                    unichar uc = [lineText characterAtIndex:urlEnd];
                    if (uc == ' ' || uc == '\t' || uc == '\n' || uc == '\r' ||
                        uc == ']' || uc == '>' || uc == 0xFF0C || uc == 0x3001) break;
                    if (uc == '(') { parenDepth++; }
                    else if (uc == ')') {
                        if (parenDepth <= 0) break;  // unbalanced closing paren = end of URL
                        parenDepth--;
                    }
                    urlEnd++;
                }
                // Strip trailing punctuation and escapes that are likely not part of the URL
                while (urlEnd > i + scheme.length) {
                    unichar last = [lineText characterAtIndex:urlEnd - 1];
                    if (last == '.' || last == ',' || last == ';' || last == ':' ||
                        last == '!' || last == '?' || last == '\\') {
                        urlEnd--;
                    } else {
                        break;
                    }
                }
                NSString *urlStr = [lineText substringWithRange:NSMakeRange(i, urlEnd - i)];
                NSURL *url = [NSURL URLWithString:urlStr];
                if (url && isAllowedLinkScheme(url)) {
                    NSUInteger start = outPlainText.length;
                    [outPlainText appendString:urlStr];
                    [outRuns addObject:[@{
                        @"start": @(start),
                        @"length": @(urlStr.length),
                        @"link": urlStr
                    } mutableCopy]];
                    i = urlEnd;
                    continue;
                }
            }
        }

        // Check for <u>text</u> (underline)
        if ((c == '<') && i + 2 < len) {
            NSString *rest = [lineText substringFromIndex:i];
            if ([rest hasPrefix:@"<span"]) {
                NSRange openEnd = [lineText rangeOfString:@">" options:0 range:NSMakeRange(i, len - i)];
                if (openEnd.location != NSNotFound) {
                    NSString *openTag = [lineText substringWithRange:NSMakeRange(i, openEnd.location - i + 1)];
                    NSString *colorHex = colorHexFromSpanTag(openTag);
                    NSRange closeTag = [lineText rangeOfString:@"</span>" options:NSCaseInsensitiveSearch
                        range:NSMakeRange(openEnd.location + 1, len - openEnd.location - 1)];
                    if (colorHex && closeTag.location != NSNotFound) {
                        NSString *inner = [lineText substringWithRange:NSMakeRange(openEnd.location + 1, closeTag.location - openEnd.location - 1)];
                        NSMutableString *innerPlain = [NSMutableString string];
                        NSMutableArray *innerRuns = [NSMutableArray array];
                        parseInlineFormatting(inner, innerPlain, innerRuns);

                        NSUInteger baseOffset = outPlainText.length;
                        [outPlainText appendString:innerPlain];

                        for (NSMutableDictionary *innerRun in innerRuns) {
                            innerRun[@"start"] = @([innerRun[@"start"] unsignedIntegerValue] + baseOffset);
                            innerRun[@"color"] = colorHex;
                            [outRuns addObject:innerRun];
                        }
                        if (innerRuns.count == 0 && innerPlain.length > 0) {
                            [outRuns addObject:[@{
                                @"start": @(baseOffset),
                                @"length": @(innerPlain.length),
                                @"color": colorHex
                            } mutableCopy]];
                        }
                        i = closeTag.location + 7;
                        continue;
                    }
                }
            }
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
    BOOL inCodeBlock = NO;
    NSMutableString *codeBlockAccumulator = nil;
    unichar fenceChar = 0;         // '`' or '~'
    NSUInteger fenceLength = 0;    // length of opening fence
    BOOL codeBlockFirstLine = YES;

    for (NSUInteger lineIdx = 0; lineIdx < lines.count; lineIdx++) {
        NSString *line = lines[lineIdx];

        // Check for fenced code block delimiter (``` or ~~~ optionally followed by info string)
        if (!inCodeBlock) {
            // Opening fence: 3+ consecutive backticks or tildes, optional info string
            NSUInteger runLen = 0;
            unichar fc = 0;
            if (line.length >= 3) {
                fc = [line characterAtIndex:0];
                if (fc == '`' || fc == '~') {
                    runLen = 1;
                    while (runLen < line.length && [line characterAtIndex:runLen] == fc) runLen++;
                }
            }
            if (runLen >= 3) {
                // For backtick fences, info string must not contain backticks
                BOOL validOpener = YES;
                if (fc == '`') {
                    NSString *rest = [line substringFromIndex:runLen];
                    if ([rest rangeOfString:@"`"].location != NSNotFound) validOpener = NO;
                }
                if (validOpener) {
                    inCodeBlock = YES;
                    fenceChar = fc;
                    fenceLength = runLen;
                    codeBlockAccumulator = [NSMutableString string];
                    codeBlockFirstLine = YES;
                    continue;
                }
            }
        } else {
            // Closing fence: same char, >= opening length, only optional trailing spaces
            NSUInteger runLen = 0;
            if (line.length >= fenceLength && [line characterAtIndex:0] == fenceChar) {
                runLen = 1;
                while (runLen < line.length && [line characterAtIndex:runLen] == fenceChar) runLen++;
                if (runLen >= fenceLength) {
                    // Rest must be only spaces
                    NSString *rest = [line substringFromIndex:runLen];
                    NSString *trimmed = [rest stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    if (trimmed.length == 0) {
                        // Closing fence — emit accumulated code block as style 4 paragraph
                        inCodeBlock = NO;
                        NSMutableDictionary *para = [NSMutableDictionary dictionary];
                        para[@"style"] = @(4);
                        para[@"indent"] = @(0);
                        para[@"text"] = [codeBlockAccumulator copy];
                        [paragraphs addObject:para];
                        codeBlockAccumulator = nil;
                        fenceChar = 0;
                        fenceLength = 0;
                        continue;
                    }
                }
            }
        }

        // Inside a code block — accumulate lines with embedded newlines
        if (inCodeBlock) {
            if (!codeBlockFirstLine) {
                [codeBlockAccumulator appendString:@"\n"];
            }
            [codeBlockAccumulator appendString:line];
            codeBlockFirstLine = NO;
            continue;
        }

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
        // Check for subheading: ### Text
        else if ([line hasPrefix:@"### "]) {
            style = 2;
            textContent = [line substringFromIndex:4];
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

        // Convert <br> variants to U+2028 (soft line break) for write round-trip fidelity
        if (textContent) {
            textContent = [textContent stringByReplacingOccurrencesOfString:@"<br />" withString:@"\u2028"];
            textContent = [textContent stringByReplacingOccurrencesOfString:@"<br/>" withString:@"\u2028"];
            textContent = [textContent stringByReplacingOccurrencesOfString:@"<br>" withString:@"\u2028"];
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

    // Handle unclosed code block (missing closing ```)
    if (inCodeBlock && codeBlockAccumulator) {
        NSMutableDictionary *para = [NSMutableDictionary dictionary];
        para[@"style"] = @(4);
        para[@"indent"] = @(0);
        para[@"text"] = [codeBlockAccumulator copy];
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
        if ([ra[@"bold"] boolValue] != [rb[@"bold"] boolValue]) return NO;
        if ([ra[@"italic"] boolValue] != [rb[@"italic"] boolValue]) return NO;
        if ([ra[@"underline"] boolValue] != [rb[@"underline"] boolValue]) return NO;
        if (![ra[@"color"] isEqual:rb[@"color"]] &&
            !(ra[@"color"] == nil && rb[@"color"] == nil)) return NO;
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

// Convert para model text (which uses U+2028 for soft line breaks) to Apple Notes
// storage format (which uses \n within a single attribute range).
static NSString *storageTextForPara(NSString *text) {
    return [text stringByReplacingOccurrencesOfString:@"\u2028" withString:@"\n"];
}

// Apply inline runs (links, bold, italic, etc.) to a paragraph in the mergeableString.
// pos: start of paragraph text in the mergeableString
// textLen: length of the paragraph text (excluding trailing \n)
// baseAttrs: the base paragraph attributes (TTStyle, etc.)
// newPara: the paragraph model dict containing "runs" array
// note, viewContext: for creating note-link inline attachments
// ms: the mergeableString
// Returns the cumulative delta from note-link FFFC replacements
static NSInteger applyInlineRuns(id ms, id note, id viewContext, NSDictionary *newPara,
                                  NSUInteger pos, NSUInteger textLen, NSDictionary *baseAttrs) {
    NSArray *runs = newPara[@"runs"];
    if (!runs) return 0;

    NSInteger runDelta = 0;
    for (NSDictionary *run in runs) {
        NSUInteger runStart = [run[@"start"] unsignedIntegerValue] + runDelta;
        NSUInteger runLen = [run[@"length"] unsignedIntegerValue];
        if (runStart + runLen > (NSUInteger)((NSInteger)textLen + runDelta)) continue;

        NSMutableDictionary *runAttrs = [baseAttrs mutableCopy];
        if (run[@"link"]) {
            NSURL *rawURL = [NSURL URLWithString:run[@"link"]];
            if (rawURL && [[rawURL scheme] isEqualToString:@"applenotes"]) {
                NSString *targetId = nil;
                for (NSURLQueryItem *qi in [[NSURLComponents componentsWithURL:rawURL resolvingAgainstBaseURL:NO] queryItems]) {
                    if ([qi.name isEqualToString:@"identifier"]) { targetId = qi.value; break; }
                }
                if (targetId) {
                    id targetNote = findNoteByID(viewContext, targetId);
                    if (targetNote) {
                        Class ICInlineAttachmentClass = NSClassFromString(@"ICInlineAttachment");
                        if (ICInlineAttachmentClass) {
                            // Replace display text with U+FFFC
                            ((void (*)(id, SEL, NSRange))objc_msgSend)(ms, sel_registerName("deleteCharactersInRange:"),
                                NSMakeRange(pos + runStart, runLen));
                            ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(ms, sel_registerName("insertString:atIndex:"),
                                @"\uFFFC", pos + runStart);
                            NSInteger delta = 1 - (NSInteger)runLen;
                            runDelta += delta;
                            runLen = 1;

                            NSString *attUUID = [[NSUUID UUID] UUIDString];
                            id attachment = ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(
                                ICInlineAttachmentClass,
                                sel_registerName("newLinkAttachmentWithIdentifier:toNote:fromNote:parentAttachment:"),
                                attUUID, targetNote, note, nil);
                            if (attachment) {
                                ((void (*)(id, SEL, id))objc_msgSend)(note, sel_registerName("addInlineAttachmentsObject:"), attachment);
                                if (ICTTAttachmentClass) {
                                    id ttAtt = [[ICTTAttachmentClass alloc] init];
                                    ((void (*)(id, SEL, id))objc_msgSend)(ttAtt, sel_registerName("setAttachmentIdentifier:"), attUUID);
                                    ((void (*)(id, SEL, id))objc_msgSend)(ttAtt, sel_registerName("setAttachmentUTI:"), @"com.apple.notes.inlinetextattachment.link");
                                    runAttrs[@"NSAttachment"] = ttAtt;
                                }
                            }
                        } else {
                            Class ICAppURLUtilities = NSClassFromString(@"ICAppURLUtilities");
                            NSURL *nativeURL = ICAppURLUtilities ? ((id (*)(id, SEL, id))objc_msgSend)(ICAppURLUtilities, sel_registerName("appURLForNote:"), targetNote) : nil;
                            if (nativeURL) runAttrs[@"NSLink"] = nativeURL;
                        }
                    }
                }
            } else if (rawURL) {
                runAttrs[@"NSLink"] = rawURL;
            }
        }
        if ([run[@"strikethrough"] boolValue]) runAttrs[@"TTStrikethrough"] = @1;
        if (run[@"color"]) {
            NSColor *colorValue = nil;
            if (parseHexColor(run[@"color"], nil, &colorValue)) {
                runAttrs[@"TTColor"] = (__bridge id)[colorValue CGColor];
            }
        }
        {
            NSUInteger hints = 0;
            if ([run[@"bold"] boolValue]) hints |= 1;
            if ([run[@"italic"] boolValue]) hints |= 2;
            if (hints > 0) runAttrs[@"TTHints"] = @(hints);
        }
        if ([run[@"underline"] boolValue]) runAttrs[@"TTUnderline"] = @1;
        NSRange runRange = NSMakeRange(pos + runStart, runLen);
        if (run[@"color"]) {
            setMergeableAttributesPreservingText(ms, runAttrs, runRange);
        } else {
            ((void (*)(id, SEL, id, NSRange))objc_msgSend)(ms, sel_registerName("setAttributes:range:"),
                runAttrs, runRange);
        }
    }
    return runDelta;
}

static BOOL modelHasColorRuns(NSArray *model) {
    for (NSDictionary *para in model) {
        for (NSDictionary *run in para[@"runs"]) {
            if (run[@"color"]) return YES;
        }
    }
    return NO;
}

static void applyColorRunsFromModel(id note, id viewContext, NSArray *model) {
    if (!modelHasColorRuns(model)) return;

    id doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
    id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
    NSUInteger msLen = ((NSUInteger (*)(id, SEL))objc_msgSend)(ms, sel_registerName("length"));
    id msAS = ((id (*)(id, SEL))objc_msgSend)(ms, sel_registerName("string"));
    NSString *msStr = (msAS && [msAS respondsToSelector:@selector(string)]) ? [msAS string] : (NSString *)msAS;
    if (!msStr) return;

    ((void (*)(id, SEL))objc_msgSend)(note, sel_registerName("beginEditing"));

    NSUInteger searchStart = 0;
    for (NSUInteger i = 0; i < model.count; i++) {
        NSDictionary *para = model[i];
        NSString *text = storageTextForPara(para[@"text"] ?: @"");
        NSUInteger boundedSearchStart = MIN(searchStart, msStr.length);
        NSRange paraSearchRange = NSMakeRange(boundedSearchStart, msStr.length - boundedSearchStart);
        NSRange paraRange = [msStr rangeOfString:text options:0 range:paraSearchRange];
        if (paraRange.location == NSNotFound) {
            searchStart = MIN(msStr.length, searchStart + text.length + 1);
            continue;
        }
        for (NSDictionary *run in para[@"runs"]) {
            NSString *colorHex = run[@"color"];
            if (!colorHex) continue;

            NSColor *colorValue = nil;
            if (!parseHexColor(colorHex, nil, &colorValue)) continue;

            NSUInteger runStart = paraRange.location + [run[@"start"] unsignedIntegerValue];
            NSUInteger runLen = [run[@"length"] unsignedIntegerValue];
            if (runLen == 0 || runStart >= msLen || runStart + runLen > msLen) continue;

            NSUInteger idx = runStart;
            NSUInteger end = runStart + runLen;
            while (idx < end) {
                NSRange effectiveRange;
                NSDictionary *existingAttrs = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
                    ms, sel_registerName("attributesAtIndex:effectiveRange:"), idx, &effectiveRange);
                NSUInteger segStart = MAX(effectiveRange.location, runStart);
                NSUInteger segEnd = MIN(effectiveRange.location + effectiveRange.length, end);
                if (segEnd <= segStart) break;

                NSMutableDictionary *patchedAttrs = [existingAttrs mutableCopy];
                if (!patchedAttrs) patchedAttrs = [NSMutableDictionary dictionary];
                patchedAttrs[@"TTColor"] = (__bridge id)[colorValue CGColor];
                setMergeableAttributesPreservingText(ms, patchedAttrs, NSMakeRange(segStart, segEnd - segStart));
                idx = segEnd;
            }
        }
        searchStart = paraRange.location + paraRange.length;
    }

    ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
        note, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, msLen), 0);
    ((void (*)(id, SEL))objc_msgSend)(note, sel_registerName("endEditing"));
    ((void (*)(id, SEL))objc_msgSend)(note, sel_registerName("saveNoteData"));
    NSError *error = nil;
    [viewContext save:&error];
    if (error) errorExit([NSString stringWithFormat:@"Save error: %@", error]);
}

// Full-replace write: clear note content and rewrite from scratch.
// This avoids diff algorithm issues that cause corruption on repeated writes.
static int cmdWriteMarkdownFullReplace(id note, id viewContext, NSString *identifier,
                                        NSArray *newModel, BOOL dryRun, BOOL backup) {
    // For dry-run, compute a diff summary to show what would change
    if (dryRun) {
        NSArray *oldModel = noteToParaModel(note);
        NSMutableArray *filteredOld = [NSMutableArray array];
        BOOL foundContent = NO;
        for (NSDictionary *para in oldModel) {
            if (!foundContent && [para[@"text"] length] == 0) continue;
            foundContent = YES;
            [filteredOld addObject:para];
        }

        NSMutableArray *oldSigs = [NSMutableArray array];
        for (NSDictionary *p in filteredOld) [oldSigs addObject:paraSignature(p)];
        NSMutableArray *newSigs = [NSMutableArray array];
        for (NSDictionary *p in newModel) [newSigs addObject:paraSignature(p)];

        NSArray *lcsPairs = computeLCS(oldSigs, newSigs);
        NSMutableSet *matchedOld = [NSMutableSet set];
        NSMutableSet *matchedNew = [NSMutableSet set];
        for (NSArray *pair in lcsPairs) {
            [matchedOld addObject:pair[0]];
            [matchedNew addObject:pair[1]];
        }

        NSUInteger deleted = 0, inserted = 0, modified = 0;
        NSMutableArray *mutations = [NSMutableArray array];
        for (NSUInteger i = 0; i < filteredOld.count; i++) {
            if (![matchedOld containsObject:@(i)]) {
                deleted++;
                [mutations addObject:@{@"type": @"delete", @"oldIndex": @(i),
                    @"oldText": filteredOld[i][@"text"]}];
            }
        }
        for (NSUInteger j = 0; j < newModel.count; j++) {
            if ([matchedNew containsObject:@(j)]) {
                NSArray *pair = nil;
                for (NSArray *p in lcsPairs) {
                    if ([p[1] isEqual:@(j)]) { pair = p; break; }
                }
                if (pair) {
                    NSUInteger oldIdx = [pair[0] unsignedIntegerValue];
                    if (oldIdx < filteredOld.count && !paragraphsEqual(filteredOld[oldIdx], newModel[j])) {
                        modified++;
                        [mutations addObject:@{@"type": @"modify", @"oldIndex": @(oldIdx),
                            @"newIndex": @(j), @"oldText": filteredOld[oldIdx][@"text"],
                            @"newText": newModel[j][@"text"]}];
                    }
                }
            } else {
                inserted++;
                [mutations addObject:@{@"type": @"insert", @"newIndex": @(j),
                    @"text": newModel[j][@"text"]}];
            }
        }

        NSUInteger unchanged = filteredOld.count - deleted - modified;
        NSMutableDictionary *summary = [NSMutableDictionary dictionary];
        summary[@"id"] = identifier;
        summary[@"mode"] = @"replace";
        summary[@"paragraphsUnchanged"] = @(unchanged);
        summary[@"paragraphsModified"] = @(modified);
        summary[@"paragraphsInserted"] = @(inserted);
        summary[@"paragraphsDeleted"] = @(deleted);
        summary[@"mutations"] = mutations;
        printJSON(summary);
        return 0;
    }

    // Backup if requested
    if (backup) {
        NSString *title = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("title"));
        NSString *backupTitle = [NSString stringWithFormat:@"[backup] %@", title ?: @"Untitled"];
        cmdDuplicate(viewContext, identifier, backupTitle);
        note = findNoteByID(viewContext, identifier);
    }

    id doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
    id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
    NSUInteger origMsLen = ((NSUInteger (*)(id, SEL))objc_msgSend)(ms, sel_registerName("length"));

    // Remove existing inline attachments (note links) before clearing content
    id inlineAttachments = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("inlineAttachments"));
    if (inlineAttachments && [inlineAttachments count] > 0) {
        NSSet *inlineAttSet = [inlineAttachments copy];
        for (id ia in inlineAttSet) {
            [viewContext deleteObject:ia];
        }
    }

    ((void (*)(id, SEL))objc_msgSend)(note, sel_registerName("beginEditing"));

    // Delete all existing content
    if (origMsLen > 0) {
        ((void (*)(id, SEL, NSRange))objc_msgSend)(ms, sel_registerName("deleteCharactersInRange:"),
            NSMakeRange(0, origMsLen));
    }

    // Build the full text string from the new model
    NSMutableString *fullText = [NSMutableString string];
    for (NSUInteger i = 0; i < newModel.count; i++) {
        [fullText appendString:newModel[i][@"text"]];
        if (i < newModel.count - 1) [fullText appendString:@"\n"];
    }

    // Insert all content at once
    if (fullText.length > 0) {
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(ms, sel_registerName("insertString:atIndex:"),
            fullText, 0);
    }

    // Apply styles and inline runs paragraph by paragraph
    NSUInteger offset = 0;
    NSInteger totalRunDelta = 0;
    for (NSUInteger i = 0; i < newModel.count; i++) {
        NSDictionary *para = newModel[i];
        NSString *text = para[@"text"];
        NSUInteger textLen = text.length;
        // Paragraph range includes trailing \n except for the last paragraph
        NSUInteger paraLen = textLen + (i < newModel.count - 1 ? 1 : 0);

        NSInteger style = [para[@"style"] integerValue];
        NSUInteger indent = [para[@"indent"] unsignedIntegerValue];

        id paraStyle = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(paraStyle, sel_registerName("setStyle:"), (NSUInteger)style);
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(paraStyle, sel_registerName("setIndent:"), indent);

        if (style == 103) {
            BOOL checked = [para[@"todoChecked"] boolValue];
            id todo = ((id (*)(id, SEL, id, BOOL))objc_msgSend)(
                [ICTTTodoClass alloc], sel_registerName("initWithIdentifier:done:"), [NSUUID UUID], checked);
            ((void (*)(id, SEL, id))objc_msgSend)(paraStyle, sel_registerName("setTodo:"), todo);
        }

        NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
        attrs[@"TTStyle"] = paraStyle;

        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(ms, sel_registerName("setAttributes:range:"),
            attrs, NSMakeRange(offset + totalRunDelta, paraLen));

        // Apply inline runs (links, bold, italic, etc.)
        NSInteger runDelta = applyInlineRuns(ms, note, viewContext, para,
            offset + totalRunDelta, textLen, attrs);
        totalRunDelta += runDelta;

        offset += paraLen;
    }

    // Save
    NSInteger totalDelta = (NSInteger)fullText.length + totalRunDelta - (NSInteger)origMsLen;
    NSUInteger newLen = (NSUInteger)((NSInteger)origMsLen + totalDelta);
    ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
        note, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, newLen), totalDelta);
    ((void (*)(id, SEL))objc_msgSend)(note, sel_registerName("endEditing"));
    ((void (*)(id, SEL))objc_msgSend)(note, sel_registerName("saveNoteData"));
    NSError *error = nil;
    [viewContext save:&error];
    if (error) {
        errorExit([NSString stringWithFormat:@"Save error: %@", error]);
    }
    applyColorRunsFromModel(note, viewContext, newModel);

    // Print summary with readback
    NSMutableDictionary *summary = [NSMutableDictionary dictionary];
    summary[@"id"] = identifier;
    summary[@"mode"] = @"replace";
    summary[@"paragraphsWritten"] = @(newModel.count);
    summary[@"content"] = noteToMarkdownString(note);
    printJSON(summary);
    return 0;
}

// Diff-based write: compute LCS diff and apply incremental mutations.
// Preserved for backward compatibility via --diff flag.
static int cmdWriteMarkdownDiff(id note, id viewContext, NSString *identifier,
                                 NSArray *newModel, BOOL dryRun, BOOL backup) {
    NSArray *oldModel = noteToParaModel(note);

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
    for (NSUInteger j = 0; j < newModel.count; j++) {
        if ([matchedNew containsObject:@(j)]) {
            // Find the corresponding pair
            NSArray *pair = nil;
            for (NSArray *p in lcsPairs) {
                if ([p[1] isEqual:@(j)]) { pair = p; break; }
            }
            if (!pair) continue;
            NSUInteger oldIdx = [pair[0] unsignedIntegerValue];
            if (oldIdx >= filteredOld.count) continue;
            if (!paragraphsEqual(filteredOld[oldIdx], newModel[j])) {
                [mutations addObject:@{@"type": @"modify", @"oldIndex": @(oldIdx),
                    @"newIndex": @(j), @"oldText": filteredOld[oldIdx][@"text"],
                    @"newText": newModel[j][@"text"]}];
            }
        } else {
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
    summary[@"mode"] = @"diff";
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
        note = findNoteByID(viewContext, identifier);
    }

    // Apply mutations directly to the mergeableString
    id doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
    id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
    NSAttributedString *attrStr = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("attributedString"));
    NSString *fullText = [attrStr string];
    NSUInteger msLen = ((NSUInteger (*)(id, SEL))objc_msgSend)(ms, sel_registerName("length"));

    // Compute paragraph offsets in the full text
    NSMutableArray *paraRanges = [NSMutableArray array];
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
    NSUInteger leadingSkipped = 0;
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
    NSMutableArray *ops = [NSMutableArray array];

    for (NSDictionary *m in mutations) {
        if ([m[@"type"] isEqualToString:@"delete"]) {
            NSUInteger oldIdx = [m[@"oldIndex"] unsignedIntegerValue];
            NSUInteger paraIdx = oldIdx + leadingSkipped;
            if (paraIdx >= paraRanges.count) continue;
            NSUInteger paraStart = [paraRanges[paraIdx][0] unsignedIntegerValue];
            NSUInteger paraLen = [paraRanges[paraIdx][1] unsignedIntegerValue];
            NSUInteger deleteStart = paraStart;
            NSUInteger deleteLen = paraLen;
            if (deleteStart + deleteLen < fullText.length) {
                deleteLen++;
            } else if (deleteStart > 0) {
                deleteStart--;
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
            [ops addObject:@{@"op": @"insert", @"pos": @(insertPos), @"newPara": newModel[newIdx], @"newIndex": @(newIdx)}];
        }
    }

    // Sort operations by position descending (bottom to top)
    [ops sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult cmp = [b[@"pos"] compare:a[@"pos"]];
        if (cmp != NSOrderedSame) return cmp;
        int prioA = [a[@"op"] isEqualToString:@"delete"] ? 0 : ([a[@"op"] isEqualToString:@"modify"] ? 1 : 2);
        int prioB = [b[@"op"] isEqualToString:@"delete"] ? 0 : ([b[@"op"] isEqualToString:@"modify"] ? 1 : 2);
        if (prioA != prioB) return prioA < prioB ? NSOrderedAscending : NSOrderedDescending;
        if (prioA == 2) return [b[@"newIndex"] compare:a[@"newIndex"]];
        return NSOrderedSame;
    }];

    NSInteger cumulativeDelta = 0;
    BOOL mutationFailed = NO;
    for (NSDictionary *op in ops) {
        NSString *opType = op[@"op"];
        NSUInteger pos = [op[@"pos"] unsignedIntegerValue];

        @try {

        if ([opType isEqualToString:@"delete"]) {
            NSUInteger deleteLen = [op[@"len"] unsignedIntegerValue];
            NSUInteger currentMsLenForDelete = (NSUInteger)((NSInteger)msLen + cumulativeDelta);
            if (pos + deleteLen > currentMsLenForDelete) {
                fprintf(stderr, "error: cannot apply delete mutation at pos %lu len %lu (exceeds string length %lu)\n",
                    (unsigned long)pos, (unsigned long)deleteLen, (unsigned long)currentMsLenForDelete);
                mutationFailed = YES;
                break;
            }
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
                NSString *writeText = storageTextForPara(newText);
                ((void (*)(id, SEL, NSRange))objc_msgSend)(ms, sel_registerName("deleteCharactersInRange:"),
                    NSMakeRange(pos, paraLen));
                ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(ms, sel_registerName("insertString:atIndex:"),
                    writeText, pos);
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
                [patchedAttrs removeObjectForKey:@"TTHints"];
                [patchedAttrs removeObjectForKey:@"TTUnderline"];
                [patchedAttrs removeObjectForKey:@"TTColor"];
                [patchedAttrs removeObjectForKey:NSForegroundColorAttributeName];

                ((void (*)(id, SEL, id, NSRange))objc_msgSend)(ms, sel_registerName("setAttributes:range:"),
                    patchedAttrs, NSMakeRange(pos, paraLen));

                NSInteger runDelta = applyInlineRuns(ms, note, viewContext, newPara, pos, paraLen, patchedAttrs);
                cumulativeDelta += runDelta;
            }
        }
        else if ([opType isEqualToString:@"insert"]) {
            NSDictionary *newPara = op[@"newPara"];
            NSString *newText = storageTextForPara(newPara[@"text"]);
            NSString *toInsert = [NSString stringWithFormat:@"%@\n", newText];

            NSUInteger currentMsLenForInsert = (NSUInteger)((NSInteger)msLen + cumulativeDelta);
            if (pos > currentMsLenForInsert) {
                fprintf(stderr, "warning: clamping insert position %lu to string length %lu\n",
                    (unsigned long)pos, (unsigned long)currentMsLenForInsert);
                pos = currentMsLenForInsert;
            }
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

            NSInteger insertRunDelta = applyInlineRuns(ms, note, viewContext, newPara, pos, newText.length, attrs);

            cumulativeDelta += (NSInteger)toInsert.length + insertRunDelta;
        }

        } @catch (NSException *mutationEx) {
            fprintf(stderr, "error: cannot apply mutation op '%s' at pos %lu: %s\n",
                [opType UTF8String], (unsigned long)pos, [[mutationEx description] UTF8String]);
            mutationFailed = YES;
            break;
        }
    }

    if (mutationFailed) {
        ((void (*)(id, SEL))objc_msgSend)(note, sel_registerName("endEditing"));
        fprintf(stderr, "error: write-markdown aborted; note was not saved\n");
        return 1;
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
    applyColorRunsFromModel(note, viewContext, newModel);

    summary[@"content"] = noteToMarkdownString(note);
    printJSON(summary);
    return 0;
}

static int cmdWriteMarkdownWithString(id note, id viewContext, NSString *markdown, BOOL dryRun, BOOL backup, BOOL diffMode) {
    NSString *identifier = noteToDict(note)[@"id"];
    NSArray *newModel = markdownToParaModel(markdown);

    if (diffMode) {
        return cmdWriteMarkdownDiff(note, viewContext, identifier, newModel, dryRun, backup);
    } else {
        return cmdWriteMarkdownFullReplace(note, viewContext, identifier, newModel, dryRun, backup);
    }
}

static int cmdWriteMarkdownNote(id note, id viewContext, BOOL dryRun, BOOL backup, BOOL diffMode, BOOL allowEmpty) {
    // Read markdown from stdin
    NSFileHandle *input = [NSFileHandle fileHandleWithStandardInput];
    NSData *data = [input readDataToEndOfFile];
    NSString *markdown = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!markdown) errorExit(@"Failed to read markdown from stdin (invalid UTF-8)");
    if (markdown.length == 0 && !allowEmpty) {
        errorExit(@"Refusing empty markdown input. Pass --allow-empty to clear a note intentionally.");
    }
    return cmdWriteMarkdownWithString(note, viewContext, markdown, dryRun, backup, diffMode);
}

static int cmdCreateMarkdown(id viewContext, NSString *folderName, NSString *title, BOOL diffMode) {
    if ([title rangeOfString:@"\n"].location != NSNotFound ||
        [title rangeOfString:@"\r"].location != NSNotFound) {
        errorExit(@"--title must be a single line");
    }

    NSFileHandle *input = [NSFileHandle fileHandleWithStandardInput];
    NSData *data = [input readDataToEndOfFile];
    NSString *markdown = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!markdown) errorExit(@"Failed to read markdown from stdin (invalid UTF-8)");

    id note = createEmptyNoteInFolder(viewContext, folderName);

    NSMutableDictionary *titlePara = [NSMutableDictionary dictionary];
    titlePara[@"style"] = @(0);
    titlePara[@"indent"] = @(0);
    titlePara[@"text"] = title;

    NSMutableArray *model = [NSMutableArray arrayWithObject:titlePara];
    [model addObjectsFromArray:markdownToParaModel(markdown)];

    NSString *identifier = noteToDict(note)[@"id"];
    int savedStdout = dup(STDOUT_FILENO);
    int devNull = open("/dev/null", O_WRONLY);
    if (savedStdout < 0 || devNull < 0) {
        if (savedStdout >= 0) close(savedStdout);
        if (devNull >= 0) close(devNull);
        errorExit(@"Failed to prepare create-markdown output");
    }
    dup2(devNull, STDOUT_FILENO);
    if (devNull >= 0) close(devNull);

    int writeResult = diffMode
        ? cmdWriteMarkdownDiff(note, viewContext, identifier, model, NO, NO)
        : cmdWriteMarkdownFullReplace(note, viewContext, identifier, model, NO, NO);
    fflush(stdout);
    if (savedStdout >= 0) {
        dup2(savedStdout, STDOUT_FILENO);
        close(savedStdout);
    }
    if (writeResult != 0) return writeResult;

    note = findNoteByID(viewContext, identifier);
    if (!note) errorExit([NSString stringWithFormat:@"Note not found with id: %@", identifier]);
    printJSON(noteLinkDict(note));
    return 0;
}



// --- Install Skill ---

// Rewrite a path under Homebrew's versioned Cellar (<prefix>/Cellar/<formula>/<version>/...)
// to the stable <prefix>/opt/<formula>/... form so installed symlinks survive upgrades.
static NSString *stableSkillSourcePath(NSString *path) {
    NSArray *parts = [path pathComponents];
    NSUInteger idx = [parts indexOfObject:@"Cellar"];
    if (idx == NSNotFound || idx + 3 > parts.count) return path;
    NSMutableArray *out = [[parts subarrayWithRange:NSMakeRange(0, idx)] mutableCopy];
    [out addObject:@"opt"];
    [out addObject:parts[idx + 1]];
    if (idx + 3 < parts.count) {
        [out addObjectsFromArray:[parts subarrayWithRange:NSMakeRange(idx + 3, parts.count - idx - 3)]];
    }
    NSString *candidate = [NSString pathWithComponents:out];
    if ([[NSFileManager defaultManager] fileExistsAtPath:candidate]) return candidate;
    return path;
}

static void addUniqueSkillTarget(NSMutableArray *targetDirs, NSString *path) {
    NSString *parent = [[path stringByDeletingLastPathComponent] stringByResolvingSymlinksInPath];
    NSString *resolvedPath = [parent stringByAppendingPathComponent:[path lastPathComponent]];
    if (![targetDirs containsObject:resolvedPath]) [targetDirs addObject:resolvedPath];
}

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

    // Try to find the skill directory relative to the binary
    // Homebrew: /opt/homebrew/Cellar/notekit-cli/X.Y.Z/bin/notekit
    //   skill: /opt/homebrew/Cellar/notekit-cli/X.Y.Z/.agents/skills/apple-notes
    // Build dir: ./notekit  ->  ./.agents/skills/apple-notes
    NSArray *candidates = @[
        [[binDir stringByDeletingLastPathComponent] stringByAppendingPathComponent:@".agents/skills/apple-notes"],
        [[binDir stringByAppendingPathComponent:@".."] stringByAppendingPathComponent:@".agents/skills/apple-notes"],
        [binDir stringByAppendingPathComponent:@".agents/skills/apple-notes"],
    ];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *sourceDir = nil;
    for (NSString *candidate in candidates) {
        NSString *resolved = [candidate stringByStandardizingPath];
        if ([fm fileExistsAtPath:[resolved stringByAppendingPathComponent:@"SKILL.md"]]) {
            sourceDir = resolved;
            break;
        }
    }

    if (!sourceDir) {
        fprintf(stderr, "Error: could not find skill directory relative to binary at %s\n", realPath);
        fprintf(stderr, "Searched:\n");
        for (NSString *candidate in candidates) {
            fprintf(stderr, "  %s\n", [[candidate stringByStandardizingPath] UTF8String]);
        }
        return 1;
    }

    // Symlink the whole skill directory, not its SKILL.md: Codex skips skills
    // whose SKILL.md is a file symlink, but follows directory symlinks.
    sourceDir = stableSkillSourcePath(sourceDir);

    // Install to selected skill directories
    NSString *home = NSHomeDirectory();
    NSMutableArray *targetDirs = [NSMutableArray array];
    if (installClaude) addUniqueSkillTarget(targetDirs, [home stringByAppendingPathComponent:@".claude/skills/apple-notes"]);
    if (installAgents) addUniqueSkillTarget(targetDirs, [home stringByAppendingPathComponent:@".agents/skills/apple-notes"]);

    NSError *error = nil;
    int failures = 0;
    for (NSString *dir in targetDirs) {
        // Use attributesOfItemAtPath (not fileExistsAtPath) to detect broken symlinks
        NSDictionary *attrs = [fm attributesOfItemAtPath:dir error:nil];
        if (attrs) {
            if (!force && [attrs[NSFileType] isEqualToString:NSFileTypeSymbolicLink]) {
                NSString *dest = [fm destinationOfSymbolicLinkAtPath:dir error:nil];
                if ([dest isEqualToString:sourceDir]) {
                    printf("Skill already installed: %s -> %s\n", [dir UTF8String], [sourceDir UTF8String]);
                    continue;
                }
            }
            printf("Replacing existing %s\n", [dir UTF8String]);
            [fm removeItemAtPath:dir error:nil];
        }
        NSString *parent = [dir stringByDeletingLastPathComponent];
        if (![fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:&error]) {
            fprintf(stderr, "Error: could not create directory %s: %s\n",
                [parent UTF8String], [[error localizedDescription] UTF8String]);
            failures++;
            continue;
        }
        if (![fm createSymbolicLinkAtPath:dir withDestinationPath:sourceDir error:&error]) {
            fprintf(stderr, "Error: could not create symlink: %s\n",
                [[error localizedDescription] UTF8String]);
            failures++;
            continue;
        }
        printf("Installed skill: %s -> %s\n", [dir UTF8String], [sourceDir UTF8String]);
    }

    return failures > 0 ? 1 : 0;
}


// --- Bulk export ---

// Walk parent chain to build a folder path like "Personal/Moving".
// Returns nil if the note has no folder or only an empty-named root.
static NSString *folderPathForNote(id note) {
    id folder = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("folder"));
    if (!folder) return nil;
    NSMutableArray *components = [NSMutableArray array];
    while (folder) {
        NSString *title = nil;
        @try {
            title = ((id (*)(id, SEL))objc_msgSend)(folder, sel_registerName("title"));
        } @catch (NSException *e) {}
        if (title && title.length > 0) [components insertObject:title atIndex:0];
        @try {
            folder = ((id (*)(id, SEL))objc_msgSend)(folder, sel_registerName("parentFolder"));
        } @catch (NSException *e) { folder = nil; }
    }
    if (components.count == 0) return nil;
    return [components componentsJoinedByString:@"/"];
}

// Sanitize a string for use as a single filename or directory component.
// Replaces filesystem-hostile chars and trims; returns "Untitled" if empty.
static NSString *sanitizeFilenameComponent(NSString *s) {
    if (!s || s.length == 0) return @"Untitled";
    NSMutableString *out = [NSMutableString stringWithCapacity:s.length];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c == '/' || c == ':' || c == '\\' || c == 0 || c < 0x20) {
            [out appendString:@"-"];
        } else {
            [out appendFormat:@"%C", c];
        }
    }
    NSString *trimmed = [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (trimmed.length == 0) return @"Untitled";
    if (trimmed.length > 200) trimmed = [trimmed substringToIndex:200];
    return trimmed;
}

// Format a string as a YAML double-quoted scalar with standard escapes.
static NSString *yamlScalar(NSString *s) {
    NSMutableString *escaped = [NSMutableString stringWithCapacity:s.length + 2];
    [escaped appendString:@"\""];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c == '\\') [escaped appendString:@"\\\\"];
        else if (c == '"') [escaped appendString:@"\\\""];
        else if (c == '\n') [escaped appendString:@"\\n"];
        else if (c == '\r') [escaped appendString:@"\\r"];
        else if (c == '\t') [escaped appendString:@"\\t"];
        else [escaped appendFormat:@"%C", c];
    }
    [escaped appendString:@"\""];
    return escaped;
}


static NSMutableDictionary *exportMetadataForNote(id note, NSString *title, NSString *folderPath, NSDate *createdDate, NSDate *modifiedDate, NSSet *metadataFields) {
    NSMutableDictionary *meta = [NSMutableDictionary dictionary];
    meta[@"title"] = title ?: @"Untitled";
    if (folderPath.length > 0) meta[@"folder"] = folderPath;
    if (createdDate) meta[@"created"] = dateToISO(createdDate);
    if (modifiedDate) meta[@"modified"] = dateToISO(modifiedDate);
    if ([metadataFields containsObject:@"id"]) {
        @try { NSString *noteID = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("identifier")); if (noteID.length > 0) meta[@"id"] = noteID; } @catch (NSException *e) {}
    }
    if ([metadataFields containsObject:@"account"]) {
        @try {
            id folder = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("folder"));
            id account = folder ? ((id (*)(id, SEL))objc_msgSend)(folder, sel_registerName("account")) : nil;
            NSString *acctName = account ? ((id (*)(id, SEL))objc_msgSend)(account, sel_registerName("name")) : nil;
            if (acctName.length > 0) meta[@"account"] = acctName;
        } @catch (NSException *e) {}
    }
    if ([metadataFields containsObject:@"pinned"]) { BOOL v = NO; @try { v = ((BOOL (*)(id, SEL))objc_msgSend)(note, sel_registerName("isPinned")); } @catch (NSException *e) {} meta[@"pinned"] = @(v); }
    if ([metadataFields containsObject:@"locked"]) { BOOL v = NO; @try { v = ((BOOL (*)(id, SEL))objc_msgSend)(note, sel_registerName("isLocked")); } @catch (NSException *e) {} meta[@"locked"] = @(v); }
    if ([metadataFields containsObject:@"hasChecklist"]) { BOOL v = NO; @try { v = ((BOOL (*)(id, SEL))objc_msgSend)(note, sel_registerName("hasChecklist")); } @catch (NSException *e) {} meta[@"hasChecklist"] = @(v); }
    if ([metadataFields containsObject:@"hasTags"]) { BOOL v = NO; @try { v = ((BOOL (*)(id, SEL))objc_msgSend)(note, sel_registerName("hasTags")); } @catch (NSException *e) {} meta[@"hasTags"] = @(v); }
    if ([metadataFields containsObject:@"attachmentCount"]) { @try { id atts = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("attachments")); meta[@"attachmentCount"] = @((NSUInteger)(atts ? [atts count] : 0)); } @catch (NSException *e) {} }
    if ([metadataFields containsObject:@"snippet"]) { @try { NSString *snippet = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("snippet")); if (snippet.length > 0) meta[@"snippet"] = snippet; } @catch (NSException *e) {} }
    if ([metadataFields containsObject:@"url"]) {
        @try { Class ICAppURLUtilities = NSClassFromString(@"ICAppURLUtilities"); NSURL *appURL = ICAppURLUtilities ? ((id (*)(id, SEL, id))objc_msgSend)(ICAppURLUtilities, sel_registerName("appURLForNote:"), note) : nil; if (appURL) meta[@"url"] = [appURL absoluteString]; } @catch (NSException *e) {}
    }
    return meta;
}

static void appendYAMLMetadata(NSMutableString *content, NSDictionary *meta) {
    [content appendString:@"---\n"];
    for (NSString *key in @[@"title", @"folder", @"created", @"modified", @"id", @"account", @"pinned", @"locked", @"hasChecklist", @"hasTags", @"attachmentCount", @"snippet", @"url"]) {
        id value = meta[key];
        if (!value) continue;
        if ([value isKindOfClass:[NSNumber class]]) {
            const char *ctype = [value objCType];
            if (strcmp(ctype, @encode(BOOL)) == 0) [content appendFormat:@"%@: %@\n", key, [value boolValue] ? @"true" : @"false"];
            else [content appendFormat:@"%@: %@\n", key, value];
        } else {
            [content appendFormat:@"%@: %@\n", key, yamlScalar(value)];
        }
    }
    [content appendString:@"---\n\n"];
}

static id syncEnsureFolder(id viewContext, NSString *folderName);
static id syncCreateNote(id viewContext, NSString *folderName, NSString *title, NSString *body);
static void syncApplyNoteDates(id viewContext, id note, NSDate *created, NSDate *modified, BOOL dryRun);
static NSDate *syncFileCreationDate(NSString *path);
static NSDate *syncFileModificationDate(NSString *path);

// Export every (non-locked) note as one file with YAML frontmatter.
// Mirrors folder hierarchy under outputPath. Locked notes are skipped.
static int cmdExport(id viewContext, NSString *outputPath, NSString *folderFilter, NSString *format, BOOL preserveRoundTrip, NSSet *metadataFields, BOOL metadataJSON) {
    if (!outputPath || outputPath.length == 0) errorExit(@"--output required");
    if (!format) format = @"md";
    BOOL isMarkdown = NO;
    if ([format isEqualToString:@"md"]) isMarkdown = YES;
    else if ([format isEqualToString:@"txt"]) isMarkdown = NO;
    else errorExit(@"--format must be 'md' or 'txt'");

    NSString *expandedOut = [outputPath stringByExpandingTildeInPath];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *err = nil;
    if (![fm createDirectoryAtPath:expandedOut withIntermediateDirectories:YES attributes:nil error:&err]) {
        errorExit([NSString stringWithFormat:@"Cannot create output directory: %@", err]);
    }

    NSArray *notes = fetchNotes(viewContext, folderFilter, 0);
    NSMutableSet *usedPaths = [NSMutableSet set];
    NSUInteger written = 0, skippedLocked = 0;

    for (id note in notes) {
        BOOL locked = NO;
        @try { locked = ((BOOL (*)(id, SEL))objc_msgSend)(note, sel_registerName("isLocked")); } @catch (NSException *e) {}

        NSString *title = nil;
        @try { title = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("title")); } @catch (NSException *e) {}
        if (!title || title.length == 0) title = @"Untitled";

        if (locked) {
            fprintf(stderr, "Skipping locked note: %s\n", [title UTF8String]);
            skippedLocked++;
            continue;
        }

        NSString *folderPath = folderPathForNote(note);
        NSDate *createdDate = nil, *modifiedDate = nil;
        @try { createdDate = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("creationDate")); } @catch (NSException *e) {}
        @try { modifiedDate = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("modificationDate")); } @catch (NSException *e) {}

        NSString *destDir = expandedOut;
        if (folderPath && folderPath.length > 0) {
            for (NSString *p in [folderPath componentsSeparatedByString:@"/"]) {
                destDir = [destDir stringByAppendingPathComponent:sanitizeFilenameComponent(p)];
            }
            if (![fm createDirectoryAtPath:destDir withIntermediateDirectories:YES attributes:nil error:&err]) {
                fprintf(stderr, "Failed to create folder %s: %s\n",
                        [destDir UTF8String], [[err localizedDescription] UTF8String]);
                continue;
            }
        }

        NSString *titlePart = sanitizeFilenameComponent(title);
        NSString *baseName = titlePart;
        if (createdDate) {
            NSString *iso = dateToISO(createdDate);
            if (iso && iso.length >= 10) {
                baseName = [NSString stringWithFormat:@"%@ %@", [iso substringToIndex:10], titlePart];
            }
        }
        NSString *ext = isMarkdown ? @"md" : @"txt";
        NSString *candidate = [destDir stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@.%@", baseName, ext]];
        NSUInteger n = 2;
        while ([usedPaths containsObject:candidate] || [fm fileExistsAtPath:candidate]) {
            candidate = [destDir stringByAppendingPathComponent:
                [NSString stringWithFormat:@"%@-%lu.%@", baseName, (unsigned long)n, ext]];
            n++;
        }
        [usedPaths addObject:candidate];

        NSMutableDictionary *metadata = exportMetadataForNote(note, title, folderPath, createdDate, modifiedDate, metadataFields ?: [NSSet set]);
        NSMutableString *content = [NSMutableString string];
        if (!metadataJSON) appendYAMLMetadata(content, metadata);

        if (isMarkdown) {
            NSString *body;
            if (preserveRoundTrip) {
                // Tight format identical to read-markdown so write-markdown
                // can round-trip the export.
                body = noteToMarkdownString(note);
            } else {
                // Loose format: blank-line separators between paragraphs
                // (with adjacent list items kept tight) for clean rendering
                // in any markdown viewer.  Soft line breaks (U+2028, emitted
                // as <br>) become markdown hard breaks; defensive backslash
                // escaping is removed for human readability.  Output is no
                // longer round-trippable through write-markdown.
                NSArray *model = noteToParaModel(note);
                NSMutableArray *filtered = [NSMutableArray array];
                BOOL fc = NO;
                for (NSDictionary *p in model) {
                    if (!fc && [p[@"text"] length] == 0) continue;
                    fc = YES;
                    [filtered addObject:p];
                }
                body = paraModelToMarkdown(filtered, YES);
                body = [body stringByReplacingOccurrencesOfString:@"<br>" withString:@"  \n"];
                body = unescapeMarkdown(body);
            }
            if (body) [content appendString:body];
        } else {
            [content appendFormat:@"%@\n\n", title];
            NSString *body = nil;
            @try {
                body = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("noteAsPlainTextWithoutTitle"));
            } @catch (NSException *e) {}
            if (body) [content appendString:body];
        }
        if (![content hasSuffix:@"\n"]) [content appendString:@"\n"];

        NSError *writeErr = nil;
        if (![content writeToFile:candidate atomically:YES encoding:NSUTF8StringEncoding error:&writeErr]) {
            fprintf(stderr, "Failed to write %s: %s\n",
                    [candidate UTF8String], [[writeErr localizedDescription] UTF8String]);
            continue;
        }
        if (metadataJSON) {
            NSString *jsonPath = [candidate stringByAppendingPathExtension:@"json"];
            NSData *json = [NSJSONSerialization dataWithJSONObject:metadata options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&writeErr];
            if (!json || ![json writeToFile:jsonPath options:NSDataWritingAtomic error:&writeErr]) {
                fprintf(stderr, "Failed to write %s: %s\n", [jsonPath UTF8String], [[writeErr localizedDescription] UTF8String]);
                continue;
            }
        }
        written++;
    }

    fprintf(stderr, "Exported %lu notes to %s\n", (unsigned long)written, [expandedOut UTF8String]);
    if (skippedLocked > 0) {
        fprintf(stderr, "Skipped %lu locked notes\n", (unsigned long)skippedLocked);
    }
    return 0;
}
static NSDictionary *importSidecarMetadata(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:[path stringByAppendingPathExtension:@"json"]];
    if (!data) return @{};
    NSError *err = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (err || ![obj isKindOfClass:[NSDictionary class]]) return @{};
    return obj;
}

static NSString *importMarkdownBody(NSString *path) {
    NSError *err = nil;
    NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&err];
    if (!content) errorExit([NSString stringWithFormat:@"Failed to read %@: %@", path, err]);
    return content;
}

static int cmdImport(id viewContext, NSString *inputPath, NSString *rootFolder, BOOL metadataJSON) {
    if (!inputPath || inputPath.length == 0) errorExit(@"--input required");
    NSString *input = [inputPath stringByExpandingTildeInPath];
    NSString *folderRoot = rootFolder ?: @"Imported Notes";
    syncEnsureFolder(viewContext, folderRoot);

    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:input];
    NSUInteger created = 0, updated = 0, skipped = 0;
    NSString *rel;
    while ((rel = [en nextObject])) {
        if (![[rel pathExtension] isEqualToString:@"md"]) continue;
        NSString *path = [input stringByAppendingPathComponent:rel];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:path isDirectory:&isDir] || isDir) continue;

        NSDictionary *meta = metadataJSON ? importSidecarMetadata(path) : @{};
        NSString *title = meta[@"title"];
        if (!title || title.length == 0) title = [[rel lastPathComponent] stringByDeletingPathExtension];
        NSString *targetFolder = meta[@"folder"];
        if (!targetFolder || targetFolder.length == 0) {
            NSString *dir = [rel stringByDeletingLastPathComponent];
            targetFolder = (!dir || [dir isEqualToString:@"."] || dir.length == 0) ? folderRoot : [folderRoot stringByAppendingPathComponent:dir];
        }
        syncEnsureFolder(viewContext, targetFolder);
        NSString *body = importMarkdownBody(path);
        NSDate *createdDate = dateFromISO(meta[@"created"]) ?: syncFileCreationDate(path);
        NSDate *modifiedDate = dateFromISO(meta[@"modified"]) ?: syncFileModificationDate(path);

        NSString *noteID = meta[@"id"];
        id note = noteID.length > 0 ? findNoteByID(viewContext, noteID) : nil;
        if (note) {
            cmdWriteMarkdownWithString(note, viewContext, body, NO, NO, NO);
            note = findNoteByID(viewContext, noteID);
            syncApplyNoteDates(viewContext, note, createdDate, modifiedDate, NO);
            updated++;
        } else {
            note = syncCreateNote(viewContext, targetFolder, title, body);
            syncApplyNoteDates(viewContext, note, createdDate, modifiedDate, NO);
            created++;
        }
    }
    printJSON(@{@"input": input, @"folder": folderRoot, @"created": @(created), @"updated": @(updated), @"skipped": @(skipped), @"metadataJSON": @(metadataJSON)});
    return 0;
}



// --- Two-way sync ---

static NSString *syncDefaultDir(void) {
    return [@"~/Development/agent-documents/agent-notes" stringByExpandingTildeInPath];
}

static NSString *syncDefaultStatePath(NSString *dir) {
    return [dir stringByAppendingPathComponent:@".notekit-sync.json"];
}

static NSString *syncHash(NSString *s) {
    const unsigned char *bytes = (const unsigned char *)[[s ?: @"" dataUsingEncoding:NSUTF8StringEncoding] bytes];
    NSUInteger len = [[s ?: @"" dataUsingEncoding:NSUTF8StringEncoding] length];
    unsigned long long h = 1469598103934665603ULL;
    for (NSUInteger i = 0; i < len; i++) { h ^= bytes[i]; h *= 1099511628211ULL; }
    return [NSString stringWithFormat:@"%016llx", h];
}

static NSString *syncContentHash(NSString *s) {
    NSString *normalized = s ?: @"";
    while ([normalized hasSuffix:@"\n"]) normalized = [normalized substringToIndex:normalized.length - 1];
    return syncHash(normalized);
}

static NSDictionary *syncLoadJSON(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return @{};
    NSError *err = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (err || ![obj isKindOfClass:[NSDictionary class]]) return @{};
    return obj;
}

static void syncWriteJSON(NSDictionary *obj, NSString *path) {
    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&err];
    if (err) errorExit([NSString stringWithFormat:@"Failed to encode sync state: %@", err]);
    NSString *tmp = [path stringByAppendingPathExtension:@"tmp"];
    if (![data writeToFile:tmp options:NSDataWritingAtomic error:&err]) errorExit([NSString stringWithFormat:@"Failed to write sync state: %@", err]);
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:path error:nil];
    if (![fm moveItemAtPath:tmp toPath:path error:&err]) errorExit([NSString stringWithFormat:@"Failed to replace sync state: %@", err]);
}

static NSString *syncYamlValue(NSString *s) {
    if (!s) return @"";
    NSString *trimmed = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trimmed hasPrefix:@"\""] && [trimmed hasSuffix:@"\""] && trimmed.length >= 2) {
        trimmed = [trimmed substringWithRange:NSMakeRange(1, trimmed.length - 2)];
        trimmed = [trimmed stringByReplacingOccurrencesOfString:@"\\\"" withString:@"\""];
        trimmed = [trimmed stringByReplacingOccurrencesOfString:@"\\n" withString:@"\n"];
        trimmed = [trimmed stringByReplacingOccurrencesOfString:@"\\r" withString:@"\r"];
        trimmed = [trimmed stringByReplacingOccurrencesOfString:@"\\t" withString:@"\t"];
        trimmed = [trimmed stringByReplacingOccurrencesOfString:@"\\\\" withString:@"\\"];
    }
    return trimmed;
}

static NSDictionary *syncParseMarkdownFile(NSString *path) {
    NSError *err = nil;
    NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&err];
    if (!content) return nil;
    NSMutableDictionary *meta = [NSMutableDictionary dictionary];
    NSString *body = content;
    if ([content hasPrefix:@"---\n"]) {
        NSRange end = [content rangeOfString:@"\n---\n" options:0 range:NSMakeRange(4, content.length - 4)];
        if (end.location != NSNotFound) {
            NSString *front = [content substringWithRange:NSMakeRange(4, end.location - 4)];
            for (NSString *line in [front componentsSeparatedByString:@"\n"]) {
                NSRange colon = [line rangeOfString:@":"];
                if (colon.location == NSNotFound) continue;
                NSString *key = [[line substringToIndex:colon.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                NSString *val = [line substringFromIndex:colon.location + 1];
                if (key.length > 0) meta[key] = syncYamlValue(val);
            }
            NSUInteger bodyStart = end.location + end.length;
            body = bodyStart <= content.length ? [content substringFromIndex:bodyStart] : @"";
            if ([body hasPrefix:@"\n"]) body = [body substringFromIndex:1];
        }
    }
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    NSDate *mtime = attrs[NSFileModificationDate];
    return @{@"metadata": meta, @"body": body ?: @"", @"modified": mtime ? dateToISO(mtime) : @"", @"hash": syncContentHash(body ?: @"")};
}

static NSString *syncRenderFile(NSString *noteID, NSString *title, NSString *folder, NSDate *created, NSDate *modified, NSString *body) {
    NSMutableString *out = [NSMutableString stringWithString:body ?: @""];
    if (![out hasSuffix:@"\n"]) [out appendString:@"\n"];
    return out;
}

static BOOL syncSetFileModifiedDate(NSString *path, NSDate *modified, BOOL dryRun) {
    if (dryRun || !modified) return YES;
    NSError *err = nil;
    if (![[NSFileManager defaultManager] setAttributes:@{NSFileModificationDate: modified} ofItemAtPath:path error:&err]) {
        errorExit([NSString stringWithFormat:@"Failed to set mtime for %@: %@", path, err]);
    }
    return YES;
}

static BOOL syncWriteString(NSString *content, NSString *path, BOOL dryRun) {
    if (dryRun) return YES;
    NSError *err = nil;
    NSString *dir = [path stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&err];
    if (err) errorExit([NSString stringWithFormat:@"Failed to create sync dir: %@", err]);
    NSString *tmp = [path stringByAppendingPathExtension:@"tmp"];
    if (![content writeToFile:tmp atomically:YES encoding:NSUTF8StringEncoding error:&err]) errorExit([NSString stringWithFormat:@"Failed to write sync file: %@", err]);
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    if (![[NSFileManager defaultManager] moveItemAtPath:tmp toPath:path error:&err]) errorExit([NSString stringWithFormat:@"Failed to replace sync file: %@", err]);
    return YES;
}

static NSString *syncAvailablePath(NSString *dir, NSString *title, NSMutableSet *used, NSString *existingRel) {
    if (existingRel.length > 0) {
        [used addObject:existingRel];
        return [dir stringByAppendingPathComponent:existingRel];
    }
    NSString *base = sanitizeFilenameComponent(title ?: @"Untitled");
    NSString *rel = [base stringByAppendingPathExtension:@"md"];
    NSUInteger n = 2;
    NSFileManager *fm = [NSFileManager defaultManager];
    while ([used containsObject:rel] || [fm fileExistsAtPath:[dir stringByAppendingPathComponent:rel]]) {
        rel = [[NSString stringWithFormat:@"%@-%lu", base, (unsigned long)n++] stringByAppendingPathExtension:@"md"];
    }
    [used addObject:rel];
    return [dir stringByAppendingPathComponent:rel];
}

static NSString *syncRelativeFolder(NSString *rootFolder, NSString *folderPath) {
    if (!folderPath || !rootFolder) return @"";
    if ([folderPath isEqualToString:rootFolder]) return @"";
    NSString *prefix = [rootFolder stringByAppendingString:@"/"];
    if ([folderPath hasPrefix:prefix]) return [folderPath substringFromIndex:prefix.length];
    return @"";
}

static BOOL syncFolderIsUnderRoot(NSString *rootFolder, NSString *folderPath) {
    if (!rootFolder || rootFolder.length == 0) return YES;
    if ([folderPath isEqualToString:rootFolder]) return YES;
    return [folderPath hasPrefix:[rootFolder stringByAppendingString:@"/"]];
}

static NSString *syncFolderForFile(NSString *rootFolder, NSString *relPath) {
    NSString *dir = [relPath stringByDeletingLastPathComponent];
    if (!dir || [dir isEqualToString:@"."] || dir.length == 0) return rootFolder;
    return [rootFolder stringByAppendingPathComponent:dir];
}

static id syncFolderObjectForPath(id viewContext, NSString *path) {
    id fallback = nil;
    for (id folder in fetchFolders(viewContext)) {
        if (folderMatchesNameOrPath(folder, path)) {
            if (!fallback) fallback = folder;
            NSString *fp = folderPathForFolder(folder);
            if (fp && [fp isEqualToString:path]) return folder;
        }
    }
    return fallback;
}

static void syncCreateFolderInParent(id viewContext, NSString *name, id parentFolder) {
    id account = nil;
    if (parentFolder) account = ((id (*)(id, SEL))objc_msgSend)(parentFolder, sel_registerName("account"));
    if (!account) {
        for (id f in fetchFolders(viewContext)) {
            account = ((id (*)(id, SEL))objc_msgSend)(f, sel_registerName("account"));
            if (account) break;
        }
    }
    if (!account) errorExit(@"No account found");
    Class ICFolder = NSClassFromString(@"ICFolder");
    id newFolder = ((id (*)(id, SEL, id))objc_msgSend)(ICFolder, sel_registerName("newFolderInAccount:"), account);
    if (!newFolder) errorExit(@"Failed to create folder");
    ((void (*)(id, SEL, id))objc_msgSend)(newFolder, sel_registerName("setTitle:"), name);
    if (parentFolder) ((void (*)(id, SEL, id))objc_msgSend)(newFolder, sel_registerName("setParent:"), parentFolder);
    NSError *error = nil;
    [viewContext save:&error];
    if (error) errorExit([NSString stringWithFormat:@"Save error: %@", error]);
}

static id syncEnsureFolder(id viewContext, NSString *folderName) {
    NSArray *folders = fetchFolders(viewContext);
    for (id folder in folders) {
        if (folderMatchesNameOrPath(folder, folderName)) return folder;
    }
    NSArray *parts = [folderName componentsSeparatedByString:@"/"];
    NSString *current = @"";
    for (NSString *part in parts) {
        if (part.length == 0) continue;
        NSString *parent = current.length > 0 ? current : nil;
        current = current.length > 0 ? [current stringByAppendingPathComponent:part] : part;
        BOOL exists = NO;
        for (id folder in fetchFolders(viewContext)) {
            if (folderMatchesNameOrPath(folder, current)) { exists = YES; break; }
        }
        if (!exists) {
            id parentFolder = parent ? syncFolderObjectForPath(viewContext, parent) : nil;
            syncCreateFolderInParent(viewContext, part, parentFolder);
        }
    }
    folders = fetchFolders(viewContext);
    for (id folder in folders) {
        if (folderMatchesNameOrPath(folder, folderName)) return folder;
    }
    errorExit([NSString stringWithFormat:@"Folder not found after create: %@", folderName]);
    return nil;
}

static NSDate *syncDateFromFileMetadata(NSDictionary *file, NSString *key) {
    NSString *value = file[@"metadata"][key];
    if (value.length > 0) return dateFromISO(value);
    if ([key isEqualToString:@"modified"]) return dateFromISO(file[@"modified"]);
    return nil;
}

static NSDate *syncFileCreationDate(NSString *path) {
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    NSDate *created = attrs[NSFileCreationDate];
    return created ?: attrs[NSFileModificationDate];
}

static NSDate *syncFileModificationDate(NSString *path) {
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    return attrs[NSFileModificationDate];
}

static void syncApplyNoteDates(id viewContext, id note, NSDate *created, NSDate *modified, BOOL dryRun) {
    if (dryRun || (!created && !modified)) return;
    @try { if (created) ((void (*)(id, SEL, id))objc_msgSend)(note, sel_registerName("setCreationDate:"), created); } @catch (NSException *e) {}
    @try { if (modified) ((void (*)(id, SEL, id))objc_msgSend)(note, sel_registerName("setModificationDate:"), modified); } @catch (NSException *e) {}
    NSError *error = nil;
    [viewContext save:&error];
    if (error) errorExit([NSString stringWithFormat:@"Save error: %@", error]);
}

static id syncCreateNote(id viewContext, NSString *folderName, NSString *title, NSString *body) {
    id note = createEmptyNoteInFolder(viewContext, folderName);
    NSMutableDictionary *titlePara = [NSMutableDictionary dictionary];
    titlePara[@"style"] = @(0);
    titlePara[@"indent"] = @(0);
    titlePara[@"text"] = title ?: @"Untitled";
    NSMutableArray *model = [NSMutableArray arrayWithObject:titlePara];
    [model addObjectsFromArray:markdownToParaModel(body ?: @"")];
    NSString *identifier = noteToDict(note)[@"id"];
    int savedStdout = dup(STDOUT_FILENO);
    int devNull = open("/dev/null", O_WRONLY);
    if (savedStdout >= 0 && devNull >= 0) dup2(devNull, STDOUT_FILENO);
    if (devNull >= 0) close(devNull);
    cmdWriteMarkdownFullReplace(note, viewContext, identifier, model, NO, NO);
    fflush(stdout);
    if (savedStdout >= 0) { dup2(savedStdout, STDOUT_FILENO); close(savedStdout); }
    return findNoteByID(viewContext, identifier);
}

static NSArray *syncMarkdownFiles(NSString *dir) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:dir];
    NSMutableArray *files = [NSMutableArray array];
    NSString *rel;
    while ((rel = [en nextObject])) {
        if ([rel hasPrefix:@".notekit-"] || [rel containsString:@"/.notekit-"]) continue;
        if ([rel containsString:@".local-conflict-"]) continue;
        if ([[rel pathExtension] isEqualToString:@"md"]) [files addObject:rel];
    }
    return files;
}

static void syncRemoveEmptyDirectories(NSString *root, BOOL dryRun) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:root];
    NSMutableArray *dirs = [NSMutableArray array];
    NSString *rel;
    while ((rel = [en nextObject])) {
        BOOL isDir = NO;
        NSString *path = [root stringByAppendingPathComponent:rel];
        if ([fm fileExistsAtPath:path isDirectory:&isDir] && isDir) [dirs addObject:path];
    }
    [dirs sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return a.length < b.length ? NSOrderedDescending : (a.length > b.length ? NSOrderedAscending : NSOrderedSame);
    }];
    for (NSString *path in dirs) {
        NSArray *items = [fm contentsOfDirectoryAtPath:path error:nil];
        if (items.count == 0 && !dryRun) [fm removeItemAtPath:path error:nil];
    }
}

static int cmdSync(id viewContext, NSString *dirArg, NSString *folderName, NSString *stateArg, BOOL dryRun) {
    NSString *dir = [(dirArg ?: syncDefaultDir()) stringByExpandingTildeInPath];
    NSString *folder = folderName ?: @"agent-notes";
    NSString *statePath = [(stateArg ?: syncDefaultStatePath(dir)) stringByExpandingTildeInPath];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *err = nil;
    if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&err]) errorExit([NSString stringWithFormat:@"Cannot create sync directory: %@", err]);
    syncEnsureFolder(viewContext, folder);

    NSDictionary *loadedState = syncLoadJSON(statePath);
    NSMutableDictionary *state = [NSMutableDictionary dictionaryWithDictionary:loadedState];
    NSMutableDictionary *newState = [NSMutableDictionary dictionary];
    NSMutableDictionary *filesByID = [NSMutableDictionary dictionary];
    NSMutableArray *newFiles = [NSMutableArray array];
    for (NSString *rel in syncMarkdownFiles(dir)) {
        NSDictionary *file = syncParseMarkdownFile([dir stringByAppendingPathComponent:rel]);
        if (!file) continue;
        NSString *fid = file[@"metadata"][@"id"];
        if (fid.length == 0) {
            for (NSString *stateID in state) {
                if ([state[stateID][@"path"] isEqualToString:rel]) { fid = stateID; break; }
            }
        }
        NSMutableDictionary *entry = [NSMutableDictionary dictionaryWithDictionary:file];
        entry[@"path"] = rel;
        entry[@"targetFolder"] = syncFolderForFile(folder, rel);
        if (fid.length > 0) filesByID[fid] = entry;
        else [newFiles addObject:entry];
    }

    NSArray *allNotes = fetchNotes(viewContext, nil, 0);
    NSMutableArray *notes = [NSMutableArray array];
    for (id note in allNotes) {
        NSDictionary *d = noteToDict(note);
        if (syncFolderIsUnderRoot(folder, d[@"folderPath"] ?: d[@"folder"])) [notes addObject:note];
    }
    NSMutableDictionary *notesByID = [NSMutableDictionary dictionary];
    for (id note in notes) {
        NSString *identifier = noteToDict(note)[@"id"];
        if (identifier) notesByID[identifier] = note;
    }
    NSMutableSet *usedPaths = [NSMutableSet setWithArray:[filesByID.allValues valueForKey:@"path"]];
    NSUInteger notesToFiles = 0, filesToNotes = 0, createdNotes = 0, conflicts = 0, unchanged = 0;

    for (id note in notes) {
        NSDictionary *dict = noteToDict(note);
        NSString *noteID = dict[@"id"];
        NSString *title = dict[@"title"] ?: @"Untitled";
        NSDate *noteCreated = nil;
        NSDate *noteModified = nil;
        @try { noteCreated = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("creationDate")); } @catch (NSException *e) {}
        @try { noteModified = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("modificationDate")); } @catch (NSException *e) {}
        NSString *noteBody = syncNoteBody(note) ?: @"";
        NSString *noteHash = syncContentHash(noteBody);
        NSDictionary *old = state[noteID] ?: @{};
        NSDictionary *file = filesByID[noteID];
        NSString *rel = file[@"path"] ?: old[@"path"];
        if (!rel || rel.length == 0) {
            NSString *noteFolderPath = dict[@"folderPath"] ?: dict[@"folder"];
            NSString *relativeFolder = syncRelativeFolder(folder, noteFolderPath);
            NSString *name = [sanitizeFilenameComponent(title) stringByAppendingPathExtension:@"md"];
            rel = relativeFolder.length > 0 ? [relativeFolder stringByAppendingPathComponent:name] : name;
        }
        NSString *path = syncAvailablePath(dir, title, usedPaths, rel);
        rel = [path substringFromIndex:dir.length + 1];
        NSString *oldHash = old[@"hash"];
        NSString *oldNoteHash = old[@"noteHash"] ?: oldHash;
        NSString *oldFileHash = old[@"fileHash"] ?: oldHash;
        BOOL noteChanged = oldNoteHash && ![oldNoteHash isEqualToString:noteHash];
        BOOL fileExists = file != nil;
        BOOL fileDeleted = !fileExists && old[@"path"];
        BOOL fileChanged = fileExists && oldFileHash && ![oldFileHash isEqualToString:file[@"hash"]];
        BOOL wroteFileFromNote = NO;

        if (fileDeleted) {
            if (!dryRun) {
                ((void (*)(id, SEL))objc_msgSend)(note, sel_registerName("markForDeletion"));
                [viewContext deleteObject:note];
                NSError *deleteError = nil;
                [viewContext save:&deleteError];
                if (deleteError) errorExit([NSString stringWithFormat:@"Save error: %@", deleteError]);
            }
        } else if (fileExists && noteChanged && fileChanged && ![file[@"hash"] isEqualToString:noteHash]) {
            NSString *stamp = [[dateToISO([NSDate date]) stringByReplacingOccurrencesOfString:@":" withString:@""] stringByReplacingOccurrencesOfString:@"-" withString:@""];
            NSString *conflict = [[path stringByDeletingPathExtension] stringByAppendingFormat:@".local-conflict-%@.md", stamp];
            NSString *renderFolder = file[@"targetFolder"] ?: (dict[@"folderPath"] ?: folder);
            syncWriteString(syncRenderFile(noteID, title, renderFolder, noteCreated, noteModified, file[@"body"]), conflict, dryRun);
            syncWriteString(syncRenderFile(noteID, title, renderFolder, noteCreated, noteModified, noteBody), path, dryRun);
            syncSetFileModifiedDate(path, noteModified, dryRun);
            fprintf(stderr, "Conflict: %s changed in Notes and on disk; kept Notes version and wrote local copy to %s\n", [title UTF8String], [conflict UTF8String]);
            wroteFileFromNote = YES;
            notesToFiles++;
            conflicts++;
        } else if (fileExists && fileChanged) {
            int savedStdout = dup(STDOUT_FILENO);
            int devNull = open("/dev/null", O_WRONLY);
            if (savedStdout >= 0 && devNull >= 0) dup2(devNull, STDOUT_FILENO);
            if (devNull >= 0) close(devNull);
            NSMutableArray *replacementModel = [NSMutableArray arrayWithArray:markdownToParaModel(file[@"body"] ?: @"")];
            cmdWriteMarkdownFullReplace(note, viewContext, noteID, replacementModel, dryRun, NO);
            fflush(stdout);
            if (savedStdout >= 0) { dup2(savedStdout, STDOUT_FILENO); close(savedStdout); }
            note = findNoteByID(viewContext, noteID);
            NSString *filePath = [dir stringByAppendingPathComponent:file[@"path"]];
            NSDate *fileCreatedDate = syncFileCreationDate(filePath);
            NSDate *fileModifiedDate = syncFileModificationDate(filePath);
            syncApplyNoteDates(viewContext, note, fileCreatedDate, fileModifiedDate, dryRun);
            note = findNoteByID(viewContext, noteID);
            noteBody = syncNoteBody(note) ?: file[@"body"];
            noteHash = syncContentHash(noteBody);
            @try { noteCreated = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("creationDate")); } @catch (NSException *e) {}
            @try { noteModified = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("modificationDate")); } @catch (NSException *e) {}
            filesToNotes++;
        } else if (!fileExists || noteChanged || !oldHash) {
            NSString *renderFolder = dict[@"folderPath"] ?: folder;
            syncWriteString(syncRenderFile(noteID, title, renderFolder, noteCreated, noteModified, noteBody), path, dryRun);
            syncSetFileModifiedDate(path, noteModified, dryRun);
            wroteFileFromNote = YES;
            notesToFiles++;
        } else {
            unchanged++;
        }

        if (!fileDeleted) {
            NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
            NSDate *fileModified = attrs[NSFileModificationDate];
            // After writing the note body to disk, the file holds noteBody, so
            // its content hash is noteHash — not the pre-write parse in file[@"hash"].
            // Recording the stale parse would make the next pass see a phantom
            // file change and echo it back to the note.
            NSString *fileHashForState = wroteFileFromNote ? noteHash : (fileExists ? file[@"hash"] : (noteHash ?: @""));
            newState[noteID] = @{@"id": noteID ?: @"", @"title": title, @"path": rel ?: @"", @"hash": noteHash ?: @"", @"noteHash": noteHash ?: @"", @"fileHash": fileHashForState ?: @"", @"lastNoteModified": noteModified ? dateToISO(noteModified) : @"", @"lastFileModified": fileModified ? dateToISO(fileModified) : @""};
        }
    }

    for (NSString *noteID in state) {
        if (notesByID[noteID]) continue;
        NSDictionary *old = state[noteID];
        NSString *rel = old[@"path"];
        if (rel.length == 0) continue;
        NSString *path = [dir stringByAppendingPathComponent:rel];
        if ([fm fileExistsAtPath:path]) {
            if (!dryRun) [fm removeItemAtPath:path error:nil];
        }
    }

    for (NSDictionary *file in newFiles) {
        NSString *title = file[@"metadata"][@"title"];
        if (!title || title.length == 0) title = [[[file[@"path"] lastPathComponent] stringByDeletingPathExtension] copy];
        if (!dryRun) {
            NSString *targetFolder = file[@"targetFolder"] ?: folder;
            syncEnsureFolder(viewContext, targetFolder);
            id note = syncCreateNote(viewContext, targetFolder, title, file[@"body"]);
            NSString *sourcePath = [dir stringByAppendingPathComponent:file[@"path"]];
            NSDate *fileCreatedDate = syncFileCreationDate(sourcePath);
            NSDate *fileModifiedDate = syncFileModificationDate(sourcePath);
            syncApplyNoteDates(viewContext, note, fileCreatedDate, fileModifiedDate, NO);
            NSDictionary *dict = noteToDict(note);
            NSString *noteID = dict[@"id"];
            NSDate *noteModified = nil;
            @try { noteModified = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("modificationDate")); } @catch (NSException *e) {}
            NSString *noteBody = syncNoteBody(note) ?: file[@"body"];
            NSString *path = [dir stringByAppendingPathComponent:file[@"path"]];
            NSDate *noteCreated = nil;
            @try { noteCreated = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("creationDate")); } @catch (NSException *e) {}
            NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
            NSDate *fileModified = attrs[NSFileModificationDate];
            NSString *noteHash = syncContentHash(noteBody);
            NSString *fileHash = syncContentHash(file[@"body"] ?: @"");
            newState[noteID] = @{@"id": noteID ?: @"", @"title": title, @"path": file[@"path"] ?: @"", @"hash": noteHash, @"noteHash": noteHash, @"fileHash": fileHash, @"lastNoteModified": noteModified ? dateToISO(noteModified) : @"", @"lastFileModified": fileModified ? dateToISO(fileModified) : @""};
        }
        createdNotes++;
    }

    syncRemoveEmptyDirectories(dir, dryRun);
    if (!dryRun) syncWriteJSON(newState, statePath);
    NSDictionary *summary = @{@"dir": dir, @"folder": folder, @"notesToFiles": @(notesToFiles), @"filesToNotes": @(filesToNotes), @"createdNotes": @(createdNotes), @"conflicts": @(conflicts), @"unchanged": @(unchanged), @"dryRun": @(dryRun)};
    printJSON(summary);
    return conflicts > 0 ? 2 : 0;
}

static NSString *syncLockPath(NSString *statePath) {
    return [statePath stringByAppendingPathExtension:@"lock"];
}

static int syncAcquireLock(NSString *statePath) {
    NSString *lockPath = syncLockPath(statePath);
    int fd = open([lockPath fileSystemRepresentation], O_CREAT | O_RDWR, 0644);
    if (fd < 0) errorExit([NSString stringWithFormat:@"Failed to open sync lock: %@", lockPath]);
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        if (errno == EWOULDBLOCK) errorExit([NSString stringWithFormat:@"Another sync daemon is already running for state %@", statePath]);
        errorExit([NSString stringWithFormat:@"Failed to acquire sync lock: %@", lockPath]);
    }
    ftruncate(fd, 0);
    NSString *info = [NSString stringWithFormat:@"pid=%d\nbinary=%@\nversion=%@\nstate=%@\n", getpid(), [[NSProcessInfo processInfo] arguments].firstObject ?: @"notekit", @NOTEKIT_VERSION, statePath];
    write(fd, info.UTF8String, strlen(info.UTF8String));
    return fd;
}

// Body renderer for sync. noteToMarkdownString escapes [ ] ( ) so the output
// round-trips through write-markdown, but synced files are meant to be plain
// human/agent-readable markdown (the fitness food-log watcher parses the
// bracketed stat annotations directly). Strip only those bracket/paren escapes;
// real note links keep their unescaped [text](url) form untouched. Hashing uses
// this same output so a note and its file compare equal when in sync.
static NSString *syncNoteBody(id note) {
    NSString *body = noteToMarkdownString(note);
    if (!body) return nil;
    body = [body stringByReplacingOccurrencesOfString:@"\\[" withString:@"["];
    body = [body stringByReplacingOccurrencesOfString:@"\\]" withString:@"]"];
    body = [body stringByReplacingOccurrencesOfString:@"\\(" withString:@"("];
    body = [body stringByReplacingOccurrencesOfString:@"\\)" withString:@")"];
    return body;
}

static NSString *syncMainPathForConflictPath(NSString *path) {
    NSString *name = [path lastPathComponent];
    NSRange r = [name rangeOfString:@".local-conflict-" options:NSBackwardsSearch];
    if (r.location == NSNotFound) return path;
    NSString *prefix = [name substringToIndex:r.location];
    NSString *mainName = [prefix stringByAppendingPathExtension:[path pathExtension]];
    return [[path stringByDeletingLastPathComponent] stringByAppendingPathComponent:mainName];
}

static int cmdSyncResolveConflict(id viewContext, NSString *fileArg, NSString *dirArg, NSString *folderName, NSString *stateArg, BOOL keepConflict) {
    if (!fileArg || fileArg.length == 0) errorExit(@"--file required");
    NSString *file = [fileArg stringByExpandingTildeInPath];
    NSString *mainPath = syncMainPathForConflictPath(file);
    NSString *dir = [(dirArg ?: syncDefaultDir()) stringByExpandingTildeInPath];
    NSString *statePath = [(stateArg ?: syncDefaultStatePath(dir)) stringByExpandingTildeInPath];
    NSString *folder = folderName ?: @"agent-notes";
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:file]) errorExit([NSString stringWithFormat:@"File not found: %@", file]);

    NSError *err = nil;
    if (![file isEqualToString:mainPath]) {
        [fm removeItemAtPath:mainPath error:nil];
        if (![fm copyItemAtPath:file toPath:mainPath error:&err]) errorExit([NSString stringWithFormat:@"Failed to copy conflict over main file: %@", err]);
        if (!keepConflict && ![fm removeItemAtPath:file error:&err]) errorExit([NSString stringWithFormat:@"Failed to remove conflict file: %@", err]);
    }

    NSString *rel = [mainPath hasPrefix:[dir stringByAppendingString:@"/"]] ? [mainPath substringFromIndex:dir.length + 1] : nil;
    if (!rel) errorExit([NSString stringWithFormat:@"Resolved file is not under sync dir %@", dir]);
    NSMutableDictionary *state = [NSMutableDictionary dictionaryWithDictionary:syncLoadJSON(statePath)];
    NSString *noteID = nil;
    for (NSString *sid in state) {
        if ([state[sid][@"path"] isEqualToString:rel]) { noteID = sid; break; }
    }
    if (!noteID) errorExit([NSString stringWithFormat:@"No synced note found for %@", rel]);
    id note = findNoteByID(viewContext, noteID);
    if (!note) errorExit([NSString stringWithFormat:@"Synced note not found with id: %@", noteID]);
    NSString *body = importMarkdownBody(mainPath);
    NSMutableArray *replacementModel = [NSMutableArray arrayWithArray:markdownToParaModel(body ?: @"")];
    cmdWriteMarkdownFullReplace(note, viewContext, noteID, replacementModel, NO, NO);
    note = findNoteByID(viewContext, noteID);
    NSDate *created = syncFileCreationDate(mainPath);
    NSDate *modified = syncFileModificationDate(mainPath);
    syncApplyNoteDates(viewContext, note, created, modified, NO);
    NSString *noteBody = syncNoteBody(note) ?: body;
    NSString *hash = syncContentHash(noteBody);
    NSDictionary *attrs = [fm attributesOfItemAtPath:mainPath error:nil];
    NSDate *fileModified = attrs[NSFileModificationDate];
    state[noteID] = @{@"id": noteID ?: @"", @"title": noteToDict(note)[@"title"] ?: [[rel lastPathComponent] stringByDeletingPathExtension], @"path": rel ?: @"", @"hash": hash ?: @"", @"noteHash": hash ?: @"", @"fileHash": syncContentHash(body ?: @"") ?: @"", @"lastNoteModified": modified ? dateToISO(modified) : @"", @"lastFileModified": fileModified ? dateToISO(fileModified) : @""};
    syncWriteJSON(state, statePath);
    printJSON(@{@"resolved": @YES, @"file": mainPath, @"folder": folder, @"noteId": noteID, @"keptConflict": @(keepConflict)});
    return 0;
}

static int cmdSyncDaemon(id viewContext, NSString *dir, NSString *folder, NSString *state, NSTimeInterval interval, BOOL dryRun) {
    if (interval <= 0) interval = 5;
    NSString *syncDir = [(dir ?: syncDefaultDir()) stringByExpandingTildeInPath];
    NSString *statePath = [(state ?: syncDefaultStatePath(syncDir)) stringByExpandingTildeInPath];
    int lockFD = syncAcquireLock(statePath);
    fprintf(stderr, "notekit sync-daemon starting pid=%d version=%s binary=%s dir=%s folder=%s state=%s interval=%.0f\n", getpid(), NOTEKIT_VERSION, [[[NSProcessInfo processInfo] arguments].firstObject UTF8String], [syncDir UTF8String], [(folder ?: @"agent-notes") UTF8String], [statePath UTF8String], interval);
    while (1) {
        @autoreleasepool {
            // Notes.app edits land in the shared store out from under our
            // long-lived context; drop cached object state each pass so the
            // sync sees external note changes instead of stale fetched copies.
            ((void (*)(id, SEL))objc_msgSend)(viewContext, sel_registerName("refreshAllObjects"));
            cmdSync(viewContext, syncDir, folder, statePath, dryRun);
        }
        fflush(stdout); fflush(stderr);
        [NSThread sleepForTimeInterval:interval];
    }
    close(lockFD);
    return 0;
}

// --- Usage ---

static void usage(void) {
    fprintf(stderr, "notekit — read and edit Apple Notes via the NotesShared framework\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "Use read-markdown/write-markdown for all note operations. With --diff,\n");
    fprintf(stderr, "write-markdown does paragraph-level LCS diffing — it only mutates paragraphs\n");
    fprintf(stderr, "that changed. Markdown supports headings, bold, italic, strikethrough, color,\n");
    fprintf(stderr, "links, code, lists, checklists, and note-to-note links. Primitives exist for edge\n");
    fprintf(stderr, "cases not covered by markdown syntax.\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "Note-to-note links:\n");
    fprintf(stderr, "  read-markdown outputs note links as:  [Display Text](applenotes://showNote?identifier=NOTE_ID)\n");
    fprintf(stderr, "  write-markdown accepts the same syntax and converts them back to native note links.\n");
    fprintf(stderr, "  To get a note's ID for linking, use:  notekit get --title \"Target Note\" --exact | jq -r .id\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "Reading and writing notes (recommended):\n");
    fprintf(stderr, "  notekit read-markdown (--title <title> | --id <id>) [--folder <name>]\n");
    fprintf(stderr, "  notekit write-markdown --id <id> [--dry-run] [--backup] [--diff] [--allow-empty]\n");
    fprintf(stderr, "      Read markdown from stdin and replace note content. Empty input is refused unless --allow-empty is set.\n");
    fprintf(stderr, "  notekit create-markdown --folder <name> --title <title> [--diff]    Create note from stdin markdown, output id/title/url\n");
    fprintf(stderr, "  notekit create --folder <name> --title <title> [--body <text>] [--style <n>]\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "Browsing and organizing:\n");
    fprintf(stderr, "  notekit folders\n");
    fprintf(stderr, "  notekit list [--folder <name>] [--limit <n>]\n");
    fprintf(stderr, "  notekit get (--title <title> | --id <id>) [--folder <name>] [--exact]\n");
    fprintf(stderr, "      --title is a substring match by default. --exact requires exactly one exact title match.\n");
    fprintf(stderr, "  notekit search --query <query> [--folder <name>]\n");
    fprintf(stderr, "  notekit delete --id <id>\n");
    fprintf(stderr, "  notekit move --id <id> --to <to-folder>\n");
    fprintf(stderr, "  notekit pin --id <id>\n");
    fprintf(stderr, "  notekit unpin --id <id>\n");
    fprintf(stderr, "  notekit duplicate --id <id> [--new-title <new-title>]\n");
    fprintf(stderr, "  notekit get-link --id <id>                     Get applenotes:// URL for note-to-note linking\n");
    fprintf(stderr, "  notekit create-folder --name <name> [--parent <parent-folder>]\n");
    fprintf(stderr, "  notekit delete-folder --name <name>\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "Bulk export:\n");
    fprintf(stderr, "  notekit export --output <dir> [--folder <name>] [--format md|txt]\n");
    fprintf(stderr, "                 [--metadata <fields>] [--preserve-round-trip]\n");
    fprintf(stderr, "      Writes one file per note with YAML frontmatter (title, folder, created,\n");
    fprintf(stderr, "      modified always included). Mirrors folder hierarchy as subdirectories.\n");
    fprintf(stderr, "      Locked notes are skipped with a warning. Default format is md.\n");
    fprintf(stderr, "      --metadata adds optional frontmatter fields (comma-separated).\n");
    fprintf(stderr, "        Available: id, account, pinned, locked, hasChecklist, hasTags,\n");
    fprintf(stderr, "        attachmentCount, snippet, url.\n");
    fprintf(stderr, "      By default, soft line breaks become markdown hard breaks and defensive\n");
    fprintf(stderr,  "      backslash escaping is removed for clean human-readable output.\n");
    fprintf(stderr, "      Use --preserve-round-trip to keep <br> tags and char escapes so the\n");
    fprintf(stderr, "      output round-trips back through write-markdown.\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "Two-way sync:\n");
    fprintf(stderr, "  notekit sync [--dir <dir>] [--folder <name>] [--state <path>] [--dry-run]\n");
    fprintf(stderr, "  notekit sync-daemon [--dir <dir>] [--folder <name>] [--state <path>] [--interval <seconds>] [--dry-run]\n");
    fprintf(stderr, "      Defaults: --dir ~/Development/agent-documents/agent-notes --folder agent-notes\n");
    fprintf(stderr, "      Sync stores metadata in .notekit-sync.json and YAML frontmatter.\n");
    fprintf(stderr, "      Deletions are non-destructive by default; Notes wins conflicts and local copies are preserved.\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "Debugging / Internals:\n");
    fprintf(stderr, "  These operate on character offsets into the raw attribute stream. You should\n");
    fprintf(stderr, "  not need these for normal use — use read-markdown/write-markdown instead.\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "  notekit read (--title <title> | --id <id>) [--folder <name>]\n");
    fprintf(stderr, "  notekit read-attrs (--title <title> | --id <id>) [--folder <name>]\n");
    fprintf(stderr, "  notekit read-structured (--title <title> | --id <id>) [--folder <name>]\n");
    fprintf(stderr, "  notekit create-empty --folder <name>\n");
    fprintf(stderr, "  notekit append --id <id> --text <text> [--style <n>]\n");
    fprintf(stderr, "  notekit insert --id <id> --text <text> --position <n> [--style <n>] [--body-offset]\n");
    fprintf(stderr, "  notekit delete-range --id <id> --start <n> --length <n> [--body-offset]\n");
    fprintf(stderr, "  notekit set-attr --id <id> --offset <n> --length <n> [--style <n>] [--indent <n>] [--todo-done true|false] [--link <url>] [--strikethrough true|false] [--color <hex|reset>] [--body-offset]\n");
    fprintf(stderr, "  notekit search-offset --id <id> --text <text> [--case-insensitive]\n");
    fprintf(stderr, "  notekit replace --id <id> --search <text> --replacement <text>\n");
    fprintf(stderr, "  notekit delete-line --id <id> --search-text <search-text>\n");
    fprintf(stderr, "  notekit add-link --id <id> --target <id> [--text <text>] [--position <n>]   Insert note-to-note link\n");
    fprintf(stderr, "  notekit add-note-link --id <id> --target <id> [--position <n>]            Insert native ICInlineAttachment note link\n");
    fprintf(stderr, "  notekit version [--skip-check]                     Print installed version and check for updates\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "  --body-offset    Treat offset/position/start as relative to body text (after title).\n");
    fprintf(stderr, "                   Use this when offsets come from 'notekit read' output.\n");
    fprintf(stderr, "                   Without this flag, offsets are into the full internal string\n");
    fprintf(stderr, "                   (including leading newline + title + newline).\n");
    fprintf(stderr, "                   Errors if the note has no body text (title-only note).\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "Skill management:\n");
    fprintf(stderr, "  notekit install-skill [--claude] [--agents] [--force]\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "Testing:\n");
    fprintf(stderr, "  notekit test\n");
    fprintf(stderr, "\nReport issues:\n");
    fprintf(stderr, "  gh api repos/johnmatthewtennant/notekit-cli/issues --method POST -f title=\"...\" -f body=\"...\"\n");
}
