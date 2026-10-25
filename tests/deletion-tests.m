// Deterministic issue #63 contract. No personal Notes store or Apple events.
// This same test runs against v0.5.88 to demonstrate the hard-delete defect.
#define main notekit_main
#include "../notekit.m"
#undef main

@interface DeletionTestNote : NSManagedObject
- (void)markForDeletion;
@end
@implementation DeletionTestNote
- (void)markForDeletion { [self setValue:@YES forKey:@"markedForDeletion"]; }
@end

static NSManagedObjectContext *testContext;
static NSManagedObject *testNote;
static NSManagedObject *testTrash;
static BOOL appCalled, appArgumentsValid;

// Simulate only the Notes.app boundary. Core Data persistence and the production
// cmdDelete implementation are real. Reject a wrong/localized/default-account
// destination rather than making a wrong command appear to succeed.
static BOOL fakeLaunch(NSTask *task, SEL selector, NSError **error) {
    appCalled = YES;
    NSArray *args = task.arguments;
    appArgumentsValid = args.count >= 5 &&
        [args[args.count - 2] isEqual:testNote.objectID.URIRepresentation.absoluteString] &&
        [args.lastObject isEqual:testTrash.objectID.URIRepresentation.absoluteString];
    if (!appArgumentsValid) {
        if (error) *error = [NSError errorWithDomain:@"test" code:1 userInfo:nil];
        return NO;
    }
    [testNote setValue:testTrash forKey:@"folder"];
    return [testContext save:error];
}
static BOOL fakeRunning(id task, SEL selector) { return NO; }
static int fakeTerminationStatus(id task, SEL selector) { return 0; }

static NSAttributeDescription *attribute(NSString *name, NSAttributeType type) {
    NSAttributeDescription *a = [[NSAttributeDescription alloc] init];
    a.name = name; a.attributeType = type; a.optional = YES;
    return a;
}
static NSRelationshipDescription *relationship(NSString *name, NSEntityDescription *destination) {
    NSRelationshipDescription *r = [[NSRelationshipDescription alloc] init];
    r.name = name; r.destinationEntity = destination; r.minCount = 0; r.maxCount = 1; r.optional = YES;
    return r;
}
static NSManagedObject *folder(NSString *name, int type, NSManagedObject *account) {
    NSManagedObject *f = [NSEntityDescription insertNewObjectForEntityForName:@"ICFolder" inManagedObjectContext:testContext];
    [f setValuesForKeysWithDictionary:@{@"title": name, @"folderType": @(type), @"markedForDeletion": @NO, @"account": account}];
    return f;
}
int main(void) {
    @autoreleasepool {
        NSEntityDescription *account = [[NSEntityDescription alloc] init];
        account.name = @"ICAccount"; account.managedObjectClassName = @"NSManagedObject";
        NSEntityDescription *folderEntity = [[NSEntityDescription alloc] init];
        folderEntity.name = @"ICFolder"; folderEntity.managedObjectClassName = @"NSManagedObject";
        folderEntity.properties = @[attribute(@"title", NSStringAttributeType), attribute(@"folderType", NSInteger16AttributeType),
            attribute(@"markedForDeletion", NSBooleanAttributeType), relationship(@"account", account)];
        NSEntityDescription *noteEntity = [[NSEntityDescription alloc] init];
        noteEntity.name = @"ICNote"; noteEntity.managedObjectClassName = @"DeletionTestNote";
        noteEntity.properties = @[attribute(@"identifier", NSStringAttributeType), attribute(@"body", NSStringAttributeType),
            attribute(@"markedForDeletion", NSBooleanAttributeType), relationship(@"folder", folderEntity)];
        NSManagedObjectModel *model = [[NSManagedObjectModel alloc] init];
        model.entities = @[account, folderEntity, noteEntity];
        NSPersistentStoreCoordinator *coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
        NSError *error = nil;
        if (![coordinator addPersistentStoreWithType:NSInMemoryStoreType configuration:nil URL:nil options:nil error:&error]) {
            fprintf(stderr, "Store failed: %s\n", error.description.UTF8String); return 2;
        }
        testContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
        testContext.persistentStoreCoordinator = coordinator;
        NSManagedObject *accountA = [NSEntityDescription insertNewObjectForEntityForName:@"ICAccount" inManagedObjectContext:testContext];
        NSManagedObject *accountB = [NSEntityDescription insertNewObjectForEntityForName:@"ICAccount" inManagedObjectContext:testContext];
        NSManagedObject *source = folder(@"Notes", 0, accountA);
        testTrash = folder(@"Zuletzt gelöscht", 1, accountA);
        folder(@"Recently Deleted", 1, accountB); // Wrong account, tempting English title.
        folder(@"Recently Deleted", 0, accountA); // Right account, wrong folder type.
        testNote = [NSEntityDescription insertNewObjectForEntityForName:@"ICNote" inManagedObjectContext:testContext];
        [testNote setValuesForKeysWithDictionary:@{@"identifier": @"fixture", @"body": @"preserve me", @"markedForDeletion": @NO, @"folder": source}];
        if (![testContext save:&error]) { fprintf(stderr, "%s\n", error.description.UTF8String); return 2; }
        ICNoteClass = [DeletionTestNote class];
        Class taskClass = [[[NSTask alloc] init] class];
        Method launch = class_getInstanceMethod(taskClass, @selector(launchAndReturnError:));
        Method running = class_getInstanceMethod(taskClass, @selector(isRunning));
        Method termination = class_getInstanceMethod(taskClass, @selector(terminationStatus));
        IMP oldLaunch = method_setImplementation(launch, (IMP)fakeLaunch);
        IMP oldRunning = method_setImplementation(running, (IMP)fakeRunning);
        IMP oldTermination = method_setImplementation(termination, (IMP)fakeTerminationStatus);
        int rc = cmdDelete(testContext, @"fixture");
        method_setImplementation(launch, oldLaunch);
        method_setImplementation(running, oldRunning);
        method_setImplementation(termination, oldTermination);
        NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"ICNote"];
        NSArray *retained = [testContext executeFetchRequest:request error:&error];
        if (retained.count != 1) {
            fprintf(stderr, "FAIL: delete hard-deleted the row instead of retaining a recoverable note\n"); return 1;
        }
        NSManagedObject *n = retained.firstObject;
        if (rc || !appCalled || !appArgumentsValid ||
            ![[n valueForKey:@"folder"] isEqual:testTrash] ||
            ![[n valueForKey:@"body"] isEqual:@"preserve me"]) {
            fprintf(stderr, "FAIL: delete must move unchanged content to its own account's localized trash through Notes.app\n"); return 1;
        }
        if (findNoteByID(testContext, @"fixture")) {
            fprintf(stderr, "FAIL: normal lookup still exposes a deleted note\n"); return 1;
        }
        fprintf(stderr, "PASS: recoverable deletion, account/type selection, native handoff, content and visibility\n");
        return 0;
    }
}
