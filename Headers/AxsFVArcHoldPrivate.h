#pragma once

#import <Foundation/Foundation.h>

// Companion fix for com.be-huge.floating-view (ARC menu).
// Runs only inside SpringBoard; never rewrites floatingView's own files.

void axs_fvarchold_log(NSString *format, ...);
