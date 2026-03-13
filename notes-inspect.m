#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreData/CoreData.h>

static void dumpProperties(Class cls) {
    unsigned int count = 0;
    objc_property_t *props = class_copyPropertyList(cls, &count);
    fprintf(stderr, "\n=== %s (%u properties) ===\n", class_getName(cls), count);
    for (unsigned int i = 0; i < count; i++) {
        const char *name = property_getName(props[i]);
        const char *attrs = property_getAttributes(props[i]);
        fprintf(stderr, "  %s  (%s)\n", name, attrs);
    }
    free(props);
}

static void dumpMethods(Class cls) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    fprintf(stderr, "\n=== %s (%u methods) ===\n", class_getName(cls), count);
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        fprintf(stderr, "  %s\n", sel_getName(sel));
    }
    free(methods);
}

int main() {
    @autoreleasepool {
        [[NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/NotesShared.framework"] load];

        // Key classes to inspect
        NSArray *classNames = @[
            @"ICNote", @"ICFolder", @"ICNoteContext",
            @"ICAccount", @"ICAttachment",
            @"ICTTTodo", @"ICTTParagraphStyle",
            @"ICTTMergeableAttributedString", @"ICTTMergeableString",
            @"ICHashtag", @"ICHashtagController",
            @"ICTable"
        ];

        for (NSString *name in classNames) {
            Class cls = NSClassFromString(name);
            if (cls) {
                dumpProperties(cls);
                dumpMethods(cls);
            } else {
                fprintf(stderr, "\n=== %s NOT FOUND ===\n", [name UTF8String]);
            }
        }

        // Live test: init context and fetch notes
        fprintf(stderr, "\n\n--- LIVE TEST ---\n");
        Class ICNoteContext = NSClassFromString(@"ICNoteContext");
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(ICNoteContext, sel_registerName("startSharedContextWithOptions:"), 0);
        id context = ((id (*)(id, SEL))objc_msgSend)(ICNoteContext, sel_registerName("sharedContext"));
        id container = ((id (*)(id, SEL))objc_msgSend)(context, sel_registerName("persistentContainer"));
        id viewContext = ((id (*)(id, SEL))objc_msgSend)(container, sel_registerName("viewContext"));

        // Fetch folders
        NSFetchRequest *folderReq = [NSFetchRequest fetchRequestWithEntityName:@"ICFolder"];
        NSError *error = nil;
        NSArray *folders = [viewContext executeFetchRequest:folderReq error:&error];
        fprintf(stderr, "Folders: %lu\n", (unsigned long)folders.count);
        for (id folder in folders) {
            NSString *title = ((id (*)(id, SEL))objc_msgSend)(folder, sel_registerName("title"));
            if (title && title.length > 0) {
                fprintf(stderr, "  Folder: %s (class: %s)\n", [title UTF8String], class_getName([folder class]));
            }
        }

        // Fetch a few notes
        NSFetchRequest *noteReq = [NSFetchRequest fetchRequestWithEntityName:@"ICNote"];
        noteReq.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"modificationDate" ascending:NO]];
        noteReq.fetchLimit = 3;
        NSArray *notes = [viewContext executeFetchRequest:noteReq error:&error];

        for (id note in notes) {
            NSString *title = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName("title"));
            fprintf(stderr, "\nNote: %s\n", [title UTF8String]);
            fprintf(stderr, "  Class: %s\n", class_getName([note class]));

            // Try common properties
            NSArray *tryProps = @[@"title", @"snippet", @"creationDate", @"modificationDate",
                @"hasChecklist", @"isPinned", @"isLocked", @"folder"];
            for (NSString *prop in tryProps) {
                @try {
                    id val = ((id (*)(id, SEL))objc_msgSend)(note, sel_registerName([prop UTF8String]));
                    fprintf(stderr, "  %s = %s\n", [prop UTF8String],
                        val ? [[val description] UTF8String] : "(nil)");
                } @catch (NSException *e) {
                    fprintf(stderr, "  %s = [EXCEPTION]\n", [prop UTF8String]);
                }
            }
        }
    }
    return 0;
}
