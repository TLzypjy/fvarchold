#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <unistd.h>
#import "AxsFVArcHoldConfig.h"
#import "AxsFVArcHoldPrivate.h"

// AxsFVArcHold — floatingView (com.be-huge.floating-view) 伴生 tweak。
// 功能：ARC 菜单里长按 App 图标超过设定停留时长后松手 → 全屏打开；
//       快速松手（未到停留时长）→ 走 floatingView 原逻辑（浮窗/分屏）。
// 实现：给 FVArcTerraceItem 挂 UILongPressGestureRecognizer（到时即 began，
//       cancelsTouchesInView 取消原点击路径），松手时通过 FBSSystemService 全屏打开。

#define AXS_LOG_FILE @"/var/mobile/Library/FVArcHold/arcfix.log"

void axs_fvarchold_log(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSLog(@"[FVArcHold] %@", msg);

    static NSString *logPath;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *dir = [AXS_LOG_FILE stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        logPath = AXS_LOG_FILE;
    });
    static NSDateFormatter *fmt;
    if (!fmt) {
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"MM-dd HH:mm:ss.SSS";
    }
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [fmt stringFromDate:[NSDate date]], msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (!fh) {
        [line writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    @try {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } @catch (NSException *e) {}
}

#pragma mark - bundle id 识别（复用 TrollOpenFix 的判定风格）

static BOOL axs_looksLikeBundleID(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return NO;
    NSUInteger len = s.length;
    if (len < 3 || len > 128) return NO;
    if ([s containsString:@"0x"]) return NO;
    if (![s containsString:@"."]) return NO;
    static NSCharacterSet *allowed;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        allowed = [NSCharacterSet characterSetWithCharactersInString:
                   @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._"];
    });
    return [s rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

// 探测对象自身/其对象型 ivar 里的 bundle id 字符串。depth 探测层数。
static NSString *axs_probeBundleIDInObject(id obj, int depth);

static NSString *axs_probeBundleIDInObject(id obj, int depth) {
    if (!obj || depth <= 0) return nil;
    if ([obj isKindOfClass:[NSString class]]) {
        return axs_looksLikeBundleID(obj) ? obj : nil;
    }
    if ([obj isKindOfClass:[NSURL class]] || [obj isKindOfClass:[NSNumber class]]) return nil;
    if ([obj isKindOfClass:[UIView class]] || [obj isKindOfClass:[CALayer class]]) return nil;
    if ([obj isKindOfClass:[UIImage class]]) return nil;

    Class cls = object_getClass(obj);
    if (!cls) return nil;

    // 常见属性优先（KVC 可能失败，忽略异常）
    NSArray *keys = @[@"bundleIdentifier", @"bundleID", @"displayIdentifier",
                      @"applicationIdentifier", @"appIdentifier", @"identifier"];
    for (NSString *k in keys) {
        SEL sel = NSSelectorFromString(k);
        if (![cls instancesRespondToSelector:sel]) continue;
        @try {
            id v = ((id(*)(id, SEL))objc_msgSend)(obj, sel);
            if (axs_looksLikeBundleID(v)) return v;
        } @catch (NSException *e) {}
    }

    if (depth <= 1) return nil;

    // ivar 扫描（只看对象型）
    unsigned int count = 0;
    Ivar *ivars = class_copyIvarList(cls, &count);
    NSString *found = nil;
    for (unsigned int i = 0; i < count && !found && i < 32; i++) {
        const char *type = ivar_getTypeEncoding(ivars[i]);
        if (!type || type[0] != '@') continue;
        const char *name = ivar_getName(ivars[i]);
        if (name && strcmp(name, "isa") == 0) continue;
        id v = object_getIvar(obj, ivars[i]);
        if (!v) continue;
        if ([v isKindOfClass:[NSString class]]) {
            if (axs_looksLikeBundleID(v)) found = v;
        } else if ([v isKindOfClass:[NSArray class]]) {
            NSArray *arr = v;
            for (id el in arr) {
                if (!el || [el isKindOfClass:[UIView class]]) continue;
                NSString *r = axs_probeBundleIDInObject(el, depth - 1);
                if (r) { found = r; break; }
            }
        } else if (![v isKindOfClass:[NSSet class]]) {
            found = axs_probeBundleIDInObject(v, depth - 1);
        }
    }
    free(ivars);
    return found;
}

#pragma mark - ARC 模型定位

// 从 terrace 的 arcList（可能是 NSArray，也可能是 Swift.Array 结构体）取第 item 个模型并探测 bundle id。
static NSString *axs_bundleIDFromArcList(id terrace, NSUInteger item) {
    Class cls = object_getClass(terrace);
    if (!cls) return nil;
    Ivar iv = class_getInstanceVariable(cls, "arcList");
    if (!iv) {
        axs_fvarchold_log(@"resolve: terrace has no arcList ivar");
        return nil;
    }
    const char *type = ivar_getTypeEncoding(iv);
    id element = nil;

    if (type && type[0] == '@') {
        id list = object_getIvar(terrace, iv);
        if ([list isKindOfClass:[NSArray class]]) {
            NSArray *arr = list;
            if (item < arr.count) element = [arr objectAtIndex:item];
        } else if (list) {
            // Swift Array 以 NSArray 桥接存储的情况
            @try {
                element = [list objectAtIndex:item];
            } @catch (NSException *e) {}
        }
    } else if (type && type[0] == '{') {
        // Swift.Array 是 2 个机器字的结构体：word1 通常是 ContiguousArrayStorage 指针。
        ptrdiff_t off = ivar_getOffset(iv);
        char *base = (char *)(__bridge void *)terrace + off;
        uint64_t w1 = 0;
        memcpy(&w1, base + 8, 8);
        if (w1 > 0x1000000000ULL) {
            id storage = (__bridge id)(void *)(uintptr_t)w1;
            @try {
                // 优先走 NSArray 下标协议；不行则按元素内存布局扫描。
                if ([storage respondsToSelector:@selector(objectAtIndexedSubscript:)]) {
                    @try {
                        element = ((id(*)(id, SEL, NSUInteger))objc_msgSend)(storage, @selector(objectAtIndexedSubscript:), item);
                    } @catch (NSException *e) {}
                }
                for (NSUInteger headerOff = 16; headerOff <= 40 && !element; headerOff += 8) {
                    @try {
                        char *elemPtr = (char *)(__bridge void *)storage + headerOff + item * 8;
                        uint64_t p = 0;
                        memcpy(&p, elemPtr, 8);
                        if (p > 0x1000000000ULL) {
                            id el = (__bridge id)(void *)(uintptr_t)p;
                            Class elCls = object_getClass(el);
                            if (elCls && !class_isMetaClass(elCls)) {
                                element = el;
                            }
                        }
                    } @catch (NSException *e) {}
                }
            } @catch (NSException *e) {}
        }
    }
    if (!element) return nil;
    NSString *bid = axs_probeBundleIDInObject(element, 3);
    if (bid) axs_fvarchold_log(@"resolve: arcList[%lu] -> %@ (class %@)", (unsigned long)item, bid, object_getClass(element));
    return bid;
}

static NSString *axs_resolveSelectedBundleID(id terrace, UILongPressGestureRecognizer *gr) {
    // 1) terrace.collectionView → 触点 → indexPath → cell
    Class terraceCls = object_getClass(terrace);
    Ivar cvIv = terraceCls ? class_getInstanceVariable(terraceCls, "collectionView") : NULL;
    if (!cvIv) return nil;
    id cv = object_getIvar(terrace, cvIv);
    if (![cv isKindOfClass:[UICollectionView class]]) return nil;

    CGPoint p = [gr locationInView:cv];
    NSIndexPath *ip = [cv indexPathForItemAtPoint:p];
    if (!ip) {
        axs_fvarchold_log(@"resolve: no indexPath at %@ (cv %@)", NSStringFromCGPoint(p), object_getClass(cv));
        return nil;
    }

    id cell = [cv cellForItemAtIndexPath:ip];
    if (cell) {
        // 1a) cell 自身属性 / 一层 ivar 深度（含 pointValue 若为模型对象）
        NSString *bid = axs_probeBundleIDInObject(cell, 2);
        if (bid) {
            axs_fvarchold_log(@"resolve: cell ivar -> %@", bid);
            return bid;
        }
        // 1b) cell.pointValue 若为对象则已被 1a 覆盖；尝试从 selectedIndexPath / arcList 取模型
    }

    // 2) terrace.selectedIndexPath（原触摸逻辑维护的选中项）
    Ivar selIv = terraceCls ? class_getInstanceVariable(terraceCls, "selectedIndexPath") : NULL;
    if (selIv) {
        NSIndexPath *sel = object_getIvar(terrace, selIv);
        if ([sel isKindOfClass:[NSIndexPath class]]) ip = sel;
    }

    // 3) arcList 模型
    NSString *bid = axs_bundleIDFromArcList(terrace, ip.item);
    if (bid) return bid;

    axs_fvarchold_log(@"resolve: FAILED (cell=%@ ip=%@)", object_getClass(cell), ip);
    return nil;
}

#pragma mark - 全屏打开

static BOOL axs_openAppFullscreen(NSString *bid) {
    Class fbsCls = objc_getClass("FBSSystemService");
    if (!fbsCls) {
        axs_fvarchold_log(@"open: FBSSystemService missing");
        return NO;
    }
    id svc = ((id(*)(id, SEL))objc_msgSend)(fbsCls, @selector(sharedService));
    SEL sel = NSSelectorFromString(@"openApplication:options:withResult:");
    if (!svc || ![svc respondsToSelector:sel]) {
        axs_fvarchold_log(@"open: service unavailable");
        return NO;
    }
    axs_fvarchold_log(@"open fullscreen: %@", bid);
    ((void(*)(id, SEL, id, id, id))objc_msgSend)(svc, sel, bid, @{}, nil);
    return YES;
}

// 兜底：全屏打开后如果 ARC 菜单没有自己收起，找到 FVArcContainerView 收起/移除。
static void axs_dismissArcIfStillVisible(void) {
    NSMutableArray *containers = [NSMutableArray array];
    NSArray<UIWindow *> *windows = nil;
    id app = [UIApplication sharedApplication];
    if ([app respondsToSelector:@selector(connectedScenes)]) {
        NSMutableOrderedSet *set = [NSMutableOrderedSet orderedSet];
        for (UIScene *scene in [app connectedScenes]) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                [set addObjectsFromArray:((UIWindowScene *)scene).windows];
            }
        }
        windows = [set array];
    } else {
        windows = [app windows];
    }
    Class containerCls = objc_getClass("FVArcContainerView");
    if (!containerCls || !windows) return;
    for (UIWindow *w in windows) {
        NSMutableArray *stack = [NSMutableArray arrayWithObject:w];
        while (stack.count && containers.count < 4) {
            UIView *v = [stack lastObject];
            [stack removeLastObject];
            if (!v) continue;
            if ([v isKindOfClass:containerCls]) {
                [containers addObject:v];
                continue;
            }
            [stack addObjectsFromArray:[v subviews]];
        }
    }
    for (id container in containers) {
        Class cls = object_getClass(container);
        Ivar iv = class_getInstanceVariable(cls, "isDisplay");
        if (iv) {
            @try {
                id disp = object_getIvar(container, iv);
                if ([disp isKindOfClass:[NSNumber class]] && ![disp boolValue]) continue;
            } @catch (NSException *e) {}
        }
        axs_fvarchold_log(@"dismiss: forcing arc container away");
        [UIView animateWithDuration:0.2 animations:^{
            if ([container isKindOfClass:[UIView class]]) {
                ((UIView *)container).alpha = 0.0;
            }
        } completion:^(BOOL done) {
            if ([container isKindOfClass:[UIView class]]) {
                [container removeFromSuperview];
            }
        }];
    }
}

#pragma mark - 手势 helper

@interface AxsFVArcHoldGestureHelper : NSObject
- (void)axs_arcHoldGesture:(UILongPressGestureRecognizer *)gr;
@end

static AxsFVArcHoldGestureHelper *axs_sharedHelper(void) {
    static AxsFVArcHoldGestureHelper *helper;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        helper = [[AxsFVArcHoldGestureHelper alloc] init];
    });
    return helper;
}

@implementation AxsFVArcHoldGestureHelper

static char axs_pendingBidKey;

- (void)axs_arcHoldGesture:(UILongPressGestureRecognizer *)gr {
    AxsFVArcHoldConfig *config = [AxsFVArcHoldConfig axs_fvarchold_shared];

    switch (gr.state) {
        case UIGestureRecognizerStateBegan: {
            if (![config axs_fvarchold_isEnabled]) return;
            id terrace = gr.view;
            if (!terrace) return;

            NSString *bid = axs_resolveSelectedBundleID(terrace, gr);
            objc_setAssociatedObject(gr, &axs_pendingBidKey, bid, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (!bid) {
                axs_fvarchold_log(@"hold began: no bundle id resolved, original path may stay cancelled");
                return;
            }
            // 轻震动反馈（停留达成）
            @try {
                Class genCls = objc_getClass("UIImpactFeedbackGenerator");
                if (genCls) {
                    id gen = ((id(*)(id, SEL, NSInteger))objc_msgSend)(genCls, @selector(initWithStyle:), 1 /*light*/);
                    ((void(*)(id, SEL))objc_msgSend)(gen, @selector(impactOccurred));
                }
            } @catch (NSException *e) {}
            axs_fvarchold_log(@"hold began: dwell reached, pending fullscreen for %@", bid);
            break;
        }
        case UIGestureRecognizerStateEnded: {
            NSString *bid = objc_getAssociatedObject(gr, &axs_pendingBidKey);
            objc_setAssociatedObject(gr, &axs_pendingBidKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (![bid isKindOfClass:[NSString class]] || bid.length == 0) return;
            if (![config axs_fvarchold_isEnabled]) return;
            if (axs_openAppFullscreen(bid)) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    axs_dismissArcIfStillVisible();
                });
            }
            break;
        }
        case UIGestureRecognizerStateCancelled: {
            objc_setAssociatedObject(gr, &axs_pendingBidKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            break;
        }
        default:
            break;
    }
}

@end

#pragma mark - terrace hook

static char axs_attachKey;
static NSHashTable *axs_liveTerraces;

static void axs_updateRecognizers(void) {
    AxsFVArcHoldConfig *config = [AxsFVArcHoldConfig axs_fvarchold_shared];
    BOOL enabled = [config axs_fvarchold_isEnabled];
    NSTimeInterval dwell = [config axs_fvarchold_dwell];
    for (id terrace in axs_liveTerraces.allObjects) {
        UILongPressGestureRecognizer *gr = objc_getAssociatedObject(terrace, &axs_attachKey);
        if (![gr isKindOfClass:[UILongPressGestureRecognizer class]]) continue;
        gr.enabled = enabled;
        gr.minimumPressDuration = dwell;
    }
}

static void axs_attachToTerrace(id terrace) {
    if (![terrace isKindOfClass:[UIView class]]) return;
    if (objc_getAssociatedObject(terrace, &axs_attachKey)) return;

    AxsFVArcHoldConfig *config = [AxsFVArcHoldConfig axs_fvarchold_shared];
    UILongPressGestureRecognizer *gr =
        [[UILongPressGestureRecognizer alloc] initWithTarget:axs_sharedHelper()
                                                      action:@selector(axs_arcHoldGesture:)];
    gr.minimumPressDuration = [config axs_fvarchold_dwell];
    gr.allowableMovement = CGFLOAT_MAX;
    gr.cancelsTouchesInView = YES;
    gr.enabled = [config axs_fvarchold_isEnabled];
    [terrace addGestureRecognizer:gr];
    objc_setAssociatedObject(terrace, &axs_attachKey, gr, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [axs_liveTerraces addObject:terrace];
    axs_fvarchold_log(@"attached recognizer to %@ (%@)", object_getClass(terrace), gr);
}

static id (*axs_orig_initWithFrame)(id, SEL, CGRect);
static id (*axs_orig_initWithCoder)(id, SEL, id);

static id axs_new_initWithFrame(id self, SEL _cmd, CGRect frame) {
    id r = axs_orig_initWithFrame(self, _cmd, frame);
    if (r) axs_attachToTerrace(r);
    return r;
}

static id axs_new_initWithCoder(id self, SEL _cmd, id coder) {
    id r = axs_orig_initWithCoder(self, _cmd, coder);
    if (r) axs_attachToTerrace(r);
    return r;
}

static void axs_hookTerraceClass(Class cls) {
    if (!cls) return;

    SEL frameSel = @selector(initWithFrame:);
    Method m = class_getInstanceMethod(cls, frameSel);
    if (m) {
        axs_orig_initWithFrame = (id (*)(id, SEL, CGRect))method_getImplementation(m);
        method_setImplementation(m, (IMP)axs_new_initWithFrame);
    }
    SEL coderSel = @selector(initWithCoder:);
    m = class_getInstanceMethod(cls, coderSel);
    if (m) {
        axs_orig_initWithCoder = (id (*)(id, SEL, id))method_getImplementation(m);
        method_setImplementation(m, (IMP)axs_new_initWithCoder);
    }
    axs_fvarchold_log(@"hooked %@ init", class_getName(cls));
}

#pragma mark - 诊断与类发现

static BOOL axs_nameHasSuffix(const char *name, const char *suffix) {
    if (!name || !suffix) return NO;
    size_t len = strlen(name);
    size_t slen = strlen(suffix);
    return len > slen && strcmp(name + len - slen, suffix) == 0;
}

// 列出运行时所有名字包含 needle 的类（roothide 可能给类名加随机前缀，按包含/后缀匹配）
static Class axs_findClassByFragment(const char *fragment, BOOL logAll) {
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    Class found = nil;
    NSMutableArray *hits = [NSMutableArray array];
    for (unsigned int i = 0; i < count; i++) {
        const char *name = class_getName(classes[i]);
        if (!name) continue;
        if (strstr(name, fragment)) {
            if (!found) found = classes[i];
            if ([hits count] < 12) {
                [hits addObject:[NSString stringWithUTF8String:name]];
            }
        }
    }
    if (classes) free(classes);
    if (logAll && hits.count) {
        axs_fvarchold_log(@"classes matching '%s': %@", fragment, [hits componentsJoinedByString:@", "]);
    }
    return found;
}

static void axs_logFloatingViewImages(void) {
    NSMutableArray *hits = [NSMutableArray array];
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *path = _dyld_get_image_name(i);
        if (path && strstr(path, "floatingView")) {
            [hits addObject:[NSString stringWithUTF8String:path]];
        }
    }
    axs_fvarchold_log(@"loaded floatingView images (%lu): %@",
                      (unsigned long)hits.count,
                      hits.count ? [hits componentsJoinedByString:@" | "] : @"none");
}

static void axs_waitAndHook(void) {
    id app = [UIApplication sharedApplication];
    axs_fvarchold_log(@"ctor process: pid=%d bundle=%@",
                      (int)getpid(),
                      [[NSBundle mainBundle] bundleIdentifier] ?: @"?");
    axs_logFloatingViewImages();

    for (int i = 0; i < 120; i++) {
        Class cls = axs_findClassByFragment("FVArcTerraceItem", NO);
        if (cls) {
            Class container = axs_findClassByFragment("FVArcContainerView", NO);
            if (container) {
                // 仅用于日志确认
                axs_fvarchold_log(@"container class present: %s", class_getName(container));
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                axs_hookTerraceClass(cls);
            });
            return;
        }
        usleep(1000 * 1000);
    }
    // 超时：一次性输出诊断
    axs_fvarchold_log(@"TIMEOUT waiting for FVArcTerraceItem, dumping diagnostics");
    axs_logFloatingViewImages();
    axs_findClassByFragment("FVArc", YES);
    axs_findClassByFragment("FVSideBar", YES);
    unsigned int imgCount = _dyld_image_count();
    NSMutableArray *tweaks = [NSMutableArray array];
    for (uint32_t i = 0; i < imgCount; i++) {
        const char *path = _dyld_get_image_name(i);
        if (path && (strstr(path, "DynamicLibraries") || strstr(path, "TweakInject") || strstr(path, "MobileSubstrate"))) {
            [tweaks addObject:[[NSString stringWithUTF8String:path] lastPathComponent]];
        }
    }
    axs_fvarchold_log(@"tweak dylibs loaded (%lu): %@",
                      (unsigned long)tweaks.count,
                      tweaks.count ? [tweaks componentsJoinedByString:@", "] : @"none");
}

#pragma mark - 入口

static void axs_preferencesChanged(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        axs_updateRecognizers();
    });
}

static void axs_preferencesChangedCB(CFNotificationCenterRef center, void *observer,
                                     CFStringRef name, const void *object, CFDictionaryRef info) {
    axs_preferencesChanged();
}

%ctor {
    @autoreleasepool {
        axs_liveTerraces = [NSHashTable weakObjectsHashTable];

        // 等 floatingView 注入后 hook（轮询 + 诊断，超时后输出已加载模块与类名）
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            axs_waitAndHook();
        });

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            NULL, axs_preferencesChangedCB,
            (__bridge CFStringRef)AxsFVArcHoldPreferencesChangedNotification,
            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}
