#import <Foundation/Foundation.h>
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

// ═══════════════════════════════════════
// STRUCTS & GLOBALS
// ═══════════════════════════════════════

typedef struct { float x, y, z; } Vec3;
typedef struct { float m[4][4]; } Matrix4x4;

#define FF_BUNDLE @"com.dts.freefireth"

// Offsets OB54 — update tiap patch via IDA
#define OFF_BONE_BASE      0x12A4F8C0
#define OFF_VIEWMATRIX     0x13B2C010
#define OFF_PLAYERLIST     0x12F3A200
#define OFF_LOCALPLAYER    0x12F3A100
#define OFF_AIMSYSTEM      0x129E4400
#define OFF_BULLETTP       0x12A11200
#define OFF_GAMESTATE      0x13C4A200

// Feature toggles
static bool g_AimbotHead  = false;
static bool g_AimbotBody  = false;
static bool g_AimbotNeck  = false;
static bool g_AimbotLeg   = false;
static float g_AimFOV     = 150.0f;
static bool g_AimSilent   = false;
static bool g_AimKill     = false;
static bool g_ESPLine     = false;
static bool g_ESPBox      = false;
static bool g_ESPSkeleton = false;
static bool g_StreamProof = false;
static bool g_MenuVisible = false;
static bool g_CheatActive = false;

static UIWindow* g_OverlayWindow = nil;
static NSUUID*   g_SpoofedUUID   = nil;

// Skeleton bone pairs FF OB54
static const int SKELETON[][2] = {
    {4,3},{3,1},{1,2},{2,5},{5,6},
    {1,8},{8,9},{9,10},
    {1,11},{11,12},{12,13}
};

// ═══════════════════════════════════════
// HELPERS
// ═══════════════════════════════════════

static uintptr_t getBase() {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char* n = _dyld_get_image_name(i);
        if (strstr(n,"UnityFramework") || strstr(n,"FreeFire"))
            return (uintptr_t)_dyld_get_image_header(i);
    }
    return 0;
}

static CGPoint worldToScreen(Vec3 pos, Matrix4x4 vp) {
    float cx = pos.x*vp.m[0][0]+pos.y*vp.m[1][0]+pos.z*vp.m[2][0]+vp.m[3][0];
    float cy = pos.x*vp.m[0][1]+pos.y*vp.m[1][1]+pos.z*vp.m[2][1]+vp.m[3][1];
    float cw = pos.x*vp.m[0][3]+pos.y*vp.m[1][3]+pos.z*vp.m[2][3]+vp.m[3][3];
    if (cw <= 0) return CGPointZero;
    CGSize s = UIScreen.mainScreen.bounds.size;
    return CGPointMake((1+cx/cw)*s.width*.5f,(1-cy/cw)*s.height*.5f);
}

static Vec3 getBone(uintptr_t player, int boneID) {
    Vec3 v = {0,0,0};
    uintptr_t bones = *(uintptr_t*)(player + 0x138);
    if (!bones) return v;
    memcpy(&v,(void*)(bones + boneID*0x30),sizeof(Vec3));
    return v;
}

static void patchAddr(uintptr_t addr) {
    uint32_t patch[] = { 0xD2800020, 0xD65F03C0 }; // mov x0,1 ; ret
    vm_protect(mach_task_self(),addr,sizeof(patch),false,
        VM_PROT_READ|VM_PROT_WRITE|VM_PROT_EXECUTE);
    memcpy((void*)addr,patch,sizeof(patch));
    sys_icache_invalidate((void*)addr,sizeof(patch));
    vm_protect(mach_task_self(),addr,sizeof(patch),false,
        VM_PROT_READ|VM_PROT_EXECUTE);
}

// ═══════════════════════════════════════
// LAYER 1 — HARDWARE SPOOF
// ═══════════════════════════════════════

static NSUUID* (*orig_idfv)(id,SEL);
static NSUUID* hook_idfv(id self, SEL _cmd) {
    if (!g_SpoofedUUID) {
        NSUserDefaults* d = NSUserDefaults.standardUserDefaults;
        NSString* s = [d stringForKey:@"atlas_uuid"];
        g_SpoofedUUID = s ? [[NSUUID alloc] initWithUUIDString:s]
                          : [NSUUID UUID];
        if (!s) {
            [d setObject:g_SpoofedUUID.UUIDString forKey:@"atlas_uuid"];
            [d synchronize];
        }
    }
    return g_SpoofedUUID;
}

static int (*orig_sysctl)(const char*,void*,size_t*,void*,size_t);
static int hook_sysctl(const char* name,void* oldp,size_t* oldlenp,
                        void* newp,size_t newlen) {
    int r = orig_sysctl(name,oldp,oldlenp,newp,newlen);
    if (r==0 && oldp) {
        if (strcmp(name,"hw.machine")==0)
            strlcpy((char*)oldp,"iPhone13,2",*oldlenp);
        if (strcmp(name,"hw.model")==0)
            strlcpy((char*)oldp,"D53gAP",*oldlenp);
    }
    return r;
}

static void HardwareSpoof_Init() {
    MSHookMessageEx([UIDevice class],
        @selector(identifierForVendor),
        (IMP)hook_idfv,(IMP*)&orig_idfv);
    MSHookFunction((void*)sysctlbyname,
        (void*)hook_sysctl,(void**)&orig_sysctl);
}

// ═══════════════════════════════════════
// LAYER 2 — MEMORY WIPER
// ═══════════════════════════════════════

static const char* (*orig_imageName)(uint32_t);
static const char* hook_imageName(uint32_t idx) {
    const char* n = orig_imageName(idx);
    if (n && (strstr(n,"AtlasMod")||strstr(n,"substrate")||
              strstr(n,"MobileSubstrate")||strstr(n,"CydiaSubstrate")))
        return "/usr/lib/system/libsystem_c.dylib";
    return n;
}

static uint32_t (*orig_imageCount)(void);
static uint32_t hook_imageCount(void) {
    uint32_t real = orig_imageCount();
    uint32_t hidden = 0;
    for (uint32_t i=0;i<real;i++) {
        const char* n = orig_imageName(i);
        if (n&&(strstr(n,"AtlasMod")||strstr(n,"substrate"))) hidden++;
    }
    return real - hidden;
}

static void MemoryWiper_Init() {
    MSHookFunction((void*)_dyld_get_image_name,
        (void*)hook_imageName,(void**)&orig_imageName);
    MSHookFunction((void*)_dyld_image_count,
        (void*)hook_imageCount,(void**)&orig_imageCount);
}

// ═══════════════════════════════════════
// LAYER 3 — NETWORK GUARD
// ═══════════════════════════════════════

static NSSet* g_BlockedHosts = nil;

static void initBlockList() {
    g_BlockedHosts = [NSSet setWithArray:@[
        @"telemetry.freefiremobile.com",
        @"anti.freefiremobile.com",
        @"report.freefiremobile.com",
        @"accheck.garena.com",
        @"security.garena.com",
        @"detect.garena.com",
        @"monitor.garena.com",
        @"log.garena.com",
        @"analytics.garena.com",
        @"ac.freefire.com",
        @"clientlog.freefiremobile.com",
        @"crash.freefiremobile.com",
    ]];
}

static BOOL isBlocked(NSString* host) {
    if (!host) return NO;
    for (NSString* b in g_BlockedHosts)
        if ([host containsString:b]) return YES;
    return NO;
}

static id (*orig_dataTask)(id,SEL,NSURLRequest*,id);
static id hook_dataTask(id self,SEL _cmd,NSURLRequest* req,id cb) {
    if (isBlocked(req.URL.host)) {
        dispatch_async(dispatch_get_main_queue(),^{
            if (cb) {
                NSHTTPURLResponse* r = [[NSHTTPURLResponse alloc]
                    initWithURL:req.URL statusCode:200
                    HTTPVersion:@"HTTP/1.1" headerFields:@{}];
                ((void(^)(NSData*,NSURLResponse*,NSError*))cb)
                    ([NSData data],r,nil);
            }
        });
        return nil;
    }
    return orig_dataTask(self,_cmd,req,cb);
}

static void NetworkGuard_Init() {
    initBlockList();
    MSHookMessageEx(NSClassFromString(@"NSURLSession"),
        @selector(dataTaskWithRequest:completionHandler:),
        (IMP)hook_dataTask,(IMP*)&orig_dataTask);
}

// ═══════════════════════════════════════
// LAYER 4 — TIMING NORMALIZER
// ═══════════════════════════════════════

static NSTimeInterval g_LastAimTime = 0;

static BOOL shouldAim() {
    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    if (now - g_LastAimTime < 0.016f) return NO;
    if ((arc4random()%100) < 2) return NO; // 2% miss simulate human
    g_LastAimTime = now;
    return YES;
}

static Vec3 smoothAim(Vec3 cur, Vec3 tgt) {
    float spd = 0.15f + ((float)(arc4random()%10)/100.0f);
    return (Vec3){
        cur.x+(tgt.x-cur.x)*spd,
        cur.y+(tgt.y-cur.y)*spd,
        cur.z+(tgt.z-cur.z)*spd
    };
}

// ═══════════════════════════════════════
// LAYER 5 — STREAM PROOF
// ═══════════════════════════════════════

static BOOL (*orig_isRecording)(id,SEL);
static BOOL hook_isRecording(id self,SEL _cmd) {
    if (g_StreamProof) return NO;
    return orig_isRecording(self,_cmd);
}

static void onCapture(CFNotificationCenterRef c,void* o,
    CFNotificationName n,const void* obj,CFDictionaryRef i) {
    if (!g_StreamProof) return;
    dispatch_async(dispatch_get_main_queue(),^{
        g_OverlayWindow.hidden = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(0.5*NSEC_PER_SEC)),
            dispatch_get_main_queue(),^{
            if (!g_MenuVisible) return;
            g_OverlayWindow.hidden = NO;
        });
    });
}

static void StreamProof_Init() {
    Class rp = NSClassFromString(@"RPScreenRecorder");
    if (rp) MSHookMessageEx(rp,@selector(isRecording),
        (IMP)hook_isRecording,(IMP*)&orig_isRecording);
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetLocalCenter(),NULL,onCapture,
        CFSTR("UIApplicationUserDidTakeScreenshotNotification"),
        NULL,CFNotificationSuspensionBehaviorDeliverImmediately);
}

// ═══════════════════════════════════════
// LAYER 6 — INTEGRITY PATCHER
// ═══════════════════════════════════════

static void IntegrityPatcher_Init(uintptr_t base) {
    uintptr_t targets[] = {
        base+0x03F2A100, // MemoryIntegrityCheck
        base+0x04A33200, // SignatureVerify
        base+0x03B11400, // DylibScanCheck
        base+0x04C22100, // AntiDebugCheck
        base+0x03D44500, // RootCheck
        base+0x04E55600, // TweakDetector
        base+0x03F66700, // HookDetector
        base+0x04122800, // TimingCheck
        base+0x03C77900, // EnvironmentCheck
    };
    for (int i=0;i<sizeof(targets)/sizeof(uintptr_t);i++)
        patchAddr(targets[i]);
}

// ═══════════════════════════════════════
// LAYER 7 — LOBBY IDLE MODE
// ═══════════════════════════════════════

typedef enum { S_Lobby=0,S_Loading=1,S_InGame=2,S_Ended=3 } GameState;
static GameState g_State = S_Lobby;

static void LobbyIdle_Tick(uintptr_t base) {
    GameState ns = (GameState)(*(int*)(base+OFF_GAMESTATE));
    if (ns == g_State) return;
    g_State = ns;
    switch(ns) {
        case S_Lobby:
        case S_Loading:
            g_CheatActive = false;
            break;
        case S_InGame:
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(3.0*NSEC_PER_SEC)),
                dispatch_get_main_queue(),^{
                g_CheatActive = true;
            });
            break;
        case S_Ended:
            g_CheatActive = false;
            break;
    }
}

// ═══════════════════════════════════════
// ANTI-DEBUG
// ═══════════════════════════════════════

typedef int (*ptrace_t)(int,pid_t,caddr_t,int);
static ptrace_t orig_ptrace;
static int hook_ptrace(int req,pid_t pid,caddr_t addr,int data) {
    if (req==31) return 0;
    return orig_ptrace(req,pid,addr,data);
}

static void AntiDebug_Init() {
    MSHookFunction((void*)dlsym(RTLD_DEFAULT,"ptrace"),
        (void*)hook_ptrace,(void**)&orig_ptrace);
}

// ═══════════════════════════════════════
// AIMBOT
// ═══════════════════════════════════════

static void Aimbot_Tick(uintptr_t local,uintptr_t* enemies,
                         int count,Matrix4x4 vp) {
    if (!g_AimbotHead&&!g_AimbotBody&&!g_AimbotNeck&&!g_AimbotLeg) return;
    if (!shouldAim()) return;

    CGSize s = UIScreen.mainScreen.bounds.size;
    CGPoint center = CGPointMake(s.width/2,s.height/2);

    int boneID = g_AimbotHead?4:g_AimbotNeck?3:g_AimbotBody?1:7;

    uintptr_t best = 0;
    float bestDist = g_AimFOV;
    Vec3 bestBone = {0,0,0};

    for (int i=0;i<count;i++) {
        if (!enemies[i]) continue;
        Vec3 bone = getBone(enemies[i],boneID);
        CGPoint sp = worldToScreen(bone,vp);
        if (CGPointEqualToPoint(sp,CGPointZero)) continue;
        float dx=sp.x-center.x, dy=sp.y-center.y;
        float dist=sqrtf(dx*dx+dy*dy);
        if (dist<bestDist) { bestDist=dist; best=enemies[i]; bestBone=bone; }
    }
    if (!best) return;

    uintptr_t base = getBase();

    if (g_AimSilent) {
        uintptr_t bs = *(uintptr_t*)(base+OFF_BULLETTP);
        if (bs) memcpy((void*)(bs+0x48),&bestBone,sizeof(Vec3));
    } else {
        uintptr_t as = *(uintptr_t*)(base+OFF_AIMSYSTEM);
        if (as) {
            float h = atan2f(bestBone.z,bestBone.x);
            float v = atan2f(bestBone.y,sqrtf(bestBone.x*bestBone.x+bestBone.z*bestBone.z));
            memcpy((void*)(as+0x10),&h,4);
            memcpy((void*)(as+0x14),&v,4);
        }
    }

    if (g_AimKill) {
        float dmg = 9999.0f;
        memcpy((void*)(base+0x12B44200),&dmg,4);
    }
}

// ═══════════════════════════════════════
// ESP
// ═══════════════════════════════════════

static void ESP_Draw(CGContextRef ctx,uintptr_t* enemies,
                     int count,Matrix4x4 vp) {
    CGSize s = UIScreen.mainScreen.bounds.size;
    CGContextSetLineWidth(ctx,1.5f);
    CGPoint myPos = CGPointMake(s.width/2,s.height);

    for (int i=0;i<count;i++) {
        if (!enemies[i]) continue;
        uintptr_t bones = *(uintptr_t*)(enemies[i]+0x138);
        if (!bones) continue;

        // Line
        if (g_ESPLine) {
            Vec3 foot={0,0,0};
            memcpy(&foot,(void*)(bones+1*0x30),sizeof(Vec3));
            CGPoint fp=worldToScreen(foot,vp);
            if (!CGPointEqualToPoint(fp,CGPointZero)) {
                CGContextSetRGBStrokeColor(ctx,1,0,0,1);
                CGContextMoveToPoint(ctx,myPos.x,myPos.y);
                CGContextAddLineToPoint(ctx,fp.x,fp.y);
                CGContextStrokePath(ctx);
            }
        }

        // Box
        if (g_ESPBox) {
            Vec3 head={0,0,0},foot={0,0,0};
            memcpy(&head,(void*)(bones+4*0x30),sizeof(Vec3));
            memcpy(&foot,(void*)(bones+7*0x30),sizeof(Vec3));
            CGPoint hp=worldToScreen(head,vp),fp=worldToScreen(foot,vp);
            if (!CGPointEqualToPoint(hp,CGPointZero)&&
                !CGPointEqualToPoint(fp,CGPointZero)) {
                float h=fp.y-hp.y, w=h*0.4f;
                CGContextSetRGBStrokeColor(ctx,0,1,0,1);
                CGContextStrokeRect(ctx,CGRectMake(hp.x-w/2,hp.y,w,h));
            }
        }

        // Skeleton
        if (g_ESPSkeleton) {
            CGContextSetRGBStrokeColor(ctx,1,1,0,1);
            int pairs=sizeof(SKELETON)/(sizeof(int)*2);
            for (int p=0;p<pairs;p++) {
                Vec3 b1={0,0,0},b2={0,0,0};
                memcpy(&b1,(void*)(bones+SKELETON[p][0]*0x30),sizeof(Vec3));
                memcpy(&b2,(void*)(bones+SKELETON[p][1]*0x30),sizeof(Vec3));
                CGPoint p1=worldToScreen(b1,vp),p2=worldToScreen(b2,vp);
                if (CGPointEqualToPoint(p1,CGPointZero)||
                    CGPointEqualToPoint(p2,CGPointZero)) continue;
                CGContextMoveToPoint(ctx,p1.x,p1.y);
                CGContextAddLineToPoint(ctx,p2.x,p2.y);
                CGContextStrokePath(ctx);
            }
        }
    }
}

// ═══════════════════════════════════════
// GUI — iPhone Style Menu
// ═══════════════════════════════════════

@interface AtlasSwitch : UIView
@property bool* target;
@property UILabel* lbl;
@property UISwitch* sw;
- (instancetype)initWithLabel:(NSString*)label boolPtr:(bool*)ptr yPos:(float)y width:(float)w;
@end

@implementation AtlasSwitch
- (instancetype)initWithLabel:(NSString*)label boolPtr:(bool*)ptr yPos:(float)y width:(float)w {
    self = [super initWithFrame:CGRectMake(0,y,w,44)];
    _target = ptr;
    _lbl = [[UILabel alloc] initWithFrame:CGRectMake(14,0,w-80,44)];
    _lbl.text = label;
    _lbl.textColor = UIColor.whiteColor;
    _lbl.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    [self addSubview:_lbl];
    _sw = [[UISwitch alloc] initWithFrame:CGRectMake(w-66,7,0,0)];
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

    // Background
    self.view.backgroundColor = [UIColor colorWithRed:.05 green:.05 blue:.1 alpha:.93];
    self.view.layer.cornerRadius = 18;
    self.view.layer.borderWidth = 1;
    self.view.layer.borderColor = [UIColor colorWithRed:.4 green:.7 blue:1 alpha:1].CGColor;

    // Title
    UILabel* title = [[UILabel alloc] initWithFrame:CGRectMake(0,0,f.size.width,46)];
    title.text = @"⚡ Atlas Mod";
    title.textColor = [UIColor colorWithRed:.4 green:.9 blue:1 alpha:1];
    title.font = [UIFont boldSystemFontOfSize:17];
    title.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:title];

    // Close btn
    UIButton* x = [UIButton buttonWithType:UIButtonTypeSystem];
    x.frame = CGRectMake(f.size.width-42,8,34,30);
    [x setTitle:@"✕" forState:UIControlStateNormal];
    [x setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    x.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
    [x addTarget:self action:@selector(closeMenu) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:x];

    // Scroll
    UIScrollView* scroll = [[UIScrollView alloc]
        initWithFrame:CGRectMake(0,46,f.size.width,f.size.height-46)];
    [self.view addSubview:scroll];

    // Toggles
    NSArray* items = @[
        @[@"Aimbot Head",   [NSValue valueWithPointer:&g_AimbotHead]],
        @[@"Aimbot Body",   [NSValue valueWithPointer:&g_AimbotBody]],
        @[@"Aimbot Neck",   [NSValue valueWithPointer:&g_AimbotNeck]],
        @[@"Aimbot Leg",    [NSValue valueWithPointer:&g_AimbotLeg]],
        @[@"Aim Silent",    [NSValue valueWithPointer:&g_AimSilent]],
        @[@"Aim Kill",      [NSValue valueWithPointer:&g_AimKill]],
        @[@"ESP Line",      [NSValue valueWithPointer:&g_ESPLine]],
        @[@"ESP Box",       [NSValue valueWithPointer:&g_ESPBox]],
        @[@"ESP Skeleton",  [NSValue valueWithPointer:&g_ESPSkeleton]],
        @[@"Stream Proof",  [NSValue valueWithPointer:&g_StreamProof]],
    ];

    float y = 8;
    for (NSArray* item in items) {
        bool* ptr = (bool*)((NSValue*)item[1]).pointerValue;
        AtlasSwitch* row = [[AtlasSwitch alloc]
            initWithLabel:item[0] boolPtr:ptr yPos:y width:f.size.width];
        [scroll addSubview:row];
        y += 48;
    }

    // FOV Label
    UILabel* fovLbl = [[UILabel alloc] initWithFrame:CGRectMake(14,y,200,20)];
    fovLbl.text = @"Aim FOV";
    fovLbl.textColor = UIColor.lightGrayColor;
    fovLbl.font = [UIFont systemFontOfSize:12];
    [scroll addSubview:fovLbl];
    y += 22;

    // FOV Slider
    UISlider* sl = [[UISlider alloc] initWithFrame:CGRectMake(14,y,f.size.width-28,30)];
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
    dispatch_async(dispatch_get_main_queue(),^{
        CGRect s = UIScreen.mainScreen.bounds;
        g_OverlayWindow = [[UIWindow alloc]
            initWithFrame:CGRectMake(s.size.width*.05,
                                     s.size.height*.1, 280, 520)];
        g_OverlayWindow.windowLevel = UIWindowLevelAlert+100;
        g_OverlayWindow.backgroundColor = UIColor.clearColor;
        g_OverlayWindow.rootViewController = [AtlasMenuVC new];
        [g_OverlayWindow makeKeyAndVisible];
        g_OverlayWindow.hidden = YES;
    });
}

// ═══════════════════════════════════════
// TRIPLE TAP DETECT
// ═══════════════════════════════════════

static void (*orig_sendEvent)(id,SEL,UIEvent*);
static void hook_sendEvent(id self,SEL _cmd,UIEvent* event) {
    static int tapCount = 0;
    static NSTimeInterval lastTap = 0;

    if (event.type == UIEventTypeTouches) {
        for (UITouch* t in [event allTouches]) {
            if (t.phase == UITouchPhaseEnded) {
                NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
                tapCount = (now-lastTap < 0.5) ? tapCount+1 : 0;
                lastTap = now;
                if (tapCount >= 2) {
                    tapCount = 0;
                    dispatch_async(dispatch_get_main_queue(),^{
                        g_MenuVisible = !g_MenuVisible;
                        g_OverlayWindow.hidden = !g_MenuVisible;
                    });
                }
            }
        }
    }
    orig_sendEvent(self,_cmd,event);
}

// ═══════════════════════════════════════
// GAME LOOP HOOK
// ═══════════════════════════════════════

static void (*orig_gameLoop)(void);
static void hook_gameLoop(void) {
    orig_gameLoop();

    uintptr_t base = getBase();
    if (!base) return;

    LobbyIdle_Tick(base);
    if (!g_CheatActive) return;

    uintptr_t playerList  = *(uintptr_t*)(base+OFF_PLAYERLIST);
    uintptr_t localPlayer = *(uintptr_t*)(base+OFF_LOCALPLAYER);
    if (!playerList||!localPlayer) return;

    Matrix4x4 vp;
    memcpy(&vp,(void*)(base+OFF_VIEWMATRIX),sizeof(Matrix4x4));

    uintptr_t enemies[50]={0};
    int enemyCount=0;
    uintptr_t listPtr=*(uintptr_t*)(playerList+0x18);
    int total=MIN(*(int*)(playerList+0x10),50);

    for (int i=0;i<total;i++) {
        uintptr_t ent=*(uintptr_t*)(listPtr+i*8);
        if (!ent||ent==localPlayer) continue;
        enemies[enemyCount++]=ent;
    }

    Aimbot_Tick(localPlayer,enemies,enemyCount,vp);
    // ESP render via overlay — hook UIView draw kalau nak realtime
}

// ═══════════════════════════════════════
// CONSTRUCTOR — ENTRY POINT
// ═══════════════════════════════════════

__attribute__((constructor))
static void AtlasMod_Load() {
    NSLog(@"[AtlasMod] Loading OB54...");

    uintptr_t base = getBase();

    HardwareSpoof_Init();
    MemoryWiper_Init();
    NetworkGuard_Init();
    StreamProof_Init();
    AntiDebug_Init();
    IntegrityPatcher_Init(base);

    // Game loop hook — update offset tiap patch
    uintptr_t loopAddr = base + 0x01234ABC;
    MSHookFunction((void*)loopAddr,
        (void*)hook_gameLoop,(void**)&orig_gameLoop);

    // UIApplication hook
    MSHookMessageEx(UIApplication.class,
        @selector(sendEvent:),
        (IMP)hook_sendEvent,(void**)&orig_sendEvent);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
        (int64_t)(2.0*NSEC_PER_SEC)),
        dispatch_get_main_queue(),^{
        MenuUI_Init();
        NSLog(@"[AtlasMod] Ready — triple tap untuk menu");
    });
}
