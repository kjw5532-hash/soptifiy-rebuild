// QualityBadge — Spotify 플레이어 재생바 가운데에 Apple Music 스타일 음질 배지를 표시합니다.
// 순수 Objective-C 런타임만 사용합니다 (Theos / CydiaSubstrate 불필요).
//
// 음질 값 (SPTPreferences audioPlayBitrate): 1 낮음, 2 보통, 3 높음, 4 매우 높음, 5/6 무손실
// 표시: 낮음→데이터 절약, 보통→일반음질, 높음→고음질, 매우 높음→무손실

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <Network/Network.h>

// 1이면 배지 끝에 원시 음질 값이 붙습니다 (예: "고음질 3"). 확인이 끝나면 0으로 바꾸세요.
#define QB_DEBUG 1

static NSString *const kPrefsClass  = @"_TtC31Preferences_CorePreferencesImpl28SPTPreferencesImplementation";
static NSString *const kPlayerClass = @"_TtC20NowPlaying_ModesImpl20FloatingElementsUnit";
static NSString *const kSavedKey    = @"spotifyglass.lossless.savedQuality"; // Vitrine이 로컬 FLAC 재생 중 저장

static __weak id gPrefs;
static BOOL gExpensive;                       // 셀룰러 등 종량제 네트워크 여부
static __weak UILabel *gLeft, *gRight;        // 재생바 시간 라벨
static UIView *gBadge;
static UILabel *gBadgeLabel;
static UIImageView *gBadgeIcon;
static CFAbsoluteTime gLastLayout;
static nw_path_monitor_t gMonitor;

#pragma mark - 로그

static void QBLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[QualityBadge] %@", s);
}

#pragma mark - 음질 읽기

static NSInteger QBReadLevel(void) {
    id p = gPrefs;
    if (!p) return -1;
    SEL sel = gExpensive ? NSSelectorFromString(@"audioPlayBitrate")
                         : NSSelectorFromString(@"audioPlayBitrateNonMetered");
    if (![p respondsToSelector:sel]) return -1;
    return ((NSInteger (*)(id, SEL))objc_msgSend)(p, sel);
}

// 배지에 쓸 문구를 반환. 없으면 NO.
static BOOL QBCurrentText(NSString **text, BOOL *icon) {
    NSInteger lv = QBReadLevel();
    if (lv < 0) return NO;

    // Vitrine이 로컬 FLAC을 재생하려고 Spotify 음질을 1로 낮춘 상태 → 실제로는 무손실
    id saved = [[NSUserDefaults standardUserDefaults] arrayForKey:kSavedKey];
    BOOL vitrineLossless = (lv == 1 && [saved isKindOfClass:NSArray.class] && [(NSArray *)saved count] == 2);

    NSString *t = nil; BOOL ic = NO;
    if (vitrineLossless)       { t = @"무손실";     ic = YES; }
    else switch (lv) {
        case 1:  t = @"데이터 절약"; break;
        case 2:  t = @"일반음질";    break;
        case 3:  t = @"고음질";      break;
        case 4: case 5: case 6: t = @"무손실"; ic = YES; break;
        default: return NO;
    }
#if QB_DEBUG
    t = [t stringByAppendingFormat:@" %ld", (long)lv];
#endif
    *text = t; *icon = ic;
    return YES;
}

#pragma mark - 시간 라벨 찾기

static BOOL QBIsTime(NSString *t) {
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"^[-−–]?\\d{1,2}(:\\d{2}){1,2}$" options:0 error:nil];
    });
    if (t.length == 0 || t.length > 9) return NO;
    return [re firstMatchInString:t options:0 range:NSMakeRange(0, t.length)] != nil;
}

static void QBCollect(UIView *v, NSMutableArray<UILabel *> *out, int depth) {
    if (depth > 60 || v.hidden || v.alpha < 0.01) return;
    if ([v isKindOfClass:UILabel.class]) {
        UILabel *l = (UILabel *)v;
        if (l != gBadgeLabel && QBIsTime(l.text)) [out addObject:l];
    }
    for (UIView *s in v.subviews) QBCollect(s, out, depth + 1);
}

static void QBFindLabels(UIWindow *w, UILabel **left, UILabel **right) {
    NSMutableArray<UILabel *> *c = [NSMutableArray array];
    QBCollect(w, c, 0);
    CGFloat W = w.bounds.size.width;
    for (UILabel *a in c) {
        CGRect ra = [a convertRect:a.bounds toView:nil];
        if (CGRectGetMinX(ra) > W * 0.25) continue;
        for (UILabel *b in c) {
            if (a == b) continue;
            CGRect rb = [b convertRect:b.bounds toView:nil];
            if (CGRectGetMaxX(rb) < W * 0.75) continue;
            if (fabs(CGRectGetMidY(ra) - CGRectGetMidY(rb)) > 4) continue;
            if (CGRectGetMinX(ra) >= CGRectGetMinX(rb)) continue;
            *left = a; *right = b; return;
        }
    }
}

static UIView *QBCommonAncestor(UIView *a, UIView *b) {
    NSMutableSet *set = [NSMutableSet set];
    for (UIView *v = a; v; v = v.superview) [set addObject:[NSValue valueWithNonretainedObject:v]];
    for (UIView *v = b; v; v = v.superview)
        if ([set containsObject:[NSValue valueWithNonretainedObject:v]]) return v;
    return nil;
}

#pragma mark - 배지 뷰

static void QBEnsureBadge(void) {
    if (gBadge) return;
    gBadge = [[UIView alloc] init];
    gBadge.userInteractionEnabled = NO;
    gBadge.backgroundColor = [UIColor colorWithWhite:1 alpha:0.22];
    gBadge.layer.cornerRadius = 4;
    gBadge.layer.cornerCurve = kCACornerCurveContinuous;
    gBadge.layer.masksToBounds = YES;

    gBadgeLabel = [[UILabel alloc] init];
    gBadgeLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightSemibold];
    gBadgeLabel.textColor = [UIColor colorWithWhite:1 alpha:0.88];
    gBadgeLabel.textAlignment = NSTextAlignmentLeft;
    [gBadge addSubview:gBadgeLabel];

    gBadgeIcon = [[UIImageView alloc] init];
    gBadgeIcon.tintColor = [UIColor colorWithWhite:1 alpha:0.88];
    gBadgeIcon.contentMode = UIViewContentModeScaleAspectFit;
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:9 weight:UIImageSymbolWeightBold];
    gBadgeIcon.image = [UIImage systemImageNamed:@"waveform" withConfiguration:cfg];
    [gBadge addSubview:gBadgeIcon];
}

static void QBHide(void) { gBadge.hidden = YES; }

static UIWindow *QBWindow(void) {
    UIWindow *fallback = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) {
            if (w.isKeyWindow) return w;
            if (!fallback) fallback = w;
        }
    }
    return fallback;
}

static void QBRefresh(void) {
    UIWindow *w = QBWindow();
    if (!w) { QBHide(); return; }

    UILabel *a = gLeft, *b = gRight;
    BOOL valid = (a && b && a.window && b.window && !a.hidden && !b.hidden && QBIsTime(a.text) && QBIsTime(b.text));
    if (!valid) {
        a = b = nil;
        if (CFAbsoluteTimeGetCurrent() - gLastLayout < 3.0) QBFindLabels(w, &a, &b);
        gLeft = a; gRight = b;
    }
    if (!a || !b) { QBHide(); return; }

    NSString *text = nil; BOOL icon = NO;
    if (!QBCurrentText(&text, &icon)) { QBHide(); return; }

    QBEnsureBadge();
    UIView *host = QBCommonAncestor(a, b);
    if (!host) { QBHide(); return; }

    gBadgeLabel.text = text;
    [gBadgeLabel sizeToFit];
    CGFloat padX = 6, iconW = icon ? 11 : 0, gap = icon ? 2 : 0, H = 16;
    CGFloat textW = ceil(gBadgeLabel.bounds.size.width);
    CGFloat width = padX * 2 + iconW + gap + textW;

    gBadgeIcon.hidden = !icon;
    gBadgeIcon.frame = CGRectMake(padX, (H - 11) / 2, iconW, 11);
    gBadgeLabel.frame = CGRectMake(padX + iconW + gap, (H - gBadgeLabel.bounds.size.height) / 2, textW, gBadgeLabel.bounds.size.height);

    CGRect ra = [a convertRect:a.bounds toView:nil];
    CGPoint center = [host convertPoint:CGPointMake(w.bounds.size.width / 2, CGRectGetMidY(ra)) fromView:nil];

    if (gBadge.superview != host) { [gBadge removeFromSuperview]; [host addSubview:gBadge]; }
    [host bringSubviewToFront:gBadge];
    gBadge.bounds = CGRectMake(0, 0, width, H);
    gBadge.center = center;
    gBadge.hidden = NO;
}

#pragma mark - 후킹

static IMP QBSwizzle(Class cls, SEL sel, IMP imp) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NULL;
    IMP inherited = method_getImplementation(m);
    IMP old = class_replaceMethod(cls, sel, imp, method_getTypeEncoding(m));
    return old ? old : inherited;
}

static id (*orig_initWithScheduler)(id, SEL, id);
static id hook_initWithScheduler(id self, SEL _cmd, id sched) {
    id r = orig_initWithScheduler(self, _cmd, sched);
    if (r) { gPrefs = r; QBLog(@"preferences object captured"); }
    return r;
}

static void (*orig_viewDidLayoutSubviews)(id, SEL);
static void hook_viewDidLayoutSubviews(id self, SEL _cmd) {
    orig_viewDidLayoutSubviews(self, _cmd);
    gLastLayout = CFAbsoluteTimeGetCurrent();
    QBRefresh();
}

static BOOL gPrefsHooked, gPlayerHooked;

static void QBInstall(void) {
    if (!gPrefsHooked) {
        Class c = NSClassFromString(kPrefsClass);
        if (c) {
            IMP o = QBSwizzle(c, NSSelectorFromString(@"initWithScheduler:"), (IMP)hook_initWithScheduler);
            if (o) { orig_initWithScheduler = (id (*)(id, SEL, id))o; gPrefsHooked = YES; QBLog(@"hooked preferences"); }
        }
    }
    if (!gPlayerHooked) {
        Class c = NSClassFromString(kPlayerClass);
        if (c) {
            IMP o = QBSwizzle(c, @selector(viewDidLayoutSubviews), (IMP)hook_viewDidLayoutSubviews);
            if (o) { orig_viewDidLayoutSubviews = (void (*)(id, SEL))o; gPlayerHooked = YES; QBLog(@"hooked player"); }
        }
    }
}

static void QBRetryInstall(int attempt) {
    QBInstall();
    if ((gPrefsHooked && gPlayerHooked) || attempt >= 20) {
        if (!(gPrefsHooked && gPlayerHooked)) QBLog(@"install incomplete: prefs=%d player=%d", gPrefsHooked, gPlayerHooked);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        QBRetryInstall(attempt + 1);
    });
}

__attribute__((constructor))
static void QBInit(void) {
    QBInstall();

    gMonitor = nw_path_monitor_create();
    nw_path_monitor_set_queue(gMonitor, dispatch_get_main_queue());
    nw_path_monitor_set_update_handler(gMonitor, ^(nw_path_t path) {
        gExpensive = nw_path_is_expensive(path);
    });
    nw_path_monitor_start(gMonitor);

    dispatch_async(dispatch_get_main_queue(), ^{
        QBRetryInstall(0);
        // 설정을 바꾸거나 곡이 바뀌어도 반영되도록 1초마다 갱신
        [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) { QBRefresh(); }];
    });
}
