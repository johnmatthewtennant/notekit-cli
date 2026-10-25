// Display preference contract without accessing a Notes store.
#define main notekit_main
#include "../notekit.m"
#undef main

@interface ImageViewFixture : NSObject {
@public
    short size;
    NSUInteger calls;
}
- (void)setPreferredViewSize:(short)value;
@end
@implementation ImageViewFixture
- (void)setPreferredViewSize:(short)value { size = value; calls++; }
@end

int main(void) {
    @autoreleasepool {
        ImageViewFixture *attachment = [ImageViewFixture new];
        attachment->size = 42;
        if (!setImagePreferredViewSize(attachment, nil) || attachment->calls || attachment->size != 42) return 1;
        if (!setImagePreferredViewSize(attachment, @"small") || attachment->size != 1 || attachment->calls != 1) return 2;
        if (!setImagePreferredViewSize(attachment, @"large") || attachment->size != 0 || attachment->calls != 2) return 3;
        NSObject *unsupported = [NSObject new];
        if (!setImagePreferredViewSize(unsupported, nil) || setImagePreferredViewSize(unsupported, @"small")) return 4;
        puts("PASS: native short setter, Small/Large, untouched default, unavailable selector");
    }
}
