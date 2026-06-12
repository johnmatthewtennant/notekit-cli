// Version string and background Homebrew upgrades.

// The version is injected at build time via -DNOTEKIT_VERSION (passed by the
// Homebrew formula as VERSION=#{version}). The "dev" fallback applies only to
// ad-hoc local builds, keeping the embedded version in lockstep with the
// release tag instead of a hand-edited constant.
#ifndef NOTEKIT_VERSION
#define NOTEKIT_VERSION "dev"
#endif
static NSString * const NotekitCurrentVersion = @NOTEKIT_VERSION;
static NSString * const NotekitFormulaTap = @"johnmatthewtennant/tap/notekit-cli";
static NSString * const NotekitFormulaName = @"notekit-cli";
static NSString * const NotekitCommandName = @"notekit";

static BOOL shouldAttemptUpgrade(NSDate *now, NSDate *lastAttempt) {
    if (!lastAttempt) return YES;
    return [now timeIntervalSinceDate:lastAttempt] >= 24 * 3600;
}

static BOOL isBrewManagedInstall(void) {
    NSString *exePath = [[NSBundle mainBundle] executablePath];
    if (!exePath) return NO;
    NSString *resolved = [exePath stringByResolvingSymlinksInPath];
    NSString *cellarPath = [NSString stringWithFormat:@"/Cellar/%@/", NotekitFormulaName];
    return [resolved containsString:cellarPath];
}

static NSString *shellSingleQuote(NSString *value) {
    return [NSString stringWithFormat:@"'%@'",
        [value stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

static void attemptBackgroundUpgrade(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSURL *tmpDir = [[fm temporaryDirectory] URLByAppendingPathComponent:NotekitCommandName isDirectory:YES];
    [fm createDirectoryAtURL:tmpDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *logFile = [tmpDir URLByAppendingPathComponent:@"upgrade.log"];

    NSDictionary *attrs = [fm attributesOfItemAtPath:[logFile path] error:nil];
    NSDate *mtime = attrs[NSFileModificationDate];
    if (!shouldAttemptUpgrade([NSDate date], mtime)) return;
    if (!isBrewManagedInstall()) return;

    [fm createFileAtPath:[logFile path] contents:nil attributes:nil];

    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/bin/sh"];
    NSString *script = [NSString stringWithFormat:
        @"HOMEBREW_NO_AUTO_UPDATE=1 brew upgrade %@ >%@ 2>&1 &",
        NotekitFormulaTap, shellSingleQuote([logFile path])];
    [task setArguments:@[@"-c", script]];
    [task setStandardInput:[NSFileHandle fileHandleWithNullDevice]];
    [task setStandardOutput:[NSFileHandle fileHandleWithNullDevice]];
    [task setStandardError:[NSFileHandle fileHandleWithNullDevice]];
    @try {
        [task launch];
    } @catch (__unused NSException *exception) {
    }
}

static int cmdVersion(BOOL skipCheck) {
    // Background auto-upgrade (attemptBackgroundUpgrade) keeps brew installs
    // current, so there is no separate outdated-version network check.
    (void)skipCheck;
    printf("notekit %s\n", [NotekitCurrentVersion UTF8String]);
    return 0;
}
