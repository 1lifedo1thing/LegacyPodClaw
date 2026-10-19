/*
 * LegacyPodClaw Daemon (clawpodd)
 * Persistent system service running as root via launchd.
 *
 * Responsibilities:
 * - Hosts CPDistributedMessagingCenter IPC server
 * - Runs the gateway server (HTTP + WebSocket)
 * - Monitors syslog for crashes/errors
 * - Manages background tasks
 * - Provides system-level services to the tweak and app
 *
 * Installed to: /usr/bin/clawpodd
 * LaunchDaemon: /Library/LaunchDaemons/pro.matthesketh.legacypodclaw.daemon.plist
 */

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#import <notify.h>
#import <signal.h>
#import <sys/sysctl.h>
#import <sys/fcntl.h>
#import <sys/resource.h>
#import <sys/wait.h>
#import <sys/types.h>
#import <unistd.h>
#import <errno.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - CPDistributedMessagingCenter (AppSupport.framework)

/* Load CPDistributedMessagingCenter dynamically from AppSupport */
@interface CPDistributedMessagingCenter : NSObject
+ (instancetype)centerNamed:(NSString *)name;
- (void)runServerOnCurrentThread;
- (void)stopServer;
- (void)registerForMessageName:(NSString *)name target:(id)target selector:(SEL)selector;
- (BOOL)sendMessageName:(NSString *)name userInfo:(NSDictionary *)info;
- (NSDictionary *)sendMessageAndReceiveReplyName:(NSString *)name userInfo:(NSDictionary *)info;
@end

#pragma mark - IPC Security

/* SECURITY FIX: Shared token authentication to prevent arbitrary process command execution.
 * The LegacyPodClaw app generates a random token on first launch and stores it in
 * /var/mobile/Library/Preferences/pro.matthesketh.legacypodclaw.plist.
 * The daemon verifies this token on sensitive operations (execute, sandboxRead, sysctl).
 * Non-sensitive operations (ping, battery, status) remain open for health checks.
 */
#define PREFS_PATH @"/var/mobile/Library/Preferences/pro.matthesketh.legacypodclaw.plist"

static NSString *_daemonToken = nil;

static BOOL _verifyCallerToken(NSDictionary *userInfo) {
    /* Lazy load token from preferences */
    if (!_daemonToken) {
        NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:PREFS_PATH];
        _daemonToken = [[prefs objectForKey:@"daemonAuthToken"] retain];
    }
    /* If no token configured, allow (backwards compatibility for fresh installs) */
    if (!_daemonToken || [_daemonToken length] == 0) return YES;
    /* Verify provided token matches */
    NSString *provided = [userInfo objectForKey:@"authToken"];
    return [provided isEqualToString:_daemonToken];
}

#pragma mark - IOKit Battery

static NSDictionary *_getBatteryInfo(void) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];

    CFTypeRef blob = IOPSCopyPowerSourcesInfo();
    if (!blob) return info;
    CFArrayRef sources = IOPSCopyPowerSourcesList(blob);
    if (!sources) { CFRelease(blob); return info; }

    for (CFIndex i = 0; i < CFArrayGetCount(sources); i++) {
        CFDictionaryRef src = IOPSGetPowerSourceDescription(blob, CFArrayGetValueAtIndex(sources, i));
        if (!src) continue;

        CFNumberRef curCap = CFDictionaryGetValue(src, CFSTR(kIOPSCurrentCapacityKey));
        CFNumberRef maxCap = CFDictionaryGetValue(src, CFSTR(kIOPSMaxCapacityKey));
        CFStringRef state = CFDictionaryGetValue(src, CFSTR(kIOPSPowerSourceStateKey));
        CFBooleanRef charging = CFDictionaryGetValue(src, CFSTR(kIOPSIsChargingKey));

        int cur = 0, max = 0;
        if (curCap) CFNumberGetValue(curCap, kCFNumberIntType, &cur);
        if (maxCap) CFNumberGetValue(maxCap, kCFNumberIntType, &max);

        [info setObject:@(max > 0 ? (cur * 100 / max) : 0) forKey:@"percent"];
        [info setObject:@(cur) forKey:@"currentCapacity"];
        [info setObject:@(max) forKey:@"maxCapacity"];
        [info setObject:(charging == kCFBooleanTrue ? @YES : @NO) forKey:@"charging"];
        if (state) [info setObject:(__bridge NSString *)state forKey:@"powerSource"];
    }

    CFRelease(sources);
    CFRelease(blob);
    return info;
}

#pragma mark - Syslog Monitor

static NSMutableArray *_recentCrashes = nil;
static NSDate *_lastSyslogCheck = nil;

static void _checkSyslogForCrashes(void) {
    /* Read recent crash reports */
    NSString *crashDir = @"/var/mobile/Library/Logs/CrashReporter/";
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:crashDir error:nil];

    NSDate *cutoff = _lastSyslogCheck ?: [NSDate dateWithTimeIntervalSinceNow:-300]; /* Last 5 min */
    [_lastSyslogCheck release];
    _lastSyslogCheck = [[NSDate date] retain];

    for (NSString *file in files) {
        if (![file hasSuffix:@".plist"]) continue;
        NSString *path = [crashDir stringByAppendingPathComponent:file];
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
        NSDate *modified = [attrs objectForKey:NSFileModificationDate];
        if (modified && [modified compare:cutoff] == NSOrderedDescending) {
            [_recentCrashes addObject:@{
                @"file": file,
                @"date": [modified description],
                @"path": path
            }];
            /* Keep only last 20 */
            while ([_recentCrashes count] > 20) [_recentCrashes removeObjectAtIndex:0];
        }
    }
}

#pragma mark - Process Info

static NSArray *_getProcessList(void) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t size;
    sysctl(mib, 4, NULL, &size, NULL, 0);
    struct kinfo_proc *procs = malloc(size);
    sysctl(mib, 4, procs, &size, NULL, 0);
    int count = (int)(size / sizeof(struct kinfo_proc));

    NSMutableArray *list = [NSMutableArray arrayWithCapacity:count];
    for (int i = 0; i < count; i++) {
        [list addObject:@{
            @"pid": @(procs[i].kp_proc.p_pid),
            @"name": [NSString stringWithUTF8String:procs[i].kp_proc.p_comm]
        }];
    }
    free(procs);
    return list;
}

#pragma mark - Sandbox Reader

static NSString *_readSandboxFile(NSString *path) {
    /* As root daemon, we can read any file on the device */
    NSError *error = nil;
    NSString *content = [NSString stringWithContentsOfFile:path
                                                  encoding:NSUTF8StringEncoding
                                                     error:&error];
    if (error) return [NSString stringWithFormat:@"Error: %@", [error localizedDescription]];
    /* Cap at 32KB */
    if ([content length] > 32768) content = [content substringToIndex:32768];
    return content;
}

#pragma mark - Daemon IPC Handler

@interface LegacyPodClawDaemon : NSObject {
    id _center; /* CPDistributedMessagingCenter, loaded at runtime */
    NSTimer *_syslogTimer;
    NSTimer *_batteryTimer;
    NSDictionary *_cachedBatteryInfo;
}
- (void)start;
@end

@implementation LegacyPodClawDaemon

- (void)start {
    NSLog(@"[clawpodd] Starting LegacyPodClaw daemon v0.1.0");

    _recentCrashes = [[NSMutableArray alloc] init];

    /* Load AppSupport framework dynamically for CPDMC */
    dlopen("/System/Library/PrivateFrameworks/AppSupport.framework/AppSupport", RTLD_NOW);

    /* Create IPC server using runtime class lookup */
    Class CPDMCClass = NSClassFromString(@"CPDistributedMessagingCenter");
    if (!CPDMCClass) {
        NSLog(@"[clawpodd] FATAL: Cannot load CPDistributedMessagingCenter");
        return;
    }
    _center = [[CPDMCClass performSelector:@selector(centerNamed:)
                                withObject:@"pro.matthesketh.legacypodclaw.daemon"] retain];
    [_center performSelector:@selector(runServerOnCurrentThread)];

    /* Register message handlers via objc_msgSend (3-arg selector) */
    SEL regSel = @selector(registerForMessageName:target:selector:);
    typedef void (*RegFunc)(id, SEL, NSString *, id, SEL);
    RegFunc regMsg = (RegFunc)objc_msgSend;

    regMsg(_center, regSel, @"ping", self, @selector(handlePing:withUserInfo:));
    regMsg(_center, regSel, @"battery", self, @selector(handleBattery:withUserInfo:));
    regMsg(_center, regSel, @"processes", self, @selector(handleProcesses:withUserInfo:));
    regMsg(_center, regSel, @"crashes", self, @selector(handleCrashes:withUserInfo:));
    regMsg(_center, regSel, @"readFile", self, @selector(handleReadFile:withUserInfo:));
    regMsg(_center, regSel, @"execute", self, @selector(handleExecute:withUserInfo:));
    regMsg(_center, regSel, @"status", self, @selector(handleStatus:withUserInfo:));
    regMsg(_center, regSel, @"sandboxRead", self, @selector(handleSandboxRead:withUserInfo:));
    regMsg(_center, regSel, @"sysctl", self, @selector(handleSysctl:withUserInfo:));

    /* Start syslog monitor (check every 30s) */
    _syslogTimer = [NSTimer scheduledTimerWithTimeInterval:30.0
        target:self selector:@selector(_checkSyslog) userInfo:nil repeats:YES];

    /* Cache battery info every 60s */
    _batteryTimer = [NSTimer scheduledTimerWithTimeInterval:60.0
        target:self selector:@selector(_updateBattery) userInfo:nil repeats:YES];
    [self _updateBattery];

    NSLog(@"[clawpodd] IPC server running, %lu handlers registered",
        (unsigned long)9);

    /* Post notification that daemon is ready */
    notify_post("pro.matthesketh.legacypodclaw/daemonReady");
}

- (void)_checkSyslog { _checkSyslogForCrashes(); }
- (void)_updateBattery {
    [_cachedBatteryInfo release];
    _cachedBatteryInfo = [_getBatteryInfo() retain];
}

#pragma mark - IPC Handlers

- (NSDictionary *)handlePing:(NSString *)name withUserInfo:(NSDictionary *)info {
    return @{@"pong": @YES, @"uptime": @([self _uptime]), @"version": @"0.1.0"};
}

- (NSDictionary *)handleBattery:(NSString *)name withUserInfo:(NSDictionary *)info {
    return _cachedBatteryInfo ?: _getBatteryInfo();
}

- (NSDictionary *)handleProcesses:(NSString *)name withUserInfo:(NSDictionary *)info {
    return @{@"processes": _getProcessList()};
}

- (NSDictionary *)handleCrashes:(NSString *)name withUserInfo:(NSDictionary *)info {
    _checkSyslogForCrashes();
    return @{@"crashes": _recentCrashes ?: @[]};
}

- (NSDictionary *)handleReadFile:(NSString *)name withUserInfo:(NSDictionary *)info {
    NSString *path = [info objectForKey:@"path"];
    if (!path) return @{@"error": @"No path"};
    NSString *content = _readSandboxFile(path);
    return @{@"content": content ?: @""};
}

/* SECURITY: Characters that could enable command injection */
static NSCharacterSet *_dangerousChars = nil;

/* SECURITY: Validate command for injection attempts */
+ (BOOL)_isCommandSafe:(NSString *)cmd error:(NSString **)error {
    if (!cmd || [cmd length] == 0) {
        if (error) *error = @"Empty command";
        return NO;
    }
    
    /* Check length */
    if ([cmd length] > 4096) {
        if (error) *error = @"Command too long (max 4096 chars)";
        return NO;
    }
    
    /* Check for shell metacharacters that could enable injection */
    NSRange dangerousRange = [cmd rangeOfCharacterFromSet:_dangerousChars];
    if (dangerousRange.location != NSNotFound) {
        if (error) {
            *error = [NSString stringWithFormat:
                @"Command contains dangerous character at position %lu",
                (unsigned long)dangerousRange.location];
        }
        return NO;
    }
    
    return YES;
}

- (NSDictionary *)handleExecute:(NSString *)name withUserInfo:(NSDictionary *)info {
    /* SECURITY FIX: Verify caller is authorized before executing root commands */
    if (!_verifyCallerToken(info)) {
        return @{@"error": @"Unauthorized: Invalid or missing auth token"};
    }

    NSString *cmd = [info objectForKey:@"command"];
    if (!cmd) return @{@"error": @"No command"};
    
    /* SECURITY: Validate command for injection */
    NSString *validationError = nil;
    if (![LegacyPodClawDaemon _isCommandSafe:cmd error:&validationError]) {
        return @{@"error": [NSString stringWithFormat:@"Command validation failed: %@", validationError]};
    }

    /* SECURITY: Execute safely using fork/exec with resource limits */
    int stdoutPipe[2];
    int stderrPipe[2];
    if (pipe(stdoutPipe) < 0 || pipe(stderrPipe) < 0) {
        return @{@"error": @"Failed to create pipes"};
    }
    
    pid_t pid = fork();
    if (pid < 0) {
        close(stdoutPipe[0]); close(stdoutPipe[1]);
        close(stderrPipe[0]); close(stderrPipe[1]);
        return @{@"error": @"Fork failed"};
    }
    
    if (pid == 0) {
        /* Child process - SECURITY: Apply resource limits */
        struct rlimit lim;
        
        /* Limit CPU time (30 seconds) */
        lim.rlim_cur = lim.rlim_max = 30;
        setrlimit(RLIMIT_CPU, &lim);
        
        /* Limit memory (64MB) */
        lim.rlim_cur = lim.rlim_max = 64 * 1024 * 1024;
        setrlimit(RLIMIT_AS, &lim);
        
        /* Limit file size (16MB output) */
        lim.rlim_cur = lim.rlim_max = 16 * 1024 * 1024;
        setrlimit(RLIMIT_FSIZE, &lim);
        
        /* Limit number of processes */
        lim.rlim_cur = lim.rlim_max = 10;
        setrlimit(RLIMIT_NPROC, &lim);
        
        /* Redirect stdout/stderr to pipes */
        dup2(stdoutPipe[1], STDOUT_FILENO);
        dup2(stderrPipe[1], STDERR_FILENO);
        
        /* Close all pipe fds */
        close(stdoutPipe[0]); close(stdoutPipe[1]);
        close(stderrPipe[0]); close(stderrPipe[1]);
        
        /* SECURITY: Clean environment - prevent env var injection */
        char *cleanEnv[] = {
            "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "HOME=/var/root",
            "USER=root",
            "TERM=xterm-256color",
            NULL
        };
        
        /* Execute via /bin/sh -c with command */
        execle("/bin/sh", "sh", "-c", [cmd UTF8String], NULL, cleanEnv);
        _exit(127); /* exec failed */
    }
    
    /* Parent process - close write ends */
    close(stdoutPipe[1]);
    close(stderrPipe[1]);
    
    /* Read output with timeout */
    NSMutableString *output = [NSMutableString stringWithCapacity:1024];
    NSMutableString *errorOutput = [NSMutableString stringWithCapacity:256];
    char buf[4096];
    
    /* Use select for timeout */
    fd_set readfds;
    struct timeval timeout;
    timeout.tv_sec = 35; /* 35 second total timeout */
    timeout.tv_usec = 0;
    
    int maxFd = (stdoutPipe[0] > stderrPipe[0]) ? stdoutPipe[0] : stderrPipe[0];
    
    while (1) {
        FD_ZERO(&readfds);
        FD_SET(stdoutPipe[0], &readfds);
        FD_SET(stderrPipe[0], &readfds);
        
        int ready = select(maxFd + 1, &readfds, NULL, NULL, &timeout);
        if (ready <= 0) break; /* Timeout or error */
        
        if (FD_ISSET(stdoutPipe[0], &readfds)) {
            ssize_t n = read(stdoutPipe[0], buf, sizeof(buf) - 1);
            if (n > 0) {
                buf[n] = '\0';
                [output appendFormat:@"%s", buf];
                if ([output length] > 32768) break; /* Output limit */
            } else if (n == 0) {
                break;
            }
        }
        
        if (FD_ISSET(stderrPipe[0], &readfds)) {
            ssize_t n = read(stderrPipe[0], buf, sizeof(buf) - 1);
            if (n > 0) {
                buf[n] = '\0';
                [errorOutput appendFormat:@"%s", buf];
                if ([errorOutput length] > 8192) break; /* Error limit */
            }
        }
    }
    
    close(stdoutPipe[0]);
    close(stderrPipe[0]);
    
    /* Wait for child with timeout */
    int status;
    pid_t result;
    int waitTime = 0;
    while ((result = waitpid(pid, &status, WNOHANG)) == 0 && waitTime < 35) {
        sleep(1);
        waitTime++;
    }
    
    /* Kill if still running */
    if (result == 0) {
        kill(pid, SIGTERM);
        sleep(1);
        kill(pid, SIGKILL);
        waitpid(pid, &status, 0);
    }
    
    int exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    
    /* If we hit output limits, note it */
    if ([output length] >= 32768) {
        [output appendString:@"\n[output truncated at 32KB limit]"];
    }
    
    return @{
        @"output": output,
        @"errorOutput": errorOutput,
        @"exitCode": @(exitCode),
        @"timedOut": @(waitTime >= 35)
    };
}

- (NSDictionary *)handleStatus:(NSString *)name withUserInfo:(NSDictionary *)info {
    return @{
        @"running": @YES,
        @"uptime": @([self _uptime]),
        @"version": @"0.1.0",
        @"battery": _cachedBatteryInfo ?: @{},
        @"recentCrashes": @([_recentCrashes count]),
        @"pid": @(getpid())
    };
}

- (NSDictionary *)handleSandboxRead:(NSString *)name withUserInfo:(NSDictionary *)info {
    /* SECURITY FIX: Verify caller before allowing arbitrary file reads */
    if (!_verifyCallerToken(info)) {
        return @{@"error": @"Unauthorized: Invalid or missing auth token"};
    }

    NSString *appId = [info objectForKey:@"appId"];
    NSString *relativePath = [info objectForKey:@"path"];
    if (!appId) return @{@"error": @"No appId"};

    /* Find app container */
    NSString *appsDir = @"/var/mobile/Applications/";
    NSArray *containers = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:appsDir error:nil];
    for (NSString *uuid in containers) {
        NSString *containerPath = [appsDir stringByAppendingPathComponent:uuid];
        /* Check if this container belongs to the requested app */
        NSString *metadataPath = [containerPath stringByAppendingPathComponent:@"iTunesMetadata.plist"];
        NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:metadataPath];
        NSString *bundleId = [metadata objectForKey:@"softwareVersionBundleId"];
        if ([bundleId isEqualToString:appId]) {
            NSString *fullPath = relativePath
                ? [containerPath stringByAppendingPathComponent:relativePath]
                : containerPath;
            if ([[NSFileManager defaultManager] fileExistsAtPath:fullPath]) {
                BOOL isDir;
                [[NSFileManager defaultManager] fileExistsAtPath:fullPath isDirectory:&isDir];
                if (isDir) {
                    NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:fullPath error:nil];
                    return @{@"type": @"directory", @"contents": contents ?: @[]};
                } else {
                    NSString *content = _readSandboxFile(fullPath);
                    return @{@"type": @"file", @"content": content ?: @""};
                }
            }
            return @{@"error": @"Path not found in container"};
        }
    }
    return @{@"error": @"App container not found"};
}

/* SECURITY: Whitelist of allowed sysctl keys - prevents info leaks and kernel manipulation */
static NSSet *_allowedSysctlKeys = nil;

+ (void)initialize {
    if (self == [LegacyPodClawDaemon class]) {
        _dangerousChars = [[NSCharacterSet characterSetWithCharactersInString:
            @";|&`$(){}[]!\\*?<>~^#%\n\r"] retain];
        
        /* SECURITY: Whitelist safe sysctl keys for device info */
        _allowedSysctlKeys = [[NSSet setWithObjects:
            /* Hardware info */
            @"hw.machine",
            @"hw.model",
            @"hw.ncpu",
            @"hw.physicalcpu",
            @"hw.logicalcpu",
            @"hw.cpufrequency",
            @"hw.busfrequency",
            @"hw.memsize",
            @"hw.pagesize",
            @"hw.cachelinesize",
            @"hw.l1icachesize",
            @"hw.l1dcachesize",
            @"hw.l2cachesize",
            @"hw.tbfrequency",
            @"hw.cputype",
            @"hw.cpusubtype",
            @"hw.cpu64bit_capable",
            @"hw.optional.floatingpoint",
            @"hw.optional.neon",
            @"hw.optional.armv7",
            @"hw.optional.armv7s",
            @"hw.optional.arm64",
            
            /* Kernel info */
            @"kern.osversion",
            @"kern.osrelease",
            @"kern.version",
            @"kern.hostname",
            @"kern.boottime",
            @"kern.procname",
            @"kern.ostype",
            @"kern.osproductversion",
            
            /* Memory/vm stats */
            @"vm.loadavg",
            @"vm.swapusage",
            @"vm.phys_mem",
            @"vm.user_mem",
            @"vm.page_free_count",
            @"vm.page_active_count",
            @"vm.page_inactive_count",
            @"vm.page_wire_count",
            
            /* Security level */
            @"security.mac.sandbox.debug",
            @"security.mac.sandbox.enforce",
            
            /* User info */
            @"kern.maxfiles",
            @"kern.maxproc",
            @"kern.maxvnodes",
            @"kern.num_files",
            @"kern.num_tasks",
            @"kern.num_threads",
            @"kern.sugid_coredump",
            
            /* Debug - limited */
            @"kern.corefile",
            @"kern.coredump",
            @"kern.coredump_mode",
            nil] retain];
    }
}

/* SECURITY: Validate sysctl key is in whitelist */
+ (BOOL)_isSysctlKeyAllowed:(NSString *)key {
    if (!key || [key length] == 0) return NO;
    
    /* Check for path traversal or injection attempts */
    if ([key rangeOfString:@".."].location != NSNotFound) return NO;
    if ([key rangeOfString:@"/"].location != NSNotFound) return NO;
    if ([key hasPrefix:@"."]) return NO;
    
    return [_allowedSysctlKeys containsObject:key];
}

- (NSDictionary *)handleSysctl:(NSString *)name withUserInfo:(NSDictionary *)info {
    /* SECURITY FIX: Verify caller before allowing kernel info leak via sysctl */
    if (!_verifyCallerToken(info)) {
        return @{@"error": @"Unauthorized: Invalid or missing auth token"};
    }

    NSString *key = [info objectForKey:@"key"];
    if (!key) return @{@"error": @"No key"};
    
    /* SECURITY: Validate key against whitelist */
    if (![LegacyPodClawDaemon _isSysctlKeyAllowed:key]) {
        NSLog(@"[clawpodd] Blocked sysctl request for non-whitelisted key: %@", key);
        return @{@"error": @"Sysctl key not in whitelist - access denied"};
    }

    size_t size;
    sysctlbyname([key UTF8String], NULL, &size, NULL, 0);
    if (size == 0) return @{@"error": @"Unknown sysctl key"};
    
    /* SECURITY: Limit max output size to prevent memory exhaustion */
    if (size > 65536) {
        return @{@"error": @"Sysctl value too large (>64KB)"};
    }

    char *buf = malloc(size);
    sysctlbyname([key UTF8String], buf, &size, NULL, 0);
    NSString *value = [[[NSString alloc] initWithBytes:buf length:size encoding:NSUTF8StringEncoding] autorelease];
    free(buf);

    return @{@"value": value ?: @"(binary data)"};
}

- (NSTimeInterval)_uptime {
    struct timeval boottime;
    size_t size = sizeof(boottime);
    int mib[2] = {CTL_KERN, KERN_BOOTTIME};
    sysctl(mib, 2, &boottime, &size, NULL, 0);
    return [[NSDate date] timeIntervalSince1970] - boottime.tv_sec;
}

@end

#pragma mark - Signal Handler (Async-Signal-Safe)

static volatile BOOL _running = YES;
static int _signalPipe[2] = {-1, -1};  /* Self-pipe for signal notification */

/* Async-signal-safe write to pipe */
static void _signalHandler(int sig) {
    /* Only async-signal-safe operations allowed here */
    const char msg[] = "[clawpodd] Signal received, shutting down\n";
    write(STDERR_FILENO, msg, sizeof(msg) - 1);
    
    /* Write byte to pipe to wake run loop (async-signal-safe) */
    if (_signalPipe[1] >= 0) {
        char dummy = (char)sig;
        (void)write(_signalPipe[1], &dummy, 1);
    }
    
    _running = NO;
}

/* Setup self-pipe for signal handling */
static BOOL _setupSignalPipe(void) {
    if (pipe(_signalPipe) < 0) {
        NSLog(@"[clawpodd] Failed to create signal pipe: %s", strerror(errno));
        return NO;
    }
    
    /* Set write end to non-blocking to prevent signal handler from blocking */
    int flags = fcntl(_signalPipe[1], F_GETFL, 0);
    if (flags >= 0) {
        fcntl(_signalPipe[1], F_SETFL, flags | O_NONBLOCK);
    }
    
    return YES;
}

/* Callback for CFRunLoop to handle signal pipe */
static void _signalPipeCallback(CFFileDescriptorRef fdRef, CFOptionFlags callBackTypes, void *info) {
    char buf[16];
    ssize_t n = read(_signalPipe[0], buf, sizeof(buf));
    if (n > 0) {
        for (int i = 0; i < n; i++) {
            NSLog(@"[clawpodd] Processing signal %d", (int)buf[i]);
        }
    }
    
    /* Re-enable callback */
    CFFileDescriptorEnableCallBacks(fdRef, kCFFileDescriptorReadCallBack);
    
    /* Stop the run loop */
    _running = NO;
    CFRunLoopStop(CFRunLoopGetMain());
}

#pragma mark - Main

int main(int argc, char *argv[]) {
    @autoreleasepool {
        /* Setup async-signal-safe signal handling via self-pipe */
        if (!_setupSignalPipe()) {
            NSLog(@"[clawpodd] WARNING: Signal pipe setup failed, using fallback signal handling");
        } else {
            /* Create CFRunLoop source for signal pipe */
            CFFileDescriptorContext ctx = {0, NULL, NULL, NULL, NULL};
            CFFileDescriptorRef fdRef = CFFileDescriptorCreate(kCFAllocatorDefault, _signalPipe[0], 
                                                                false, _signalPipeCallback, &ctx);
            if (fdRef) {
                CFFileDescriptorEnableCallBacks(fdRef, kCFFileDescriptorReadCallBack);
                CFRunLoopSourceRef rlSrc = CFFileDescriptorCreateRunLoopSource(kCFAllocatorDefault, fdRef, 0);
                if (rlSrc) {
                    CFRunLoopAddSource(CFRunLoopGetMain(), rlSrc, kCFRunLoopDefaultMode);
                    CFRelease(rlSrc);
                }
                CFRelease(fdRef);
                NSLog(@"[clawpodd] Signal pipe registered with run loop");
            }
        }
        
        /* Register signal handlers */
        signal(SIGTERM, _signalHandler);
        signal(SIGINT, _signalHandler);
        signal(SIGPIPE, SIG_IGN);  /* Ignore SIGPIPE from socket operations */

        LegacyPodClawDaemon *daemon = [[LegacyPodClawDaemon alloc] init];
        [daemon start];

        /* Run the main run loop */
        while (_running) {
            @autoreleasepool {
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 10.0, NO);
            }
        }

        NSLog(@"[clawpodd] Daemon stopped cleanly");
        [daemon release];

        /* Cleanup signal pipe */
        if (_signalPipe[0] >= 0) close(_signalPipe[0]);
        if (_signalPipe[1] >= 0) close(_signalPipe[1]);
        
        /* Cleanup security token */
        [_daemonToken release];
        _daemonToken = nil;
    }
    return 0;
}
