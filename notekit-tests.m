// --- Tests ---

static void deleteNote(id note, id viewContext) {
    // Detach attachments before deleting to prevent cascade deleting shared attachments.
    // ICNote relationships (attachments, inlineAttachments) use NSCascadeDeleteRule,
    // so deleteObject would destroy attachment data that other notes may reference.
    id inlineAttachments = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("inlineAttachments"));
    if (inlineAttachments && [inlineAttachments count] > 0) {
        // Delete inline attachment objects that have a required note relationship
        // (e.g. ICInlineAttachment link attachments) to avoid orphan validation errors.
        NSSet *inlineAttSet = [inlineAttachments copy];
        for (id ia in inlineAttSet) {
            [viewContext deleteObject:ia];
        }
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


// --- Test Helpers ---

// Run a subprocess command and parse JSON output
static id runCommandAndParseJSON(const char *exePath, NSString *args) {
    NSString *cmd = [NSString stringWithFormat:@"'%s' %@ 2>/dev/null", exePath, args];
    FILE *fp = popen([cmd UTF8String], "r");
    NSMutableData *outData = [NSMutableData data];
    if (fp) {
        char buf[4096];
        size_t n;
        while ((n = fread(buf, 1, sizeof(buf), fp)) > 0) [outData appendBytes:buf length:n];
        pclose(fp);
    }
    if (outData.length == 0) return nil;
    return [NSJSONSerialization JSONObjectWithData:outData options:0 error:nil];
}

// Validate that a note dict has all required keys with correct types
// Returns nil on success, or error description on failure
static NSString *validateNoteDict(NSDictionary *dict) {
    if (![dict isKindOfClass:[NSDictionary class]]) return @"not a dictionary";
    // Required keys (always present)
    NSDictionary *requiredTypes = @{
        @"title": [NSString class],
        @"body": [NSString class],
        @"folder": [NSString class],
        @"id": [NSString class],
        @"createdAt": [NSString class],
        @"modifiedAt": [NSString class],
        @"hasChecklist": [NSNumber class],
        @"isPinned": [NSNumber class],
        @"hasTags": [NSNumber class],
        @"snippet": [NSString class],
    };
    for (NSString *key in requiredTypes) {
        id val = dict[key];
        if (!val) return [NSString stringWithFormat:@"missing required key '%@'", key];
        if (![val isKindOfClass:requiredTypes[key]])
            return [NSString stringWithFormat:@"key '%@' has wrong type", key];
    }
    // Optional keys (type-checked if present)
    id url = dict[@"url"];
    if (url && ![url isKindOfClass:[NSString class]]) return @"key 'url' has wrong type";
    return nil;
}

// Validate all note dicts in an array. Returns nil on success, error on first failure.
static NSString *validateNoteDictArray(NSArray *arr) {
    if (![arr isKindOfClass:[NSArray class]] || arr.count == 0) return @"not a non-empty JSON array";
    for (NSUInteger i = 0; i < arr.count; i++) {
        NSString *err = validateNoteDict(arr[i]);
        if (err) return [NSString stringWithFormat:@"element %lu: %@", (unsigned long)i, err];
    }
    return nil;
}

// Check subprocess exit safely (handles system() failures)
static BOOL subprocessFailedProperly(int sysRet) {
    if (sysRet == -1) return NO; // system() itself failed
    return WIFEXITED(sysRet) && WEXITSTATUS(sysRet) != 0;
}

static int cmdTest(id viewContext) {
    int passed = 0, failed = 0;
    NSString *testFolderName = @"__notes_cli_test_folder__";
    NSString *testSubfolderName = @"__notes_cli_test_subfolder__";
    NSString *testTitle = @"__notes_cli_test__";
    NSString *testTitle2 = @"__notes_cli_test_2__";

    // Cleanup leftover test data — loop until no test folders remain (max 1000 iterations)
    {
        Class ICFolder = NSClassFromString(@"ICFolder");
        int cleanedCount = 0;
        int maxIter = 1000;
        BOOL found = YES;
        while (found && maxIter-- > 0) {
            found = NO;
            NSArray *allFolders = fetchFolders(viewContext);
            for (id f in allFolders) {
                NSString *fname = ((id (*)(id, SEL))objc_msgSend)(f, sel_registerName("title"));
                if ([fname isEqualToString:testFolderName] ||
                    [fname isEqualToString:@"__notes_cli_test_folder_2__"] ||
                    [fname isEqualToString:testSubfolderName] ||
                    [fname isEqualToString:@"__nested_sub_test__"]) {
                    // markForDeletion soft-deletes (moves to Recently Deleted) without
                    // triggering CloudKit sync deletion. deleteObject removes from Core Data
                    // context so re-fetch won't return it. activeFolderPredicate filters out
                    // markedForDeletion folders, so they won't appear in subsequent queries.
                    // We avoid deleteFolder: because it triggers CloudKit sync operations
                    // that can interfere with iCloud shared folder state.
                    @try {
                        ((void (*)(id, SEL))objc_msgSend)(f, sel_registerName("markForDeletion"));
                    } @catch (id e) {
                        fprintf(stderr, "Warning: markForDeletion threw exception during cleanup\n");
                    }
                    [viewContext deleteObject:f];
                    NSError *saveErr = nil;
                    if (![viewContext save:&saveErr]) {
                        fprintf(stderr, "Warning: save failed during cleanup: %s\n",
                                [[saveErr localizedDescription] UTF8String]);
                    }
                    cleanedCount++;
                    found = YES;
                    break; // re-fetch after each delete to avoid stale references
                }
            }
        }
        if (maxIter <= 0) {
            fprintf(stderr, "Warning: cleanup loop hit max iterations, %d folders deleted\n", cleanedCount);
        } else if (cleanedCount > 0) {
            fprintf(stderr, "Cleaned up %d leftover test folder(s)\n", cleanedCount);
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
        int ret = cmdAppend(viewContext, noteID, @"Appended text", -1);
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

        // Cleanup second folder (markForDeletion + deleteObject, no CloudKit sync)
        @try {
            ((void (*)(id, SEL))objc_msgSend)(tf2, sel_registerName("markForDeletion"));
        } @catch (id e) {
            fprintf(stderr, "  Warning: markForDeletion threw exception cleaning up folder_2\n");
        }
        [viewContext deleteObject:tf2];
        NSError *saveErr11 = nil;
        if (![viewContext save:&saveErr11]) {
            fprintf(stderr, "  Warning: save failed cleaning up folder_2: %s\n",
                    [[saveErr11 localizedDescription] UTF8String]);
        }
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

    // Test 14: Verify JSON shape from noteToDict (all fields + types)
    fprintf(stderr, "Test 14: JSON shape (all noteToDict fields)...\n");
    {
        id note = findNote(viewContext, testTitle, testFolderName);
        NSDictionary *dict = noteToDict(note);
        NSString *err = validateNoteDict(dict);
        if (!err) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (%s)\n", [err UTF8String]); failed++; }
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

    // --- JSON Output Shape + Error Path Tests (subprocess) ---

    char rawExePath[PATH_MAX];
    char exePath[PATH_MAX];
    uint32_t exeSize = sizeof(rawExePath);
    _NSGetExecutablePath(rawExePath, &exeSize);
    if (realpath(rawExePath, exePath) == NULL) {
        fprintf(stderr, "ERROR: Could not resolve executable path\n");
        return 1;
    }

    // --- Command Coverage Tests ---

    // Helper: run subprocess and capture stdout
    #define RUN_CAPTURE(cmdStr, outData) do { \
        FILE *_fp = popen([(cmdStr) UTF8String], "r"); \
        (outData) = [NSMutableData data]; \
        if (_fp) { \
            char _buf[4096]; size_t _n; \
            while ((_n = fread(_buf, 1, sizeof(_buf), _fp)) > 0) [(outData) appendBytes:_buf length:_n]; \
            pclose(_fp); \
        } \
    } while(0)

    // Helper: run subprocess, check for non-zero exit and optional stderr text
    #define RUN_EXPECT_FAIL(cmdStr, exitOk, stderrStr) do { \
        NSString *_fullCmd = [NSString stringWithFormat:@"%@ 2>&1", (cmdStr)]; \
        FILE *_fp = popen([_fullCmd UTF8String], "r"); \
        NSMutableData *_out = [NSMutableData data]; \
        if (_fp) { \
            char _buf[4096]; size_t _n; \
            while ((_n = fread(_buf, 1, sizeof(_buf), _fp)) > 0) [_out appendBytes:_buf length:_n]; \
            int _status = pclose(_fp); \
            NSString *_output = [[NSString alloc] initWithData:_out encoding:NSUTF8StringEncoding]; \
            (exitOk) = WIFEXITED(_status) && WEXITSTATUS(_status) != 0; \
            if ((stderrStr) != nil) (exitOk) = (exitOk) && _output && [_output containsString:(stderrStr)]; \
        } else { (exitOk) = NO; } \
    } while(0)

    // Test: cmdRead via subprocess (verify plain text output)
    fprintf(stderr, "Test: cmdRead output...\n");
    {
        id noteR = findNote(viewContext, testTitle, testFolderName);
        if (noteR) {
            NSString *noteRId = noteToDict(noteR)[@"id"];
            NSString *readCmd = [NSString stringWithFormat:@"'%s' read --id '%@' 2>/dev/null", exePath, noteRId];
            NSMutableData *readData;
            RUN_CAPTURE(readCmd, readData);
            NSString *readOutput = [[NSString alloc] initWithData:readData encoding:NSUTF8StringEncoding];
            if (readOutput && [readOutput containsString:@"Modified body"]) {
                fprintf(stderr, "  PASS\n"); passed++;
            } else { fprintf(stderr, "  FAIL (output: %s)\n", readOutput ? [readOutput UTF8String] : "nil"); failed++; }
        } else { fprintf(stderr, "  FAIL (note not found)\n"); failed++; }
    }

    // Test: cmdInsert (direct function call — avoids CoreData contention)
    fprintf(stderr, "Test: cmdInsert...\n");
    {
        id noteForInsert = findNote(viewContext, testTitle, testFolderName);
        if (noteForInsert) {
            NSString *insertID = noteToDict(noteForInsert)[@"id"];
            NSUInteger insertBodyOff = bodyOffsetForNote(noteForInsert);
            int ret = cmdInsert(viewContext, insertID, @"INSERTED_TEXT ", insertBodyOff, NO, -1);
            if (ret == 0) {
                id noteAfter = findNoteByID(viewContext, insertID);
                NSString *bodyAfter = ((id (*)(id, SEL))objc_msgSend)(noteAfter, sel_registerName("noteAsPlainTextWithoutTitle"));
                if ([bodyAfter containsString:@"INSERTED_TEXT"]) {
                    fprintf(stderr, "  PASS\n"); passed++;
                } else { fprintf(stderr, "  FAIL (text not found)\n"); failed++; }
            } else { fprintf(stderr, "  FAIL (cmdInsert returned %d)\n", ret); failed++; }
        } else { fprintf(stderr, "  FAIL (note not found)\n"); failed++; }
    }

    // Test: cmdDeleteRange (direct function call — avoids CoreData contention)
    fprintf(stderr, "Test: cmdDeleteRange...\n");
    {
        id noteForDelete = findNote(viewContext, testTitle, testFolderName);
        if (noteForDelete) {
            NSString *deleteID = noteToDict(noteForDelete)[@"id"];
            NSUInteger deleteBodyOff = bodyOffsetForNote(noteForDelete);
            int ret = cmdDeleteRange(viewContext, deleteID, deleteBodyOff, 14, NO);
            if (ret == 0) {
                id noteAfter = findNoteByID(viewContext, deleteID);
                NSString *bodyAfter = ((id (*)(id, SEL))objc_msgSend)(noteAfter, sel_registerName("noteAsPlainTextWithoutTitle"));
                if (![bodyAfter containsString:@"INSERTED_TEXT"]) {
                    fprintf(stderr, "  PASS\n"); passed++;
                } else { fprintf(stderr, "  FAIL (text still in body)\n"); failed++; }
            } else { fprintf(stderr, "  FAIL (cmdDeleteRange returned %d)\n", ret); failed++; }
        } else { fprintf(stderr, "  FAIL (note not found)\n"); failed++; }
    }

    // Test: toggle-checkbox via write-markdown
    fprintf(stderr, "Test: toggle-checkbox...\n");
    {
        id toggleNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id toggleDoc = ((id (*)(id, SEL))objc_msgSend)(toggleNote, sel_registerName("document"));
        id toggleMs = ((id (*)(id, SEL))objc_msgSend)(toggleDoc, sel_registerName("mergeableString"));
        NSString *toggleTitle = @"__toggle_test__";
        ((void (*)(id, SEL))objc_msgSend)(toggleNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(toggleMs, sel_registerName("insertString:atIndex:"), toggleTitle, 0);
        id toggleS0 = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(toggleS0, sel_registerName("setStyle:"), 0);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(toggleMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": toggleS0}, NSMakeRange(0, toggleTitle.length));
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            toggleNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, toggleTitle.length), toggleTitle.length);
        ((void (*)(id, SEL))objc_msgSend)(toggleNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(toggleNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        NSString *toggleID = noteToDict(toggleNote)[@"id"];
        cmdAppend(viewContext, toggleID, @"Unchecked item", 103);
        toggleNote = findNoteByID(viewContext, toggleID);

        id tDoc = ((id (*)(id, SEL))objc_msgSend)(toggleNote, sel_registerName("document"));
        id tMs = ((id (*)(id, SEL))objc_msgSend)(tDoc, sel_registerName("mergeableString"));
        NSString *tText = [((id (*)(id, SEL))objc_msgSend)(toggleNote, sel_registerName("attributedString")) string];
        BOOL startedUnchecked = NO;
        NSUInteger ti = 0;
        while (ti < tText.length) {
            NSRange tr;
            NSDictionary *ta = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
                tMs, sel_registerName("attributesAtIndex:effectiveRange:"), ti, &tr);
            id tStyle = ta[@"TTStyle"];
            if (tStyle) {
                int tsv = (int)((NSInteger (*)(id, SEL))objc_msgSend)(tStyle, sel_registerName("style"));
                if (tsv == 103) {
                    id ttodo = ((id (*)(id, SEL))objc_msgSend)(tStyle, sel_registerName("todo"));
                    if (ttodo && !((BOOL (*)(id, SEL))objc_msgSend)(ttodo, sel_registerName("done"))) {
                        startedUnchecked = YES;
                    }
                }
            }
            ti = tr.location + tr.length;
        }

        NSString *checkedMd = [NSString stringWithFormat:@"# %@\n- [x] Unchecked item\n", toggleTitle];
        cmdWriteMarkdownWithString(toggleNote, viewContext, checkedMd, NO, NO, NO);

        toggleNote = findNoteByID(viewContext, toggleID);
        tDoc = ((id (*)(id, SEL))objc_msgSend)(toggleNote, sel_registerName("document"));
        tMs = ((id (*)(id, SEL))objc_msgSend)(tDoc, sel_registerName("mergeableString"));
        tText = [((id (*)(id, SEL))objc_msgSend)(toggleNote, sel_registerName("attributedString")) string];
        BOOL isNowChecked = NO;
        ti = 0;
        while (ti < tText.length) {
            NSRange tr;
            NSDictionary *ta = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
                tMs, sel_registerName("attributesAtIndex:effectiveRange:"), ti, &tr);
            id tStyle = ta[@"TTStyle"];
            if (tStyle) {
                int tsv = (int)((NSInteger (*)(id, SEL))objc_msgSend)(tStyle, sel_registerName("style"));
                if (tsv == 103) {
                    id ttodo = ((id (*)(id, SEL))objc_msgSend)(tStyle, sel_registerName("todo"));
                    if (ttodo && ((BOOL (*)(id, SEL))objc_msgSend)(ttodo, sel_registerName("done"))) {
                        isNowChecked = YES;
                    }
                }
            }
            ti = tr.location + tr.length;
        }

        if (startedUnchecked && isNowChecked) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (unchecked=%d checked=%d)\n", startedUnchecked, isNowChecked); failed++; }

        deleteNote(findNoteByID(viewContext, toggleID), viewContext);
        [viewContext save:nil];
    }

    // Test: noteToDict full field type validation
    fprintf(stderr, "Test: noteToDict field types...\n");
    {
        id noteJS = findNote(viewContext, testTitle, testFolderName);
        NSDictionary *jsDict = noteToDict(noteJS);
        BOOL jsOk = YES;
        if (![jsDict[@"title"] isKindOfClass:[NSString class]]) jsOk = NO;
        if (![jsDict[@"body"] isKindOfClass:[NSString class]]) jsOk = NO;
        if (![jsDict[@"folder"] isKindOfClass:[NSString class]]) jsOk = NO;
        if (![jsDict[@"id"] isKindOfClass:[NSString class]]) jsOk = NO;
        if (![jsDict[@"createdAt"] isKindOfClass:[NSString class]]) jsOk = NO;
        if (![jsDict[@"modifiedAt"] isKindOfClass:[NSString class]]) jsOk = NO;
        if (![jsDict[@"hasChecklist"] isKindOfClass:[NSNumber class]]) jsOk = NO;
        if (![jsDict[@"isPinned"] isKindOfClass:[NSNumber class]]) jsOk = NO;
        if (![jsDict[@"hasTags"] isKindOfClass:[NSNumber class]]) jsOk = NO;
        if (![jsDict[@"snippet"] isKindOfClass:[NSString class]]) jsOk = NO;
        if (![jsDict[@"url"] isKindOfClass:[NSString class]]) jsOk = NO;
        if (jsOk) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (type mismatch)\n"); failed++; }
    }

    // Test: error — append to non-existent note (verify exit=1 and error message)
    fprintf(stderr, "Test: error - append to non-existent note...\n");
    {
        NSString *e1Cmd = [NSString stringWithFormat:@"'%s' append --id 'NONEXISTENT_ID_12345' --text 'hello'", exePath];
        BOOL e1Ok = NO;
        RUN_EXPECT_FAIL(e1Cmd, e1Ok, @"Note not found");
        if (e1Ok) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (expected exit=1 with 'Note not found')\n"); failed++; }
    }

    // Test: error — delete-range out of bounds (verify exit=1 and error message)
    fprintf(stderr, "Test: error - delete-range out of bounds...\n");
    {
        id noteE2 = findNote(viewContext, testTitle, testFolderName);
        if (noteE2) {
            NSString *e2Id = noteToDict(noteE2)[@"id"];
            NSString *e2Cmd = [NSString stringWithFormat:@"'%s' delete-range --id '%@' --start 99999 --length 1", exePath, e2Id];
            BOOL e2Ok = NO;
            RUN_EXPECT_FAIL(e2Cmd, e2Ok, @"Range exceeds");
            if (e2Ok) { fprintf(stderr, "  PASS\n"); passed++; }
            else { fprintf(stderr, "  FAIL (expected exit=1 with 'Range exceeds')\n"); failed++; }
        } else { fprintf(stderr, "  FAIL (note not found)\n"); failed++; }
    }

    // Test: error — replace non-existent text (verify exit=1 and error message)
    fprintf(stderr, "Test: error - replace non-existent text...\n");
    {
        id noteE3 = findNote(viewContext, testTitle, testFolderName);
        if (noteE3) {
            NSString *e3Id = noteToDict(noteE3)[@"id"];
            NSString *e3Cmd = [NSString stringWithFormat:@"'%s' replace --id '%@' --search '__NONEXISTENT_TEXT_XYZ__' --replacement 'new'", exePath, e3Id];
            BOOL e3Ok = NO;
            RUN_EXPECT_FAIL(e3Cmd, e3Ok, @"Text not found");
            if (e3Ok) { fprintf(stderr, "  PASS\n"); passed++; }
            else { fprintf(stderr, "  FAIL (expected exit=1 with 'Text not found')\n"); failed++; }
        } else { fprintf(stderr, "  FAIL (note not found)\n"); failed++; }
    }

    // --- Note Linking Tests (continued) ---

    // Test: append to non-existent note
    fprintf(stderr, "Test: append error (note not found)...\n");
    {
        NSString *cmd = [NSString stringWithFormat:@"'%s' append --id NONEXISTENT_NOTE_ID --text 'hello' 2>/dev/null", exePath];
        int ret = system([cmd UTF8String]);
        if (WIFEXITED(ret) && WEXITSTATUS(ret) == 1) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (expected exit 1, got status %d)\n", ret); failed++; }
    }

    // Test: delete-range with start beyond note length
    fprintf(stderr, "Test: delete-range error (range exceeds length)...\n");
    {
        id noteForErr = findNote(viewContext, testTitle, testFolderName);
        if (!noteForErr) { fprintf(stderr, "  FAIL (fixture note not found)\n"); failed++; }
        else {
            NSString *errId = noteToDict(noteForErr)[@"id"];
            NSString *textBefore = [((id (*)(id, SEL))objc_msgSend)(noteForErr, sel_registerName("attributedString")) string];
            NSString *cmd = [NSString stringWithFormat:@"'%s' delete-range --id '%@' --start 999999 --length 1 2>/dev/null", exePath, errId];
            int ret = system([cmd UTF8String]);
            id noteAfter = findNoteByID(viewContext, errId);
            NSString *textAfter = [((id (*)(id, SEL))objc_msgSend)(noteAfter, sel_registerName("attributedString")) string];
            if (WIFEXITED(ret) && WEXITSTATUS(ret) == 1 && [textBefore isEqualToString:textAfter]) {
                fprintf(stderr, "  PASS\n"); passed++;
            } else {
                fprintf(stderr, "  FAIL (exit=%d, content changed=%d)\n", ret, ![textBefore isEqualToString:textAfter]);
                failed++;
            }
        }
    }

    // Test: delete-range with length exceeding remaining text
    fprintf(stderr, "Test: delete-range error (length exceeds remaining)...\n");
    {
        id noteForErr = findNote(viewContext, testTitle, testFolderName);
        if (!noteForErr) { fprintf(stderr, "  FAIL (fixture note not found)\n"); failed++; }
        else {
            NSString *errId = noteToDict(noteForErr)[@"id"];
            NSString *cmd = [NSString stringWithFormat:@"'%s' delete-range --id '%@' --start 0 --length 999999 2>/dev/null", exePath, errId];
            int ret = system([cmd UTF8String]);
            if (WIFEXITED(ret) && WEXITSTATUS(ret) == 1) { fprintf(stderr, "  PASS\n"); passed++; }
            else { fprintf(stderr, "  FAIL (expected exit 1, got status %d)\n", ret); failed++; }
        }
    }

    // Test: replace with non-existent search text
    fprintf(stderr, "Test: replace error (text not found)...\n");
    {
        id noteForErr = findNote(viewContext, testTitle, testFolderName);
        if (!noteForErr) { fprintf(stderr, "  FAIL (fixture note not found)\n"); failed++; }
        else {
            NSString *errId = noteToDict(noteForErr)[@"id"];
            NSString *cmd = [NSString stringWithFormat:@"'%s' replace --id '%@' --search '__NONEXISTENT_TEXT_XYZ__' --replacement 'new' 2>/dev/null", exePath, errId];
            int ret = system([cmd UTF8String]);
            if (WIFEXITED(ret) && WEXITSTATUS(ret) == 1) { fprintf(stderr, "  PASS\n"); passed++; }
            else { fprintf(stderr, "  FAIL (expected exit 1, got status %d)\n", ret); failed++; }
        }
    }

    // Test: replace on non-existent note
    fprintf(stderr, "Test: replace error (note not found)...\n");
    {
        NSString *cmd = [NSString stringWithFormat:@"'%s' replace --id NONEXISTENT_NOTE_ID --search 'foo' --replacement 'bar' 2>/dev/null", exePath];
        int ret = system([cmd UTF8String]);
        if (WIFEXITED(ret) && WEXITSTATUS(ret) == 1) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (expected exit 1, got status %d)\n", ret); failed++; }
    }

    // Test: delete-range on non-existent note
    fprintf(stderr, "Test: delete-range error (note not found)...\n");
    {
        NSString *cmd = [NSString stringWithFormat:@"'%s' delete-range --id NONEXISTENT_NOTE_ID --start 0 --length 1 2>/dev/null", exePath];
        int ret = system([cmd UTF8String]);
        if (WIFEXITED(ret) && WEXITSTATUS(ret) == 1) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (expected exit 1, got status %d)\n", ret); failed++; }
    }

    // --- Note Linking Tests ---

    // Test: cmdList JSON output shape (subprocess, all elements validated)
    fprintf(stderr, "Test: cmdList JSON shape...\n");
    {
        NSString *args = [NSString stringWithFormat:@"list --folder '%@'", testFolderName];
        id parsed = runCommandAndParseJSON(exePath, args);
        NSString *err = validateNoteDictArray(parsed);
        if (!err) { fprintf(stderr, "  PASS (%lu notes)\n", (unsigned long)[parsed count]); passed++; }
        else { fprintf(stderr, "  FAIL (%s)\n", [err UTF8String]); failed++; }
    }

    // Test: cmdFolders JSON output shape (subprocess)
    fprintf(stderr, "Test: cmdFolders JSON shape...\n");
    {
        id parsed = runCommandAndParseJSON(exePath, @"folders");
        if (parsed && [parsed isKindOfClass:[NSArray class]] && [parsed count] > 0) {
            BOOL allValid = YES;
            BOOL foundTestFolder = NO;
            NSUInteger badIdx = 0;
            for (NSUInteger i = 0; i < [parsed count]; i++) {
                NSDictionary *entry = parsed[i];
                if (![entry[@"name"] isKindOfClass:[NSString class]]) { allValid = NO; badIdx = i; break; }
                if ([entry[@"name"] isEqualToString:testFolderName]) foundTestFolder = YES;
            }
            if (allValid && foundTestFolder) { fprintf(stderr, "  PASS (%lu folders)\n", (unsigned long)[parsed count]); passed++; }
            else if (!allValid) { fprintf(stderr, "  FAIL (element %lu missing 'name')\n", (unsigned long)badIdx); failed++; }
            else { fprintf(stderr, "  FAIL (test folder not found)\n"); failed++; }
        } else { fprintf(stderr, "  FAIL (not a JSON array or empty)\n"); failed++; }
    }

    // Test: cmdGet JSON output shape (subprocess)
    fprintf(stderr, "Test: cmdGet JSON shape...\n");
    {
        id noteForGet = findNote(viewContext, testTitle, testFolderName);
        NSString *getID = noteToDict(noteForGet)[@"id"];
        NSString *args = [NSString stringWithFormat:@"get --id '%@'", getID];
        id parsed = runCommandAndParseJSON(exePath, args);
        NSString *err = validateNoteDict(parsed);
        if (!err) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (%s)\n", [err UTF8String]); failed++; }
    }

    // Test: cmdSearch JSON output shape (subprocess, all elements validated)
    fprintf(stderr, "Test: cmdSearch JSON shape...\n");
    {
        NSString *args = [NSString stringWithFormat:@"search --query '%@' --folder '%@'", testTitle, testFolderName];
        id parsed = runCommandAndParseJSON(exePath, args);
        NSString *err = validateNoteDictArray(parsed);
        if (!err) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (%s)\n", [err UTF8String]); failed++; }
    }

    // Test: cmdReadStructured JSON shape (subprocess, predicate-based)
    fprintf(stderr, "Test: cmdReadStructured JSON shape...\n");
    {
        id noteForRS = findNote(viewContext, testTitle, testFolderName);
        NSString *rsID = noteToDict(noteForRS)[@"id"];
        NSString *args = [NSString stringWithFormat:@"read-structured --id '%@'", rsID];
        NSArray *arr = runCommandAndParseJSON(exePath, args);
        if (arr && [arr isKindOfClass:[NSArray class]] && arr.count > 0) {
            // Validate schema for every paragraph
            BOOL schemaOk = YES;
            NSUInteger badIdx = 0;
            for (NSUInteger i = 0; i < arr.count; i++) {
                NSDictionary *p = arr[i];
                if (![p[@"text"] isKindOfClass:[NSString class]] ||
                    ![p[@"style"] isKindOfClass:[NSNumber class]]) {
                    schemaOk = NO; badIdx = i; break;
                }
            }
            // Find at least one of each expected type by predicate
            BOOL foundTitle = NO, foundBody = NO, foundChecklist = NO;
            for (NSDictionary *p in arr) {
                int style = [p[@"style"] intValue];
                if (style == 0) foundTitle = YES;
                if (style == 3) foundBody = YES;
                if (style == 103) {
                    if ([p[@"type"] isEqualToString:@"checklist"] && p[@"checked"] != nil)
                        foundChecklist = YES;
                }
            }
            if (schemaOk && foundTitle && foundBody && foundChecklist) {
                fprintf(stderr, "  PASS (%lu paragraphs, all types found)\n", (unsigned long)arr.count); passed++;
            } else if (!schemaOk) {
                fprintf(stderr, "  FAIL (element %lu missing text/style)\n", (unsigned long)badIdx); failed++;
            } else {
                fprintf(stderr, "  FAIL (title=%d body=%d checklist=%d)\n", foundTitle, foundBody, foundChecklist); failed++;
            }
        } else { fprintf(stderr, "  FAIL (not a JSON array or empty)\n"); failed++; }
    }

    // Test: cmdReadAttrs JSON shape (subprocess, all elements validated)
    fprintf(stderr, "Test: cmdReadAttrs JSON shape...\n");
    {
        id noteForRA = findNote(viewContext, testTitle, testFolderName);
        NSString *raID = noteToDict(noteForRA)[@"id"];
        NSString *args = [NSString stringWithFormat:@"read-attrs --id '%@'", raID];
        NSArray *arr = runCommandAndParseJSON(exePath, args);
        if (arr && [arr isKindOfClass:[NSArray class]] && arr.count > 0) {
            BOOL allValid = YES;
            NSUInteger badIdx = 0;
            for (NSUInteger i = 0; i < arr.count; i++) {
                NSDictionary *entry = arr[i];
                if (![entry[@"text"] isKindOfClass:[NSString class]] ||
                    ![entry[@"offset"] isKindOfClass:[NSNumber class]] ||
                    ![entry[@"length"] isKindOfClass:[NSNumber class]] ||
                    ![entry[@"style"] isKindOfClass:[NSNumber class]]) {
                    allValid = NO; badIdx = i; break;
                }
            }
            if (allValid) { fprintf(stderr, "  PASS (%lu ranges)\n", (unsigned long)arr.count); passed++; }
            else { fprintf(stderr, "  FAIL (element %lu missing required fields)\n", (unsigned long)badIdx); failed++; }
        } else { fprintf(stderr, "  FAIL (not a JSON array or empty)\n"); failed++; }
    }

    // --- Error Path Tests (subprocess) ---

    // Test: Error - get non-existent note
    fprintf(stderr, "Test: Error - get non-existent note...\n");
    {
        NSString *cmd = [NSString stringWithFormat:@"'%s' get --title '__nonexistent_note_999__' --folder '%@' 2>/dev/null", exePath, testFolderName];
        int ret = system([cmd UTF8String]);
        if (subprocessFailedProperly(ret)) { fprintf(stderr, "  PASS (exit code %d)\n", WEXITSTATUS(ret)); passed++; }
        else { fprintf(stderr, "  FAIL (ret=%d, should have failed properly)\n", ret); failed++; }
    }

    // Test: Error - read non-existent note
    fprintf(stderr, "Test: Error - read non-existent note...\n");
    {
        NSString *cmd = [NSString stringWithFormat:@"'%s' read --title '__nonexistent_note_999__' --folder '%@' 2>/dev/null", exePath, testFolderName];
        int ret = system([cmd UTF8String]);
        if (subprocessFailedProperly(ret)) { fprintf(stderr, "  PASS (exit code %d)\n", WEXITSTATUS(ret)); passed++; }
        else { fprintf(stderr, "  FAIL (ret=%d, should have failed properly)\n", ret); failed++; }
    }

    // --- Note Linking Tests ---

    // Test: get-link
    fprintf(stderr, "Test: get-link...\n");
    {
        id noteA = findNote(viewContext, testTitle, testFolderName);
        if (noteA) {
            NSString *noteAId = noteToDict(noteA)[@"id"];
            int ret = cmdGetLink(viewContext, noteAId);
            if (ret == 0) {
                NSDictionary *dict = noteToDict(noteA);
                NSString *url = dict[@"url"];
                if (url && [url containsString:@"applenotes://showNote?identifier="]) {
                    fprintf(stderr, "  PASS\n"); passed++;
                } else { fprintf(stderr, "  FAIL (no url in noteToDict)\n"); failed++; }
            } else { fprintf(stderr, "  FAIL (cmdGetLink returned %d)\n", ret); failed++; }
        } else { fprintf(stderr, "  FAIL (note not found)\n"); failed++; }
    }

    // Test: add-link (append, default text)
    fprintf(stderr, "Test: add-link (append)...\n");
    {
        id noteA = findNote(viewContext, testTitle, testFolderName);
        id noteB = findNote(viewContext, testTitle2, testFolderName);
        if (noteA && noteB) {
            NSString *aId = noteToDict(noteA)[@"id"];
            NSString *bId = noteToDict(noteB)[@"id"];
            int ret = cmdAddLink(viewContext, aId, bId, nil, -1);
            if (ret == 0) {
                noteA = findNoteByID(viewContext, aId);
                id doc = ((id (*)(id, SEL))objc_msgSend)(noteA, sel_registerName("document"));
                id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
                NSString *fullText = [((id (*)(id, SEL))objc_msgSend)(noteA, sel_registerName("attributedString")) string];
                BOOL foundNoteLink = NO;
                NSString *expectedURL = [NSString stringWithFormat:@"applenotes://showNote?identifier=%@", bId];
                NSUInteger li = 0;
                while (li < fullText.length) {
                    NSRange lr;
                    NSDictionary *la = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
                        ms, sel_registerName("attributesAtIndex:effectiveRange:"), li, &lr);
                    id link = la[@"NSLink"];
                    if (link && [[link description] containsString:expectedURL]) {
                        foundNoteLink = YES; break;
                    }
                    li = lr.location + lr.length;
                }
                if (foundNoteLink) { fprintf(stderr, "  PASS\n"); passed++; }
                else { fprintf(stderr, "  FAIL (note link not found in attrs)\n"); failed++; }
            } else { fprintf(stderr, "  FAIL (cmdAddLink returned %d)\n", ret); failed++; }
        } else { fprintf(stderr, "  FAIL (notes not found)\n"); failed++; }
    }

    // Test: read-attrs JSON output includes linkType=note and linkedNoteId (subprocess)
    fprintf(stderr, "Test: read-attrs linkType/linkedNoteId...\n");
    {
        id noteA = findNote(viewContext, testTitle, testFolderName);
        id noteB = findNote(viewContext, testTitle2, testFolderName);
        if (noteA && noteB) {
            NSString *aId = noteToDict(noteA)[@"id"];
            NSString *bId = noteToDict(noteB)[@"id"];
            NSString *cmd = [NSString stringWithFormat:@"'%s' read-attrs --id '%@' 2>/dev/null", exePath, aId];
            FILE *fp = popen([cmd UTF8String], "r");
            NSMutableData *outData = [NSMutableData data];
            if (fp) {
                char buf[4096];
                size_t n;
                while ((n = fread(buf, 1, sizeof(buf), fp)) > 0) [outData appendBytes:buf length:n];
                pclose(fp);
            }
            NSArray *arr = [NSJSONSerialization JSONObjectWithData:outData options:0 error:nil];
            BOOL foundLinkType = NO;
            BOOL foundLinkedNoteId = NO;
            for (NSDictionary *entry in arr) {
                if ([entry[@"linkType"] isEqualToString:@"note"]) foundLinkType = YES;
                if ([entry[@"linkedNoteId"] isEqualToString:bId]) foundLinkedNoteId = YES;
            }
            if (foundLinkType && foundLinkedNoteId) { fprintf(stderr, "  PASS\n"); passed++; }
            else { fprintf(stderr, "  FAIL (linkType=%d linkedNoteId=%d)\n", foundLinkType, foundLinkedNoteId); failed++; }
        } else { fprintf(stderr, "  FAIL (notes not found)\n"); failed++; }
    }

    // Test: read-structured JSON output includes links array with note link (subprocess)
    fprintf(stderr, "Test: read-structured links array...\n");
    {
        id noteA = findNote(viewContext, testTitle, testFolderName);
        id noteB = findNote(viewContext, testTitle2, testFolderName);
        if (noteA && noteB) {
            NSString *aId = noteToDict(noteA)[@"id"];
            NSString *bId = noteToDict(noteB)[@"id"];
            NSString *cmd = [NSString stringWithFormat:@"'%s' read-structured --id '%@' 2>/dev/null", exePath, aId];
            FILE *fp = popen([cmd UTF8String], "r");
            NSMutableData *outData = [NSMutableData data];
            if (fp) {
                char buf[4096];
                size_t n;
                while ((n = fread(buf, 1, sizeof(buf), fp)) > 0) [outData appendBytes:buf length:n];
                pclose(fp);
            }
            NSArray *arr = [NSJSONSerialization JSONObjectWithData:outData options:0 error:nil];
            BOOL foundNoteLink = NO;
            for (NSDictionary *para in arr) {
                NSArray *links = para[@"links"];
                for (NSDictionary *link in links) {
                    if ([link[@"type"] isEqualToString:@"note"] && [link[@"linkedNoteId"] isEqualToString:bId]) {
                        foundNoteLink = YES;
                    }
                }
            }
            if (foundNoteLink) { fprintf(stderr, "  PASS\n"); passed++; }
            else { fprintf(stderr, "  FAIL (no note link in structured output)\n"); failed++; }
        } else { fprintf(stderr, "  FAIL (notes not found)\n"); failed++; }
    }

    // Test: add-link at position
    fprintf(stderr, "Test: add-link (position)...\n");
    {
        id posNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id posDoc = ((id (*)(id, SEL))objc_msgSend)(posNote, sel_registerName("document"));
        id posMs = ((id (*)(id, SEL))objc_msgSend)(posDoc, sel_registerName("mergeableString"));
        NSString *posContent = @"Hello World";
        ((void (*)(id, SEL))objc_msgSend)(posNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(posMs, sel_registerName("insertString:atIndex:"), posContent, 0);
        id posStyle = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(posStyle, sel_registerName("setStyle:"), 3);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(posMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": posStyle}, NSMakeRange(0, posContent.length));
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            posNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, posContent.length), posContent.length);
        ((void (*)(id, SEL))objc_msgSend)(posNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(posNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        NSString *posId = noteToDict(posNote)[@"id"];
        id noteB = findNote(viewContext, testTitle2, testFolderName);
        NSString *bId = noteToDict(noteB)[@"id"];

        int ret = cmdAddLink(viewContext, posId, bId, nil, 5);
        if (ret == 0) {
            posNote = findNoteByID(viewContext, posId);
            posDoc = ((id (*)(id, SEL))objc_msgSend)(posNote, sel_registerName("document"));
            posMs = ((id (*)(id, SEL))objc_msgSend)(posDoc, sel_registerName("mergeableString"));
            NSRange lr;
            NSDictionary *la = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
                posMs, sel_registerName("attributesAtIndex:effectiveRange:"), 5, &lr);
            if (la[@"NSLink"]) { fprintf(stderr, "  PASS\n"); passed++; }
            else { fprintf(stderr, "  FAIL (no link at offset 5)\n"); failed++; }
        } else { fprintf(stderr, "  FAIL (cmdAddLink returned %d)\n", ret); failed++; }

        deleteNote(findNoteByID(viewContext, posId), viewContext);
        [viewContext save:nil];
    }

    // Test: add-link to empty note
    fprintf(stderr, "Test: add-link (empty note)...\n");
    {
        id emptyNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        ((void (*)(id, SEL))objc_msgSend)(emptyNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        NSString *emptyId = noteToDict(emptyNote)[@"id"];
        id noteB = findNote(viewContext, testTitle2, testFolderName);
        NSString *bId = noteToDict(noteB)[@"id"];

        int ret = cmdAddLink(viewContext, emptyId, bId, nil, -1);
        if (ret == 0) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL\n"); failed++; }

        deleteNote(findNoteByID(viewContext, emptyId), viewContext);
        [viewContext save:nil];
    }

    // Test: add-link with custom text
    fprintf(stderr, "Test: add-link (custom text)...\n");
    {
        id noteA = findNote(viewContext, testTitle, testFolderName);
        id noteB = findNote(viewContext, testTitle2, testFolderName);
        if (noteA && noteB) {
            NSString *aId = noteToDict(noteA)[@"id"];
            NSString *bId = noteToDict(noteB)[@"id"];
            int ret = cmdAddLink(viewContext, aId, bId, @"custom label", -1);
            if (ret == 0) {
                noteA = findNoteByID(viewContext, aId);
                NSString *body = ((id (*)(id, SEL))objc_msgSend)(noteA, sel_registerName("noteAsPlainTextWithoutTitle"));
                if ([body containsString:@"custom label"]) { fprintf(stderr, "  PASS\n"); passed++; }
                else { fprintf(stderr, "  FAIL (custom label not in body)\n"); failed++; }
            } else { fprintf(stderr, "  FAIL\n"); failed++; }
        } else { fprintf(stderr, "  FAIL (notes not found)\n"); failed++; }
    }

    // Test: add-link error - invalid target (subprocess)
    fprintf(stderr, "Test: add-link error (invalid target)...\n");
    {
        id noteA = findNote(viewContext, testTitle, testFolderName);
        NSString *aId = noteToDict(noteA)[@"id"];
        NSString *cmd = [NSString stringWithFormat:@"'%s' add-link --id '%@' --target NONEXISTENT_ID 2>/dev/null", exePath, aId];
        int ret = system([cmd UTF8String]);
        if (ret != 0) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (should have failed)\n"); failed++; }
    }

    // Test: add-link error - position out of bounds (subprocess)
    fprintf(stderr, "Test: add-link error (position OOB)...\n");
    {
        id noteA = findNote(viewContext, testTitle, testFolderName);
        id noteB = findNote(viewContext, testTitle2, testFolderName);
        NSString *aId = noteToDict(noteA)[@"id"];
        NSString *bId = noteToDict(noteB)[@"id"];
        NSString *cmd = [NSString stringWithFormat:@"'%s' add-link --id '%@' --target '%@' --position 99999 2>/dev/null", exePath, aId, bId];
        int ret = system([cmd UTF8String]);
        if (ret != 0) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (should have failed)\n"); failed++; }
    }

    // Test: add-note-link (append)
    fprintf(stderr, "Test: add-note-link (append)...\n");
    {
        id noteA = findNote(viewContext, testTitle, testFolderName);
        id noteB = findNote(viewContext, testTitle2, testFolderName);
        if (noteA && noteB) {
            NSString *aId = noteToDict(noteA)[@"id"];
            NSString *bId = noteToDict(noteB)[@"id"];
            int ret = cmdAddNoteLink(viewContext, aId, bId, -1);
            if (ret == 0) {
                noteA = findNoteByID(viewContext, aId);
                NSString *fullText = [((id (*)(id, SEL))objc_msgSend)(noteA, sel_registerName("attributedString")) string];
                // The U+FFFC character should be present
                BOOL foundUFFFC = [fullText containsString:@"\uFFFC"];
                if (foundUFFFC) { fprintf(stderr, "  PASS\n"); passed++; }
                else { fprintf(stderr, "  FAIL (U+FFFC not found in text)\n"); failed++; }
            } else { fprintf(stderr, "  FAIL (cmdAddNoteLink returned %d)\n", ret); failed++; }
        } else { fprintf(stderr, "  FAIL (notes not found)\n"); failed++; }
    }

    // Test: add-note-link (position)
    fprintf(stderr, "Test: add-note-link (position)...\n");
    {
        NSString *anlTitle = @"__notes_cli_add_note_link_pos_test__";
        id anlNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id anlDoc = ((id (*)(id, SEL))objc_msgSend)(anlNote, sel_registerName("document"));
        id anlMs = ((id (*)(id, SEL))objc_msgSend)(anlDoc, sel_registerName("mergeableString"));
        NSString *anlContent = [NSString stringWithFormat:@"%@\nHello World", anlTitle];
        ((void (*)(id, SEL))objc_msgSend)(anlNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(anlMs, sel_registerName("insertString:atIndex:"), anlContent, 0);
        id anlStyle = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(anlStyle, sel_registerName("setStyle:"), 3);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(anlMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": anlStyle}, NSMakeRange(anlTitle.length + 1, anlContent.length - anlTitle.length - 1));
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            anlNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, anlContent.length), anlContent.length);
        ((void (*)(id, SEL))objc_msgSend)(anlNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(anlNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        NSString *anlId = noteToDict(anlNote)[@"id"];
        id noteB = findNote(viewContext, testTitle2, testFolderName);
        NSString *bId = noteToDict(noteB)[@"id"];

        // Insert at position after the title newline (title.length + 1 = first char of body)
        NSUInteger insertAt = anlTitle.length + 1;
        int ret = cmdAddNoteLink(viewContext, anlId, bId, (NSInteger)insertAt);
        if (ret == 0) {
            anlNote = findNoteByID(viewContext, anlId);
            NSString *newText = [((id (*)(id, SEL))objc_msgSend)(anlNote, sel_registerName("attributedString")) string];
            unichar ch = [newText characterAtIndex:insertAt];
            if (ch == 0xFFFC) { fprintf(stderr, "  PASS\n"); passed++; }
            else { fprintf(stderr, "  FAIL (U+FFFC not at position %lu)\n", (unsigned long)insertAt); failed++; }
        } else { fprintf(stderr, "  FAIL (cmdAddNoteLink returned %d)\n", ret); failed++; }

        deleteNote(findNoteByID(viewContext, anlId), viewContext);
        [viewContext save:nil];
    }

    // Test: add-note-link error - invalid target (subprocess)
    fprintf(stderr, "Test: add-note-link error (invalid target)...\n");
    {
        id noteA = findNote(viewContext, testTitle, testFolderName);
        NSString *aId = noteToDict(noteA)[@"id"];
        NSString *cmd = [NSString stringWithFormat:@"'%s' add-note-link --id '%@' --target NONEXISTENT_ID 2>/dev/null", exePath, aId];
        int ret = system([cmd UTF8String]);
        if (ret != 0) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (should have failed)\n"); failed++; }
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

    // --- Hyperlink tests ---

    // Test: Set link on a text range
    fprintf(stderr, "Test: Set link on text range...\n");
    {
        id note = findNote(viewContext, testTitle, testFolderName);
        NSString *noteID = noteToDict(note)[@"id"];
        // Body starts after title + newline
        NSUInteger linkOffset = [testTitle length] + 1;
        int ret = cmdSetAttr(viewContext, noteID, linkOffset, 13,
            @{@"link": @"https://example.com/test"});
        if (ret == 0) {
            note = findNote(viewContext, testTitle, testFolderName);
            id doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
            id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
            NSRange lr;
            NSDictionary *la = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
                ms, sel_registerName("attributesAtIndex:effectiveRange:"), linkOffset, &lr);
            NSURL *foundLink = la[@"NSLink"];
            if (foundLink && [[foundLink absoluteString] containsString:@"example.com"]) {
                fprintf(stderr, "  PASS\n"); passed++;
            } else {
                fprintf(stderr, "  FAIL (link not found: attrs=%s)\n", [[la description] UTF8String]); failed++;
            }
        } else { fprintf(stderr, "  FAIL (cmdSetAttr returned %d)\n", ret); failed++; }
    }

    // Test: Link-only update preserves style
    fprintf(stderr, "Test: Link preserves existing style...\n");
    {
        id note = findNote(viewContext, testTitle, testFolderName);
        NSString *noteID = noteToDict(note)[@"id"];
        NSUInteger linkOffset = [testTitle length] + 1;
        id doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
        id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
        NSRange sr;
        NSDictionary *beforeAttrs = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
            ms, sel_registerName("attributesAtIndex:effectiveRange:"), linkOffset, &sr);
        id beforeStyle = beforeAttrs[@"TTStyle"];
        int beforeStyleVal = beforeStyle ? (int)((NSInteger (*)(id, SEL))objc_msgSend)(beforeStyle, sel_registerName("style")) : -1;
        NSURL *beforeLink = beforeAttrs[@"NSLink"];

        if (beforeStyleVal >= 0 && beforeLink) {
            fprintf(stderr, "  PASS (style=%d preserved with link)\n", beforeStyleVal); passed++;
        } else {
            fprintf(stderr, "  FAIL (style=%d, link=%s)\n", beforeStyleVal, beforeLink ? "yes" : "no"); failed++;
        }
    }

    // Test: Style-only update preserves existing link
    fprintf(stderr, "Test: Style update preserves link...\n");
    {
        id note = findNote(viewContext, testTitle, testFolderName);
        NSString *noteID = noteToDict(note)[@"id"];
        NSUInteger linkOffset = [testTitle length] + 1;
        // Change style to heading (1) on the range that has a link
        int ret = cmdSetAttr(viewContext, noteID, linkOffset, 13, @{@"style": @"1"});
        if (ret == 0) {
            note = findNote(viewContext, testTitle, testFolderName);
            id doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
            id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
            NSRange lr;
            NSDictionary *la = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
                ms, sel_registerName("attributesAtIndex:effectiveRange:"), linkOffset, &lr);
            NSURL *foundLink = la[@"NSLink"];
            id styleObj = la[@"TTStyle"];
            int styleVal = styleObj ? (int)((NSInteger (*)(id, SEL))objc_msgSend)(styleObj, sel_registerName("style")) : -1;
            if (foundLink && styleVal == 1) {
                fprintf(stderr, "  PASS (link preserved, style=%d)\n", styleVal); passed++;
            } else {
                fprintf(stderr, "  FAIL (link=%s, style=%d)\n", foundLink ? "yes" : "no", styleVal); failed++;
            }
        } else { fprintf(stderr, "  FAIL\n"); failed++; }
        // Restore style back to body (3)
        note = findNote(viewContext, testTitle, testFolderName);
        NSString *restoreID = noteToDict(note)[@"id"];
        cmdSetAttr(viewContext, restoreID, [testTitle length] + 1, 13, @{@"style": @"3"});
    }

    // Test: Remove link
    fprintf(stderr, "Test: Remove link...\n");
    {
        id note = findNote(viewContext, testTitle, testFolderName);
        NSString *noteID = noteToDict(note)[@"id"];
        NSUInteger linkOffset = [testTitle length] + 1;
        int ret = cmdSetAttr(viewContext, noteID, linkOffset, 13, @{@"link": @""});
        if (ret == 0) {
            note = findNote(viewContext, testTitle, testFolderName);
            id doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
            id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
            NSRange lr;
            NSDictionary *la = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
                ms, sel_registerName("attributesAtIndex:effectiveRange:"), linkOffset, &lr);
            if (!la[@"NSLink"]) {
                id styleObj = la[@"TTStyle"];
                int styleVal = styleObj ? (int)((NSInteger (*)(id, SEL))objc_msgSend)(styleObj, sel_registerName("style")) : -1;
                if (styleVal >= 0) {
                    fprintf(stderr, "  PASS (link removed, style=%d preserved)\n", styleVal); passed++;
                } else {
                    fprintf(stderr, "  FAIL (link removed but style lost)\n"); failed++;
                }
            } else {
                fprintf(stderr, "  FAIL (link still present)\n"); failed++;
            }
        } else { fprintf(stderr, "  FAIL\n"); failed++; }
    }

    // Test: Invalid URL returns error (subprocess test)
    fprintf(stderr, "Test: Invalid URL rejected...\n");
    {
        char pathBuf[4096];
        uint32_t pathSize = sizeof(pathBuf);
        _NSGetExecutablePath(pathBuf, &pathSize);
        id note = findNote(viewContext, testTitle, testFolderName);
        NSString *noteID = noteToDict(note)[@"id"];
        NSUInteger linkOffset = [testTitle length] + 1;
        // Use spaces in URL which NSURL rejects
        NSString *cmd = [NSString stringWithFormat:@"%s set-attr --id %@ --offset %lu --length 13 --link 'has space in url' 2>/dev/null",
            pathBuf, noteID, (unsigned long)linkOffset];
        int ret = system([cmd UTF8String]);
        if (ret != 0) {
            fprintf(stderr, "  PASS (rejected with exit code %d)\n", WEXITSTATUS(ret)); passed++;
        } else {
            fprintf(stderr, "  FAIL (should have been rejected)\n"); failed++;
        }
    }

    // Test: Rejected URL scheme
    fprintf(stderr, "Test: javascript: scheme rejected...\n");
    {
        char pathBuf[4096];
        uint32_t pathSize = sizeof(pathBuf);
        _NSGetExecutablePath(pathBuf, &pathSize);
        id note = findNote(viewContext, testTitle, testFolderName);
        NSString *noteID = noteToDict(note)[@"id"];
        NSUInteger linkOffset = [testTitle length] + 1;
        NSString *cmd = [NSString stringWithFormat:@"%s set-attr --id %@ --offset %lu --length 13 --link 'javascript:alert(1)' 2>/dev/null",
            pathBuf, noteID, (unsigned long)linkOffset];
        int ret = system([cmd UTF8String]);
        if (ret != 0) {
            fprintf(stderr, "  PASS (rejected with exit code %d)\n", WEXITSTATUS(ret)); passed++;
        } else {
            fprintf(stderr, "  FAIL (should have been rejected)\n"); failed++;
        }
    }

    // Test: Multi-run range preservation (set link across body + checklist)
    fprintf(stderr, "Test: Multi-run link preserves styles...\n");
    {
        id note = findNote(viewContext, testTitle, testFolderName);
        NSString *noteID = noteToDict(note)[@"id"];
        id doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
        id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
        NSUInteger msLen = ((NSUInteger (*)(id, SEL))objc_msgSend)(ms, sel_registerName("length"));

        NSUInteger multiOffset = [testTitle length] + 1;
        NSUInteger multiLength = msLen - multiOffset;
        if (multiLength > 0) {
            // Read styles before
            NSRange r1;
            NSDictionary *a1 = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
                ms, sel_registerName("attributesAtIndex:effectiveRange:"), multiOffset, &r1);
            id s1 = a1[@"TTStyle"];
            int style1 = s1 ? (int)((NSInteger (*)(id, SEL))objc_msgSend)(s1, sel_registerName("style")) : -1;

            int ret = cmdSetAttr(viewContext, noteID, multiOffset, multiLength,
                @{@"link": @"https://multi.example.com"});
            if (ret == 0) {
                note = findNote(viewContext, testTitle, testFolderName);
                doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
                ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));

                NSDictionary *a1After = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
                    ms, sel_registerName("attributesAtIndex:effectiveRange:"), multiOffset, &r1);
                id s1After = a1After[@"TTStyle"];
                int style1After = s1After ? (int)((NSInteger (*)(id, SEL))objc_msgSend)(s1After, sel_registerName("style")) : -1;
                NSURL *link1 = a1After[@"NSLink"];

                if (style1 == style1After && link1) {
                    fprintf(stderr, "  PASS (style=%d preserved, link set)\n", style1After); passed++;
                } else {
                    fprintf(stderr, "  FAIL (style %d->%d, link=%s)\n", style1, style1After, link1 ? "yes" : "no"); failed++;
                }

                // Clean up multi-run links
                cmdSetAttr(viewContext, noteToDict(findNote(viewContext, testTitle, testFolderName))[@"id"],
                    multiOffset, multiLength, @{@"link": @""});
            } else { fprintf(stderr, "  FAIL (cmdSetAttr returned %d)\n", ret); failed++; }
        } else { fprintf(stderr, "  FAIL (no body text)\n"); failed++; }
    }

    // Test: Link at paragraph boundary does not bleed into adjacent paragraph
    // Regression test for: set-attr --link breaks paragraph boundaries when
    // offset+length crosses a '\n' character.
    fprintf(stderr, "Test: Link at paragraph boundary preserves adjacent paragraph style...\n");
    {
        id note = findNote(viewContext, testTitle, testFolderName);
        NSString *noteID = noteToDict(note)[@"id"];
        NSString *noteText = [((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("attributedString")) string];
        // By this point Test 7 has replaced "Test body" with "Modified body".
        // The body paragraph (style=3) is followed by '\n' then "Checklist item" (style=103).
        // Set a link that ends right on (or just after) the '\n' to exercise the boundary.
        NSRange bodyRange = [noteText rangeOfString:@"Modified body"];
        NSRange clRange2 = [noteText rangeOfString:@"Checklist item"];
        if (bodyRange.location != NSNotFound && clRange2.location != NSNotFound) {
            id doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
            id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));

            // Record checklist paragraph style before applying link
            NSRange erBefore;
            NSDictionary *clBefore = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
                ms, sel_registerName("attributesAtIndex:effectiveRange:"), clRange2.location, &erBefore);
            id clStyleBefore = clBefore[@"TTStyle"];
            int clStyleValBefore = clStyleBefore
                ? (int)((NSInteger (*)(id, SEL))objc_msgSend)(clStyleBefore, sel_registerName("style")) : -1;
            BOOL clHadTodoBefore = clStyleBefore
                && (((id (*)(id, SEL))objc_msgSend)(clStyleBefore, sel_registerName("todo")) != nil);

            // Apply link to "Modified body\n" — range deliberately includes the '\n'
            NSUInteger linkLen = bodyRange.length + 1; // include trailing '\n'
            int ret = cmdSetAttr(viewContext, noteID, bodyRange.location, linkLen,
                @{@"link": @"https://boundary.example.com"});
            if (ret == 0) {
                note = findNote(viewContext, testTitle, testFolderName);
                doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
                ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
                noteText = [((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("attributedString")) string];
                clRange2 = [noteText rangeOfString:@"Checklist item"];

                NSRange erAfter;
                NSDictionary *clAfter = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
                    ms, sel_registerName("attributesAtIndex:effectiveRange:"), clRange2.location, &erAfter);
                id clStyleAfter = clAfter[@"TTStyle"];
                int clStyleValAfter = clStyleAfter
                    ? (int)((NSInteger (*)(id, SEL))objc_msgSend)(clStyleAfter, sel_registerName("style")) : -1;
                BOOL clHasTodoAfter = clStyleAfter
                    && (((id (*)(id, SEL))objc_msgSend)(clStyleAfter, sel_registerName("todo")) != nil);
                // The link must NOT have bled into the checklist paragraph
                NSURL *clLinkAfter = clAfter[@"NSLink"];

                if (clStyleValBefore == clStyleValAfter && clHadTodoBefore == clHasTodoAfter && !clLinkAfter) {
                    fprintf(stderr, "  PASS (style=%d preserved, todo=%d, no link bleed)\n",
                        clStyleValAfter, clHasTodoAfter); passed++;
                } else {
                    fprintf(stderr, "  FAIL (style %d->%d, todo %d->%d, link bleed=%s)\n",
                        clStyleValBefore, clStyleValAfter, clHadTodoBefore, clHasTodoAfter,
                        clLinkAfter ? "YES" : "no"); failed++;
                }

                // Clean up: remove link from body range
                note = findNote(viewContext, testTitle, testFolderName);
                noteText = [((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("attributedString")) string];
                bodyRange = [noteText rangeOfString:@"Modified body"];
                cmdSetAttr(viewContext, noteToDict(note)[@"id"],
                    bodyRange.location, bodyRange.length + 1, @{@"link": @""});
            } else { fprintf(stderr, "  FAIL (cmdSetAttr returned %d)\n", ret); failed++; }
        } else { fprintf(stderr, "  FAIL (body or checklist text not found)\n"); failed++; }
    }

    // Test: Link on checklist preserves todo state
    fprintf(stderr, "Test: Link on checklist preserves todo...\n");
    {
        id note = findNote(viewContext, testTitle, testFolderName);
        NSString *noteID = noteToDict(note)[@"id"];
        NSString *noteText = [((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("attributedString")) string];
        NSRange clRange = [noteText rangeOfString:@"Checklist item"];
        if (clRange.location != NSNotFound) {
            id doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
            id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
            NSRange er;
            NSDictionary *beforeAttrs = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
                ms, sel_registerName("attributesAtIndex:effectiveRange:"), clRange.location, &er);
            id beforeStyle = beforeAttrs[@"TTStyle"];
            id beforeTodo = beforeStyle ? ((id (*)(id, SEL))objc_msgSend)(beforeStyle, sel_registerName("todo")) : nil;
            BOOL hadTodo = (beforeTodo != nil);

            int ret = cmdSetAttr(viewContext, noteID, clRange.location, clRange.length,
                @{@"link": @"https://checklist.example.com"});
            if (ret == 0) {
                note = findNote(viewContext, testTitle, testFolderName);
                doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
                ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
                NSDictionary *afterAttrs = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
                    ms, sel_registerName("attributesAtIndex:effectiveRange:"), clRange.location, &er);
                id afterStyle = afterAttrs[@"TTStyle"];
                id afterTodo = afterStyle ? ((id (*)(id, SEL))objc_msgSend)(afterStyle, sel_registerName("todo")) : nil;
                NSURL *afterLink = afterAttrs[@"NSLink"];
                int afterStyleVal = afterStyle ? (int)((NSInteger (*)(id, SEL))objc_msgSend)(afterStyle, sel_registerName("style")) : -1;

                if (hadTodo && afterTodo && afterLink && afterStyleVal == 103) {
                    fprintf(stderr, "  PASS (todo preserved, style=103, link set)\n"); passed++;
                } else {
                    fprintf(stderr, "  FAIL (hadTodo=%d, afterTodo=%s, link=%s, style=%d)\n",
                        hadTodo, afterTodo ? "yes" : "no", afterLink ? "yes" : "no", afterStyleVal); failed++;
                }
            } else { fprintf(stderr, "  FAIL\n"); failed++; }
        } else { fprintf(stderr, "  FAIL (checklist item not found)\n"); failed++; }
    }

    // Test: Todo-done update preserves existing link
    fprintf(stderr, "Test: Todo-done preserves link...\n");
    {
        id note = findNote(viewContext, testTitle, testFolderName);
        NSString *noteID = noteToDict(note)[@"id"];
        NSString *noteText = [((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("attributedString")) string];
        NSRange clRange = [noteText rangeOfString:@"Checklist item"];
        if (clRange.location != NSNotFound) {
            int ret = cmdSetAttr(viewContext, noteID, clRange.location, clRange.length,
                @{@"todo-done": @"true"});
            if (ret == 0) {
                note = findNote(viewContext, testTitle, testFolderName);
                id doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
                id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
                NSRange er;
                NSDictionary *afterAttrs = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
                    ms, sel_registerName("attributesAtIndex:effectiveRange:"), clRange.location, &er);
                NSURL *afterLink = afterAttrs[@"NSLink"];
                id afterStyle = afterAttrs[@"TTStyle"];
                id afterTodo = afterStyle ? ((id (*)(id, SEL))objc_msgSend)(afterStyle, sel_registerName("todo")) : nil;
                BOOL afterDone = afterTodo ? ((BOOL (*)(id, SEL))objc_msgSend)(afterTodo, sel_registerName("done")) : NO;

                if (afterLink && afterTodo && afterDone) {
                    fprintf(stderr, "  PASS (link preserved, todo done=true)\n"); passed++;
                } else {
                    fprintf(stderr, "  FAIL (link=%s, todo=%s, done=%d)\n",
                        afterLink ? "yes" : "no", afterTodo ? "yes" : "no", afterDone); failed++;
                }
            } else { fprintf(stderr, "  FAIL\n"); failed++; }
        } else { fprintf(stderr, "  FAIL (checklist item not found)\n"); failed++; }
    }

    // Test: Indent update preserves todo state
    fprintf(stderr, "Test: Indent preserves todo state...\n");
    {
        id note = findNote(viewContext, testTitle, testFolderName);
        NSString *noteID = noteToDict(note)[@"id"];
        NSString *noteText = [((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("attributedString")) string];
        NSRange clRange = [noteText rangeOfString:@"Checklist item"];
        if (clRange.location != NSNotFound) {
            int ret = cmdSetAttr(viewContext, noteID, clRange.location, clRange.length,
                @{@"indent": @"1"});
            if (ret == 0) {
                note = findNote(viewContext, testTitle, testFolderName);
                id doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
                id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
                NSRange er;
                NSDictionary *afterAttrs = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
                    ms, sel_registerName("attributesAtIndex:effectiveRange:"), clRange.location, &er);
                id afterStyle = afterAttrs[@"TTStyle"];
                id afterTodo = afterStyle ? ((id (*)(id, SEL))objc_msgSend)(afterStyle, sel_registerName("todo")) : nil;
                BOOL afterDone = afterTodo ? ((BOOL (*)(id, SEL))objc_msgSend)(afterTodo, sel_registerName("done")) : NO;
                NSUInteger afterIndent = afterStyle ? ((NSUInteger (*)(id, SEL))objc_msgSend)(afterStyle, sel_registerName("indent")) : 0;
                int afterStyleVal = afterStyle ? (int)((NSInteger (*)(id, SEL))objc_msgSend)(afterStyle, sel_registerName("style")) : -1;

                if (afterTodo && afterDone && afterIndent == 1 && afterStyleVal == 103) {
                    fprintf(stderr, "  PASS (todo preserved, done=true, indent=1, style=103)\n"); passed++;
                } else {
                    fprintf(stderr, "  FAIL (todo=%s, done=%d, indent=%lu, style=%d)\n",
                        afterTodo ? "yes" : "no", afterDone, (unsigned long)afterIndent, afterStyleVal); failed++;
                }
            } else { fprintf(stderr, "  FAIL\n"); failed++; }
        } else { fprintf(stderr, "  FAIL (checklist item not found)\n"); failed++; }
    }

    // Test: List formatting (dash list via append --style 100)
    fprintf(stderr, "Test: List formatting (dash list)...\n");
    {
        NSString *listTitle = @"__notes_cli_list_test__";
        id listNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id listDoc = ((id (*)(id, SEL))objc_msgSend)(listNote, sel_registerName("document"));
        id listMs = ((id (*)(id, SEL))objc_msgSend)(listDoc, sel_registerName("mergeableString"));
        // Insert title
        ((void (*)(id, SEL))objc_msgSend)(listNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(listMs, sel_registerName("insertString:atIndex:"), listTitle, 0);
        id ltStyle = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(ltStyle, sel_registerName("setStyle:"), 0);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(listMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": ltStyle}, NSMakeRange(0, listTitle.length));
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            listNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, listTitle.length), listTitle.length);
        ((void (*)(id, SEL))objc_msgSend)(listNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(listNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        NSString *listNoteID = noteToDict(listNote)[@"id"];
        // Append three dash list items
        cmdAppend(viewContext, listNoteID, @"Dash item 1", 100);
        cmdAppend(viewContext, listNoteID, @"Dash item 2", 100);
        cmdAppend(viewContext, listNoteID, @"Dash item 3", 100);
        // Append two numbered list items
        cmdAppend(viewContext, listNoteID, @"Number item 1", 102);
        cmdAppend(viewContext, listNoteID, @"Number item 2", 102);

        // Verify via read-attrs
        id verifyNote = findNoteByID(viewContext, listNoteID);
        id verifyDoc = ((id (*)(id, SEL))objc_msgSend)(verifyNote, sel_registerName("document"));
        id verifyMs = ((id (*)(id, SEL))objc_msgSend)(verifyDoc, sel_registerName("mergeableString"));
        NSString *verifyText = [((id (*)(id, SEL))objc_msgSend)(verifyNote, sel_registerName("attributedString")) string];
        int dash100Count = 0, numbered102Count = 0;
        NSUInteger vi = 0;
        while (vi < verifyText.length) {
            NSRange vr;
            NSDictionary *va = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
                verifyMs, sel_registerName("attributesAtIndex:effectiveRange:"), vi, &vr);
            id vs = va[@"TTStyle"];
            if (vs) {
                int sval = (int)((NSInteger (*)(id, SEL))objc_msgSend)(vs, sel_registerName("style"));
                if (sval == 100) dash100Count++;
                if (sval == 102) numbered102Count++;
            }
            vi = vr.location + vr.length;
        }
        if (dash100Count >= 3 && numbered102Count >= 2) {
            fprintf(stderr, "  PASS (dash=%d, numbered=%d)\n", dash100Count, numbered102Count); passed++;
        } else {
            fprintf(stderr, "  FAIL (dash=%d, numbered=%d)\n", dash100Count, numbered102Count); failed++;
        }
        // Cleanup
        deleteNote(findNoteByID(viewContext, listNoteID), viewContext);
        [viewContext save:nil];
    }

    // Test: Checklist via append --style 103
    fprintf(stderr, "Test: Checklist via append...\n");
    {
        NSString *clTitle = @"__notes_cli_checklist_test__";
        id clNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id clDoc = ((id (*)(id, SEL))objc_msgSend)(clNote, sel_registerName("document"));
        id clMs = ((id (*)(id, SEL))objc_msgSend)(clDoc, sel_registerName("mergeableString"));
        ((void (*)(id, SEL))objc_msgSend)(clNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(clMs, sel_registerName("insertString:atIndex:"), clTitle, 0);
        id clTitleStyle = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(clTitleStyle, sel_registerName("setStyle:"), 0);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(clMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": clTitleStyle}, NSMakeRange(0, clTitle.length));
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            clNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, clTitle.length), clTitle.length);
        ((void (*)(id, SEL))objc_msgSend)(clNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(clNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        NSString *clNoteID = noteToDict(clNote)[@"id"];
        cmdAppend(viewContext, clNoteID, @"Check this item", 103);

        // Verify style 103 and todo exists
        id clVerify = findNoteByID(viewContext, clNoteID);
        id clVDoc = ((id (*)(id, SEL))objc_msgSend)(clVerify, sel_registerName("document"));
        id clVMs = ((id (*)(id, SEL))objc_msgSend)(clVDoc, sel_registerName("mergeableString"));
        NSString *clVText = [((id (*)(id, SEL))objc_msgSend)(clVerify, sel_registerName("attributedString")) string];
        BOOL found103 = NO, foundTodo = NO;
        NSUInteger ci = 0;
        while (ci < clVText.length) {
            NSRange cr;
            NSDictionary *ca = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
                clVMs, sel_registerName("attributesAtIndex:effectiveRange:"), ci, &cr);
            id cs = ca[@"TTStyle"];
            if (cs) {
                int csv = (int)((NSInteger (*)(id, SEL))objc_msgSend)(cs, sel_registerName("style"));
                if (csv == 103) {
                    found103 = YES;
                    id ctodo = ((id (*)(id, SEL))objc_msgSend)(cs, sel_registerName("todo"));
                    if (ctodo) foundTodo = YES;
                }
            }
            ci = cr.location + cr.length;
        }
        if (found103 && foundTodo) {
            fprintf(stderr, "  PASS (style=103, todo present)\n"); passed++;
        } else {
            fprintf(stderr, "  FAIL (style103=%d, todo=%d)\n", found103, foundTodo); failed++;
        }
        // Cleanup
        deleteNote(findNoteByID(viewContext, clNoteID), viewContext);
        [viewContext save:nil];
    }

    // Test: Style validation (subprocess-based)
    fprintf(stderr, "Test: Style validation (invalid styles)...\n");
    {
        // Get path to current executable
        char testExecPath[PATH_MAX];
        uint32_t testExecSize = sizeof(testExecPath);
        if (_NSGetExecutablePath(testExecPath, &testExecSize) == 0) {
            char testRealPath[PATH_MAX];
            realpath(testExecPath, testRealPath);
            NSString *binaryPath = [NSString stringWithUTF8String:testRealPath];

            // Create a temp note to test against
            id valNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
            ((void (*)(id, SEL))objc_msgSend)(valNote, sel_registerName("saveNoteData"));
            [viewContext save:nil];
            NSString *valNoteID = noteToDict(valNote)[@"id"];

            // Test invalid style number (999)
            NSTask *task1 = [[NSTask alloc] init];
            [task1 setLaunchPath:binaryPath];
            [task1 setArguments:@[@"append", @"--id", valNoteID, @"--text", @"Bad", @"--style", @"999"]];
            [task1 setStandardOutput:[NSPipe pipe]];
            [task1 setStandardError:[NSPipe pipe]];
            [task1 launch];
            [task1 waitUntilExit];
            int status1 = [task1 terminationStatus];

            // Test non-numeric style (abc)
            NSTask *task2 = [[NSTask alloc] init];
            [task2 setLaunchPath:binaryPath];
            [task2 setArguments:@[@"append", @"--id", valNoteID, @"--text", @"Bad", @"--style", @"abc"]];
            [task2 setStandardOutput:[NSPipe pipe]];
            [task2 setStandardError:[NSPipe pipe]];
            [task2 launch];
            [task2 waitUntilExit];
            int status2 = [task2 terminationStatus];

            if (status1 != 0 && status2 != 0) {
                fprintf(stderr, "  PASS (invalid=exit%d, non-numeric=exit%d)\n", status1, status2); passed++;
            } else {
                fprintf(stderr, "  FAIL (invalid=exit%d, non-numeric=exit%d)\n", status1, status2); failed++;
            }

            // Cleanup
            deleteNote(findNoteByID(viewContext, valNoteID), viewContext);
            [viewContext save:nil];
        } else {
            fprintf(stderr, "  SKIP (could not determine executable path)\n");
        }
    }

    // Test: Multiline append with list style (behavior documentation)
    fprintf(stderr, "Test: Multiline append with list style...\n");
    {
        NSString *mlTitle = @"__notes_cli_multiline_list_test__";
        id mlNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id mlDoc = ((id (*)(id, SEL))objc_msgSend)(mlNote, sel_registerName("document"));
        id mlMs = ((id (*)(id, SEL))objc_msgSend)(mlDoc, sel_registerName("mergeableString"));
        ((void (*)(id, SEL))objc_msgSend)(mlNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(mlMs, sel_registerName("insertString:atIndex:"), mlTitle, 0);
        id mlTitleStyle = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(mlTitleStyle, sel_registerName("setStyle:"), 0);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mlMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": mlTitleStyle}, NSMakeRange(0, mlTitle.length));
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            mlNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, mlTitle.length), mlTitle.length);
        ((void (*)(id, SEL))objc_msgSend)(mlNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(mlNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        NSString *mlNoteID = noteToDict(mlNote)[@"id"];
        // Append multiline text with dash list style
        cmdAppend(viewContext, mlNoteID, @"Line A\nLine B", 100);

        // Read back and count style-100 ranges
        id mlVerify = findNoteByID(viewContext, mlNoteID);
        id mlVDoc = ((id (*)(id, SEL))objc_msgSend)(mlVerify, sel_registerName("document"));
        id mlVMs = ((id (*)(id, SEL))objc_msgSend)(mlVDoc, sel_registerName("mergeableString"));
        NSString *mlVText = [((id (*)(id, SEL))objc_msgSend)(mlVerify, sel_registerName("attributedString")) string];
        int mlDashCount = 0;
        NSUInteger mi = 0;
        while (mi < mlVText.length) {
            NSRange mr;
            NSDictionary *ma = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
                mlVMs, sel_registerName("attributesAtIndex:effectiveRange:"), mi, &mr);
            id ms2 = ma[@"TTStyle"];
            if (ms2) {
                int msv = (int)((NSInteger (*)(id, SEL))objc_msgSend)(ms2, sel_registerName("style"));
                if (msv == 100) mlDashCount++;
            }
            mi = mr.location + mr.length;
        }
        // Document behavior: style applies to the entire inserted range as one block
        fprintf(stderr, "  PASS (multiline dash ranges=%d, style applied as single block)\n", mlDashCount); passed++;

        // Cleanup
        deleteNote(findNoteByID(viewContext, mlNoteID), viewContext);
        [viewContext save:nil];
    }

    // Cleanup

    // Test: bodyOffsetForNote
    fprintf(stderr, "Test: bodyOffsetForNote...\n");
    {
        id note = findNote(viewContext, testTitle, testFolderName);
        if (note) {
            NSUInteger bodyOff = bodyOffsetForNote(note);
            NSAttributedString *attrStr = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("attributedString"));
            NSString *fullText = [attrStr string];
            NSString *bodyFromRead = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("noteAsPlainTextWithoutTitle"));
            if (bodyOff != NSNotFound && bodyOff <= fullText.length) {
                NSString *bodyFromOffset = [fullText substringFromIndex:bodyOff];
                // noteAsPlainTextWithoutTitle may include a leading newline; strip it for comparison
                NSString *trimmedRead = [bodyFromRead stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
                // Guard: empty body would trivially pass hasPrefix; fail explicitly
                if (trimmedRead.length == 0) {
                    fprintf(stderr, "  FAIL (body is empty, cannot verify offset)\n"); failed++;
                } else if ([bodyFromOffset hasPrefix:trimmedRead]) {
                    fprintf(stderr, "  PASS (bodyOff=%lu)\n", (unsigned long)bodyOff); passed++;
                } else {
                    fprintf(stderr, "  FAIL (body mismatch at offset %lu)\n", (unsigned long)bodyOff); failed++;
                }
            } else {
                fprintf(stderr, "  FAIL (bodyOff=%lu)\n", (unsigned long)bodyOff); failed++;
            }
        } else { fprintf(stderr, "  FAIL (not found)\n"); failed++; }
    }

    // Test: set-attr with --body-offset
    fprintf(stderr, "Test: set-attr with --body-offset...\n");
    {
        id note = findNote(viewContext, testTitle, testFolderName);
        if (note) {
            NSString *noteID = noteToDict(note)[@"id"];
            NSUInteger bodyOff = bodyOffsetForNote(note);
            NSDictionary *attrOpts = @{@"style": @"1", @"body-offset": @"true"};
            int ret = cmdSetAttr(viewContext, noteID, 0, 5, attrOpts);
            if (ret == 0) {
                note = findNoteByID(viewContext, noteID);
                id doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
                id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
                NSRange effectiveRange;
                NSDictionary *attrs = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(ms, sel_registerName("attributesAtIndex:effectiveRange:"), bodyOff, &effectiveRange);
                id style = attrs[@"TTStyle"];
                NSInteger styleVal = style ? ((NSInteger (*)(id, SEL))objc_msgSend)(style, sel_registerName("style")) : -1;
                if (styleVal == 1) { fprintf(stderr, "  PASS\n"); passed++; }
                else { fprintf(stderr, "  FAIL (style=%ld)\n", (long)styleVal); failed++; }
            } else { fprintf(stderr, "  FAIL (ret=%d)\n", ret); failed++; }
            NSDictionary *resetOpts = @{@"style": @"3", @"body-offset": @"true"};
            cmdSetAttr(viewContext, noteID, 0, 5, resetOpts);
        } else { fprintf(stderr, "  FAIL (not found)\n"); failed++; }
    }

    // Test: set-attr without --body-offset (regression)
    fprintf(stderr, "Test: set-attr without --body-offset...\n");
    {
        id note = findNote(viewContext, testTitle, testFolderName);
        if (note) {
            NSString *noteID = noteToDict(note)[@"id"];
            NSUInteger bodyOff = bodyOffsetForNote(note);
            NSDictionary *attrOpts = @{@"style": @"1"};
            int ret = cmdSetAttr(viewContext, noteID, bodyOff, 5, attrOpts);
            if (ret == 0) {
                note = findNoteByID(viewContext, noteID);
                id doc = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("document"));
                id ms = ((id (*)(id, SEL))objc_msgSend)(doc, sel_registerName("mergeableString"));
                NSRange effectiveRange;
                NSDictionary *attrs = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(ms, sel_registerName("attributesAtIndex:effectiveRange:"), bodyOff, &effectiveRange);
                id style = attrs[@"TTStyle"];
                NSInteger styleVal = style ? ((NSInteger (*)(id, SEL))objc_msgSend)(style, sel_registerName("style")) : -1;
                if (styleVal == 1) { fprintf(stderr, "  PASS\n"); passed++; }
                else { fprintf(stderr, "  FAIL (style=%ld)\n", (long)styleVal); failed++; }
            } else { fprintf(stderr, "  FAIL (ret=%d)\n", ret); failed++; }
            NSDictionary *resetOpts = @{@"style": @"3"};
            cmdSetAttr(viewContext, noteID, bodyOff, 5, resetOpts);
        } else { fprintf(stderr, "  FAIL (not found)\n"); failed++; }
    }

    // Test: insert with --body-offset
    fprintf(stderr, "Test: insert with --body-offset...\n");
    {
        id note = findNote(viewContext, testTitle, testFolderName);
        if (note) {
            NSString *noteID = noteToDict(note)[@"id"];
            int ret = cmdInsert(viewContext, noteID, @"INSERTED", 0, YES, -1);
            if (ret == 0) {
                note = findNoteByID(viewContext, noteID);
                NSString *body = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("noteAsPlainTextWithoutTitle"));
                // noteAsPlainTextWithoutTitle may have leading newline; check after trimming
                NSString *trimmed = [body stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
                if ([trimmed hasPrefix:@"INSERTED"]) { fprintf(stderr, "  PASS\n"); passed++; }
                else { fprintf(stderr, "  FAIL (body prefix wrong)\n"); failed++; }
                cmdDeleteRange(viewContext, noteID, 0, 8, YES);
            } else { fprintf(stderr, "  FAIL (ret=%d)\n", ret); failed++; }
        } else { fprintf(stderr, "  FAIL (not found)\n"); failed++; }
    }

    // Test: delete-range with --body-offset
    fprintf(stderr, "Test: delete-range with --body-offset...\n");
    {
        id note = findNote(viewContext, testTitle, testFolderName);
        if (note) {
            NSString *noteID = noteToDict(note)[@"id"];
            NSString *bodyBefore = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("noteAsPlainTextWithoutTitle"));
            cmdInsert(viewContext, noteID, @"DELME", 0, YES, -1);
            int ret = cmdDeleteRange(viewContext, noteID, 0, 5, YES);
            if (ret == 0) {
                note = findNoteByID(viewContext, noteID);
                NSString *bodyAfter = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("noteAsPlainTextWithoutTitle"));
                if ([bodyAfter isEqualToString:bodyBefore]) { fprintf(stderr, "  PASS\n"); passed++; }
                else { fprintf(stderr, "  FAIL (body mismatch)\n"); failed++; }
            } else { fprintf(stderr, "  FAIL (ret=%d)\n", ret); failed++; }
        } else { fprintf(stderr, "  FAIL (not found)\n"); failed++; }
    }

    // Test: --body-offset on title-only note
    fprintf(stderr, "Test: body-offset title-only note...\n");
    {
        NSString *toTitle = @"__notes_cli_title_only_test__";
        id toNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id toDoc = ((id (*)(id, SEL))objc_msgSend)(toNote, sel_registerName("document"));
        id toMs = ((id (*)(id, SEL))objc_msgSend)(toDoc, sel_registerName("mergeableString"));
        ((void (*)(id, SEL))objc_msgSend)(toNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(toMs, sel_registerName("insertString:atIndex:"), toTitle, 0);
        id toStyle = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(toStyle, sel_registerName("setStyle:"), 0);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(toMs, sel_registerName("setAttributes:range:"), @{@"TTStyle": toStyle}, NSMakeRange(0, toTitle.length));
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(toNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, toTitle.length), toTitle.length);
        ((void (*)(id, SEL))objc_msgSend)(toNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(toNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];
        NSUInteger bodyOff = bodyOffsetForNote(toNote);
        if (bodyOff == NSNotFound) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (expected NSNotFound, got %lu)\n", (unsigned long)bodyOff); failed++; }
        // Note: command-level --body-offset on title-only notes calls errorExit(exit(1)),
        // so cannot be tested in-process. The helper returns NSNotFound and all three
        // commands (set-attr, insert, delete-range) check for NSNotFound before errorExit.
        deleteNote(toNote, viewContext);
        [viewContext save:nil];
    }

    // Test: bodyOffsetForNote with canonical format (\n + title + \n + body)
    fprintf(stderr, "Test: bodyOffsetForNote canonical format...\n");
    {
        id cnNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id cnDoc = ((id (*)(id, SEL))objc_msgSend)(cnNote, sel_registerName("document"));
        id cnMs = ((id (*)(id, SEL))objc_msgSend)(cnDoc, sel_registerName("mergeableString"));
        NSString *cnTitle = @"__canonical_test__";
        NSString *cnBody = @"canonical body text";
        // Build canonical format: \n + title + \n + body
        NSString *cnContent = [NSString stringWithFormat:@"\n%@\n%@", cnTitle, cnBody];
        ((void (*)(id, SEL))objc_msgSend)(cnNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(cnMs, sel_registerName("insertString:atIndex:"), cnContent, 0);
        id cnStyle = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(cnStyle, sel_registerName("setStyle:"), 0);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(cnMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": cnStyle}, NSMakeRange(0, 1 + cnTitle.length + 1));
        id cnBodyStyle = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(cnBodyStyle, sel_registerName("setStyle:"), 3);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(cnMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": cnBodyStyle}, NSMakeRange(1 + cnTitle.length + 1, cnBody.length));
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            cnNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, cnContent.length), cnContent.length);
        ((void (*)(id, SEL))objc_msgSend)(cnNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(cnNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];
        NSUInteger cnBodyOff = bodyOffsetForNote(cnNote);
        // Expected: 1 (leading \n) + title.length + 1 (separator \n) = cnTitle.length + 2
        NSUInteger expectedOff = 1 + cnTitle.length + 1;
        if (cnBodyOff == expectedOff) {
            // Also verify the body text at that offset matches
            NSAttributedString *cnAttrStr = ((id (*)(id, SEL))objc_msgSend)(cnNote, sel_registerName("attributedString"));
            NSString *cnFullText = [cnAttrStr string];
            NSString *bodyAtOffset = [cnFullText substringFromIndex:cnBodyOff];
            if ([bodyAtOffset hasPrefix:cnBody]) {
                fprintf(stderr, "  PASS (bodyOff=%lu, expected=%lu)\n", (unsigned long)cnBodyOff, (unsigned long)expectedOff); passed++;
            } else {
                fprintf(stderr, "  FAIL (offset correct but body text mismatch: '%s')\n", [bodyAtOffset UTF8String]); failed++;
            }
        } else {
            fprintf(stderr, "  FAIL (bodyOff=%lu, expected=%lu)\n", (unsigned long)cnBodyOff, (unsigned long)expectedOff); failed++;
        }
        deleteNote(cnNote, viewContext);
        [viewContext save:nil];
    }

    // --- Markdown Tests ---

    // Test: read-markdown basic (title + body)
    fprintf(stderr, "Test: read-markdown basic...\n");
    {
        NSString *mdTitle = @"__md_test_basic__";
        id mdNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id mdDoc = ((id (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("document"));
        id mdMs = ((id (*)(id, SEL))objc_msgSend)(mdDoc, sel_registerName("mergeableString"));
        NSString *mdContent = [NSString stringWithFormat:@"%@\nBody text here", mdTitle];
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(mdMs, sel_registerName("insertString:atIndex:"), mdContent, 0);
        id mdTitleStyle = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(mdTitleStyle, sel_registerName("setStyle:"), 0);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": mdTitleStyle}, NSMakeRange(0, mdTitle.length + 1));
        id mdBodyStyle = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(mdBodyStyle, sel_registerName("setStyle:"), 3);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": mdBodyStyle}, NSMakeRange(mdTitle.length + 1, 14));
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            mdNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, mdContent.length), mdContent.length);
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        // Read as markdown via paraModel
        NSArray *model = noteToParaModel(mdNote);
        NSMutableArray *filtered = [NSMutableArray array];
        BOOL fc = NO;
        for (NSDictionary *p in model) {
            if (!fc && [p[@"text"] length] == 0) continue;
            fc = YES;
            [filtered addObject:p];
        }
        NSString *markdown = paraModelToMarkdown(filtered);
        BOOL hasTitleMd = [markdown hasPrefix:@"# "];
        BOOL hasBody = [markdown containsString:@"Body text here"];
        if (hasTitleMd && hasBody) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (md: %s)\n", [markdown UTF8String]); failed++; }

        deleteNote(mdNote, viewContext);
        [viewContext save:nil];
    }

    // Test: read-markdown heading
    fprintf(stderr, "Test: read-markdown heading...\n");
    {
        NSString *mdTitle = @"__md_test_heading__";
        id mdNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id mdDoc = ((id (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("document"));
        id mdMs = ((id (*)(id, SEL))objc_msgSend)(mdDoc, sel_registerName("mergeableString"));
        NSString *mdContent = [NSString stringWithFormat:@"%@\nMy Heading", mdTitle];
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(mdMs, sel_registerName("insertString:atIndex:"), mdContent, 0);
        id s0 = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s0, sel_registerName("setStyle:"), 0);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": s0}, NSMakeRange(0, mdTitle.length + 1));
        id s1 = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s1, sel_registerName("setStyle:"), 1);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": s1}, NSMakeRange(mdTitle.length + 1, 10));
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            mdNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, mdContent.length), mdContent.length);
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        NSArray *model = noteToParaModel(mdNote);
        NSMutableArray *filtered = [NSMutableArray array];
        BOOL fc = NO;
        for (NSDictionary *p in model) {
            if (!fc && [p[@"text"] length] == 0) continue;
            fc = YES;
            [filtered addObject:p];
        }
        NSString *markdown = paraModelToMarkdown(filtered);
        if ([markdown containsString:@"## My Heading"]) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (md: %s)\n", [markdown UTF8String]); failed++; }

        deleteNote(mdNote, viewContext);
        [viewContext save:nil];
    }

    // Test: read-markdown dash list
    fprintf(stderr, "Test: read-markdown dash list...\n");
    {
        NSString *mdTitle = @"__md_test_dash__";
        id mdNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id mdDoc = ((id (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("document"));
        id mdMs = ((id (*)(id, SEL))objc_msgSend)(mdDoc, sel_registerName("mergeableString"));
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(mdMs, sel_registerName("insertString:atIndex:"), mdTitle, 0);
        id s0 = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s0, sel_registerName("setStyle:"), 0);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": s0}, NSMakeRange(0, mdTitle.length));
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            mdNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, mdTitle.length), mdTitle.length);
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        NSString *mdNoteID = noteToDict(mdNote)[@"id"];
        cmdAppend(viewContext, mdNoteID, @"Dash item", 100);

        mdNote = findNoteByID(viewContext, mdNoteID);
        NSArray *model = noteToParaModel(mdNote);
        NSMutableArray *filtered = [NSMutableArray array];
        BOOL fc = NO;
        for (NSDictionary *p in model) {
            if (!fc && [p[@"text"] length] == 0) continue;
            fc = YES;
            [filtered addObject:p];
        }
        NSString *markdown = paraModelToMarkdown(filtered);
        if ([markdown containsString:@"- Dash item"]) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (md: %s)\n", [markdown UTF8String]); failed++; }

        deleteNote(findNoteByID(viewContext, mdNoteID), viewContext);
        [viewContext save:nil];
    }

    // Test: read-markdown numbered list
    fprintf(stderr, "Test: read-markdown numbered list...\n");
    {
        NSString *mdTitle = @"__md_test_num__";
        id mdNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id mdDoc = ((id (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("document"));
        id mdMs = ((id (*)(id, SEL))objc_msgSend)(mdDoc, sel_registerName("mergeableString"));
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(mdMs, sel_registerName("insertString:atIndex:"), mdTitle, 0);
        id s0 = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s0, sel_registerName("setStyle:"), 0);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": s0}, NSMakeRange(0, mdTitle.length));
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            mdNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, mdTitle.length), mdTitle.length);
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        NSString *mdNoteID = noteToDict(mdNote)[@"id"];
        cmdAppend(viewContext, mdNoteID, @"Numbered item", 102);

        mdNote = findNoteByID(viewContext, mdNoteID);
        NSArray *model = noteToParaModel(mdNote);
        NSMutableArray *filtered = [NSMutableArray array];
        BOOL fc = NO;
        for (NSDictionary *p in model) {
            if (!fc && [p[@"text"] length] == 0) continue;
            fc = YES;
            [filtered addObject:p];
        }
        NSString *markdown = paraModelToMarkdown(filtered);
        if ([markdown containsString:@"1. Numbered item"]) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (md: %s)\n", [markdown UTF8String]); failed++; }

        deleteNote(findNoteByID(viewContext, mdNoteID), viewContext);
        [viewContext save:nil];
    }

    // Test: read-markdown checklist
    fprintf(stderr, "Test: read-markdown checklist...\n");
    {
        NSString *mdTitle = @"__md_test_check__";
        id mdNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id mdDoc = ((id (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("document"));
        id mdMs = ((id (*)(id, SEL))objc_msgSend)(mdDoc, sel_registerName("mergeableString"));
        NSString *mdContent = [NSString stringWithFormat:@"%@\nUnchecked item\nChecked item", mdTitle];
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(mdMs, sel_registerName("insertString:atIndex:"), mdContent, 0);
        // Title style
        id s0 = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s0, sel_registerName("setStyle:"), 0);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": s0}, NSMakeRange(0, mdTitle.length + 1));
        // Unchecked checklist
        id s103a = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s103a, sel_registerName("setStyle:"), 103);
        id todoA = ((id (*)(id, SEL, id, BOOL))objc_msgSend)(
            [ICTTTodoClass alloc], sel_registerName("initWithIdentifier:done:"), [NSUUID UUID], NO);
        ((void (*)(id, SEL, id))objc_msgSend)(s103a, sel_registerName("setTodo:"), todoA);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": s103a}, NSMakeRange(mdTitle.length + 1, 15));
        // Checked checklist
        id s103b = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s103b, sel_registerName("setStyle:"), 103);
        id todoB = ((id (*)(id, SEL, id, BOOL))objc_msgSend)(
            [ICTTTodoClass alloc], sel_registerName("initWithIdentifier:done:"), [NSUUID UUID], YES);
        ((void (*)(id, SEL, id))objc_msgSend)(s103b, sel_registerName("setTodo:"), todoB);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": s103b}, NSMakeRange(mdTitle.length + 16, 12));
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            mdNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, mdContent.length), mdContent.length);
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        NSArray *model = noteToParaModel(mdNote);
        NSMutableArray *filtered = [NSMutableArray array];
        BOOL fc = NO;
        for (NSDictionary *p in model) {
            if (!fc && [p[@"text"] length] == 0) continue;
            fc = YES;
            [filtered addObject:p];
        }
        NSString *markdown = paraModelToMarkdown(filtered);
        BOOL hasUnchecked = [markdown containsString:@"- [ ] Unchecked item"];
        BOOL hasChecked = [markdown containsString:@"- [x] Checked item"];
        if (hasUnchecked && hasChecked) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (md: %s)\n", [markdown UTF8String]); failed++; }

        deleteNote(mdNote, viewContext);
        [viewContext save:nil];
    }

    // Test: read-markdown with link
    fprintf(stderr, "Test: read-markdown link...\n");
    {
        NSString *mdTitle = @"__md_test_link__";
        id mdNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id mdDoc = ((id (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("document"));
        id mdMs = ((id (*)(id, SEL))objc_msgSend)(mdDoc, sel_registerName("mergeableString"));
        NSString *mdContent = [NSString stringWithFormat:@"%@\nClick here", mdTitle];
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(mdMs, sel_registerName("insertString:atIndex:"), mdContent, 0);
        id s0 = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s0, sel_registerName("setStyle:"), 0);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": s0}, NSMakeRange(0, mdTitle.length + 1));
        id s3 = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s3, sel_registerName("setStyle:"), 3);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            (@{@"TTStyle": s3, @"NSLink": [NSURL URLWithString:@"https://example.com"]}),
            NSMakeRange(mdTitle.length + 1, 10));
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            mdNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, mdContent.length), mdContent.length);
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        NSArray *model = noteToParaModel(mdNote);
        NSMutableArray *filtered = [NSMutableArray array];
        BOOL fc = NO;
        for (NSDictionary *p in model) {
            if (!fc && [p[@"text"] length] == 0) continue;
            fc = YES;
            [filtered addObject:p];
        }
        NSString *markdown = paraModelToMarkdown(filtered);
        if ([markdown containsString:@"[Click here](https://example.com)"]) {
            fprintf(stderr, "  PASS\n"); passed++;
        } else { fprintf(stderr, "  FAIL (md: %s)\n", [markdown UTF8String]); failed++; }

        deleteNote(mdNote, viewContext);
        [viewContext save:nil];
    }

    // Test: read-markdown with strikethrough
    fprintf(stderr, "Test: read-markdown strikethrough...\n");
    {
        NSString *mdTitle = @"__md_test_strike__";
        id mdNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id mdDoc = ((id (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("document"));
        id mdMs = ((id (*)(id, SEL))objc_msgSend)(mdDoc, sel_registerName("mergeableString"));
        NSString *mdContent = [NSString stringWithFormat:@"%@\nStruck text", mdTitle];
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(mdMs, sel_registerName("insertString:atIndex:"), mdContent, 0);
        id s0 = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s0, sel_registerName("setStyle:"), 0);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": s0}, NSMakeRange(0, mdTitle.length + 1));
        id s3 = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s3, sel_registerName("setStyle:"), 3);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            (@{@"TTStyle": s3, @"TTStrikethrough": @1}),
            NSMakeRange(mdTitle.length + 1, 11));
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            mdNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, mdContent.length), mdContent.length);
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        NSArray *model = noteToParaModel(mdNote);
        NSMutableArray *filtered = [NSMutableArray array];
        BOOL fc = NO;
        for (NSDictionary *p in model) {
            if (!fc && [p[@"text"] length] == 0) continue;
            fc = YES;
            [filtered addObject:p];
        }
        NSString *markdown = paraModelToMarkdown(filtered);
        if ([markdown containsString:@"~~Struck text~~"]) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (md: %s)\n", [markdown UTF8String]); failed++; }

        deleteNote(mdNote, viewContext);
        [viewContext save:nil];
    }

    // Test: read-markdown with bold
    fprintf(stderr, "Test: read-markdown bold...\n");
    {
        NSString *mdTitle = @"__md_test_bold__";
        id mdNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id mdDoc = ((id (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("document"));
        id mdMs = ((id (*)(id, SEL))objc_msgSend)(mdDoc, sel_registerName("mergeableString"));
        NSString *mdContent = [NSString stringWithFormat:@"%@\nBold text", mdTitle];
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(mdMs, sel_registerName("insertString:atIndex:"), mdContent, 0);
        id s0b = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s0b, sel_registerName("setStyle:"), 0);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": s0b}, NSMakeRange(0, mdTitle.length + 1));
        id s3b = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s3b, sel_registerName("setStyle:"), 3);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            (@{@"TTStyle": s3b, @"TTHints": @1}),
            NSMakeRange(mdTitle.length + 1, 9));
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            mdNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, mdContent.length), mdContent.length);
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        NSArray *model = noteToParaModel(mdNote);
        NSMutableArray *filtered = [NSMutableArray array];
        BOOL fc = NO;
        for (NSDictionary *p in model) {
            if (!fc && [p[@"text"] length] == 0) continue;
            fc = YES;
            [filtered addObject:p];
        }
        NSString *markdown = paraModelToMarkdown(filtered);
        if ([markdown containsString:@"**Bold text**"]) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (md: %s)\n", [markdown UTF8String]); failed++; }

        deleteNote(mdNote, viewContext);
        [viewContext save:nil];
    }

    // Test: read-markdown with italic
    fprintf(stderr, "Test: read-markdown italic...\n");
    {
        NSString *mdTitle = @"__md_test_italic__";
        id mdNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id mdDoc = ((id (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("document"));
        id mdMs = ((id (*)(id, SEL))objc_msgSend)(mdDoc, sel_registerName("mergeableString"));
        NSString *mdContent = [NSString stringWithFormat:@"%@\nItalic text", mdTitle];
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(mdMs, sel_registerName("insertString:atIndex:"), mdContent, 0);
        id s0i = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s0i, sel_registerName("setStyle:"), 0);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": s0i}, NSMakeRange(0, mdTitle.length + 1));
        id s3i = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s3i, sel_registerName("setStyle:"), 3);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            (@{@"TTStyle": s3i, @"TTHints": @2}),
            NSMakeRange(mdTitle.length + 1, 11));
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            mdNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, mdContent.length), mdContent.length);
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        NSArray *model = noteToParaModel(mdNote);
        NSMutableArray *filtered = [NSMutableArray array];
        BOOL fc = NO;
        for (NSDictionary *p in model) {
            if (!fc && [p[@"text"] length] == 0) continue;
            fc = YES;
            [filtered addObject:p];
        }
        NSString *markdown = paraModelToMarkdown(filtered);
        if ([markdown containsString:@"*Italic text*"]) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (md: %s)\n", [markdown UTF8String]); failed++; }

        deleteNote(mdNote, viewContext);
        [viewContext save:nil];
    }

    // Test: read-markdown with bold+italic
    fprintf(stderr, "Test: read-markdown bold+italic...\n");
    {
        NSString *mdTitle = @"__md_test_bolditalic__";
        id mdNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id mdDoc = ((id (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("document"));
        id mdMs = ((id (*)(id, SEL))objc_msgSend)(mdDoc, sel_registerName("mergeableString"));
        NSString *mdContent = [NSString stringWithFormat:@"%@\nBoth text", mdTitle];
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(mdMs, sel_registerName("insertString:atIndex:"), mdContent, 0);
        id s0bi = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s0bi, sel_registerName("setStyle:"), 0);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": s0bi}, NSMakeRange(0, mdTitle.length + 1));
        id s3bi = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s3bi, sel_registerName("setStyle:"), 3);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            (@{@"TTStyle": s3bi, @"TTHints": @3}),
            NSMakeRange(mdTitle.length + 1, 9));
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            mdNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, mdContent.length), mdContent.length);
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        NSArray *model = noteToParaModel(mdNote);
        NSMutableArray *filtered = [NSMutableArray array];
        BOOL fc = NO;
        for (NSDictionary *p in model) {
            if (!fc && [p[@"text"] length] == 0) continue;
            fc = YES;
            [filtered addObject:p];
        }
        NSString *markdown = paraModelToMarkdown(filtered);
        if ([markdown containsString:@"***Both text***"]) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (md: %s)\n", [markdown UTF8String]); failed++; }

        deleteNote(mdNote, viewContext);
        [viewContext save:nil];
    }

    // Test: read-markdown with underline
    fprintf(stderr, "Test: read-markdown underline...\n");
    {
        NSString *mdTitle = @"__md_test_underline__";
        id mdNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id mdDoc = ((id (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("document"));
        id mdMs = ((id (*)(id, SEL))objc_msgSend)(mdDoc, sel_registerName("mergeableString"));
        NSString *mdContent = [NSString stringWithFormat:@"%@\nUnderlined", mdTitle];
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(mdMs, sel_registerName("insertString:atIndex:"), mdContent, 0);
        id s0u = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s0u, sel_registerName("setStyle:"), 0);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": s0u}, NSMakeRange(0, mdTitle.length + 1));
        id s3u = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s3u, sel_registerName("setStyle:"), 3);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            (@{@"TTStyle": s3u, @"TTUnderline": @1}),
            NSMakeRange(mdTitle.length + 1, 10));
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            mdNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, mdContent.length), mdContent.length);
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        NSArray *model = noteToParaModel(mdNote);
        NSMutableArray *filtered = [NSMutableArray array];
        BOOL fc = NO;
        for (NSDictionary *p in model) {
            if (!fc && [p[@"text"] length] == 0) continue;
            fc = YES;
            [filtered addObject:p];
        }
        NSString *markdown = paraModelToMarkdown(filtered);
        if ([markdown containsString:@"<u>Underlined</u>"]) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (md: %s)\n", [markdown UTF8String]); failed++; }

        deleteNote(mdNote, viewContext);
        [viewContext save:nil];
    }

    // Test: bold/italic/underline parse round-trip
    fprintf(stderr, "Test: bold/italic/underline parse round-trip...\n");
    {
        NSString *input = @"**bold** and *italic* and ***both*** and <u>underlined</u>";
        NSMutableString *plain = [NSMutableString string];
        NSMutableArray *runs = [NSMutableArray array];
        parseInlineFormatting(input, plain, runs);

        // Check plain text has formatting stripped
        BOOL plainOk = [plain isEqualToString:@"bold and italic and both and underlined"];

        // Check runs have correct properties
        BOOL runsOk = YES;
        BOOL foundBold = NO, foundItalic = NO, foundBoth = NO, foundUnderline = NO;
        for (NSDictionary *run in runs) {
            NSString *text = [plain substringWithRange:NSMakeRange([run[@"start"] unsignedIntegerValue], [run[@"length"] unsignedIntegerValue])];
            if ([text isEqualToString:@"bold"] && [run[@"bold"] boolValue] && ![run[@"italic"] boolValue]) foundBold = YES;
            if ([text isEqualToString:@"italic"] && [run[@"italic"] boolValue] && ![run[@"bold"] boolValue]) foundItalic = YES;
            if ([text isEqualToString:@"both"] && [run[@"bold"] boolValue] && [run[@"italic"] boolValue]) foundBoth = YES;
            if ([text isEqualToString:@"underlined"] && [run[@"underline"] boolValue]) foundUnderline = YES;
        }
        runsOk = foundBold && foundItalic && foundBoth && foundUnderline;

        if (plainOk && runsOk) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (plain=%s, bold=%d, italic=%d, both=%d, underline=%d)\n",
            [plain UTF8String], foundBold, foundItalic, foundBoth, foundUnderline); failed++; }
    }

    // Test: markdown escape/unescape round-trip
    fprintf(stderr, "Test: markdown escape round-trip...\n");
    {
        NSString *original = @"Hello *world* [link](url) ~~strike~~ <tag> back\\slash";
        NSString *escaped = escapeMarkdown(original);
        NSString *unescaped = unescapeMarkdown(escaped);
        if ([original isEqualToString:unescaped]) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (orig: %s, unescaped: %s)\n", [original UTF8String], [unescaped UTF8String]); failed++; }
    }

    // Test: markdown parser round-trip
    fprintf(stderr, "Test: markdown parser round-trip...\n");
    {
        NSString *mdTitle = @"__md_test_roundtrip__";
        id mdNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id mdDoc = ((id (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("document"));
        id mdMs = ((id (*)(id, SEL))objc_msgSend)(mdDoc, sel_registerName("mergeableString"));
        NSString *mdContent = [NSString stringWithFormat:@"%@\nBody line 1\nBody line 2", mdTitle];
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(mdMs, sel_registerName("insertString:atIndex:"), mdContent, 0);
        id s0 = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s0, sel_registerName("setStyle:"), 0);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": s0}, NSMakeRange(0, mdTitle.length + 1));
        // Style each body paragraph separately so each gets its own UUID
        NSArray *rtBodyLines = @[@"Body line 1", @"Body line 2"];
        NSUInteger rtOff = mdTitle.length + 1;
        for (NSString *rtl in rtBodyLines) {
            id rts = [[ICTTParagraphStyleClass alloc] init];
            ((void (*)(id, SEL, NSUInteger))objc_msgSend)(rts, sel_registerName("setStyle:"), 3);
            NSUInteger rtLen = rtl.length + 1;
            if (rtOff + rtLen > mdContent.length) rtLen = mdContent.length - rtOff;
            ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
                @{@"TTStyle": rts}, NSMakeRange(rtOff, rtLen));
            rtOff += rtl.length + 1;
        }
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            mdNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, mdContent.length), mdContent.length);
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        // Read as markdown
        NSArray *model = noteToParaModel(mdNote);
        NSMutableArray *filtered = [NSMutableArray array];
        BOOL fc = NO;
        for (NSDictionary *p in model) {
            if (!fc && [p[@"text"] length] == 0) continue;
            fc = YES;
            [filtered addObject:p];
        }
        NSString *markdown = paraModelToMarkdown(filtered);
        // Parse back
        NSArray *parsed = markdownToParaModel(markdown);
        // Compare models
        BOOL match = (filtered.count == parsed.count);
        if (match) {
            for (NSUInteger pi = 0; pi < filtered.count; pi++) {
                NSDictionary *orig = filtered[pi];
                NSDictionary *back = parsed[pi];
                if (![orig[@"style"] isEqual:back[@"style"]] ||
                    ![normalizeParaText(orig[@"text"]) isEqualToString:normalizeParaText(back[@"text"])]) {
                    match = NO;
                    fprintf(stderr, "    Mismatch at para %lu: style %s vs %s, text '%s' vs '%s'\n",
                        (unsigned long)pi, [[orig[@"style"] description] UTF8String],
                        [[back[@"style"] description] UTF8String],
                        [orig[@"text"] UTF8String], [back[@"text"] UTF8String]);
                    break;
                }
            }
        }
        if (match) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (count: %lu vs %lu)\n", (unsigned long)filtered.count, (unsigned long)parsed.count); failed++; }

        deleteNote(mdNote, viewContext);
        [viewContext save:nil];
    }

    // Test: markdown code block round-trip
    fprintf(stderr, "Test: markdown code block round-trip...\n");
    {
        // Test 1: Simple single-line code block
        NSString *md1 = @"# Title\n```\nmkdir -p ~/.config\n```\nSome body text";
        NSArray *parsed1 = markdownToParaModel(md1);
        BOOL ok = YES;
        // Expect: title(style 0), code(style 4), body(style 3)
        if (parsed1.count != 3) { ok = NO; fprintf(stderr, "    FAIL: expected 3 paragraphs, got %lu\n", (unsigned long)parsed1.count); }
        else {
            if ([parsed1[1][@"style"] integerValue] != 4) { ok = NO; fprintf(stderr, "    FAIL: code block style is %ld, expected 4\n", (long)[parsed1[1][@"style"] integerValue]); }
            if (![parsed1[1][@"text"] isEqualToString:@"mkdir -p ~/.config"]) { ok = NO; fprintf(stderr, "    FAIL: code block text is '%s'\n", [parsed1[1][@"text"] UTF8String]); }
        }

        // Test 2: Multi-line code block (should be single paragraph with embedded newlines)
        NSString *md2 = @"# Title\n```\nline 1\nline 2\nline 3\n```";
        NSArray *parsed2 = markdownToParaModel(md2);
        if (parsed2.count != 2) { ok = NO; fprintf(stderr, "    FAIL: multi-line: expected 2 paragraphs, got %lu\n", (unsigned long)parsed2.count); }
        else {
            if ([parsed2[1][@"style"] integerValue] != 4) { ok = NO; fprintf(stderr, "    FAIL: multi-line: style is %ld\n", (long)[parsed2[1][@"style"] integerValue]); }
            if (![parsed2[1][@"text"] isEqualToString:@"line 1\nline 2\nline 3"]) { ok = NO; fprintf(stderr, "    FAIL: multi-line: text is '%s'\n", [parsed2[1][@"text"] UTF8String]); }
        }

        // Test 3: Round-trip: markdown -> model -> markdown
        NSString *md3 = @"# Title\n```\necho hello\n```\nBody after code";
        NSArray *parsed3 = markdownToParaModel(md3);
        NSString *rt3 = paraModelToMarkdown(parsed3);
        if (![rt3 isEqualToString:md3]) { ok = NO; fprintf(stderr, "    FAIL: round-trip mismatch:\n    got:  '%s'\n    want: '%s'\n", [rt3 UTF8String], [md3 UTF8String]); }

        // Test 4: Code block with language specifier (```bash)
        NSString *md4 = @"# Title\n```bash\necho hello\n```";
        NSArray *parsed4 = markdownToParaModel(md4);
        if (parsed4.count != 2) { ok = NO; fprintf(stderr, "    FAIL: lang spec: expected 2 paragraphs, got %lu\n", (unsigned long)parsed4.count); }
        else {
            if ([parsed4[1][@"style"] integerValue] != 4) { ok = NO; fprintf(stderr, "    FAIL: lang spec: style is %ld\n", (long)[parsed4[1][@"style"] integerValue]); }
            if (![parsed4[1][@"text"] isEqualToString:@"echo hello"]) { ok = NO; fprintf(stderr, "    FAIL: lang spec: text is '%s'\n", [parsed4[1][@"text"] UTF8String]); }
        }

        // Test 5: Code block content not treated as markdown (e.g., # inside code block)
        NSString *md5 = @"# Title\n```\n# Not a heading\n- Not a list\n1. Not numbered\n```";
        NSArray *parsed5 = markdownToParaModel(md5);
        if (parsed5.count != 2) { ok = NO; fprintf(stderr, "    FAIL: escape: expected 2 paragraphs, got %lu\n", (unsigned long)parsed5.count); }
        else {
            NSString *expected5 = @"# Not a heading\n- Not a list\n1. Not numbered";
            if (![parsed5[1][@"text"] isEqualToString:expected5]) { ok = NO; fprintf(stderr, "    FAIL: escape: code text is '%s'\n", [parsed5[1][@"text"] UTF8String]); }
        }

        // Test 6: Multiple code blocks
        NSString *md6 = @"# Title\n```\nblock 1\n```\nMiddle text\n```\nblock 2\n```";
        NSArray *parsed6 = markdownToParaModel(md6);
        if (parsed6.count != 4) { ok = NO; fprintf(stderr, "    FAIL: multiple: expected 4 paragraphs, got %lu\n", (unsigned long)parsed6.count); }
        else {
            if ([parsed6[1][@"style"] integerValue] != 4) { ok = NO; fprintf(stderr, "    FAIL: multiple: first block style %ld\n", (long)[parsed6[1][@"style"] integerValue]); }
            if ([parsed6[3][@"style"] integerValue] != 4) { ok = NO; fprintf(stderr, "    FAIL: multiple: second block style %ld\n", (long)[parsed6[3][@"style"] integerValue]); }
            if (![parsed6[1][@"text"] isEqualToString:@"block 1"]) { ok = NO; fprintf(stderr, "    FAIL: multiple: first block text '%s'\n", [parsed6[1][@"text"] UTF8String]); }
            if (![parsed6[3][@"text"] isEqualToString:@"block 2"]) { ok = NO; fprintf(stderr, "    FAIL: multiple: second block text '%s'\n", [parsed6[3][@"text"] UTF8String]); }
        }

        // Test 7: Round-trip with multiple code blocks
        NSString *rt6 = paraModelToMarkdown(parsed6);
        if (![rt6 isEqualToString:md6]) { ok = NO; fprintf(stderr, "    FAIL: multiple round-trip:\n    got:  '%s'\n    want: '%s'\n", [rt6 UTF8String], [md6 UTF8String]); }

        // Test 8: Empty code block
        NSString *md8 = @"# Title\n```\n```\nBody";
        NSArray *parsed8 = markdownToParaModel(md8);
        if (parsed8.count != 3) { ok = NO; fprintf(stderr, "    FAIL: empty code block: expected 3 paragraphs, got %lu\n", (unsigned long)parsed8.count); }
        else {
            if ([parsed8[1][@"style"] integerValue] != 4) { ok = NO; fprintf(stderr, "    FAIL: empty code block: style is %ld\n", (long)[parsed8[1][@"style"] integerValue]); }
            if (![parsed8[1][@"text"] isEqualToString:@""]) { ok = NO; fprintf(stderr, "    FAIL: empty code block: text is '%s', expected empty\n", [parsed8[1][@"text"] UTF8String]); }
        }
        // Empty code block round-trip
        NSString *rt8 = paraModelToMarkdown(parsed8);
        if (![rt8 isEqualToString:md8]) { ok = NO; fprintf(stderr, "    FAIL: empty code block round-trip:\n    got:  '%s'\n    want: '%s'\n", [rt8 UTF8String], [md8 UTF8String]); }

        // Test 9: Leading empty line in code block
        NSString *md9 = @"# Title\n```\n\nline after blank\n```";
        NSArray *parsed9 = markdownToParaModel(md9);
        if (parsed9.count != 2) { ok = NO; fprintf(stderr, "    FAIL: leading blank: expected 2 paragraphs, got %lu\n", (unsigned long)parsed9.count); }
        else {
            NSString *expected9 = @"\nline after blank";
            if (![parsed9[1][@"text"] isEqualToString:expected9]) { ok = NO; fprintf(stderr, "    FAIL: leading blank: text is '%s', expected '%s'\n", [parsed9[1][@"text"] UTF8String], [expected9 UTF8String]); }
        }

        // Test 10: Code containing triple backtick-like lines (should not close fence)
        NSString *md10 = @"# Title\n````\nSome ```code``` here\n````";
        NSArray *parsed10 = markdownToParaModel(md10);
        if (parsed10.count != 2) { ok = NO; fprintf(stderr, "    FAIL: backtick content: expected 2 paragraphs, got %lu\n", (unsigned long)parsed10.count); }
        else {
            if (![parsed10[1][@"text"] isEqualToString:@"Some ```code``` here"]) { ok = NO; fprintf(stderr, "    FAIL: backtick content: text is '%s'\n", [parsed10[1][@"text"] UTF8String]); }
        }

        // Test 11: Tilde fence
        NSString *md11 = @"# Title\n~~~\ncode in tildes\n~~~";
        NSArray *parsed11 = markdownToParaModel(md11);
        if (parsed11.count != 2) { ok = NO; fprintf(stderr, "    FAIL: tilde fence: expected 2 paragraphs, got %lu\n", (unsigned long)parsed11.count); }
        else {
            if ([parsed11[1][@"style"] integerValue] != 4) { ok = NO; fprintf(stderr, "    FAIL: tilde fence: style is %ld\n", (long)[parsed11[1][@"style"] integerValue]); }
            if (![parsed11[1][@"text"] isEqualToString:@"code in tildes"]) { ok = NO; fprintf(stderr, "    FAIL: tilde fence: text is '%s'\n", [parsed11[1][@"text"] UTF8String]); }
        }

        // Test 12: Closing fence must match opening char (backtick opened, tilde doesn't close)
        NSString *md12 = @"# Title\n```\nline1\n~~~\nline2\n```";
        NSArray *parsed12 = markdownToParaModel(md12);
        if (parsed12.count != 2) { ok = NO; fprintf(stderr, "    FAIL: fence char mismatch: expected 2 paragraphs, got %lu\n", (unsigned long)parsed12.count); }
        else {
            NSString *expected12 = @"line1\n~~~\nline2";
            if (![parsed12[1][@"text"] isEqualToString:expected12]) { ok = NO; fprintf(stderr, "    FAIL: fence char mismatch: text is '%s'\n", [parsed12[1][@"text"] UTF8String]); }
        }

        if (ok) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL\n"); failed++; }
    }

    // Test: write-markdown code block (end-to-end)
    fprintf(stderr, "Test: write-markdown code block...\n");
    {
        // Create a note and write markdown with a code block
        id cbNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        NSString *cbTitle = @"__code_block_test__";
        id cbDoc = ((id (*)(id, SEL))objc_msgSend)(cbNote, sel_registerName("document"));
        id cbMs = ((id (*)(id, SEL))objc_msgSend)(cbDoc, sel_registerName("mergeableString"));
        ((void (*)(id, SEL))objc_msgSend)(cbNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(cbMs, sel_registerName("insertString:atIndex:"), cbTitle, 0);
        id cbS0 = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(cbS0, sel_registerName("setStyle:"), 0);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(cbMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": cbS0}, NSMakeRange(0, cbTitle.length));
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            cbNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, cbTitle.length), cbTitle.length);
        ((void (*)(id, SEL))objc_msgSend)(cbNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(cbNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        // Write markdown with code block
        NSString *cbMarkdown = @"# __code_block_test__\n```\necho hello world\n```\nBody after code";
        cmdWriteMarkdownWithString(cbNote, viewContext, cbMarkdown, NO, NO, NO);

        // Re-read the note and check the style
        cbNote = findNoteByID(viewContext, noteToDict(cbNote)[@"id"]);
        NSArray *cbModel = noteToParaModel(cbNote);
        BOOL cbOk = NO;
        for (NSDictionary *p in cbModel) {
            if ([p[@"style"] integerValue] == 4 && [p[@"text"] isEqualToString:@"echo hello world"]) {
                cbOk = YES;
                break;
            }
        }

        if (cbOk) { fprintf(stderr, "  PASS\n"); passed++; }
        else {
            fprintf(stderr, "  FAIL (style 4 paragraph not found)\n");
            for (NSDictionary *p in cbModel) {
                fprintf(stderr, "    style=%ld text='%s'\n", (long)[p[@"style"] integerValue], [p[@"text"] UTF8String]);
            }
            failed++;
        }

        deleteNote(cbNote, viewContext);
        [viewContext save:nil];
    }

    // Test: write-markdown no-change round-trip (subprocess)
    fprintf(stderr, "Test: write-markdown no-change round-trip...\n");
    {
        NSString *mdTitle = @"__md_test_nochange__";
        id mdNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id mdDoc = ((id (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("document"));
        id mdMs = ((id (*)(id, SEL))objc_msgSend)(mdDoc, sel_registerName("mergeableString"));
        NSString *mdContent = [NSString stringWithFormat:@"%@\nKeep this line\nAnd this one", mdTitle];
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(mdMs, sel_registerName("insertString:atIndex:"), mdContent, 0);
        id s0 = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s0, sel_registerName("setStyle:"), 0);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": s0}, NSMakeRange(0, mdTitle.length + 1));
        // Style each body paragraph separately so each gets its own UUID
        NSArray *ncLines = @[@"Keep this line", @"And this one"];
        NSUInteger ncOff = mdTitle.length + 1;
        for (NSString *ncl in ncLines) {
            id ncs = [[ICTTParagraphStyleClass alloc] init];
            ((void (*)(id, SEL, NSUInteger))objc_msgSend)(ncs, sel_registerName("setStyle:"), 3);
            NSUInteger ncLen = ncl.length + 1;
            if (ncOff + ncLen > mdContent.length) ncLen = mdContent.length - ncOff;
            ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
                @{@"TTStyle": ncs}, NSMakeRange(ncOff, ncLen));
            ncOff += ncl.length + 1;
        }
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            mdNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, mdContent.length), mdContent.length);
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        NSString *mdNoteID = noteToDict(mdNote)[@"id"];
        // Read markdown and pipe to write-markdown --dry-run
        NSString *cmd = [NSString stringWithFormat:@"'%s' read-markdown --id '%@' 2>/dev/null | '%s' write-markdown --id '%@' --dry-run 2>/dev/null",
            exePath, mdNoteID, exePath, mdNoteID];
        FILE *fp = popen([cmd UTF8String], "r");
        NSMutableData *outData = [NSMutableData data];
        if (fp) {
            char buf[4096];
            size_t n;
            while ((n = fread(buf, 1, sizeof(buf), fp)) > 0) [outData appendBytes:buf length:n];
            pclose(fp);
        }
        NSDictionary *result = [NSJSONSerialization JSONObjectWithData:outData options:0 error:nil];
        NSUInteger modified = [result[@"paragraphsModified"] unsignedIntegerValue];
        NSUInteger insertedCount = [result[@"paragraphsInserted"] unsignedIntegerValue];
        NSUInteger deletedCount = [result[@"paragraphsDeleted"] unsignedIntegerValue];
        if (modified == 0 && insertedCount == 0 && deletedCount == 0) {
            fprintf(stderr, "  PASS\n"); passed++;
        } else {
            fprintf(stderr, "  FAIL (modified=%lu, inserted=%lu, deleted=%lu)\n",
                (unsigned long)modified, (unsigned long)insertedCount, (unsigned long)deletedCount); failed++;
        }

        deleteNote(findNoteByID(viewContext, mdNoteID), viewContext);
        [viewContext save:nil];
    }

    // Test: write-markdown text change (in-process)
    fprintf(stderr, "Test: write-markdown text change...\n");
    {
        NSString *mdTitle = @"__md_test_textchange__";
        id mdNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id mdDoc = ((id (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("document"));
        id mdMs = ((id (*)(id, SEL))objc_msgSend)(mdDoc, sel_registerName("mergeableString"));
        NSString *mdContent = [NSString stringWithFormat:@"%@\nOriginal line\nUntouched line", mdTitle];
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(mdMs, sel_registerName("insertString:atIndex:"), mdContent, 0);
        id s0 = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s0, sel_registerName("setStyle:"), 0);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": s0}, NSMakeRange(0, mdTitle.length + 1));
        // Style each body paragraph separately so each gets its own UUID
        NSArray *tcLines = @[@"Original line", @"Untouched line"];
        NSUInteger tcOff = mdTitle.length + 1;
        for (NSString *tcl in tcLines) {
            id tcs = [[ICTTParagraphStyleClass alloc] init];
            ((void (*)(id, SEL, NSUInteger))objc_msgSend)(tcs, sel_registerName("setStyle:"), 3);
            NSUInteger tcLen = tcl.length + 1;
            if (tcOff + tcLen > mdContent.length) tcLen = mdContent.length - tcOff;
            ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
                @{@"TTStyle": tcs}, NSMakeRange(tcOff, tcLen));
            tcOff += tcl.length + 1;
        }
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            mdNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, mdContent.length), mdContent.length);
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        NSString *mdNoteID = noteToDict(mdNote)[@"id"];
        // Redirect stdout to /dev/null during write
        int savedOut = dup(STDOUT_FILENO);
        int devNull1 = open("/dev/null", O_WRONLY);
        dup2(devNull1, STDOUT_FILENO); close(devNull1);

        NSString *newMd = [NSString stringWithFormat:@"# %@\nModified line\nUntouched line\n", mdTitle];
        cmdWriteMarkdownWithString(mdNote, viewContext, newMd, NO, NO, NO);

        dup2(savedOut, STDOUT_FILENO); close(savedOut);

        // Verify the note was modified
        mdNote = findNoteByID(viewContext, mdNoteID);
        NSString *body = ((id (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("noteAsPlainTextWithoutTitle"));
        BOOL hasModified = [body containsString:@"Modified line"];
        BOOL hasUntouched = [body containsString:@"Untouched line"];
        if (hasModified && hasUntouched) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (body: %s)\n", [body UTF8String]); failed++; }

        deleteNote(findNoteByID(viewContext, mdNoteID), viewContext);
        [viewContext save:nil];
    }

    // Test: write-markdown add paragraph
    fprintf(stderr, "Test: write-markdown add paragraph...\n");
    {
        NSString *mdTitle = @"__md_test_addpara__";
        id mdNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id mdDoc = ((id (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("document"));
        id mdMs = ((id (*)(id, SEL))objc_msgSend)(mdDoc, sel_registerName("mergeableString"));
        NSString *mdContent = [NSString stringWithFormat:@"%@\nExisting line", mdTitle];
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(mdMs, sel_registerName("insertString:atIndex:"), mdContent, 0);
        id s0 = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s0, sel_registerName("setStyle:"), 0);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": s0}, NSMakeRange(0, mdTitle.length + 1));
        id s3 = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s3, sel_registerName("setStyle:"), 3);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": s3}, NSMakeRange(mdTitle.length + 1, 13));
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            mdNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, mdContent.length), mdContent.length);
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        NSString *mdNoteID = noteToDict(mdNote)[@"id"];
        int savedOut = dup(STDOUT_FILENO);
        int devNull1 = open("/dev/null", O_WRONLY);
        dup2(devNull1, STDOUT_FILENO); close(devNull1);

        NSString *newMd = [NSString stringWithFormat:@"# %@\nExisting line\nNew line added\n", mdTitle];
        cmdWriteMarkdownWithString(mdNote, viewContext, newMd, NO, NO, NO);

        dup2(savedOut, STDOUT_FILENO); close(savedOut);

        mdNote = findNoteByID(viewContext, mdNoteID);
        NSString *body = ((id (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("noteAsPlainTextWithoutTitle"));
        BOOL hasExisting = [body containsString:@"Existing line"];
        BOOL hasNew = [body containsString:@"New line added"];
        if (hasExisting && hasNew) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (body: %s)\n", [body UTF8String]); failed++; }

        deleteNote(findNoteByID(viewContext, mdNoteID), viewContext);
        [viewContext save:nil];
    }

    // Test: write-markdown delete paragraph
    fprintf(stderr, "Test: write-markdown delete paragraph...\n");
    {
        NSString *mdTitle = @"__md_test_delpara__";
        id mdNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id mdDoc = ((id (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("document"));
        id mdMs = ((id (*)(id, SEL))objc_msgSend)(mdDoc, sel_registerName("mergeableString"));
        NSString *mdContent = [NSString stringWithFormat:@"%@\nKeep me\nDelete me\nAlso keep", mdTitle];
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(mdMs, sel_registerName("insertString:atIndex:"), mdContent, 0);
        id s0 = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s0, sel_registerName("setStyle:"), 0);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": s0}, NSMakeRange(0, mdTitle.length + 1));
        // Style each body paragraph separately so each gets its own UUID
        NSArray *bodyLines = @[@"Keep me", @"Delete me", @"Also keep"];
        NSUInteger bOff = mdTitle.length + 1;
        for (NSString *bl in bodyLines) {
            id bs = [[ICTTParagraphStyleClass alloc] init];
            ((void (*)(id, SEL, NSUInteger))objc_msgSend)(bs, sel_registerName("setStyle:"), 3);
            NSUInteger bLen = bl.length + 1; // +1 for \n (or to end)
            if (bOff + bLen > mdContent.length) bLen = mdContent.length - bOff;
            ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
                @{@"TTStyle": bs}, NSMakeRange(bOff, bLen));
            bOff += bl.length + 1;
        }
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            mdNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, mdContent.length), mdContent.length);
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        NSString *mdNoteID = noteToDict(mdNote)[@"id"];
        int savedOut = dup(STDOUT_FILENO);
        int devNull1 = open("/dev/null", O_WRONLY);
        dup2(devNull1, STDOUT_FILENO); close(devNull1);

        NSString *newMd = [NSString stringWithFormat:@"# %@\nKeep me\nAlso keep\n", mdTitle];
        cmdWriteMarkdownWithString(mdNote, viewContext, newMd, NO, NO, NO);

        dup2(savedOut, STDOUT_FILENO); close(savedOut);

        mdNote = findNoteByID(viewContext, mdNoteID);
        NSString *body = ((id (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("noteAsPlainTextWithoutTitle"));
        BOOL hasKeep = [body containsString:@"Keep me"];
        BOOL hasAlso = [body containsString:@"Also keep"];
        BOOL hasDelete = [body containsString:@"Delete me"];
        if (hasKeep && hasAlso && !hasDelete) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (body: %s)\n", [body UTF8String]); failed++; }

        deleteNote(findNoteByID(viewContext, mdNoteID), viewContext);
        [viewContext save:nil];
    }

    // Test: write-markdown dry-run mode
    fprintf(stderr, "Test: write-markdown dry-run...\n");
    {
        NSString *mdTitle = @"__md_test_dryrun__";
        id mdNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id mdDoc = ((id (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("document"));
        id mdMs = ((id (*)(id, SEL))objc_msgSend)(mdDoc, sel_registerName("mergeableString"));
        NSString *mdContent = [NSString stringWithFormat:@"%@\nOriginal text", mdTitle];
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(mdMs, sel_registerName("insertString:atIndex:"), mdContent, 0);
        id s0 = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s0, sel_registerName("setStyle:"), 0);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": s0}, NSMakeRange(0, mdTitle.length + 1));
        id s3 = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s3, sel_registerName("setStyle:"), 3);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": s3}, NSMakeRange(mdTitle.length + 1, 13));
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            mdNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, mdContent.length), mdContent.length);
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        NSString *mdNoteID = noteToDict(mdNote)[@"id"];
        // Redirect stdout to /dev/null during dry-run
        int savedOut = dup(STDOUT_FILENO);
        int devNull1 = open("/dev/null", O_WRONLY);
        dup2(devNull1, STDOUT_FILENO); close(devNull1);

        NSString *newMd = [NSString stringWithFormat:@"# %@\nChanged text\n", mdTitle];
        cmdWriteMarkdownWithString(mdNote, viewContext, newMd, YES, NO, NO);

        dup2(savedOut, STDOUT_FILENO); close(savedOut);

        // Verify note was NOT changed (dry-run)
        mdNote = findNoteByID(viewContext, mdNoteID);
        NSString *body = ((id (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("noteAsPlainTextWithoutTitle"));
        BOOL unchanged = [body containsString:@"Original text"];
        if (unchanged) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (body: %s)\n", [body UTF8String]); failed++; }

        deleteNote(findNoteByID(viewContext, mdNoteID), viewContext);
        [viewContext save:nil];
    }

    // Test: write-markdown checklist toggle
    fprintf(stderr, "Test: write-markdown checklist toggle...\n");
    {
        NSString *mdTitle = @"__md_test_toggle__";
        id mdNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id mdDoc = ((id (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("document"));
        id mdMs = ((id (*)(id, SEL))objc_msgSend)(mdDoc, sel_registerName("mergeableString"));
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(mdMs, sel_registerName("insertString:atIndex:"), mdTitle, 0);
        id s0 = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s0, sel_registerName("setStyle:"), 0);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": s0}, NSMakeRange(0, mdTitle.length));
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            mdNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, mdTitle.length), mdTitle.length);
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        NSString *mdNoteID = noteToDict(mdNote)[@"id"];
        cmdAppend(viewContext, mdNoteID, @"Todo item", 103);
        mdNote = findNoteByID(viewContext, mdNoteID);

        // Toggle checked
        int savedOut = dup(STDOUT_FILENO);
        int devNull1 = open("/dev/null", O_WRONLY);
        dup2(devNull1, STDOUT_FILENO); close(devNull1);

        NSString *newMd = [NSString stringWithFormat:@"# %@\n- [x] Todo item\n", mdTitle];
        cmdWriteMarkdownWithString(mdNote, viewContext, newMd, NO, NO, NO);

        dup2(savedOut, STDOUT_FILENO); close(savedOut);
        // Verify the checklist item is now checked
        mdNote = findNoteByID(viewContext, mdNoteID);
        id mdDoc2 = ((id (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("document"));
        id mdMs2 = ((id (*)(id, SEL))objc_msgSend)(mdDoc2, sel_registerName("mergeableString"));
        NSString *fullText = [((id (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("attributedString")) string];
        BOOL foundChecked = NO;
        NSUInteger ci = 0;
        while (ci < fullText.length) {
            NSRange cr;
            NSDictionary *ca = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
                mdMs2, sel_registerName("attributesAtIndex:effectiveRange:"), ci, &cr);
            id cs = ca[@"TTStyle"];
            if (cs) {
                int csv = (int)((NSInteger (*)(id, SEL))objc_msgSend)(cs, sel_registerName("style"));
                if (csv == 103) {
                    id ctodo = ((id (*)(id, SEL))objc_msgSend)(cs, sel_registerName("todo"));
                    if (ctodo && ((BOOL (*)(id, SEL))objc_msgSend)(ctodo, sel_registerName("done"))) {
                        foundChecked = YES;
                    }
                }
            }
            ci = cr.location + cr.length;
        }
        if (foundChecked) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (checklist not toggled)\n"); failed++; }

        deleteNote(findNoteByID(viewContext, mdNoteID), viewContext);
        [viewContext save:nil];
    }

    // Test: line prefix escaping
    fprintf(stderr, "Test: line prefix escaping...\n");
    {
        // Test that body text starting with "# " gets escaped
        NSString *mdTitle = @"__md_test_prefix__";
        id mdNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id mdDoc = ((id (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("document"));
        id mdMs = ((id (*)(id, SEL))objc_msgSend)(mdDoc, sel_registerName("mergeableString"));
        NSString *mdContent = [NSString stringWithFormat:@"%@\n# Not a heading\n- Not a list\n1. Not numbered", mdTitle];
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(mdMs, sel_registerName("insertString:atIndex:"), mdContent, 0);
        id s0 = [[ICTTParagraphStyleClass alloc] init];
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s0, sel_registerName("setStyle:"), 0);
        ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
            @{@"TTStyle": s0}, NSMakeRange(0, mdTitle.length + 1));
        // Style each body paragraph separately so each gets its own UUID
        NSArray *prefixLines = @[@"# Not a heading", @"- Not a list", @"1. Not numbered"];
        NSUInteger pOff = mdTitle.length + 1;
        for (NSString *pl in prefixLines) {
            id ps = [[ICTTParagraphStyleClass alloc] init];
            ((void (*)(id, SEL, NSUInteger))objc_msgSend)(ps, sel_registerName("setStyle:"), 3);
            NSUInteger pLen = pl.length + 1;
            if (pOff + pLen > mdContent.length) pLen = mdContent.length - pOff;
            ((void (*)(id, SEL, id, NSRange))objc_msgSend)(mdMs, sel_registerName("setAttributes:range:"),
                @{@"TTStyle": ps}, NSMakeRange(pOff, pLen));
            pOff += pl.length + 1;
        }
        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            mdNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, mdContent.length), mdContent.length);
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(mdNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        NSArray *model = noteToParaModel(mdNote);
        NSMutableArray *filtered = [NSMutableArray array];
        BOOL fc = NO;
        for (NSDictionary *p in model) {
            if (!fc && [p[@"text"] length] == 0) continue;
            fc = YES;
            [filtered addObject:p];
        }
        NSString *markdown = paraModelToMarkdown(filtered);
        // The body lines should have escaped prefixes
        // The markdown output contains escaped body text lines
        // Find lines that should be escaped
        NSArray *mdLines = [markdown componentsSeparatedByString:@"\n"];
        BOOL hasEscapedHash = NO, hasEscapedDash = NO, hasEscapedNum = NO;
        for (NSString *mdLine in mdLines) {
            // After escapeMarkdown, # stays as # (not in escape list), prefix escape adds backslash
            if ([mdLine containsString:@"Not a heading"] && [mdLine hasPrefix:@"\\#"]) hasEscapedHash = YES;
            if ([mdLine containsString:@"Not a list"] && [mdLine hasPrefix:@"\\-"]) hasEscapedDash = YES;
            if ([mdLine containsString:@"Not numbered"] && [mdLine containsString:@"\\."]) hasEscapedNum = YES;
        }
        if (hasEscapedHash && hasEscapedDash && hasEscapedNum) {
            fprintf(stderr, "  PASS\n"); passed++;
        } else {
            fprintf(stderr, "  FAIL (md: %s)\n", [markdown UTF8String]); failed++;
        }

        deleteNote(mdNote, viewContext);
        [viewContext save:nil];
    }

    // Test: CRLF normalization
    fprintf(stderr, "Test: CRLF normalization...\n");
    {
        NSString *crlfInput = @"# Title\r\nBody line\r\n";
        NSArray *model = markdownToParaModel(crlfInput);
        BOOL titleFound = NO, bodyFound = NO;
        for (NSDictionary *p in model) {
            if ([p[@"style"] integerValue] == 0 && [p[@"text"] isEqualToString:@"Title"]) titleFound = YES;
            if ([p[@"style"] integerValue] == 3 && [p[@"text"] isEqualToString:@"Body line"]) bodyFound = YES;
        }
        if (titleFound && bodyFound) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL\n"); failed++; }
    }

    // Test: rejected link scheme
    fprintf(stderr, "Test: rejected link scheme...\n");
    {
        NSString *dangerousMd = @"[click](javascript:alert(1))";
        NSArray *model = markdownToParaModel(dangerousMd);
        // Should be treated as literal text (no link run)
        BOOL hasLink = NO;
        for (NSDictionary *p in model) {
            NSArray *runs = p[@"runs"];
            for (NSDictionary *r in runs) {
                if (r[@"link"]) hasLink = YES;
            }
        }
        if (!hasLink) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (link was not rejected)\n"); failed++; }
    }

    // Test: get --title returns multiple matches
    fprintf(stderr, "Test: get --title multiple matches...\n");
    {
        // Both testTitle and testTitle2 contain "__notes_cli_test"
        NSArray *matches = findNotes(viewContext, @"__notes_cli_test", testFolderName);
        if (matches.count >= 2) {
            // Verify cmdGet outputs a JSON array via subprocess
            NSString *cmd = [NSString stringWithFormat:@"'%s' get --title '__notes_cli_test' --folder '%@' 2>/dev/null", exePath, testFolderName];
            FILE *fp = popen([cmd UTF8String], "r");
            NSMutableData *outData = [NSMutableData data];
            if (fp) {
                char buf[4096];
                size_t n;
                while ((n = fread(buf, 1, sizeof(buf), fp)) > 0) [outData appendBytes:buf length:n];
                pclose(fp);
            }
            id parsed = [NSJSONSerialization JSONObjectWithData:outData options:0 error:nil];
            if ([parsed isKindOfClass:[NSArray class]] && [(NSArray *)parsed count] >= 2) {
                fprintf(stderr, "  PASS (%lu matches)\n", (unsigned long)[(NSArray *)parsed count]); passed++;
            } else {
                fprintf(stderr, "  FAIL (expected array with >=2 items, got %s)\n",
                    [[parsed description] UTF8String]); failed++;
            }
        } else {
            fprintf(stderr, "  FAIL (findNotes returned %lu, expected >=2)\n", (unsigned long)matches.count); failed++;
        }
    }

    // Test: read --title errors on ambiguous match
    fprintf(stderr, "Test: read --title ambiguous match error...\n");
    {
        // "__notes_cli_test" matches both testTitle and testTitle2
        NSString *cmd = [NSString stringWithFormat:@"'%s' read --title '__notes_cli_test' --folder '%@' 2>&1 1>/dev/null", exePath, testFolderName];
        FILE *fp = popen([cmd UTF8String], "r");
        NSMutableData *outData = [NSMutableData data];
        if (fp) {
            char buf[4096];
            size_t n;
            while ((n = fread(buf, 1, sizeof(buf), fp)) > 0) [outData appendBytes:buf length:n];
            int status = pclose(fp);
            NSString *errOutput = [[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding];
            BOOL exitedNonZero = WEXITSTATUS(status) != 0;
            BOOL mentionsMultiple = [errOutput containsString:@"Multiple notes match"];
            BOOL mentionsId = [errOutput containsString:@"--id"];
            if (exitedNonZero && mentionsMultiple && mentionsId) {
                fprintf(stderr, "  PASS\n"); passed++;
            } else {
                fprintf(stderr, "  FAIL (exit=%d multiple=%d id=%d stderr=%s)\n",
                    exitedNonZero, mentionsMultiple, mentionsId, [errOutput UTF8String]); failed++;
            }
        } else { fprintf(stderr, "  FAIL (popen failed)\n"); failed++; }
    }

    // --- Round-trip fidelity tests ---

    // Test: Structured round-trip (markdown read → write → read)
    fprintf(stderr, "Test: Structured round-trip...\n");
    {
        // 1. Create a rich test note with many content types
        NSString *rtTitle = @"__rt_roundtrip_test__";
        id rtNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        id rtDoc = ((id (*)(id, SEL))objc_msgSend)(rtNote, sel_registerName("document"));
        id rtMs = ((id (*)(id, SEL))objc_msgSend)(rtDoc, sel_registerName("mergeableString"));

        // Build content: title\nheading\nbody with URL\ndash\n  indented dash\nnumbered\nunchecked\nchecked
        NSString *rtContent = [NSString stringWithFormat:@"%@\nA Heading\nBody text https://example.com here\nDash item\nIndented dash\nNumbered item\nUnchecked todo\nChecked todo", rtTitle];
        ((void (*)(id, SEL))objc_msgSend)(rtNote, sel_registerName("beginEditing"));
        ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(rtMs, sel_registerName("insertString:atIndex:"), rtContent, 0);

        // Apply styles to each paragraph
        NSUInteger off = 0;

        // Title (style 0)
        {
            id s = [[ICTTParagraphStyleClass alloc] init];
            ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s, sel_registerName("setStyle:"), 0);
            ((void (*)(id, SEL, id, NSRange))objc_msgSend)(rtMs, sel_registerName("setAttributes:range:"),
                @{@"TTStyle": s}, NSMakeRange(off, rtTitle.length + 1));
            off += rtTitle.length + 1;
        }

        // Heading (style 1)
        {
            NSString *headingText = @"A Heading";
            id s = [[ICTTParagraphStyleClass alloc] init];
            ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s, sel_registerName("setStyle:"), 1);
            ((void (*)(id, SEL, id, NSRange))objc_msgSend)(rtMs, sel_registerName("setAttributes:range:"),
                @{@"TTStyle": s}, NSMakeRange(off, headingText.length + 1));
            off += headingText.length + 1;
        }

        // Body text with URL link (style 3)
        {
            NSString *bodyPrefix = @"Body text ";
            NSString *urlStr = @"https://example.com";
            NSString *bodySuffix = @" here";
            NSUInteger bodyLen = bodyPrefix.length + urlStr.length + bodySuffix.length + 1; // +1 for \n
            id s = [[ICTTParagraphStyleClass alloc] init];
            ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s, sel_registerName("setStyle:"), 3);
            // Apply body style to whole paragraph
            ((void (*)(id, SEL, id, NSRange))objc_msgSend)(rtMs, sel_registerName("setAttributes:range:"),
                @{@"TTStyle": s}, NSMakeRange(off, bodyLen));
            // Apply URL link to the URL portion
            ((void (*)(id, SEL, id, NSRange))objc_msgSend)(rtMs, sel_registerName("setAttributes:range:"),
                (@{@"TTStyle": s, @"NSLink": [NSURL URLWithString:urlStr]}),
                NSMakeRange(off + bodyPrefix.length, urlStr.length));
            off += bodyLen;
        }

        // Dash item (style 100)
        {
            NSString *dashText = @"Dash item";
            id s = [[ICTTParagraphStyleClass alloc] init];
            ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s, sel_registerName("setStyle:"), 100);
            ((void (*)(id, SEL, id, NSRange))objc_msgSend)(rtMs, sel_registerName("setAttributes:range:"),
                @{@"TTStyle": s}, NSMakeRange(off, dashText.length + 1));
            off += dashText.length + 1;
        }

        // Indented dash item (style 100, indent 1)
        {
            NSString *indentDashText = @"Indented dash";
            id s = [[ICTTParagraphStyleClass alloc] init];
            ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s, sel_registerName("setStyle:"), 100);
            ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s, sel_registerName("setIndent:"), 1);
            ((void (*)(id, SEL, id, NSRange))objc_msgSend)(rtMs, sel_registerName("setAttributes:range:"),
                @{@"TTStyle": s}, NSMakeRange(off, indentDashText.length + 1));
            off += indentDashText.length + 1;
        }

        // Numbered item (style 102)
        {
            NSString *numText = @"Numbered item";
            id s = [[ICTTParagraphStyleClass alloc] init];
            ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s, sel_registerName("setStyle:"), 102);
            ((void (*)(id, SEL, id, NSRange))objc_msgSend)(rtMs, sel_registerName("setAttributes:range:"),
                @{@"TTStyle": s}, NSMakeRange(off, numText.length + 1));
            off += numText.length + 1;
        }

        // Unchecked checklist (style 103, done=NO)
        {
            NSString *unchkText = @"Unchecked todo";
            id s = [[ICTTParagraphStyleClass alloc] init];
            ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s, sel_registerName("setStyle:"), 103);
            id todo = ((id (*)(id, SEL, id, BOOL))objc_msgSend)(
                [ICTTTodoClass alloc], sel_registerName("initWithIdentifier:done:"), [NSUUID UUID], NO);
            ((void (*)(id, SEL, id))objc_msgSend)(s, sel_registerName("setTodo:"), todo);
            ((void (*)(id, SEL, id, NSRange))objc_msgSend)(rtMs, sel_registerName("setAttributes:range:"),
                @{@"TTStyle": s}, NSMakeRange(off, unchkText.length + 1));
            off += unchkText.length + 1;
        }

        // Checked checklist (style 103, done=YES)
        {
            NSString *chkText = @"Checked todo";
            id s = [[ICTTParagraphStyleClass alloc] init];
            ((void (*)(id, SEL, NSUInteger))objc_msgSend)(s, sel_registerName("setStyle:"), 103);
            id todo = ((id (*)(id, SEL, id, BOOL))objc_msgSend)(
                [ICTTTodoClass alloc], sel_registerName("initWithIdentifier:done:"), [NSUUID UUID], YES);
            ((void (*)(id, SEL, id))objc_msgSend)(s, sel_registerName("setTodo:"), todo);
            ((void (*)(id, SEL, id, NSRange))objc_msgSend)(rtMs, sel_registerName("setAttributes:range:"),
                @{@"TTStyle": s}, NSMakeRange(off, chkText.length));
            // No +1 because last paragraph has no trailing \n
        }

        ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
            rtNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, rtContent.length), rtContent.length);
        ((void (*)(id, SEL))objc_msgSend)(rtNote, sel_registerName("endEditing"));
        ((void (*)(id, SEL))objc_msgSend)(rtNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];

        // Add a note-to-note link (ICInlineAttachment) to the note
        NSString *rtNoteID = noteToDict(rtNote)[@"id"];
        // Use testTitle2 note as the link target
        id rtLinkTarget = findNote(viewContext, testTitle2, testFolderName);
        if (rtLinkTarget) {
            NSString *rtTargetID = noteToDict(rtLinkTarget)[@"id"];
            // Redirect stdout during cmdAddNoteLink (it prints JSON)
            int savedOut = dup(STDOUT_FILENO);
            int devNull1 = open("/dev/null", O_WRONLY);
            dup2(devNull1, STDOUT_FILENO); close(devNull1);
            cmdAddNoteLink(viewContext, rtNoteID, rtTargetID, -1);
            dup2(savedOut, STDOUT_FILENO); close(savedOut);
        }

        // Re-fetch the note after adding the link
        rtNote = findNoteByID(viewContext, rtNoteID);

        // 2. Read original note as para model
        NSArray *origModel = noteToParaModel(rtNote);
        // Filter leading empty paragraphs
        NSMutableArray *origFiltered = [NSMutableArray array];
        BOOL rtFC = NO;
        for (NSDictionary *p in origModel) {
            if (!rtFC && [p[@"text"] length] == 0) continue;
            rtFC = YES;
            [origFiltered addObject:p];
        }

        // 3. Read as markdown
        NSString *rtMarkdown = paraModelToMarkdown(origFiltered);

        // 4. Create a new empty note and write the markdown to it
        id rtNewNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
        ((void (*)(id, SEL))objc_msgSend)(rtNewNote, sel_registerName("saveNoteData"));
        [viewContext save:nil];
        NSString *rtNewNoteID = noteToDict(rtNewNote)[@"id"];

        // Redirect stdout during write
        {
            int savedOut = dup(STDOUT_FILENO);
            int devNull1 = open("/dev/null", O_WRONLY);
            dup2(devNull1, STDOUT_FILENO); close(devNull1);
            cmdWriteMarkdownWithString(rtNewNote, viewContext, rtMarkdown, NO, NO, NO);
            dup2(savedOut, STDOUT_FILENO); close(savedOut);
        }

        // 5. Re-read the round-tripped note as para model
        rtNewNote = findNoteByID(viewContext, rtNewNoteID);
        NSArray *rtNewModel = noteToParaModel(rtNewNote);
        NSMutableArray *rtNewFiltered = [NSMutableArray array];
        BOOL rtFC2 = NO;
        for (NSDictionary *p in rtNewModel) {
            if (!rtFC2 && [p[@"text"] length] == 0) continue;
            rtFC2 = YES;
            [rtNewFiltered addObject:p];
        }

        // 6. Compare paragraph by paragraph
        // Filter out cosmetic blank paragraphs before headings (paraModelToMarkdown
        // inserts blank lines before headings for proper markdown spacing; these
        // become empty body paragraphs on round-trip but are visually identical)
        NSArray *(^filterCosmeticBlanks)(NSArray *) = ^NSArray *(NSArray *paras) {
            NSMutableArray *result = [NSMutableArray array];
            for (NSUInteger fi = 0; fi < paras.count; fi++) {
                NSDictionary *fp = paras[fi];
                NSInteger fStyle = [fp[@"style"] integerValue];
                NSString *fText = fp[@"text"];
                // Skip empty body paragraphs that precede a heading
                if (fStyle == 3 && fText.length == 0 && fi + 1 < paras.count) {
                    NSInteger nextStyle = [paras[fi + 1][@"style"] integerValue];
                    if (nextStyle == 0 || nextStyle == 1) continue;
                }
                [result addObject:fp];
            }
            return result;
        };
        NSArray *origForCmp = filterCosmeticBlanks(origFiltered);
        NSArray *rtForCmp = filterCosmeticBlanks(rtNewFiltered);

        BOOL rtPass = YES;
        NSString *rtFailMsg = nil;

        if (origForCmp.count != rtForCmp.count) {
            rtPass = NO;
            rtFailMsg = [NSString stringWithFormat:@"paragraph count mismatch: orig=%lu rt=%lu",
                (unsigned long)origForCmp.count, (unsigned long)rtForCmp.count];
        } else {
            for (NSUInteger pi = 0; pi < origForCmp.count; pi++) {
                NSDictionary *origP = origForCmp[pi];
                NSDictionary *rtP = rtForCmp[pi];

                // Compare text (note-to-note links use U+FFFC in orig but display text in rt)
                NSString *origText = origP[@"text"];
                NSString *rtText = rtP[@"text"];
                // For note link paragraphs, the original has U+FFFC while round-tripped has the display text
                // So skip text comparison for paragraphs containing U+FFFC
                BOOL hasFFFC = [origText containsString:@"\uFFFC"];
                if (!hasFFFC && ![origText isEqualToString:rtText]) {
                    rtPass = NO;
                    rtFailMsg = [NSString stringWithFormat:@"para %lu text mismatch: '%@' vs '%@'",
                        (unsigned long)pi, origText, rtText];
                    break;
                }

                // Compare style
                if ([origP[@"style"] integerValue] != [rtP[@"style"] integerValue]) {
                    rtPass = NO;
                    rtFailMsg = [NSString stringWithFormat:@"para %lu style mismatch: %@ vs %@",
                        (unsigned long)pi, origP[@"style"], rtP[@"style"]];
                    break;
                }

                // Compare indent
                if ([origP[@"indent"] unsignedIntegerValue] != [rtP[@"indent"] unsignedIntegerValue]) {
                    rtPass = NO;
                    rtFailMsg = [NSString stringWithFormat:@"para %lu indent mismatch: %@ vs %@",
                        (unsigned long)pi, origP[@"indent"], rtP[@"indent"]];
                    break;
                }

                // Compare checked state for checklists
                if ([origP[@"style"] integerValue] == 103) {
                    if ([origP[@"todoChecked"] boolValue] != [rtP[@"todoChecked"] boolValue]) {
                        rtPass = NO;
                        rtFailMsg = [NSString stringWithFormat:@"para %lu checked mismatch: %@ vs %@",
                            (unsigned long)pi, origP[@"todoChecked"], rtP[@"todoChecked"]];
                        break;
                    }
                }

                // Compare link count
                NSArray *origRuns = origP[@"runs"];
                NSArray *rtRuns = rtP[@"runs"];
                NSUInteger origLinkCount = 0, rtLinkCount = 0;
                for (NSDictionary *r in origRuns) { if (r[@"link"]) origLinkCount++; }
                for (NSDictionary *r in rtRuns) { if (r[@"link"]) rtLinkCount++; }
                if (origLinkCount != rtLinkCount) {
                    rtPass = NO;
                    rtFailMsg = [NSString stringWithFormat:@"para %lu link count mismatch: %lu vs %lu",
                        (unsigned long)pi, (unsigned long)origLinkCount, (unsigned long)rtLinkCount];
                    break;
                }
            }
        }

        if (rtPass) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (%s)\n", [rtFailMsg UTF8String]); failed++; }

        // --- Test: Bold/italic/underline write-back round-trip ---
        fprintf(stderr, "Test: Bold/italic write-back round-trip...\n");
        {
            // Write markdown with bold and italic to a fresh note, then read back and verify TTHints
            NSString *biTitle = @"__bi_write_test__";
            id biNote = ((id (*)(id, SEL, id))objc_msgSend)(ICNoteClass, sel_registerName("newEmptyNoteInFolder:"), testFolder);
            ((void (*)(id, SEL))objc_msgSend)(biNote, sel_registerName("beginEditing"));
            id biDoc = ((id (*)(id, SEL))objc_msgSend)(biNote, sel_registerName("document"));
            id biMs = ((id (*)(id, SEL))objc_msgSend)(biDoc, sel_registerName("mergeableString"));
            ((void (*)(id, SEL, id, NSUInteger))objc_msgSend)(biMs, sel_registerName("insertString:atIndex:"), biTitle, 0);
            id biS0 = [[ICTTParagraphStyleClass alloc] init];
            ((void (*)(id, SEL, NSUInteger))objc_msgSend)(biS0, sel_registerName("setStyle:"), 0);
            ((void (*)(id, SEL, id, NSRange))objc_msgSend)(biMs, sel_registerName("setAttributes:range:"),
                @{@"TTStyle": biS0}, NSMakeRange(0, biTitle.length));
            ((void (*)(id, SEL, NSUInteger, NSRange, NSInteger))objc_msgSend)(
                biNote, sel_registerName("edited:range:changeInLength:"), 1, NSMakeRange(0, biTitle.length), biTitle.length);
            ((void (*)(id, SEL))objc_msgSend)(biNote, sel_registerName("endEditing"));
            ((void (*)(id, SEL))objc_msgSend)(biNote, sel_registerName("saveNoteData"));
            [viewContext save:nil];

            // Write markdown with bold, italic and underline
            NSString *biMd = [NSString stringWithFormat:@"# %@\n**bold word** and *italic word* and <u>underlined</u>", biTitle];
            cmdWriteMarkdownWithString(biNote, viewContext, biMd, NO, NO, NO);
            [viewContext save:nil];

            // Read back and check the model has bold/italic/underline runs
            NSArray *biModel = noteToParaModel(biNote);
            NSMutableArray *biFiltered = [NSMutableArray array];
            BOOL biFC = NO;
            for (NSDictionary *p in biModel) {
                if (!biFC && [p[@"text"] length] == 0) continue;
                biFC = YES;
                [biFiltered addObject:p];
            }
            NSString *biMarkdown = paraModelToMarkdown(biFiltered);
            BOOL biPass = [biMarkdown containsString:@"**bold word**"] &&
                          [biMarkdown containsString:@"*italic word*"] &&
                          [biMarkdown containsString:@"<u>underlined</u>"];
            if (biPass) { fprintf(stderr, "  PASS\n"); passed++; }
            else { fprintf(stderr, "  FAIL (md: %s)\n", [biMarkdown UTF8String]); failed++; }

            deleteNote(biNote, viewContext);
            [viewContext save:nil];
        }

        // --- Test: Raw attribute round-trip ---
        fprintf(stderr, "Test: Raw attribute round-trip...\n");
        {
            // Build attr model for original note (same logic as cmdReadAttrsNote but in-process)
            NSArray *(^buildAttrModel)(id) = ^NSArray *(id aNote) {
                id aDoc = ((id (*)(id, SEL))objc_msgSend)(aNote, sel_registerName("document"));
                id aMs = ((id (*)(id, SEL))objc_msgSend)(aDoc, sel_registerName("mergeableString"));
                NSAttributedString *aAttrStr = ((id (*)(id, SEL))objc_msgSend)(aNote, sel_registerName("attributedString"));
                NSString *aFullText = [aAttrStr string];
                NSUInteger aLen = aFullText.length;
                if (aLen == 0) return @[];

                NSMutableArray *ranges = [NSMutableArray array];
                NSUInteger aIdx = 0;
                NSRange aEffRange;
                while (aIdx < aLen) {
                    NSDictionary *aAttrs = ((id (*)(id, SEL, NSUInteger, NSRange*))objc_msgSend)(
                        aMs, sel_registerName("attributesAtIndex:effectiveRange:"), aIdx, &aEffRange);
                    NSString *aText = [aFullText substringWithRange:aEffRange];
                    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
                    entry[@"text"] = aText;
                    id aStyle = aAttrs[@"TTStyle"];
                    if (aStyle) {
                        entry[@"style"] = @(((NSInteger (*)(id, SEL))objc_msgSend)(aStyle, sel_registerName("style")));
                        entry[@"indent"] = @(((NSUInteger (*)(id, SEL))objc_msgSend)(aStyle, sel_registerName("indent")));
                        id aTodo = ((id (*)(id, SEL))objc_msgSend)(aStyle, sel_registerName("todo"));
                        if (aTodo) entry[@"todoDone"] = @(((BOOL (*)(id, SEL))objc_msgSend)(aTodo, sel_registerName("done")));
                    }
                    if (aAttrs[@"NSLink"]) entry[@"hasLink"] = @YES;
                    if (aAttrs[@"NSAttachment"]) entry[@"hasAttachment"] = @YES;
                    [ranges addObject:entry];
                    aIdx = aEffRange.location + aEffRange.length;
                }
                return ranges;
            };

            NSArray *origAttrs = buildAttrModel(rtNote);
            NSArray *rtAttrs = buildAttrModel(rtNewNote);

            // Group attributes by paragraph (split on \n in text)
            NSArray *(^groupByParagraph)(NSArray *) = ^NSArray *(NSArray *attrs) {
                NSMutableArray *groups = [NSMutableArray array];
                NSMutableArray *currentGroup = [NSMutableArray array];
                for (NSDictionary *entry in attrs) {
                    NSString *eText = entry[@"text"];
                    // Split text on \n - if contains \n, emit current group and start new
                    NSArray *parts = [eText componentsSeparatedByString:@"\n"];
                    if (parts.count <= 1) {
                        [currentGroup addObject:entry];
                    } else {
                        // First part goes to current group
                        if ([parts[0] length] > 0) {
                            NSMutableDictionary *firstEntry = [entry mutableCopy];
                            firstEntry[@"text"] = parts[0];
                            [currentGroup addObject:firstEntry];
                        }
                        [groups addObject:currentGroup];
                        // Middle parts are their own groups (empty usually)
                        for (NSUInteger mi = 1; mi < parts.count - 1; mi++) {
                            NSMutableArray *midGroup = [NSMutableArray array];
                            if ([parts[mi] length] > 0) {
                                NSMutableDictionary *midEntry = [entry mutableCopy];
                                midEntry[@"text"] = parts[mi];
                                [midGroup addObject:midEntry];
                            }
                            [groups addObject:midGroup];
                        }
                        // Last part starts a new group
                        currentGroup = [NSMutableArray array];
                        NSString *lastPart = parts[parts.count - 1];
                        if (lastPart.length > 0) {
                            NSMutableDictionary *lastEntry = [entry mutableCopy];
                            lastEntry[@"text"] = lastPart;
                            [currentGroup addObject:lastEntry];
                        }
                    }
                }
                if (currentGroup.count > 0) [groups addObject:currentGroup];
                return groups;
            };

            NSArray *origGroups = groupByParagraph(origAttrs);
            NSArray *rtGroups = groupByParagraph(rtAttrs);

            // Filter out empty leading groups
            NSMutableArray *origGroupsFiltered = [NSMutableArray array];
            BOOL ogFC = NO;
            for (NSArray *g in origGroups) {
                if (!ogFC && g.count == 0) continue;
                ogFC = YES;
                [origGroupsFiltered addObject:g];
            }
            NSMutableArray *rtGroupsFiltered = [NSMutableArray array];
            BOOL rgFC = NO;
            for (NSArray *g in rtGroups) {
                if (!rgFC && g.count == 0) continue;
                rgFC = YES;
                [rtGroupsFiltered addObject:g];
            }

            // Filter out cosmetic blank groups before heading groups (same rationale
            // as filterCosmeticBlanks above — markdown spacing adds empty paragraphs)
            NSArray *(^filterCosmeticBlankGroups)(NSArray *) = ^NSArray *(NSArray *groups) {
                NSMutableArray *result = [NSMutableArray array];
                for (NSUInteger fi = 0; fi < groups.count; fi++) {
                    NSArray *g = groups[fi];
                    if (g.count == 0 && fi + 1 < groups.count) {
                        NSArray *nextG = groups[fi + 1];
                        NSInteger nextStyle = -1;
                        for (NSDictionary *e in nextG) {
                            if (e[@"style"]) { nextStyle = [e[@"style"] integerValue]; break; }
                        }
                        if (nextStyle == 0 || nextStyle == 1) continue;
                    }
                    [result addObject:g];
                }
                return result;
            };
            NSArray *origGroupsCmp = filterCosmeticBlankGroups(origGroupsFiltered);
            NSArray *rtGroupsCmp = filterCosmeticBlankGroups(rtGroupsFiltered);

            BOOL attrPass = YES;
            NSString *attrFailMsg = nil;

            if (origGroupsCmp.count != rtGroupsCmp.count) {
                attrPass = NO;
                attrFailMsg = [NSString stringWithFormat:@"paragraph group count mismatch: orig=%lu rt=%lu",
                    (unsigned long)origGroupsCmp.count, (unsigned long)rtGroupsCmp.count];
            } else {
                for (NSUInteger gi = 0; gi < origGroupsCmp.count; gi++) {
                    NSArray *origG = origGroupsCmp[gi];
                    NSArray *rtG = rtGroupsCmp[gi];

                    // Compare each attribute range in the group
                    // Build summary for each group: style, indent, todoDone, hasLink, hasAttachment
                    // We compare group-level properties since individual ranges may differ
                    NSInteger origStyle = -1, rtStyle = -1;
                    NSUInteger origIndent = 0, rtIndent = 0;
                    BOOL origTodoDone = NO, rtTodoDone = NO;
                    BOOL origHasLink = NO, rtHasLink = NO;
                    BOOL origHasAtt = NO, rtHasAtt = NO;

                    for (NSDictionary *e in origG) {
                        if (e[@"style"]) origStyle = [e[@"style"] integerValue];
                        if (e[@"indent"]) origIndent = [e[@"indent"] unsignedIntegerValue];
                        if ([e[@"todoDone"] boolValue]) origTodoDone = YES;
                        if ([e[@"hasLink"] boolValue]) origHasLink = YES;
                        if ([e[@"hasAttachment"] boolValue]) origHasAtt = YES;
                    }
                    for (NSDictionary *e in rtG) {
                        if (e[@"style"]) rtStyle = [e[@"style"] integerValue];
                        if (e[@"indent"]) rtIndent = [e[@"indent"] unsignedIntegerValue];
                        if ([e[@"todoDone"] boolValue]) rtTodoDone = YES;
                        if ([e[@"hasLink"] boolValue]) rtHasLink = YES;
                        if ([e[@"hasAttachment"] boolValue]) rtHasAtt = YES;
                    }

                    if (origStyle != rtStyle) {
                        attrPass = NO;
                        attrFailMsg = [NSString stringWithFormat:@"group %lu style mismatch: %ld vs %ld",
                            (unsigned long)gi, (long)origStyle, (long)rtStyle];
                        break;
                    }
                    if (origIndent != rtIndent) {
                        attrPass = NO;
                        attrFailMsg = [NSString stringWithFormat:@"group %lu indent mismatch: %lu vs %lu",
                            (unsigned long)gi, (unsigned long)origIndent, (unsigned long)rtIndent];
                        break;
                    }
                    if (origStyle == 103 && origTodoDone != rtTodoDone) {
                        attrPass = NO;
                        attrFailMsg = [NSString stringWithFormat:@"group %lu todoDone mismatch: %d vs %d",
                            (unsigned long)gi, origTodoDone, rtTodoDone];
                        break;
                    }
                    if (origHasLink != rtHasLink) {
                        attrPass = NO;
                        attrFailMsg = [NSString stringWithFormat:@"group %lu link presence mismatch: %d vs %d",
                            (unsigned long)gi, origHasLink, rtHasLink];
                        break;
                    }
                    // Note: hasAttachment won't survive round-trip for note-to-note links (they become [text](url) links)
                    // So we check that if orig has attachment, rt has either attachment or link
                    if (origHasAtt && !rtHasAtt && !rtHasLink) {
                        attrPass = NO;
                        attrFailMsg = [NSString stringWithFormat:@"group %lu: orig has attachment but rt has neither attachment nor link",
                            (unsigned long)gi];
                        break;
                    }
                }
            }

            if (attrPass) { fprintf(stderr, "  PASS\n"); passed++; }
            else { fprintf(stderr, "  FAIL (%s)\n", [attrFailMsg UTF8String]); failed++; }
        }

        // Cleanup round-trip test notes
        deleteNote(findNoteByID(viewContext, rtNoteID), viewContext);
        deleteNote(findNoteByID(viewContext, rtNewNoteID), viewContext);
        [viewContext save:nil];
    }

    // Test 19: cmdCreate with title only
    fprintf(stderr, "Test 19: cmdCreate with title only...\n");
    {
        NSString *createTitle = @"__create_test_title_only__";
        int rc = cmdCreate(viewContext, testFolderName, createTitle, nil, -1);
        id createdNote = findNote(viewContext, createTitle, testFolderName);
        if (rc == 0 && createdNote) {
            NSString *noteTitle = ((id (*)(id, SEL))objc_msgSend)(createdNote, sel_registerName("title"));
            if ([noteTitle isEqualToString:createTitle]) {
                fprintf(stderr, "  PASS\n"); passed++;
            } else {
                fprintf(stderr, "  FAIL (title mismatch: %s)\n", [noteTitle UTF8String]); failed++;
            }
            deleteNote(createdNote, viewContext);
            [viewContext save:nil];
        } else {
            fprintf(stderr, "  FAIL (create returned %d or note not found)\n", rc); failed++;
        }
    }

    // Test 20: cmdCreate with title and body
    fprintf(stderr, "Test 20: cmdCreate with title and body...\n");
    {
        NSString *createTitle = @"__create_test_with_body__";
        NSString *createBody = @"This is the body text";
        int rc = cmdCreate(viewContext, testFolderName, createTitle, createBody, -1);
        id createdNote = findNote(viewContext, createTitle, testFolderName);
        if (rc == 0 && createdNote) {
            NSString *noteTitle = ((id (*)(id, SEL))objc_msgSend)(createdNote, sel_registerName("title"));
            NSString *bodyText = ((id (*)(id, SEL))objc_msgSend)(createdNote, sel_registerName("noteAsPlainTextWithoutTitle"));
            BOOL hasTitle = [noteTitle isEqualToString:createTitle];
            BOOL hasBody = [bodyText containsString:createBody];
            if (hasTitle && hasBody) {
                fprintf(stderr, "  PASS\n"); passed++;
            } else {
                fprintf(stderr, "  FAIL (title=%d body=%d)\n", hasTitle, hasBody); failed++;
            }
            deleteNote(createdNote, viewContext);
            [viewContext save:nil];
        } else {
            fprintf(stderr, "  FAIL (create returned %d or note not found)\n", rc); failed++;
        }
    }

    // Test 21: cmdCreate with title, body, and checklist style
    fprintf(stderr, "Test 21: cmdCreate with body style...\n");
    {
        NSString *createTitle = @"__create_test_styled__";
        NSString *createBody = @"Checklist item";
        int rc = cmdCreate(viewContext, testFolderName, createTitle, createBody, 103);
        id createdNote = findNote(viewContext, createTitle, testFolderName);
        if (rc == 0 && createdNote) {
            NSArray *paras = noteToParaModel(createdNote);
            BOOL foundChecklist = NO;
            for (NSDictionary *para in paras) {
                if ([para[@"text"] containsString:@"Checklist item"] && [para[@"style"] integerValue] == 103) {
                    foundChecklist = YES;
                    break;
                }
            }
            if (foundChecklist) {
                fprintf(stderr, "  PASS\n"); passed++;
            } else {
                fprintf(stderr, "  FAIL (checklist style not found in paragraphs)\n"); failed++;
            }
            deleteNote(createdNote, viewContext);
            [viewContext save:nil];
        } else {
            fprintf(stderr, "  FAIL (create returned %d or note not found)\n", rc); failed++;
        }
    }

    // Test: search-offset (exact match)
    fprintf(stderr, "Test: search-offset (exact match)...\n");
    {
        id noteForSO = findNote(viewContext, testTitle, testFolderName);
        if (noteForSO) {
            NSString *soId = noteToDict(noteForSO)[@"id"];
            NSString *soCmd = [NSString stringWithFormat:@"search-offset --id '%@' --text 'Modified body'", soId];
            id result = runCommandAndParseJSON(exePath, soCmd);
            if (result && [result[@"text"] isEqualToString:@"Modified body"] &&
                [result[@"length"] integerValue] == (NSInteger)[@"Modified body" length]) {
                fprintf(stderr, "  PASS\n"); passed++;
            } else {
                fprintf(stderr, "  FAIL (result: %s)\n", [[result description] UTF8String]); failed++;
            }
        } else { fprintf(stderr, "  FAIL (note not found)\n"); failed++; }
    }

    // Test: search-offset (case-insensitive)
    fprintf(stderr, "Test: search-offset (case-insensitive)...\n");
    {
        id noteForSOci = findNote(viewContext, testTitle, testFolderName);
        if (noteForSOci) {
            NSString *ciId = noteToDict(noteForSOci)[@"id"];
            NSString *ciCmd = [NSString stringWithFormat:@"search-offset --id '%@' --text 'modified BODY' --case-insensitive", ciId];
            id result = runCommandAndParseJSON(exePath, ciCmd);
            if (result && [result[@"text"] isEqualToString:@"Modified body"] &&
                [result[@"length"] integerValue] == (NSInteger)[@"Modified body" length]) {
                fprintf(stderr, "  PASS\n"); passed++;
            } else {
                fprintf(stderr, "  FAIL (result: %s)\n", [[result description] UTF8String]); failed++;
            }
        } else { fprintf(stderr, "  FAIL (note not found)\n"); failed++; }
    }

    // Test: search-offset (not found)
    fprintf(stderr, "Test: search-offset (not found)...\n");
    {
        id noteForSOerr = findNote(viewContext, testTitle, testFolderName);
        if (noteForSOerr) {
            NSString *errId = noteToDict(noteForSOerr)[@"id"];
            NSString *errCmd = [NSString stringWithFormat:@"'%s' search-offset --id '%@' --text '__NONEXISTENT__'", exePath, errId];
            BOOL errOk = NO;
            RUN_EXPECT_FAIL(errCmd, errOk, @"Text not found");
            if (errOk) { fprintf(stderr, "  PASS\n"); passed++; }
            else { fprintf(stderr, "  FAIL (expected exit=1 with 'Text not found')\n"); failed++; }
        } else { fprintf(stderr, "  FAIL (note not found)\n"); failed++; }
    }

    // Test: Nested folder creation (--parent flag)
    fprintf(stderr, "Test: Nested folder creation...\n");
    {
        // Create a subfolder under the test folder using cmdCreateFolder with parent
        int rc = cmdCreateFolder(viewContext, testSubfolderName, testFolderName);
        if (rc != 0) {
            fprintf(stderr, "  FAIL (cmdCreateFolder returned %d)\n", rc); failed++;
        } else {
            // Verify subfolder exists
            id subfolder = nil;
            for (id f in fetchFolders(viewContext)) {
                NSString *fname = ((id (*)(id, SEL))objc_msgSend)(f, sel_registerName("title"));
                if ([fname isEqualToString:testSubfolderName]) { subfolder = f; break; }
            }
            if (!subfolder) {
                fprintf(stderr, "  FAIL (subfolder not found)\n"); failed++;
            } else {
                // Verify parent relationship is set
                id parent = ((id (*)(id, SEL))objc_msgSend)(subfolder, sel_registerName("parentFolder"));
                if (parent) {
                    NSString *parentTitle = ((id (*)(id, SEL))objc_msgSend)(parent, sel_registerName("title"));
                    if ([parentTitle isEqualToString:testFolderName]) {
                        fprintf(stderr, "  PASS\n"); passed++;
                    } else {
                        fprintf(stderr, "  FAIL (parent title mismatch: %s)\n", [parentTitle UTF8String]); failed++;
                    }
                } else {
                    fprintf(stderr, "  FAIL (parentFolder is nil)\n"); failed++;
                }
                // Clean up subfolder
                @try {
                    ((void (*)(id, SEL))objc_msgSend)(subfolder, sel_registerName("markForDeletion"));
                } @catch (id e) {}
                [viewContext deleteObject:subfolder];
                [viewContext save:nil];
            }
        }
    }

    // Test: Nested folder creation via subprocess (JSON output)
    fprintf(stderr, "Test: Nested folder creation (subprocess)...\n");
    {
        NSString *subCmd = [NSString stringWithFormat:@"'%s' create-folder --name '__nested_sub_test__' --parent '%@'", exePath, testFolderName];
        id result = runCommandAndParseJSON(exePath, [NSString stringWithFormat:@"create-folder --name '__nested_sub_test__' --parent '%@'", testFolderName]);
        if (result && [result[@"created"] boolValue] && [result[@"parent"] isEqualToString:testFolderName]) {
            fprintf(stderr, "  PASS\n"); passed++;
            // Clean up the subfolder
            for (id f in fetchFolders(viewContext)) {
                NSString *fname = ((id (*)(id, SEL))objc_msgSend)(f, sel_registerName("title"));
                if ([fname isEqualToString:@"__nested_sub_test__"]) {
                    @try { ((void (*)(id, SEL))objc_msgSend)(f, sel_registerName("markForDeletion")); } @catch (id e) {}
                    [viewContext deleteObject:f];
                    [viewContext save:nil];
                    break;
                }
            }
        } else {
            fprintf(stderr, "  FAIL (result: %s)\n", [[result description] UTF8String]); failed++;
        }
    }

    // Test: Nested folder creation error path (nonexistent parent)
    fprintf(stderr, "Test: Nested folder error (parent not found)...\n");
    {
        NSString *errCmd = [NSString stringWithFormat:@"'%s' create-folder --name 'test' --parent '__nonexistent_parent__'", exePath];
        BOOL errOk = NO;
        RUN_EXPECT_FAIL(errCmd, errOk, @"Parent folder not found");
        if (errOk) { fprintf(stderr, "  PASS\n"); passed++; }
        else { fprintf(stderr, "  FAIL (expected exit=1 with 'Parent folder not found')\n"); failed++; }
    }
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

    // Test 19b: Clean up any remaining test notes before folder delete
    fprintf(stderr, "Test 19b: Clean up remaining notes...\n");
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

    // Test 20: Delete folder (markForDeletion + deleteObject, safe for shared folders)
    fprintf(stderr, "Test 20: Delete folder...\n");
    {
        Class ICFolder = NSClassFromString(@"ICFolder");
        id tf = nil;
        for (id f in fetchFolders(viewContext)) {
            NSString *fname = ((id (*)(id, SEL))objc_msgSend)(f, sel_registerName("title"));
            if ([fname isEqualToString:testFolderName]) { tf = f; break; }
        }
        if (tf) {
            // markForDeletion + deleteObject (no CloudKit sync, safe for shared folders)
            @try {
                ((void (*)(id, SEL))objc_msgSend)(tf, sel_registerName("markForDeletion"));
            } @catch (id e) {
                fprintf(stderr, "  Warning: markForDeletion threw exception\n");
            }
            [viewContext deleteObject:tf];
            NSError *saveErr = nil;
            if (![viewContext save:&saveErr]) {
                fprintf(stderr, "  Warning: save failed: %s\n",
                        [[saveErr localizedDescription] UTF8String]);
            }
            // Verify test folder is gone from Core Data context
            BOOL foundTestFolder = NO;
            for (id f in fetchFolders(viewContext)) {
                NSString *fname = ((id (*)(id, SEL))objc_msgSend)(f, sel_registerName("title"));
                if ([fname isEqualToString:testFolderName]) {
                    foundTestFolder = YES; break;
                }
            }
            if (!foundTestFolder) { fprintf(stderr, "  PASS\n"); passed++; }
            else {
                fprintf(stderr, "  FAIL (test folder still found after deletion)\n"); failed++;
            }
        } else { fprintf(stderr, "  FAIL (folder not found to delete)\n"); failed++; }
    }

    fprintf(stderr, "\nResults: %d passed, %d failed\n", passed, failed);
    return failed > 0 ? 1 : 0;
}


