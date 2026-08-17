#include <sys/stat.h>
#import <Foundation/Foundation.h>
#include <libkern/OSCacheControl.h>
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ReplayKit/ReplayKit.h>
#import <CommonCrypto/CommonCrypto.h>
#import <CFNetwork/CFNetwork.h>
#import <substrate.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/mach.h>
#import <sys/sysctl.h>
#import <dlfcn.h>
#import <sys/utsname.h>
#import <pthread.h>
#import <math.h>

// ═══════════════════════════════════════
// OFFSETS — Il2Cpp v31 | UnityFramework arm64
// Extracted: global-metadata.dat + UnityFramework Mach-O
// All RVAs verified — valid ARM64 prologues confirmed
// ═══════════════════════════════════════

// --- FUNCTION RVAs (dari method pointer table) ---
// Usage: base + RVA = real runtime address
// base = _dyld_get_image_header("UnityFramework") at runtime

#define RVA_GetUnityVPMatrix   0x04610DAC  // GetUnityProjectionMatrix_Injected | idx=332019
#define RVA_GetPlayer          0x0306CDB8  // GetPlayer(int index)               | idx=280188
#define RVA_GetPlayerCount     0x03967360  // GetPlayerCount()                   | idx=190926
#define RVA_GetLocalPlayer     0x0959F8E0  // GetLocalPlayer()                   | idx=129753
#define RVA_GetLocalPlayer2    0x01523140  // GetLocalPlayer() alt               | idx=167463
#define RVA_isLocalPlayer      0x0862A9F8  // isLocalPlayer()                    | idx=6290
#define RVA_AimRotation        0x073D9824  // AimRotation()                      | idx=105515
#define RVA_SetAsAimTarget     0x06DD25F8  // SetAsAimTarget()                   | idx=212202
#define RVA_SetAimed           0x0979F9DC  // SetAimed()                         | idx=139572
#define RVA_get_CurrentState   0x06FD1960  // get_CurrentState()                 | idx=43047
#define RVA_GetCurrentState    0x01704DC4  // GetCurrentState()                  | idx=216972
#define RVA_get_BonePosition   0x07ED4AEC  // get_BonePosition()                 | idx=46692
#define RVA_BoneTransform      0x0789072C  // BoneTransform()                    | idx=44897
#define RVA_Update             0x09F1BC64  // Update() Unity main loop           | idx=666
#define RVA_OnUpdate           0x0866A720  // OnUpdate()                         | idx=9900
#define RVA_VerifySignature    0x05869098  // VerifySignature() — AC target      | idx=374886
#define RVA_WorldToViewport    0x05051ED8  // WorldToViewportPoint()             | idx=356562
#define RVA_GetMainCamera      0x05B7FE20  // GetMainCamera()                    | idx=203000
#define RVA_BuildProjMatrix    0x09EA629C  // BuildProjectionMatrix()            | idx=27
#define RVA_HitList2Entity     0x031482D0  // HitList2EntityList()               | idx=282069
#define RVA_TargetPlayer       0x04C95E60  // TargetPlayer()                     | idx=198365
#define RVA_SetBone            0x04BB0A24  // SetBone()                          | idx=345483

// --- INTEGRITY PATCH — satu target sahaja (VerifySignature confirmed) ---
// INTEG_1..5 dibuang — bukan AC functions sebenar, risk force close
#define RVA_INTEG_0            0x05869098  // VerifySignature — patch → mov x0,1; ret

// --- STRUCT FIELD OFFSETS ---
// Bone array: player_obj + 0x138 = ptr to bone array
// Each bone = 0x30 bytes: Vec3 pos @ +0x00, Quaternion @ +0x0C, Vec3 scale @ +0x1C
#define BONE_ARRAY_FIELD       0x138
#define BONE_STRIDE            0x30

// AimSystem struct (from AimRotation object)
// +0x10 = float yaw, +0x14 = float pitch
#define AIMSYS_YAW             0x10
#define AIMSYS_PITCH           0x14

// BulletTP struct (from SetAsAimTarget object)
// +0x48 = Vec3 target position
#define BULLETTP_TARGET        0x48

// ═══════════════════════════════════════
// TYPES & GLOBALS
// ═══════════════════════════════════════

typedef struct { float x, y, z; }       Vec3;
typedef struct { float m[4][4]; }        Matrix4x4;
typedef struct { float x, y, z, w; }    Quaternion;

#define FF_BUNDLE @"com.dts.freefireth"

// --- Feature toggles ---
static bool  g_AimbotHead   = false;
static bool  g_AimbotBody   = false;
static bool  g_AimbotNeck   = false;
static bool  g_AimbotLeg    = false;
static float g_AimFOV       = 150.0f;
static bool  g_AimSilent    = false;
static bool  g_AimKill      = false;
static bool  g_ESPLine      = false;
static bool  g_ESPBox       = false;
static bool  g_ESPSkeleton  = false;
static bool  g_StreamProof  = false;
static bool  g_LogoPC       = false;
static bool  g_MenuVisible  = false;
static bool  g_CheatActive  = false;

// --- Runtime state ---
static UIWindow*    g_OverlayWindow  = nil;
static NSUUID*      g_SpoofedUUID    = nil;
static Matrix4x4    g_VP;                    // cached VP matrix dari hook
static bool         g_VP_valid       = false;
static pthread_mutex_t g_VP_lock     = PTHREAD_MUTEX_INITIALIZER;

// --- Skeleton bone pairs (untuk ESP skeleton draw) ---
static const int SKELETON[][2] = {
    {4,3},{3,1},{1,2},{2,5},{5,6},
    {1,8},{8,9},{9,10},
    {1,11},{11,12},{12,13}
};

// ═══════════════════════════════════════
// SAFE READ — zero crash guarantee
// ═══════════════════════════════════════

static bool safeRead(uintptr_t addr, void* out, size_t size) {
    if (!addr || addr < 0x1000) return false;
    vm_size_t outSize = size;
    return vm_read_overwrite(mach_task_self(), addr, size,
        (vm_address_t)out, &outSize) == KERN_SUCCESS;
}

static uintptr_t safeReadPtr(uintptr_t addr) {
    uintptr_t val = 0;
    return safeRead(addr, &val, sizeof(val)) ? val : 0;
}

// ═══════════════════════════════════════
// BASE ADDRESS
// ═══════════════════════════════════════

static uintptr_t g_CachedBase = 0;

static uintptr_t getBase() {
    if (g_CachedBase) return g_CachedBase;
    const char* targets[] = {
        "UnityFramework",
        "GameAssembly",
        "FreeFire",
        "freefire",
        "com.dts.freefireth",
        NULL
    };
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char* n = _dyld_get_image_name(i);
        if (!n) continue;
        for (int t = 0; targets[t]; t++) {
            if (strstr(n, targets[t])) {
                g_CachedBase = (uintptr_t)_dyld_get_image_header(i);
                return g_CachedBase;
            }
        }
    }
    return 0;
}

// ═══════════════════════════════════════
// VP MATRIX — hooked, not safeRead from code ptr
// GetUnityProjectionMatrix_Injected dipatch hook
// matrix disimpan ke g_VP global bila dipanggil game
// ═══════════════════════════════════════

// Il2Cpp Il2CppMethodPointer typedef untuk function ini:
// void GetUnityProjectionMatrix_Injected(Matrix4x4* outMatrix)
typedef void (*GetVPMatrix_t)(void*, void*); // thisPtr, Matrix4x4* out
static GetVPMatrix_t orig_getVP = NULL;

static void hook_getVP(void* thiz, void* outMat) {
    orig_getVP(thiz, outMat);
    // Copy hasil ke global cache
    if (outMat) {
        pthread_mutex_lock(&g_VP_lock);
        memcpy(&g_VP, outMat, sizeof(Matrix4x4));
        g_VP_valid = true;
        pthread_mutex_unlock(&g_VP_lock);
    }
}

// ═══════════════════════════════════════
// PLAYER ACCESS — hooked function calls
// GetPlayer(int index) → player object ptr
// GetPlayerCount() → int
// GetLocalPlayer() → local player ptr
// ═══════════════════════════════════════

typedef void* (*GetPlayer_t)(void*, int);      // classPtr, index
typedef int   (*GetPlayerCount_t)(void*);       // classPtr
typedef void* (*GetLocalPlayer_t)(void*);       // classPtr

static GetPlayer_t      fn_GetPlayer      = NULL;
static GetPlayerCount_t fn_GetPlayerCount = NULL;
static GetLocalPlayer_t fn_GetLocalPlayer = NULL;

// Manager singleton — cari melalui il2cpp class instance
// FreeFire menyimpan PlayerManager as static/singleton
// Kita hook GetPlayerCount supaya boleh intercept pointer manager
static void* g_PlayerManager = NULL;

typedef int (*GetPlayerCount_hook_t)(void*);
static GetPlayerCount_hook_t orig_GetPlayerCount = NULL;

static int hook_GetPlayerCount(void* mgr) {
    if (!g_PlayerManager && mgr) g_PlayerManager = mgr;
    return orig_GetPlayerCount(mgr);
}

// GetLocalPlayer hook — capture localPlayer ptr
static void* g_LocalPlayer = NULL;
typedef void* (*GetLocalPlayer_hook_t)(void*);
static GetLocalPlayer_hook_t orig_GetLocalPlayer = NULL;

static void* hook_GetLocalPlayer(void* mgr) {
    void* lp = orig_GetLocalPlayer(mgr);
    if (lp) g_LocalPlayer = lp;
    return lp;
}

// ═══════════════════════════════════════
// HELPERS
// ═══════════════════════════════════════

static CGPoint worldToScreen(Vec3 pos) {
    pthread_mutex_lock(&g_VP_lock);
    if (!g_VP_valid) {
        pthread_mutex_unlock(&g_VP_lock);
        return CGPointZero;
    }
    Matrix4x4 vp = g_VP;
    pthread_mutex_unlock(&g_VP_lock);

    float cx = pos.x*vp.m[0][0]+pos.y*vp.m[1][0]+pos.z*vp.m[2][0]+vp.m[3][0];
    float cy = pos.x*vp.m[0][1]+pos.y*vp.m[1][1]+pos.z*vp.m[2][1]+vp.m[3][1];
    float cw = pos.x*vp.m[0][3]+pos.y*vp.m[1][3]+pos.z*vp.m[2][3]+vp.m[3][3];
    if (cw <= 0) return CGPointZero;
    CGSize s = UIScreen.mainScreen.bounds.size;
    return CGPointMake((1.0f + cx/cw)*s.width*0.5f,
                       (1.0f - cy/cw)*s.height*0.5f);
}

static Vec3 getBone(uintptr_t player, int boneID) {
    Vec3 v = {0,0,0};
    uintptr_t bones = safeReadPtr(player + BONE_ARRAY_FIELD);
    if (!bones) return v;
    safeRead(bones + boneID * BONE_STRIDE, &v, sizeof(Vec3));
    return v;
}

// patch function → mov x0,#1 ; ret  (ARM64)
static void patchAddr(uintptr_t addr) {
    if (!addr || addr < 0x1000) return;
    uint32_t patch[] = { 0xD2800020, 0xD65F03C0 };
    kern_return_t kr = vm_protect(mach_task_self(), addr, sizeof(patch),
        false, VM_PROT_READ|VM_PROT_WRITE|VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) return;
    memcpy((void*)addr, patch, sizeof(patch));
    sys_icache_invalidate((void*)addr, sizeof(patch));
    vm_protect(mach_task_self(), addr, sizeof(patch),
        false, VM_PROT_READ|VM_PROT_EXECUTE);
}

// ═══════════════════════════════════════
// LAYER 1 — HARDWARE SPOOF
// ═══════════════════════════════════════

static NSUUID* (*orig_idfv)(id,SEL);
static NSUUID* hook_idfv(id self, SEL _cmd) {
    if (!g_SpoofedUUID) {
        NSUserDefaults* d = NSUserDefaults.standardUserDefaults;
        NSString* s = [d stringForKey:@"atlas_uuid"];
        g_SpoofedUUID = s ? [[NSUUID alloc] initWithUUIDString:s] : [NSUUID UUID];
        if (!s) {
            [d setObject:g_SpoofedUUID.UUIDString forKey:@"atlas_uuid"];
            [d synchronize];
        }
    }
    return g_SpoofedUUID;
}

static int (*orig_sysctlbyname)(const char*,void*,size_t*,void*,size_t);
static int hook_sysctlbyname(const char* name, void* oldp, size_t* oldlenp,
                              void* newp, size_t newlen) {
    int r = orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
    if (r == 0 && oldp) {
        if (strcmp(name, "hw.machine") == 0)
            strlcpy((char*)oldp, "iPhone13,2", *oldlenp);
        if (strcmp(name, "hw.model") == 0)
            strlcpy((char*)oldp, "D53gAP", *oldlenp);
    }
    return r;
}

static void HardwareSpoof_Init() {
    MSHookMessageEx([UIDevice class],
        @selector(identifierForVendor),
        (IMP)hook_idfv, (IMP*)&orig_idfv);
    MSHookFunction((void*)sysctlbyname,
        (void*)hook_sysctlbyname, (void**)&orig_sysctlbyname);
}

// ═══════════════════════════════════════
// LAYER 2 — LOGO PC
// ═══════════════════════════════════════

static NSString* (*orig_systemName)(id,SEL);
static NSString* hook_systemName(id self, SEL _cmd) {
    return g_LogoPC ? @"Windows" : orig_systemName(self, _cmd);
}

static NSString* (*orig_systemVersion)(id,SEL);
static NSString* hook_systemVersion(id self, SEL _cmd) {
    return g_LogoPC ? @"10.0" : orig_systemVersion(self, _cmd);
}

static NSString* (*orig_model)(id,SEL);
static NSString* hook_model(id self, SEL _cmd) {
    return g_LogoPC ? @"PC" : orig_model(self, _cmd);
}

static NSString* (*orig_name)(id,SEL);
static NSString* hook_name(id self, SEL _cmd) {
    return g_LogoPC ? @"DESKTOP-ATLAS" : orig_name(self, _cmd);
}

static NSString* (*orig_processName)(id,SEL);
static NSString* hook_processName(id self, SEL _cmd) {
    return g_LogoPC ? @"FreeFire" : orig_processName(self, _cmd);
}

static NSString* (*orig_hostName)(id,SEL);
static NSString* hook_hostName(id self, SEL _cmd) {
    return g_LogoPC ? @"DESKTOP-ATLAS" : orig_hostName(self, _cmd);
}

static int (*orig_uname)(struct utsname*);
static int hook_uname(struct utsname* info) {
    int r = orig_uname(info);
    if (r == 0 && g_LogoPC) {
        strlcpy(info->sysname,  "Windows_NT",    sizeof(info->sysname));
        strlcpy(info->nodename, "DESKTOP-ATLAS", sizeof(info->nodename));
        strlcpy(info->release,  "10.0.19041",    sizeof(info->release));
        strlcpy(info->version,  "10.0.19041.1",  sizeof(info->version));
        strlcpy(info->machine,  "x86_64",         sizeof(info->machine));
    }
    return r;
}

static void LogoPC_Init() {
    MSHookMessageEx([UIDevice class], @selector(systemName),
        (IMP)hook_systemName, (IMP*)&orig_systemName);
    MSHookMessageEx([UIDevice class], @selector(systemVersion),
        (IMP)hook_systemVersion, (IMP*)&orig_systemVersion);
    MSHookMessageEx([UIDevice class], @selector(model),
        (IMP)hook_model, (IMP*)&orig_model);
    MSHookMessageEx([UIDevice class], @selector(name),
        (IMP)hook_name, (IMP*)&orig_name);
    MSHookMessageEx([NSProcessInfo class], @selector(processName),
        (IMP)hook_processName, (IMP*)&orig_processName);
    MSHookMessageEx([NSProcessInfo class], @selector(hostName),
        (IMP)hook_hostName, (IMP*)&orig_hostName);
    MSHookFunction((void*)uname, (void*)hook_uname, (void**)&orig_uname);
}

// ═══════════════════════════════════════
// LAYER 3 — MEMORY WIPER
// ═══════════════════════════════════════

static const char* (*orig_imageName)(uint32_t);
static const char* hook_imageName(uint32_t idx) {
    const char* n = orig_imageName(idx);
    if (n && (strstr(n,"AtlasMod") || strstr(n,"substrate") ||
              strstr(n,"MobileSubstrate") || strstr(n,"CydiaSubstrate") ||
              strstr(n,"TrollStore") || strstr(n,"AltStore") ||
              strstr(n,"inject") || strstr(n,"tweak")))
        return "/usr/lib/system/libsystem_c.dylib";
    return n;
}

static uint32_t (*orig_imageCount)(void);
static uint32_t hook_imageCount(void) {
    uint32_t real = orig_imageCount();
    uint32_t hidden = 0;
    for (uint32_t i = 0; i < real; i++) {
        const char* n = orig_imageName(i);
        if (n && (strstr(n,"AtlasMod") || strstr(n,"substrate") ||
                  strstr(n,"TrollStore") || strstr(n,"inject") ||
                  strstr(n,"tweak"))) hidden++;
    }
    return real - hidden;
}

static void MemoryWiper_Init() {
    MSHookFunction((void*)_dyld_get_image_name,
        (void*)hook_imageName, (void**)&orig_imageName);
    MSHookFunction((void*)_dyld_image_count,
        (void*)hook_imageCount, (void**)&orig_imageCount);
}

// ═══════════════════════════════════════
// LAYER 4 — NETWORK GUARD
// ═══════════════════════════════════════

static NSSet* g_BlockedHosts = nil;

static void initBlockList() {
    g_BlockedHosts = [NSSet setWithArray:@[
        @"telemetry.freefiremobile.com",
        @"anti.freefiremobile.com",
        @"report.freefiremobile.com",
        @"clientlog.freefiremobile.com",
        @"crash.freefiremobile.com",
        @"ac.freefire.com",
        @"accheck.garena.com",
        @"security.garena.com",
        @"detect.garena.com",
        @"monitor.garena.com",
        @"log.garena.com",
        @"analytics.garena.com",
        @"check.garena.com",
        @"ban.garena.com",
        @"report.garena.com",
        @"integrity.garena.com",
        @"datadog",
        @"sentry.io",
        @"bugsnag",
        @"crashlytics",
    ]];
}

static BOOL isBlocked(NSString* host) {
    if (!host) return NO;
    for (NSString* b in g_BlockedHosts)
        if ([host containsString:b]) return YES;
    return NO;
}

static id (*orig_dataTask)(id,SEL,NSURLRequest*,id);
static id hook_dataTask(id self, SEL _cmd, NSURLRequest* req, id cb) {
    if (isBlocked(req.URL.host)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (cb) {
                NSHTTPURLResponse* r = [[NSHTTPURLResponse alloc]
                    initWithURL:req.URL statusCode:200
                    HTTPVersion:@"HTTP/1.1" headerFields:@{}];
                ((void(^)(NSData*,NSURLResponse*,NSError*))cb)
                    ([NSData data], r, nil);
            }
        });
        return nil;
    }
    return orig_dataTask(self, _cmd, req, cb);
}

static NSData* (*orig_sendSyncReq)(id,SEL,NSURLRequest*,NSURLResponse**,NSError**);
static NSData* hook_sendSyncReq(id self, SEL _cmd, NSURLRequest* req,
                                 NSURLResponse** resp, NSError** err) {
    if (isBlocked(req.URL.host)) {
        if (resp) *resp = [[NSHTTPURLResponse alloc]
            initWithURL:req.URL statusCode:200
            HTTPVersion:@"HTTP/1.1" headerFields:@{}];
        if (err) *err = nil;
        return [NSData data];
    }
    return orig_sendSyncReq(self, _cmd, req, resp, err);
}

static void NetworkGuard_Init() {
    initBlockList();
    MSHookMessageEx(NSClassFromString(@"NSURLSession"),
        @selector(dataTaskWithRequest:completionHandler:),
        (IMP)hook_dataTask, (IMP*)&orig_dataTask);
    MSHookMessageEx(NSClassFromString(@"NSURLConnection"),
        @selector(sendSynchronousRequest:returningResponse:error:),
        (IMP)hook_sendSyncReq, (IMP*)&orig_sendSyncReq);
}

// ═══════════════════════════════════════
// LAYER 5 — JAILBREAK BYPASS
// ═══════════════════════════════════════

static int (*orig_access)(const char*, int);
static int hook_access(const char* path, int mode) {
    if (!path) return -1;
    const char* jbPaths[] = {
        "/Applications/Cydia.app","/Applications/Sileo.app",
        "/Applications/Zebra.app","/usr/sbin/sshd","/usr/bin/ssh",
        "/bin/bash","/private/var/lib/apt","/private/var/stash",
        "/private/var/mobile/Library/SBSettings","/Library/MobileSubstrate",
        "/usr/libexec/cydia","/var/cache/apt","/var/lib/apt",
        "/var/lib/cydia","/var/log/syslog","/bin/su",
        "/usr/bin/scp","/etc/apt", NULL
    };
    for (int i = 0; jbPaths[i]; i++)
        if (strcmp(path, jbPaths[i]) == 0) return -1;
    return orig_access(path, mode);
}

static FILE* (*orig_fopen)(const char*, const char*);
static FILE* hook_fopen(const char* path, const char* mode) {
    if (!path) return NULL;
    const char* blocked[] = {
        "/bin/bash","/usr/sbin/sshd","/etc/apt",
        "/private/var/lib/apt","/Library/MobileSubstrate", NULL
    };
    for (int i = 0; blocked[i]; i++)
        if (strcmp(path, blocked[i]) == 0) return NULL;
    return orig_fopen(path, mode);
}

static int (*orig_stat)(const char*, struct stat*);
static int hook_stat(const char* path, struct stat* buf) {
    if (!path) return -1;
    const char* jbPaths[] = {
        "/Applications/Cydia.app","/usr/sbin/sshd",
        "/bin/bash","/Library/MobileSubstrate",
        "/private/var/lib/apt", NULL
    };
    for (int i = 0; jbPaths[i]; i++)
        if (strcmp(path, jbPaths[i]) == 0) return -1;
    return orig_stat(path, buf);
}

static BOOL (*orig_fileExists)(id,SEL,NSString*);
static BOOL hook_fileExists(id self, SEL _cmd, NSString* path) {
    if (!path) return NO;
    NSArray* blocked = @[
        @"/Applications/Cydia.app",@"/Applications/Sileo.app",
        @"/usr/sbin/sshd",@"/bin/bash",
        @"/Library/MobileSubstrate",@"/private/var/lib/apt",
        @"/var/lib/cydia",
    ];
    for (NSString* b in blocked)
        if ([path hasPrefix:b]) return NO;
    return orig_fileExists(self, _cmd, path);
}

static BOOL (*orig_canOpen)(id,SEL,NSURL*);
static BOOL hook_canOpen(id self, SEL _cmd, NSURL* url) {
    NSString* scheme = url.scheme.lowercaseString;
    if ([scheme isEqualToString:@"cydia"] ||
        [scheme isEqualToString:@"sileo"] ||
        [scheme isEqualToString:@"zbra"])
        return NO;
    return orig_canOpen(self, _cmd, url);
}

static void JailbreakBypass_Init() {
    MSHookFunction((void*)access, (void*)hook_access, (void**)&orig_access);
    MSHookFunction((void*)fopen,  (void*)hook_fopen,  (void**)&orig_fopen);
    MSHookFunction((void*)(&::stat), (void*)hook_stat, (void**)&orig_stat);
    MSHookMessageEx([NSFileManager class], @selector(fileExistsAtPath:),
        (IMP)hook_fileExists, (IMP*)&orig_fileExists);
    MSHookMessageEx([UIApplication class], @selector(canOpenURL:),
        (IMP)hook_canOpen, (IMP*)&orig_canOpen);
}

// ═══════════════════════════════════════
// LAYER 6 — STREAM PROOF
// ═══════════════════════════════════════

static BOOL (*orig_isRecording)(id,SEL);
static BOOL hook_isRecording(id self, SEL _cmd) {
    if (g_StreamProof) return NO;
    return orig_isRecording(self, _cmd);
}

static void onCapture(CFNotificationCenterRef c, void* o,
    CFNotificationName n, const void* obj, CFDictionaryRef i) {
    if (!g_StreamProof) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        g_OverlayWindow.hidden = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(0.5*NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
            if (g_MenuVisible) g_OverlayWindow.hidden = NO;
        });
    });
}

static void StreamProof_Init() {
    Class rp = NSClassFromString(@"RPScreenRecorder");
    if (rp) MSHookMessageEx(rp, @selector(isRecording),
        (IMP)hook_isRecording, (IMP*)&orig_isRecording);
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetLocalCenter(), NULL, onCapture,
        CFSTR("UIApplicationUserDidTakeScreenshotNotification"),
        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}

// ═══════════════════════════════════════
// LAYER 7 — INTEGRITY PATCHER
// Hanya patch VerifySignature — confirmed target
// ═══════════════════════════════════════

static void IntegrityPatcher_Init(uintptr_t base) {
    uintptr_t target = base + RVA_INTEG_0;
    if (target > base) patchAddr(target);
}

// ═══════════════════════════════════════
// LAYER 8 — ANTI-DEBUG
// ═══════════════════════════════════════

typedef int (*ptrace_t)(int,pid_t,caddr_t,int);
static ptrace_t orig_ptrace;
static int hook_ptrace(int req, pid_t pid, caddr_t addr, int data) {
    if (req == 31) return 0; // PT_DENY_ATTACH
    return orig_ptrace(req, pid, addr, data);
}

static void AntiDebug_Init() {
    void* sym = dlsym(RTLD_DEFAULT, "ptrace");
    if (sym) MSHookFunction(sym, (void*)hook_ptrace, (void**)&orig_ptrace);
}

// ═══════════════════════════════════════
// LAYER 9 — GAME STATE TRACKER
// Intercept get_CurrentState calls → update g_State
// ═══════════════════════════════════════

typedef enum { S_Lobby=0, S_Loading=1, S_InGame=2, S_Ended=3 } GameStateEnum;
static GameStateEnum g_State = S_Lobby;

typedef int (*get_CurrentState_t)(void*);
static get_CurrentState_t orig_get_CurrentState = NULL;

static int hook_get_CurrentState(void* thiz) {
    int state = orig_get_CurrentState(thiz);
    GameStateEnum ns = (GameStateEnum)state;
    if (ns != g_State) {
        g_State = ns;
        switch (ns) {
            case S_Lobby:
            case S_Loading:
                g_CheatActive = false;
                break;
            case S_InGame:
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                    (int64_t)(3.0*NSEC_PER_SEC)),
                    dispatch_get_main_queue(), ^{
                    g_CheatActive = true;
                });
                break;
            case S_Ended:
                g_CheatActive = false;
                break;
        }
    }
    return state;
}

// ═══════════════════════════════════════
// TIMING NORMALIZER — anti-pattern detection
// ═══════════════════════════════════════

static NSTimeInterval g_LastAimTime = 0;

static BOOL shouldAim() {
    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    if (now - g_LastAimTime < 0.016f) return NO;
    if ((arc4random() % 100) < 2) return NO;
    g_LastAimTime = now;
    return YES;
}

// ═══════════════════════════════════════
// AIMBOT
// Guna fn_GetPlayer + fn_GetPlayerCount (hooked) 
// Tak guna raw pointer read dari list — guna actual game functions
// ═══════════════════════════════════════

static void Aimbot_Tick() {
    if (!g_AimbotHead && !g_AimbotBody && !g_AimbotNeck && !g_AimbotLeg) return;
    if (!shouldAim()) return;
    if (!fn_GetPlayer || !fn_GetPlayerCount || !g_PlayerManager) return;
    if (!g_LocalPlayer) return;
    if (!g_VP_valid) return;

    CGSize s = UIScreen.mainScreen.bounds.size;
    CGPoint center = CGPointMake(s.width/2, s.height/2);
    int boneID = g_AimbotHead ? 4 : g_AimbotNeck ? 3 : g_AimbotBody ? 1 : 7;

    int total = fn_GetPlayerCount(g_PlayerManager);
    total = MIN(total, 50);

    uintptr_t best = 0;
    float bestDist = g_AimFOV;
    Vec3 bestBone = {0,0,0};

    for (int i = 0; i < total; i++) {
        void* ent = fn_GetPlayer(g_PlayerManager, i);
        if (!ent || ent == g_LocalPlayer) continue;
        Vec3 bone = getBone((uintptr_t)ent, boneID);
        if (bone.x == 0 && bone.y == 0 && bone.z == 0) continue;
        CGPoint sp = worldToScreen(bone);
        if (CGPointEqualToPoint(sp, CGPointZero)) continue;
        float dx = sp.x - center.x, dy = sp.y - center.y;
        float dist = sqrtf(dx*dx + dy*dy);
        if (dist < bestDist) {
            bestDist = dist;
            best = (uintptr_t)ent;
            bestBone = bone;
        }
    }

    if (!best) return;
    uintptr_t base = getBase();

    if (g_AimSilent) {
        // Silent aim — tulis terus ke bullet target position
        uintptr_t bs = safeReadPtr(base + RVA_SetAsAimTarget);
        if (bs) safeRead(0, NULL, 0); // placeholder — trace bs struct dulu
        // Sementara guna direct write ke AimSystem object
        uintptr_t as = safeReadPtr(base + RVA_AimRotation);
        if (as) {
            float h = atan2f(bestBone.z, bestBone.x);
            float v = atan2f(bestBone.y,
                sqrtf(bestBone.x*bestBone.x + bestBone.z*bestBone.z));
            // safeRead guna vm_write untuk write
            vm_write(mach_task_self(), as + AIMSYS_YAW,   (vm_offset_t)&h, sizeof(float));
            vm_write(mach_task_self(), as + AIMSYS_PITCH,  (vm_offset_t)&v, sizeof(float));
        }
    } else {
        uintptr_t as = safeReadPtr(base + RVA_AimRotation);
        if (as) {
            float h = atan2f(bestBone.z, bestBone.x);
            float v = atan2f(bestBone.y,
                sqrtf(bestBone.x*bestBone.x + bestBone.z*bestBone.z));
            vm_write(mach_task_self(), as + AIMSYS_YAW,   (vm_offset_t)&h, sizeof(float));
            vm_write(mach_task_self(), as + AIMSYS_PITCH,  (vm_offset_t)&v, sizeof(float));
        }
    }
}

// ═══════════════════════════════════════
// ESP DRAW LAYER — render overlaid pada CADisplayLink
// ═══════════════════════════════════════

@interface AtlasESPView : UIView
@property (nonatomic, assign) uintptr_t* enemies;
@property (nonatomic, assign) int enemyCount;
@end

@implementation AtlasESPView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.userInteractionEnabled = NO;
        self.opaque = NO;
    }
    return self;
}

- (void)drawRect:(CGRect)rect {
    if (!g_CheatActive) return;
    if (!fn_GetPlayer || !fn_GetPlayerCount || !g_PlayerManager) return;
    if (!g_VP_valid) return;

    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;

    CGSize s = UIScreen.mainScreen.bounds.size;
    CGContextSetLineWidth(ctx, 1.5f);
    CGPoint myPos = CGPointMake(s.width/2, s.height);

    int total = fn_GetPlayerCount(g_PlayerManager);
    total = MIN(total, 50);

    for (int i = 0; i < total; i++) {
        void* ent = fn_GetPlayer(g_PlayerManager, i);
        if (!ent || ent == g_LocalPlayer) continue;
        uintptr_t e = (uintptr_t)ent;

        if (g_ESPLine) {
            Vec3 foot = getBone(e, 7);
            CGPoint fp = worldToScreen(foot);
            if (!CGPointEqualToPoint(fp, CGPointZero)) {
                CGContextSetRGBStrokeColor(ctx, 1, 0.2f, 0.2f, 1);
                CGContextMoveToPoint(ctx, myPos.x, myPos.y);
                CGContextAddLineToPoint(ctx, fp.x, fp.y);
                CGContextStrokePath(ctx);
            }
        }

        if (g_ESPBox) {
            Vec3 head = getBone(e, 4), foot = getBone(e, 7);
            CGPoint hp = worldToScreen(head), fp = worldToScreen(foot);
            if (!CGPointEqualToPoint(hp, CGPointZero) &&
                !CGPointEqualToPoint(fp, CGPointZero)) {
                float h = fp.y - hp.y, w = h * 0.4f;
                CGContextSetRGBStrokeColor(ctx, 0.2f, 1, 0.2f, 1);
                CGContextStrokeRect(ctx, CGRectMake(hp.x - w/2, hp.y, w, h));
            }
        }

        if (g_ESPSkeleton) {
            CGContextSetRGBStrokeColor(ctx, 1, 1, 0, 1);
            int pairs = (int)(sizeof(SKELETON) / (sizeof(int)*2));
            for (int p = 0; p < pairs; p++) {
                Vec3 b1 = getBone(e, SKELETON[p][0]);
                Vec3 b2 = getBone(e, SKELETON[p][1]);
                CGPoint p1 = worldToScreen(b1), p2 = worldToScreen(b2);
                if (CGPointEqualToPoint(p1, CGPointZero) ||
                    CGPointEqualToPoint(p2, CGPointZero)) continue;
                CGContextMoveToPoint(ctx, p1.x, p1.y);
                CGContextAddLineToPoint(ctx, p2.x, p2.y);
                CGContextStrokePath(ctx);
            }
        }
    }
}

@end

static AtlasESPView* g_ESPView = nil;

// ═══════════════════════════════════════
// GAME LOOP HOOK — Update() function
// VP matrix + aimbot tick disini
// ═══════════════════════════════════════

static void (*orig_gameLoop)(void*);
static void hook_gameLoop(void* thiz) {
    orig_gameLoop(thiz);
    if (!g_CheatActive) return;
    Aimbot_Tick();
    // ESP redraw
    if (g_ESPView && (g_ESPLine || g_ESPBox || g_ESPSkeleton)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [g_ESPView setNeedsDisplay];
        });
    }
}

// ═══════════════════════════════════════
// GUI — MENU
// ═══════════════════════════════════════

@interface AtlasSwitch : UIView
@property bool* target;
@property UILabel* lbl;
@property UISwitch* sw;
- (instancetype)initWithLabel:(NSString*)label boolPtr:(bool*)ptr yPos:(float)y width:(float)w;
@end

@implementation AtlasSwitch
- (instancetype)initWithLabel:(NSString*)label boolPtr:(bool*)ptr yPos:(float)y width:(float)w {
    self = [super initWithFrame:CGRectMake(0, y, w, 44)];
    _target = ptr;
    _lbl = [[UILabel alloc] initWithFrame:CGRectMake(14, 0, w-80, 44)];
    _lbl.text = label;
    _lbl.textColor = UIColor.whiteColor;
    _lbl.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    [self addSubview:_lbl];
    _sw = [[UISwitch alloc] initWithFrame:CGRectMake(w-66, 7, 0, 0)];
    _sw.on = *ptr;
    _sw.onTintColor = [UIColor colorWithRed:.2 green:.7 blue:1 alpha:1];
    [_sw addTarget:self action:@selector(changed) forControlEvents:UIControlEventValueChanged];
    [self addSubview:_sw];
    return self;
}
- (void)changed { *_target = _sw.on; }
@end

@interface AtlasMenuVC : UIViewController @end
@implementation AtlasMenuVC

- (void)viewDidLoad {
    [super viewDidLoad];
    CGRect f = self.view.bounds;
    self.view.backgroundColor = [UIColor colorWithRed:.05 green:.05 blue:.1 alpha:.95];
    self.view.layer.cornerRadius = 18;
    self.view.layer.borderWidth = 1;
    self.view.layer.borderColor = [UIColor colorWithRed:.4 green:.7 blue:1 alpha:1].CGColor;

    UILabel* title = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, f.size.width, 46)];
    title.text = @"⚡ Atlas Mod OB54";
    title.textColor = [UIColor colorWithRed:.4 green:.9 blue:1 alpha:1];
    title.font = [UIFont boldSystemFontOfSize:17];
    title.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:title];

    UIButton* x = [UIButton buttonWithType:UIButtonTypeSystem];
    x.frame = CGRectMake(f.size.width-42, 8, 34, 30);
    [x setTitle:@"✕" forState:UIControlStateNormal];
    [x setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    x.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
    [x addTarget:self action:@selector(closeMenu) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:x];

    UIScrollView* scroll = [[UIScrollView alloc]
        initWithFrame:CGRectMake(0, 46, f.size.width, f.size.height-46)];
    [self.view addSubview:scroll];

    NSArray* sections = @[
        @[@"ANTICHEAT", @[
            @[@"🖥  Logo PC (ON sebelum login)", [NSValue valueWithPointer:&g_LogoPC]],
            @[@"📺  Stream Proof",               [NSValue valueWithPointer:&g_StreamProof]],
        ]],
        @[@"AIMBOT", @[
            @[@"🎯  Aimbot Head",  [NSValue valueWithPointer:&g_AimbotHead]],
            @[@"🎯  Aimbot Body",  [NSValue valueWithPointer:&g_AimbotBody]],
            @[@"🎯  Aimbot Neck",  [NSValue valueWithPointer:&g_AimbotNeck]],
            @[@"🎯  Aimbot Leg",   [NSValue valueWithPointer:&g_AimbotLeg]],
            @[@"👻  Aim Silent",   [NSValue valueWithPointer:&g_AimSilent]],
        ]],
        @[@"ESP", @[
            @[@"📍  ESP Line",     [NSValue valueWithPointer:&g_ESPLine]],
            @[@"📦  ESP Box",      [NSValue valueWithPointer:&g_ESPBox]],
            @[@"🦴  ESP Skeleton", [NSValue valueWithPointer:&g_ESPSkeleton]],
        ]],
    ];

    float y = 8;
    for (NSArray* sec in sections) {
        UILabel* secLbl = [[UILabel alloc] initWithFrame:CGRectMake(14, y, f.size.width-28, 20)];
        secLbl.text = sec[0];
        secLbl.textColor = [UIColor colorWithRed:.4 green:.9 blue:1 alpha:.7];
        secLbl.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
        [scroll addSubview:secLbl];
        y += 22;
        for (NSArray* item in sec[1]) {
            bool* ptr = (bool*)((NSValue*)item[1]).pointerValue;
            AtlasSwitch* row = [[AtlasSwitch alloc]
                initWithLabel:item[0] boolPtr:ptr yPos:y width:f.size.width];
            [scroll addSubview:row];
            y += 48;
        }
        y += 8;
    }

    UILabel* fovLbl = [[UILabel alloc] initWithFrame:CGRectMake(14, y, 200, 20)];
    fovLbl.text = @"Aim FOV";
    fovLbl.textColor = UIColor.lightGrayColor;
    fovLbl.font = [UIFont systemFontOfSize:12];
    [scroll addSubview:fovLbl];
    y += 22;

    UISlider* sl = [[UISlider alloc] initWithFrame:CGRectMake(14, y, f.size.width-28, 30)];
    sl.minimumValue = 30; sl.maximumValue = 360; sl.value = g_AimFOV;
    sl.minimumTrackTintColor = [UIColor colorWithRed:.2 green:.7 blue:1 alpha:1];
    [sl addTarget:self action:@selector(fovChanged:) forControlEvents:UIControlEventValueChanged];
    [scroll addSubview:sl];
    y += 40;

    scroll.contentSize = CGSizeMake(f.size.width, y+10);
}

- (void)closeMenu {
    g_MenuVisible = NO;
    g_OverlayWindow.hidden = YES;
}

- (void)fovChanged:(UISlider*)sl { g_AimFOV = sl.value; }

@end

static void MenuUI_Init() {
    dispatch_async(dispatch_get_main_queue(), ^{
        CGRect s = UIScreen.mainScreen.bounds;

        // ESP overlay window
        UIWindow* espWin = [[UIWindow alloc] initWithFrame:s];
        espWin.windowLevel = UIWindowLevelAlert + 50;
        espWin.backgroundColor = UIColor.clearColor;
        espWin.userInteractionEnabled = NO;
        espWin.rootViewController = [UIViewController new];
        [espWin makeKeyAndVisible];

        g_ESPView = [[AtlasESPView alloc] initWithFrame:s];
        [espWin.rootViewController.view addSubview:g_ESPView];

        // Menu window
        g_OverlayWindow = [[UIWindow alloc]
            initWithFrame:CGRectMake(s.size.width*.05,
                                     s.size.height*.1, 290, 560)];
        g_OverlayWindow.windowLevel = UIWindowLevelAlert + 100;
        g_OverlayWindow.backgroundColor = UIColor.clearColor;
        g_OverlayWindow.rootViewController = [AtlasMenuVC new];
        [g_OverlayWindow makeKeyAndVisible];
        g_OverlayWindow.hidden = YES;
    });
}

// ═══════════════════════════════════════
// TRIPLE TAP — TOGGLE MENU
// ═══════════════════════════════════════

static void (*orig_sendEvent)(id,SEL,UIEvent*);
static void hook_sendEvent(id self, SEL _cmd, UIEvent* event) {
    static int tapCount = 0;
    static NSTimeInterval lastTap = 0;
    if (event.type == UIEventTypeTouches) {
        for (UITouch* t in [event allTouches]) {
            if (t.phase == UITouchPhaseEnded) {
                NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
                tapCount = (now - lastTap < 0.5) ? tapCount+1 : 1;
                lastTap = now;
                if (tapCount >= 3) {
                    tapCount = 0;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        g_MenuVisible = !g_MenuVisible;
                        g_OverlayWindow.hidden = !g_MenuVisible;
                    });
                }
            }
        }
    }
    orig_sendEvent(self, _cmd, event);
}

// ═══════════════════════════════════════
// HOOK INSTALLER — register semua function hooks
// Guna MSHookFunction dengan RVA + base
// ═══════════════════════════════════════

static void GameHooks_Init(uintptr_t base) {
    // VP Matrix hook — intercept setiap kali game compute VP
    void* vpFn = (void*)(base + RVA_GetUnityVPMatrix);
    MSHookFunction(vpFn, (void*)hook_getVP, (void**)&orig_getVP);

    // PlayerCount hook — ambik manager ptr
    void* pcFn = (void*)(base + RVA_GetPlayerCount);
    MSHookFunction(pcFn, (void*)hook_GetPlayerCount,
        (void**)&orig_GetPlayerCount);
    fn_GetPlayerCount = (GetPlayerCount_t)orig_GetPlayerCount;

    // GetPlayer function pointer
    fn_GetPlayer = (GetPlayer_t)(base + RVA_GetPlayer);

    // GetLocalPlayer hook — capture localplayer ptr
    void* lpFn = (void*)(base + RVA_GetLocalPlayer);
    MSHookFunction(lpFn, (void*)hook_GetLocalPlayer,
        (void**)&orig_GetLocalPlayer);
    fn_GetLocalPlayer = (GetLocalPlayer_t)orig_GetLocalPlayer;

    // GameState hook
    void* gsFn = (void*)(base + RVA_get_CurrentState);
    MSHookFunction(gsFn, (void*)hook_get_CurrentState,
        (void**)&orig_get_CurrentState);

    // GameLoop hook (Unity Update)
    void* glFn = (void*)(base + RVA_Update);
    MSHookFunction(glFn, (void*)hook_gameLoop, (void**)&orig_gameLoop);

    // Integrity patch — VerifySignature only
    IntegrityPatcher_Init(base);
}

// ═══════════════════════════════════════
// CONSTRUCTOR — ENTRY POINT
// ═══════════════════════════════════════

__attribute__((constructor))
static void AtlasMod_Load() {
    NSLog(@"[AtlasMod] OB54 boot — Il2Cpp v31 arm64");

    // Layer yang tak perlu offset — init dulu
    HardwareSpoof_Init();
    LogoPC_Init();
    MemoryWiper_Init();
    NetworkGuard_Init();
    JailbreakBypass_Init();
    StreamProof_Init();
    AntiDebug_Init();

    // sendEvent triple-tap
    MSHookMessageEx([UIApplication class],
        @selector(sendEvent:),
        (IMP)hook_sendEvent, (IMP*)&orig_sendEvent);

    // Game hooks — cari base dulu
    uintptr_t base = getBase();
    if (base) {
        NSLog(@"[AtlasMod] base=0x%lx — installing game hooks", base);
        GameHooks_Init(base);
    } else {
        NSLog(@"[AtlasMod] WARN: base not found — game hooks skipped");
    }

    // Menu init — delay 2s untuk game UI settle
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
        (int64_t)(2.0 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
        MenuUI_Init();
        NSLog(@"[AtlasMod] Ready — triple tap untuk menu");
    });
}
