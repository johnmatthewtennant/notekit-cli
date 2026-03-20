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


static int cmdCreate(id viewContext, NSString *folderName, NSString *title, NSString *body, NSInteger styleValue) {
    id targetFolder = nil;
    NSArray *folders = fetchFolders(viewContext);
    for (id folder in folders) {
        NSString *fname = ((id (*)(id, SEL))objc_msgSend)(folder, sel_registerName("title"));
        if ([fname isEqualToString:folderName]) { targetFolder = folder; break; }
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
    printJSON(noteToDict(note));
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
            // Check for note-to-note link attachment (￼ chars with NSAttachment)
            id nsAttachment = attrs[@"NSAttachment"];
            if (nsAttachment && !nsLink && [chunk isEqualToString:@"\uFFFC"]) {
                NSDictionary *noteLink = noteLinksByOffset[@(effectiveRange.location)];
                if (noteLink) {
                    run[@"link"] = noteLink[@"url"];
                    run[@"noteLinkDisplayText"] = noteLink[@"displayText"];
                }
            }
            id strikethrough = attrs[@"TTStrikethrough"];
            if (strikethrough) run[@"strikethrough"] = @YES;
            id ttHints1 = attrs[@"TTHints"];
            if (ttHints1) {
                NSUInteger hints1 = [ttHints1 unsignedIntegerValue];
                if (hints1 & 1) run[@"bold"] = @YES;
                if (hints1 & 2) run[@"italic"] = @YES;
            }
            id ttUnderline1 = attrs[@"TTUnderline"];
            if (ttUnderline1) run[@"underline"] = @YES;
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
            // Check for note-to-note link attachment (￼ chars with NSAttachment)
            id nsAttachment = attrs[@"NSAttachment"];
            if (nsAttachment && !nsLink && [chunk isEqualToString:@"\uFFFC"]) {
                NSDictionary *noteLink = noteLinksByOffset[@(effectiveRange.location)];
                if (noteLink) {
                    run[@"link"] = noteLink[@"url"];
                    run[@"noteLinkDisplayText"] = noteLink[@"displayText"];
                }
            }
            id strikethrough = attrs[@"TTStrikethrough"];
            if (strikethrough) run[@"strikethrough"] = @YES;
            id ttHints2 = attrs[@"TTHints"];
            if (ttHints2) {
                NSUInteger hints2 = [ttHints2 unsignedIntegerValue];
                if (hints2 & 1) run[@"bold"] = @YES;
                if (hints2 & 2) run[@"italic"] = @YES;
            }
            id ttUnderline2 = attrs[@"TTUnderline"];
            if (ttUnderline2) run[@"underline"] = @YES;
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

        // Handle code block paragraphs (style 4) — no markdown escaping
        if (style == 4) {
            if (i > 0) [output appendString:@"\n"];
            // Replace U+2028 line separators back to newlines
            NSString *codeText = [rawText stringByReplacingOccurrencesOfString:@"\u2028" withString:@"\n"];
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

        if (i > 0) {
            [output appendString:@"\n"];
            // Add blank line before headings unless previous paragraph was already blank
            if (style == 0 || style == 1) {
                NSDictionary *prev = paragraphs[i - 1];
                NSInteger prevStyle = [prev[@"style"] integerValue];
                NSString *prevText = prev[@"text"];
                BOOL prevWasBlank = (prevStyle == 3 && prevText.length == 0);
                if (!prevWasBlank) {
                    [output appendString:@"\n"];
                }
            }
        }
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

// Convert para model text (which uses U+2028 for soft line breaks) to Apple Notes
// storage format (which uses \n within a single attribute range).
static NSString *storageTextForPara(NSString *text) {
    return [text stringByReplacingOccurrencesOfString:@"\u2028" withString:@"\n"];
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
            if (!pair) continue; // guard: matched entry with no corresponding LCS pair (corrupted state)
            NSUInteger oldIdx = [pair[0] unsignedIntegerValue];
            if (oldIdx >= filteredOld.count) continue; // guard: out-of-bounds old index
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
            [ops addObject:@{@"op": @"insert", @"pos": @(insertPos), @"newPara": newModel[newIdx], @"newIndex": @(newIdx)}];
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
        if (prioA != prioB) return prioA < prioB ? NSOrderedAscending : NSOrderedDescending;
        // For inserts at the same position, process higher newIndex first so paragraphs
        // end up in correct top-to-bottom order after bottom-to-top insertion
        if (prioA == 2) return [b[@"newIndex"] compare:a[@"newIndex"]];
        return NSOrderedSame;
    }];

    NSInteger cumulativeDelta = 0;
    for (NSDictionary *op in ops) {
        NSString *opType = op[@"op"];
        NSUInteger pos = [op[@"pos"] unsignedIntegerValue];

        @try {

        if ([opType isEqualToString:@"delete"]) {
            NSUInteger deleteLen = [op[@"len"] unsignedIntegerValue];
            NSUInteger currentMsLenForDelete = (NSUInteger)((NSInteger)msLen + cumulativeDelta);
            if (pos + deleteLen > currentMsLenForDelete) {
                fprintf(stderr, "warning: skipping delete mutation at pos %lu len %lu (exceeds string length %lu)\n",
                    (unsigned long)pos, (unsigned long)deleteLen, (unsigned long)currentMsLenForDelete);
                continue;
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

                ((void (*)(id, SEL, id, NSRange))objc_msgSend)(ms, sel_registerName("setAttributes:range:"),
                    patchedAttrs, NSMakeRange(pos, paraLen));

                NSArray *newRuns = newPara[@"runs"];
                if (newRuns) {
                    NSInteger runDelta = 0; // tracks offset shift from note-link replacements
                    for (NSDictionary *run in newRuns) {
                        NSUInteger runStart = [run[@"start"] unsignedIntegerValue] + runDelta;
                        NSUInteger runLen = [run[@"length"] unsignedIntegerValue];
                        if (runStart + runLen > (NSUInteger)((NSInteger)paraLen + runDelta)) continue;
                        NSMutableDictionary *runAttrs = [patchedAttrs mutableCopy];
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
                                        // Create native ICInlineAttachment note-to-note link
                                        Class ICInlineAttachmentClass = NSClassFromString(@"ICInlineAttachment");
                                        if (ICInlineAttachmentClass) {
                                            // Replace display text with U+FFFC
                                            ((void (*)(id, SEL, NSRange))objc_msgSend)(ms, sel_registerName("deleteCharactersInRange:"),
                                                NSMakeRange(pos + runStart, runLen));
                                            ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(ms, sel_registerName("insertString:atIndex:"),
                                                @"\uFFFC", pos + runStart);
                                            NSInteger delta = 1 - (NSInteger)runLen;
                                            runDelta += delta;
                                            cumulativeDelta += delta;
                                            runLen = 1;

                                            // Create the inline attachment (CoreData entity)
                                            NSString *attUUID = [[NSUUID UUID] UUIDString];
                                            id attachment = ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(
                                                ICInlineAttachmentClass,
                                                sel_registerName("newLinkAttachmentWithIdentifier:toNote:fromNote:parentAttachment:"),
                                                attUUID, targetNote, note, nil);
                                            if (attachment) {
                                                ((void (*)(id, SEL, id))objc_msgSend)(note, sel_registerName("addInlineAttachmentsObject:"), attachment);
                                                // Create ICTTAttachment for the mergeableString attribute
                                                if (ICTTAttachmentClass) {
                                                    id ttAtt = [[ICTTAttachmentClass alloc] init];
                                                    ((void (*)(id, SEL, id))objc_msgSend)(ttAtt, sel_registerName("setAttachmentIdentifier:"), attUUID);
                                                    ((void (*)(id, SEL, id))objc_msgSend)(ttAtt, sel_registerName("setAttachmentUTI:"), @"com.apple.notes.inlinetextattachment.link");
                                                    runAttrs[@"NSAttachment"] = ttAtt;
                                                }
                                            }
                                        } else {
                                            // Fallback: use NSLink if ICInlineAttachment unavailable
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
                        {
                            NSUInteger hints = 0;
                            if ([run[@"bold"] boolValue]) hints |= 1;
                            if ([run[@"italic"] boolValue]) hints |= 2;
                            if (hints > 0) runAttrs[@"TTHints"] = @(hints);
                        }
                        if ([run[@"underline"] boolValue]) runAttrs[@"TTUnderline"] = @1;
                        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(ms, sel_registerName("setAttributes:range:"),
                            runAttrs, NSMakeRange(pos + runStart, runLen));
                    }
                }
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

            NSArray *newRuns = newPara[@"runs"];
            NSInteger insertRunDelta = 0; // tracks offset shift from note-link replacements
            if (newRuns) {
                for (NSDictionary *run in newRuns) {
                    NSUInteger runStart = [run[@"start"] unsignedIntegerValue] + insertRunDelta;
                    NSUInteger runLen = [run[@"length"] unsignedIntegerValue];
                    if (runStart + runLen > (NSUInteger)((NSInteger)newText.length + insertRunDelta)) continue;
                    NSMutableDictionary *runAttrs = [attrs mutableCopy];
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
                                    // Create native ICInlineAttachment note-to-note link
                                    Class ICInlineAttachmentClass = NSClassFromString(@"ICInlineAttachment");
                                    if (ICInlineAttachmentClass) {
                                        // Replace display text with U+FFFC
                                        ((void (*)(id, SEL, NSRange))objc_msgSend)(ms, sel_registerName("deleteCharactersInRange:"),
                                            NSMakeRange(pos + runStart, runLen));
                                        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(ms, sel_registerName("insertString:atIndex:"),
                                            @"\uFFFC", pos + runStart);
                                        NSInteger delta = 1 - (NSInteger)runLen;
                                        insertRunDelta += delta;
                                        runLen = 1;

                                        // Create the inline attachment (CoreData entity)
                                        NSString *attUUID = [[NSUUID UUID] UUIDString];
                                        id attachment = ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(
                                            ICInlineAttachmentClass,
                                            sel_registerName("newLinkAttachmentWithIdentifier:toNote:fromNote:parentAttachment:"),
                                            attUUID, targetNote, note, nil);
                                        if (attachment) {
                                            ((void (*)(id, SEL, id))objc_msgSend)(note, sel_registerName("addInlineAttachmentsObject:"), attachment);
                                            // Create ICTTAttachment for the mergeableString attribute
                                            if (ICTTAttachmentClass) {
                                                id ttAtt = [[ICTTAttachmentClass alloc] init];
                                                ((void (*)(id, SEL, id))objc_msgSend)(ttAtt, sel_registerName("setAttachmentIdentifier:"), attUUID);
                                                ((void (*)(id, SEL, id))objc_msgSend)(ttAtt, sel_registerName("setAttachmentUTI:"), @"com.apple.notes.inlinetextattachment.link");
                                                runAttrs[@"NSAttachment"] = ttAtt;
                                            }
                                        }
                                    } else {
                                        // Fallback: use NSLink if ICInlineAttachment unavailable
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
                    {
                        NSUInteger hints = 0;
                        if ([run[@"bold"] boolValue]) hints |= 1;
                        if ([run[@"italic"] boolValue]) hints |= 2;
                        if (hints > 0) runAttrs[@"TTHints"] = @(hints);
                    }
                    if ([run[@"underline"] boolValue]) runAttrs[@"TTUnderline"] = @1;
                    ((void (*)(id, SEL, id, NSRange))objc_msgSend)(ms, sel_registerName("setAttributes:range:"),
                        runAttrs, NSMakeRange(pos + runStart, runLen));
                }
            }

            cumulativeDelta += (NSInteger)toInsert.length + insertRunDelta;
        }

        } @catch (NSException *mutationEx) {
            fprintf(stderr, "warning: skipping mutation op '%s' at pos %lu due to exception: %s\n",
                [opType UTF8String], (unsigned long)pos, [[mutationEx description] UTF8String]);
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
    fprintf(stderr, "notekit — read and edit Apple Notes via the NotesShared framework\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "Data model: A note is a flat string with attribute ranges at character offsets.\n");
    fprintf(stderr, "Each range has a style (0=title, 1=heading, 3=body, 4=code-block, 100=dash-list, 102=numbered-list, 103=checklist), indent level,\n");
    fprintf(stderr, "and optional properties (todo-done, link, strikethrough). Use read-attrs to see\n");
    fprintf(stderr, "the raw attribute stream. All editing operates on character offsets.\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "Primitive commands:\n");
    fprintf(stderr, "  These give you full control over notes. You can do anything with read-attrs,\n");
    fprintf(stderr, "  set-attr, insert, and delete-range.\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "  notekit folders\n");
    fprintf(stderr, "  notekit list [--folder <name>] [--limit <n>]\n");
    fprintf(stderr, "  notekit get (--title <title> | --id <id>) [--folder <name>]\n");
    fprintf(stderr, "  notekit read (--title <title> | --id <id>) [--folder <name>]\n");
    fprintf(stderr, "  notekit read-attrs (--title <title> | --id <id>) [--folder <name>]\n");
    fprintf(stderr, "  notekit create-empty --folder <name>\n");
    fprintf(stderr, "  notekit create --folder <name> --title <title> [--body <text>] [--style <n>]\n");
    fprintf(stderr, "  notekit delete --id <id>\n");
    fprintf(stderr, "  notekit append --id <id> --text <text> [--style <n>]\n");
    fprintf(stderr, "  notekit insert --id <id> --text <text> --position <n> [--style <n>] [--body-offset]\n");
    fprintf(stderr, "  notekit delete-range --id <id> --start <n> --length <n> [--body-offset]\n");
    fprintf(stderr, "  notekit set-attr --id <id> --offset <n> --length <n> [--style <n>] [--indent <n>] [--todo-done true|false] [--link <url>] [--body-offset]\n");
    fprintf(stderr, "  notekit move --id <id> --to <to-folder>\n");
    fprintf(stderr, "  notekit create-folder --name <name>\n");
    fprintf(stderr, "  notekit delete-folder --name <name>\n");
    fprintf(stderr, "  notekit search --query <query> [--folder <name>]\n");
    fprintf(stderr, "  notekit pin --id <id>\n");
    fprintf(stderr, "  notekit unpin --id <id>\n");
    fprintf(stderr, "  notekit get-link --id <id>                     Get applenotes:// URL for note-to-note linking\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "  --body-offset    Treat offset/position/start as relative to body text (after title).\n");
    fprintf(stderr, "                   Use this when offsets come from 'notekit read' output.\n");
    fprintf(stderr, "                   Without this flag, offsets are into the full internal string\n");
    fprintf(stderr, "                   (including leading newline + title + newline).\n");
    fprintf(stderr, "                   Errors if the note has no body text (title-only note).\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "Convenience commands:\n");
    fprintf(stderr, "  These compose multiple primitives for common operations. Everything they do\n");
    fprintf(stderr, "  can be accomplished with the primitive commands above.\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "  notekit search-offset --id <id> --text <text> [--case-insensitive]\n");
    fprintf(stderr, "  notekit replace --id <id> --search <text> --replacement <text>\n");
    fprintf(stderr, "  notekit read-structured (--title <title> | --id <id>) [--folder <name>]\n");
    fprintf(stderr, "  notekit read-markdown (--title <title> | --id <id>) [--folder <name>]\n");
    fprintf(stderr, "  notekit write-markdown --id <id> [--dry-run] [--backup]            Read markdown from stdin, diff-update note\n");
    fprintf(stderr, "  notekit duplicate --id <id> [--new-title <new-title>]\n");
    fprintf(stderr, "  notekit delete-line --id <id> --search-text <search-text>\n");
    fprintf(stderr, "  notekit add-link --id <id> --target <id> [--text <text>] [--position <n>]   Insert note-to-note link\n");
    fprintf(stderr, "  notekit add-note-link --id <id> --target <id> [--position <n>]            Insert native ICInlineAttachment note link\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "Skill management:\n");
    fprintf(stderr, "  notekit install-skill [--claude] [--agents] [--force]\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "Testing:\n");
    fprintf(stderr, "  notekit test\n");
}


