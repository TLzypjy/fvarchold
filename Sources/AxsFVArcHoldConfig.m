#import "AxsFVArcHoldConfig.h"

NSString * const AxsFVArcHoldPreferencesDomain = @"com.axs.fvarchold";
NSString * const AxsFVArcHoldPreferencesChangedNotification = @"com.axs.fvarchold-prefs-changed";

@implementation AxsFVArcHoldConfig

+ (instancetype)axs_fvarchold_shared {
    static AxsFVArcHoldConfig *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (BOOL)axs_fvarchold_isEnabled {
    // Read-through every time: gesture events are rare and cfprefsd keeps this cheap.
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:AxsFVArcHoldPreferencesDomain];
    [defaults synchronize];
    id value = [defaults objectForKey:@"enabled"];
    if ([value isKindOfClass:[NSNumber class]]) {
        return [value boolValue];
    }
    return YES;
}

- (NSTimeInterval)axs_fvarchold_dwell {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:AxsFVArcHoldPreferencesDomain];
    [defaults synchronize];
    id value = [defaults objectForKey:@"dwell"];
    if ([value isKindOfClass:[NSNumber class]]) {
        double v = [value doubleValue];
        if (v >= 0.05 && v <= 5.0) {
            return v;
        }
    }
    return 0.5;
}

@end
