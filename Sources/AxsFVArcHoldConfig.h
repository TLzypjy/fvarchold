#pragma once

#import <Foundation/Foundation.h>

// Settings domain written by the Preferences entries (PSSwitchCell / PSSliderCell).
extern NSString * const AxsFVArcHoldPreferencesDomain;
extern NSString * const AxsFVArcHoldPreferencesChangedNotification;

@interface AxsFVArcHoldConfig : NSObject

+ (instancetype)axs_fvarchold_shared;

// enabled: ARC 长按松手全屏总开关（默认开）。
- (BOOL)axs_fvarchold_isEnabled;
// dwell: 停留多少秒后松手算全屏（默认 0.5，范围 0.1 - 2.0）。
- (NSTimeInterval)axs_fvarchold_dwell;

@end
