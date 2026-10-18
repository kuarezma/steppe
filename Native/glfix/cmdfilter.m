// SPDX-License-Identifier: MIT
// Copyright (c) Steppe contributors
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#include <stdlib.h>

void glfix_trace(const char *fmt, ...);

static id g_monitor;
static dispatch_source_t g_timer;

static void cmdfilter_install(void) {
  if (g_monitor || !NSApp) return;
  g_monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskFlagsChanged
                                                    handler:^NSEvent *(NSEvent *e) {
                                                      unsigned short k = [e keyCode];

                                                      if ((k == kVK_Command || k == kVK_RightCommand) &&
                                                          ([e modifierFlags] & NSEventModifierFlagCommand))
                                                        return nil;
                                                      return e;
                                                    }];
  glfix_trace("CMDFILTER installed monitor=%p", (void *)g_monitor);
  dispatch_source_cancel(g_timer);
}

__attribute__((constructor)) static void cmdfilter_init(void) {
  const char *v = getenv("GLFIX_CMDFILTER");
  if (v && !strcmp(v, "0")) return;
  g_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
  dispatch_source_set_timer(g_timer, dispatch_time(DISPATCH_TIME_NOW, 0), 200 * NSEC_PER_MSEC,
                            50 * NSEC_PER_MSEC);
  dispatch_source_set_event_handler(g_timer, ^{ cmdfilter_install(); });
  dispatch_resume(g_timer);
}
