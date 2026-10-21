// Read-only integration-test observer. Never expose note contents outside test runs.
#define main notekit_main
#include "../notekit.m"
#undef main
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 2) return 2;
        loadFramework();
        id context = getViewContext();
        id note = findNoteByID(context, [NSString stringWithUTF8String:argv[1]]);
        if (!note) return 3;
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        result[@"pinned"] = [note valueForKey:@"isPinned"];
        result[@"modified"] = dateToISO([note valueForKey:@"modificationDate"]);
        result[@"text"] = [((NSAttributedString *)[note valueForKey:@"attributedString"]) string];
        id state = [note valueForKey:@"cloudState"];
        result[@"localVersion"] = [state valueForKey:@"currentLocalVersion"] ?: @0;
        result[@"syncedVersion"] = [state valueForKey:@"latestVersionSyncedToCloud"] ?: @0;
        result[@"inCloud"] = [state valueForKey:@"inCloud"] ?: @NO;
        NSMutableArray *attachments = [NSMutableArray array];
        for (id attachment in [note valueForKey:@"visibleAttachments"]) {
            NSMutableDictionary *entry = [NSMutableDictionary dictionary];
            entry[@"id"] = [attachment valueForKey:@"identifier"];
            entry[@"uti"] = [attachment valueForKey:@"typeUTI"] ?: @"";
            NSRange range = ((NSRange (*)(id, SEL, id))objc_msgSend)(note, sel_registerName("rangeForAttachment:"), attachment);
            entry[@"position"] = @(range.location);
            entry[@"length"] = @(range.length);
            id media = [attachment valueForKey:@"media"];
            NSURL *url = [media valueForKey:@"mediaURL"];
            NSData *data = url ? [NSData dataWithContentsOfURL:url] : nil;
            entry[@"data"] = data ? [data base64EncodedStringWithOptions:0] : @"";
            NSMutableArray *cloud = [NSMutableArray array];
            for (id object in @[attachment, media ?: attachment]) {
                id cs = [object valueForKey:@"cloudState"];
                [cloud addObject:@{@"inCloud": [cs valueForKey:@"inCloud"] ?: @NO,
                    @"localVersion": [cs valueForKey:@"currentLocalVersion"] ?: @0,
                    @"syncedVersion": [cs valueForKey:@"latestVersionSyncedToCloud"] ?: @0}];
            }
            entry[@"cloud"] = cloud;
            [attachments addObject:entry];
        }
        result[@"attachments"] = attachments;
        printJSON(result);
    }
}
