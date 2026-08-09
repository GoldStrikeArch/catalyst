// catalyst-input — macOS input/observation helper for Catalyst's computer-use
// tools (plan §2).
//
// Build (see `mix catalyst.computer.build`):
//   cc -arch arm64 -O2 -fobjc-arc -Wno-deprecated-declarations \
//      -framework ApplicationServices -framework Carbon -framework Foundation \
//      -framework AppKit -o catalyst-input computer_helper.m
//
// Two modes:
//
// 1. Server mode (default, no args): a long-lived process speaking
//    newline-delimited JSON on stdin/stdout. One JSON object per line in, one
//    per line out. Every request carries an "id" (any JSON value) which is
//    echoed in the response. Success: {"id":<id>,"result":{...}}. Failure:
//    {"id":<id>,"error":"<message>"} (id is null when the request line could
//    not be parsed). The process never exits or crashes on malformed input —
//    it answers with an error line and keeps reading. Nothing is printed at
//    startup; the first output is the response to the first request.
//
//    Ops (all mouse coordinates are GLOBAL DISPLAY POINTS, top-left origin —
//    the space CGEventCreateMouseEvent expects; events post to
//    kCGHIDEventTap):
//
//      {"op":"screens"}    -> {"screens":[{id,index,main,bounds:{x,y,width,height},scale}]}
//      {"op":"windows"}    -> {"windows":[{id,pid,app,title,layer,bounds:{x,y,width,height}}]}
//      {"op":"cursor"}     -> {"x":<pt>,"y":<pt>}
//      {"op":"mouse_move","coordinate":[x,y]}
//      {"op":"mouse_down","coordinate":[x,y],"button":"left|right|middle","modifiers":[..]}
//      {"op":"mouse_up",  "coordinate":[x,y],"button":..}
//      {"op":"click","coordinate":[x,y],"button":..,"count":1|2|3,"modifiers":[..]}
//      {"op":"drag","start_coordinate":[x,y],"coordinate":[x,y],"duration_ms":N,"button":..}
//      {"op":"scroll","coordinate":[x,y],"scroll_direction":"up|down|left|right","scroll_amount":N}
//      {"op":"type","text":"…"}                     (arbitrary Unicode, no keycode table)
//      {"op":"key","key":"s","modifiers":["command","shift"]}
//      {"op":"hold_key","key":"a","duration_ms":N,"modifiers":[..]}
//      {"op":"release_all"}
//      {"op":"trusted"}                -> {"trusted":bool}   (AXIsProcessTrusted)
//      {"op":"request_trust"}          -> {"trusted":bool}   (prompts)
//      {"op":"screen_capture_allowed"} -> {"allowed":bool}   (CGPreflightScreenCaptureAccess)
//      {"op":"request_screen_capture"} -> {"allowed":bool}   (prompts)
//
//    Modifiers accept: command/cmd, shift, control/ctrl, option/alt,
//    function/fn. Named keys accept: return, enter, tab, space, delete,
//    backspace, forward_delete, escape/esc, left/right/up/down, home, end,
//    page_up, page_down, f1–f20, plus any single character (resolved against
//    the ACTIVE keyboard layout, not a hardcoded US table).
//
// 2. Self-test target mode (`catalyst-input --test-target`): opens a plain
//    NSWindow of known size with instrumented regions — colored click pads, a
//    text field, a scroll view. Prints its own window id + frame as a JSON
//    line at startup ({"event":"ready","window_id":N,"frame":{x,y,width,height}}),
//    then reports every event it receives as JSON lines. This is the
//    instrument for the `mix test.computer` round-trip tier.

#import <Foundation/Foundation.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <AppKit/AppKit.h>

#include <stdio.h>
#include <string.h>
#include <unistd.h>

// ---------------------------------------------------------------------------
// JSON IO
// ---------------------------------------------------------------------------

static void writeJSONLine(NSDictionary *obj) {
  NSError *err = nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:&err];
  if (!data) {
    const char *fallback = "{\"id\":null,\"error\":\"encode_failed\"}\n";
    fwrite(fallback, 1, strlen(fallback), stdout);
    fflush(stdout);
    return;
  }
  fwrite(data.bytes, 1, data.length, stdout);
  fputc('\n', stdout);
  fflush(stdout);
}

static void writeError(id reqId, NSString *msg) {
  writeJSONLine(@{@"id" : (reqId ?: [NSNull null]), @"error" : (msg ?: @"error")});
}

static void writeOk(id reqId, NSDictionary *result) {
  writeJSONLine(@{@"id" : (reqId ?: [NSNull null]), @"result" : (result ?: @{})});
}

// ---------------------------------------------------------------------------
// Keycode mapping (layout-aware)
// ---------------------------------------------------------------------------

static NSMutableDictionary<NSString *, NSNumber *> *gCharToKey;  // "s" -> keycode
static NSMutableDictionary<NSString *, NSNumber *> *gNamedKeys;  // "return" -> keycode

// Reverse-scan the active keyboard layout so `key`/named-char resolution uses
// the keycodes that actually produce each character on THIS layout.
static void buildCharKeyMap(void) {
  gCharToKey = [NSMutableDictionary dictionary];
  TISInputSourceRef src = TISCopyCurrentKeyboardLayoutInputSource();
  if (!src) return;
  CFDataRef layoutData =
      (CFDataRef)TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData);
  if (!layoutData) {
    CFRelease(src);
    return;
  }
  const UCKeyboardLayout *layout = (const UCKeyboardLayout *)CFDataGetBytePtr(layoutData);
  UInt32 kbdType = LMGetKbdType();
  for (CGKeyCode key = 0; key < 128; key++) {
    UInt32 deadKeyState = 0;
    UniChar chars[4];
    UniCharCount len = 0;
    OSStatus st = UCKeyTranslate(layout, key, kUCKeyActionDown, 0, kbdType,
                                 kUCKeyTranslateNoDeadKeysBit, &deadKeyState, 4, &len, chars);
    if (st == noErr && len > 0) {
      NSString *s = [NSString stringWithCharacters:chars length:len];
      if (s.length > 0 && gCharToKey[s] == nil) gCharToKey[s] = @(key);
    }
  }
  CFRelease(src);
}

static void buildNamedKeys(void) {
  gNamedKeys = [@{
    @"return" : @(kVK_Return),
    @"enter" : @(kVK_ANSI_KeypadEnter),
    @"tab" : @(kVK_Tab),
    @"space" : @(kVK_Space),
    @"delete" : @(kVK_Delete),
    @"backspace" : @(kVK_Delete),
    @"forward_delete" : @(kVK_ForwardDelete),
    @"escape" : @(kVK_Escape),
    @"esc" : @(kVK_Escape),
    @"left" : @(kVK_LeftArrow),
    @"right" : @(kVK_RightArrow),
    @"up" : @(kVK_UpArrow),
    @"down" : @(kVK_DownArrow),
    @"home" : @(kVK_Home),
    @"end" : @(kVK_End),
    @"page_up" : @(kVK_PageUp),
    @"page_down" : @(kVK_PageDown),
    @"help" : @(kVK_Help),
    @"caps_lock" : @(kVK_CapsLock),
  } mutableCopy];

  CGKeyCode fkeys[20] = {kVK_F1,  kVK_F2,  kVK_F3,  kVK_F4,  kVK_F5,  kVK_F6,  kVK_F7,
                         kVK_F8,  kVK_F9,  kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14,
                         kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20};
  for (int i = 0; i < 20; i++) {
    gNamedKeys[[NSString stringWithFormat:@"f%d", i + 1]] = @(fkeys[i]);
  }
}

// Resolve a key name (named key first, then a single character on this layout).
// Returns -1 when unknown.
static int keycodeForName(NSString *name) {
  if (name.length == 0) return -1;
  NSString *lower = [name lowercaseString];
  NSNumber *named = gNamedKeys[lower];
  if (named) return named.intValue;
  NSNumber *ch = gCharToKey[name];
  if (ch) return ch.intValue;
  NSNumber *chLower = gCharToKey[lower];
  if (chLower) return chLower.intValue;
  return -1;
}

// ---------------------------------------------------------------------------
// Modifier + button parsing
// ---------------------------------------------------------------------------

static BOOL modifierEntry(id m, CGKeyCode *code, CGEventFlags *flag) {
  if (![m isKindOfClass:[NSString class]]) return NO;
  NSString *s = [m lowercaseString];
  if ([s isEqualToString:@"command"] || [s isEqualToString:@"cmd"]) {
    *code = kVK_Command;
    *flag = kCGEventFlagMaskCommand;
  } else if ([s isEqualToString:@"shift"]) {
    *code = kVK_Shift;
    *flag = kCGEventFlagMaskShift;
  } else if ([s isEqualToString:@"control"] || [s isEqualToString:@"ctrl"]) {
    *code = kVK_Control;
    *flag = kCGEventFlagMaskControl;
  } else if ([s isEqualToString:@"option"] || [s isEqualToString:@"alt"]) {
    *code = kVK_Option;
    *flag = kCGEventFlagMaskAlternate;
  } else if ([s isEqualToString:@"function"] || [s isEqualToString:@"fn"]) {
    *code = kVK_Function;
    *flag = kCGEventFlagMaskSecondaryFn;
  } else {
    return NO;
  }
  return YES;
}

static CGEventFlags flagsFromArray(NSArray *mods) {
  CGEventFlags f = 0;
  if (![mods isKindOfClass:[NSArray class]]) return f;
  for (id m in mods) {
    CGKeyCode code;
    CGEventFlags flag;
    if (modifierEntry(m, &code, &flag)) f |= flag;
  }
  return f;
}

static void postKeyRaw(CGKeyCode keycode, CGEventFlags flags, BOOL down) {
  CGEventRef ev = CGEventCreateKeyboardEvent(NULL, keycode, down);
  CGEventSetFlags(ev, flags);
  CGEventPost(kCGHIDEventTap, ev);
  CFRelease(ev);
}

// Posting a keyboard/mouse event whose flags include a modifier LATCHES that
// modifier in the session's synthetic-event state — later synthetic events
// (even from other processes) inherit it, turning `type` into a shortcut and
// vertical scrolls horizontal. So modifiers are pressed and released as REAL
// modifier key events around the modified action, always ending at flags 0.
static CGEventFlags pressModifiers(NSArray *mods) {
  CGEventFlags flags = 0;
  if (![mods isKindOfClass:[NSArray class]]) return flags;
  for (id m in mods) {
    CGKeyCode code;
    CGEventFlags flag;
    if (!modifierEntry(m, &code, &flag)) continue;
    flags |= flag;
    postKeyRaw(code, flags, YES);
  }
  return flags;
}

static void releaseModifiers(NSArray *mods) {
  if (![mods isKindOfClass:[NSArray class]]) return;
  CGEventFlags flags = flagsFromArray(mods);
  for (id m in [[mods reverseObjectEnumerator] allObjects]) {
    CGKeyCode code;
    CGEventFlags flag;
    if (!modifierEntry(m, &code, &flag)) continue;
    flags &= ~flag;
    postKeyRaw(code, flags, NO);
  }
}

typedef struct {
  CGMouseButton button;
  CGEventType downType;
  CGEventType upType;
  CGEventType dragType;
} MouseKind;

static MouseKind mouseKindFor(NSString *button) {
  NSString *b = [button lowercaseString];
  if ([b isEqualToString:@"right"])
    return (MouseKind){kCGMouseButtonRight, kCGEventRightMouseDown, kCGEventRightMouseUp,
                       kCGEventRightMouseDragged};
  if ([b isEqualToString:@"middle"])
    return (MouseKind){kCGMouseButtonCenter, kCGEventOtherMouseDown, kCGEventOtherMouseUp,
                       kCGEventOtherMouseDragged};
  return (MouseKind){kCGMouseButtonLeft, kCGEventLeftMouseDown, kCGEventLeftMouseUp,
                     kCGEventLeftMouseDragged};
}

// ---------------------------------------------------------------------------
// Held-state tracking (abort safety, plan §3)
// ---------------------------------------------------------------------------

static NSMutableSet<NSString *> *gHeldButtons;  // "left"/"right"/"middle"

static CGPoint currentCursor(void) {
  CGEventRef ev = CGEventCreate(NULL);
  CGPoint p = CGEventGetLocation(ev);
  CFRelease(ev);
  return p;
}

// Read a [x, y] coordinate; falls back to the current cursor when absent.
static CGPoint pointFromArg(NSDictionary *req, NSString *key, BOOL *present) {
  id v = req[key];
  if ([v isKindOfClass:[NSArray class]] && [(NSArray *)v count] == 2) {
    if (present) *present = YES;
    return CGPointMake([v[0] doubleValue], [v[1] doubleValue]);
  }
  if (present) *present = NO;
  return currentCursor();
}

// ---------------------------------------------------------------------------
// Ops
// ---------------------------------------------------------------------------

static void postMouse(CGEventType type, CGPoint p, CGMouseButton button, int clickState,
                      CGEventFlags flags) {
  CGEventRef ev = CGEventCreateMouseEvent(NULL, type, p, button);
  if (clickState > 0) CGEventSetIntegerValueField(ev, kCGMouseEventClickState, clickState);
  if (flags) CGEventSetFlags(ev, flags);
  CGEventPost(kCGHIDEventTap, ev);
  CFRelease(ev);
}

static void opScreens(id reqId) {
  uint32_t count = 0;
  CGGetActiveDisplayList(0, NULL, &count);
  if (count > 32) count = 32;
  CGDirectDisplayID displays[32];
  CGGetActiveDisplayList(count, displays, &count);

  NSMutableArray *arr = [NSMutableArray array];
  for (uint32_t i = 0; i < count; i++) {
    CGDirectDisplayID d = displays[i];
    CGRect b = CGDisplayBounds(d);
    double scale = 1.0;
    CGDisplayModeRef mode = CGDisplayCopyDisplayMode(d);
    if (mode) {
      size_t pw = CGDisplayModeGetPixelWidth(mode);
      size_t lw = CGDisplayModeGetWidth(mode);
      if (lw > 0) scale = (double)pw / (double)lw;
      CGDisplayModeRelease(mode);
    }
    [arr addObject:@{
      @"id" : @(d),
      @"index" : @(i),
      @"main" : [NSNumber numberWithBool:CGDisplayIsMain(d)],
      @"bounds" : @{
        @"x" : @(b.origin.x),
        @"y" : @(b.origin.y),
        @"width" : @(b.size.width),
        @"height" : @(b.size.height)
      },
      @"scale" : @(scale)
    }];
  }
  writeOk(reqId, @{@"screens" : arr});
}

static void opWindows(id reqId) {
  CFArrayRef list = CGWindowListCopyWindowInfo(
      kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
  NSMutableArray *arr = [NSMutableArray array];
  if (list) {
    NSArray *windows = (__bridge NSArray *)list;
    for (NSDictionary *w in windows) {
      NSDictionary *boundsDict = w[(id)kCGWindowBounds];
      CGRect r = CGRectZero;
      if (boundsDict)
        CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)boundsDict, &r);
      [arr addObject:@{
        @"id" : w[(id)kCGWindowNumber] ?: @(0),
        @"pid" : w[(id)kCGWindowOwnerPID] ?: @(0),
        @"app" : w[(id)kCGWindowOwnerName] ?: @"",
        @"title" : w[(id)kCGWindowName] ?: @"",
        @"layer" : w[(id)kCGWindowLayer] ?: @(0),
        @"bounds" : @{
          @"x" : @(r.origin.x),
          @"y" : @(r.origin.y),
          @"width" : @(r.size.width),
          @"height" : @(r.size.height)
        }
      }];
    }
    CFRelease(list);
  }
  writeOk(reqId, @{@"windows" : arr});
}

static void opCursor(id reqId) {
  CGPoint p = currentCursor();
  writeOk(reqId, @{@"x" : @(p.x), @"y" : @(p.y)});
}

static void opMouseMove(id reqId, NSDictionary *req) {
  CGPoint p = pointFromArg(req, @"coordinate", NULL);
  postMouse(kCGEventMouseMoved, p, kCGMouseButtonLeft, 0, 0);
  writeOk(reqId, @{@"ok" : @YES});
}

static void opMouseDown(id reqId, NSDictionary *req) {
  NSString *button = req[@"button"] ?: @"left";
  MouseKind mk = mouseKindFor(button);
  CGPoint p = pointFromArg(req, @"coordinate", NULL);
  NSArray *mods = req[@"modifiers"];
  CGEventFlags flags = pressModifiers(mods);
  postMouse(mk.downType, p, mk.button, 1, flags);
  // Release the modifier keys immediately (the button stays held): a
  // modified press only needs its modifiers at the down, and leaving them
  // down would latch them if the caller dies before the mouse_up.
  releaseModifiers(mods);
  [gHeldButtons addObject:[button lowercaseString]];
  writeOk(reqId, @{@"ok" : @YES});
}

static void opMouseUp(id reqId, NSDictionary *req) {
  NSString *button = req[@"button"] ?: @"left";
  MouseKind mk = mouseKindFor(button);
  CGPoint p = pointFromArg(req, @"coordinate", NULL);
  postMouse(mk.upType, p, mk.button, 1, 0);
  [gHeldButtons removeObject:[button lowercaseString]];
  writeOk(reqId, @{@"ok" : @YES});
}

static void opClick(id reqId, NSDictionary *req) {
  NSString *button = req[@"button"] ?: @"left";
  MouseKind mk = mouseKindFor(button);
  CGPoint p = pointFromArg(req, @"coordinate", NULL);
  NSArray *mods = req[@"modifiers"];
  CGEventFlags flags = pressModifiers(mods);
  int count = req[@"count"] ? MAX(1, MIN(3, [req[@"count"] intValue])) : 1;

  for (int i = 1; i <= count; i++) {
    postMouse(mk.downType, p, mk.button, i, flags);
    postMouse(mk.upType, p, mk.button, i, flags);
  }
  releaseModifiers(mods);
  writeOk(reqId, @{@"ok" : @YES, @"count" : @(count)});
}

static void opDrag(id reqId, NSDictionary *req) {
  NSString *button = req[@"button"] ?: @"left";
  MouseKind mk = mouseKindFor(button);
  CGPoint start = pointFromArg(req, @"start_coordinate", NULL);
  CGPoint end = pointFromArg(req, @"coordinate", NULL);
  int durationMs = req[@"duration_ms"] ? [req[@"duration_ms"] intValue] : 300;
  if (durationMs < 0) durationMs = 0;
  if (durationMs > 30000) durationMs = 30000;

  int steps = MAX(10, durationMs / 10);
  postMouse(mk.downType, start, mk.button, 1, 0);
  [gHeldButtons addObject:[button lowercaseString]];
  for (int i = 1; i <= steps; i++) {
    double t = (double)i / (double)steps;
    CGPoint p = CGPointMake(start.x + (end.x - start.x) * t, start.y + (end.y - start.y) * t);
    postMouse(mk.dragType, p, mk.button, 0, 0);
    if (durationMs > 0) usleep((useconds_t)(durationMs * 1000 / steps));
  }
  postMouse(mk.upType, end, mk.button, 1, 0);
  [gHeldButtons removeObject:[button lowercaseString]];
  writeOk(reqId, @{@"ok" : @YES});
}

static void opScroll(id reqId, NSDictionary *req) {
  BOOL present = NO;
  CGPoint p = pointFromArg(req, @"coordinate", &present);
  if (present) postMouse(kCGEventMouseMoved, p, kCGMouseButtonLeft, 0, 0);

  NSString *dir = [(req[@"scroll_direction"] ?: @"down") lowercaseString];
  int amount = req[@"scroll_amount"] ? [req[@"scroll_amount"] intValue] : 3;
  int32_t v = 0, h = 0;
  if ([dir isEqualToString:@"up"])
    v = amount;
  else if ([dir isEqualToString:@"down"])
    v = -amount;
  else if ([dir isEqualToString:@"left"])
    h = amount;
  else if ([dir isEqualToString:@"right"])
    h = -amount;

  CGEventRef ev = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitLine, 2, v, h);
  CGEventPost(kCGHIDEventTap, ev);
  CFRelease(ev);
  writeOk(reqId, @{@"ok" : @YES});
}

static void opType(id reqId, NSDictionary *req) {
  NSString *text = req[@"text"];
  if (![text isKindOfClass:[NSString class]]) {
    writeError(reqId, @"type: missing text");
    return;
  }
  NSUInteger len = text.length;
  NSUInteger i = 0;
  while (i < len) {
    NSUInteger chunk = MIN((NSUInteger)20, len - i);
    // Never split a UTF-16 surrogate pair across chunks: a non-BMP character
    // (every emoji) straddling the boundary would be posted as two halves,
    // neither a valid codepoint. Back the boundary off by one unit so the
    // pair travels together in the next chunk. (chunk is only shortened when
    // more text follows, so it can never reach zero: shortening requires
    // chunk == 20.)
    if (i + chunk < len && CFStringIsSurrogateHighCharacter([text characterAtIndex:i + chunk - 1]) &&
        CFStringIsSurrogateLowCharacter([text characterAtIndex:i + chunk])) {
      chunk -= 1;
    }
    unichar buf[20];
    [text getCharacters:buf range:NSMakeRange(i, chunk)];
    CGEventRef down = CGEventCreateKeyboardEvent(NULL, 0, true);
    CGEventKeyboardSetUnicodeString(down, chunk, buf);
    CGEventPost(kCGHIDEventTap, down);
    CFRelease(down);
    CGEventRef up = CGEventCreateKeyboardEvent(NULL, 0, false);
    CGEventKeyboardSetUnicodeString(up, chunk, buf);
    CGEventPost(kCGHIDEventTap, up);
    CFRelease(up);
    i += chunk;
  }
  writeOk(reqId, @{@"ok" : @YES, @"length" : @(len)});
}

static void postKey(int keycode, CGEventFlags flags, BOOL down) {
  CGEventRef ev = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)keycode, down);
  if (flags) CGEventSetFlags(ev, flags);
  CGEventPost(kCGHIDEventTap, ev);
  CFRelease(ev);
}

static void opKey(id reqId, NSDictionary *req) {
  NSString *keyName = req[@"key"];
  if (![keyName isKindOfClass:[NSString class]] || keyName.length == 0) {
    writeError(reqId, @"key: missing key");
    return;
  }
  int kc = keycodeForName(keyName);
  if (kc < 0) {
    writeError(reqId, [NSString stringWithFormat:@"key: unknown key %@", keyName]);
    return;
  }
  NSArray *mods = req[@"modifiers"];
  CGEventFlags flags = pressModifiers(mods);
  postKey(kc, flags, YES);
  postKey(kc, flags, NO);
  releaseModifiers(mods);
  writeOk(reqId, @{@"ok" : @YES});
}

static void opHoldKey(id reqId, NSDictionary *req) {
  NSString *keyName = req[@"key"];
  if (![keyName isKindOfClass:[NSString class]] || keyName.length == 0) {
    writeError(reqId, @"hold_key: missing key");
    return;
  }
  int kc = keycodeForName(keyName);
  if (kc < 0) {
    writeError(reqId, [NSString stringWithFormat:@"hold_key: unknown key %@", keyName]);
    return;
  }
  int durationMs = req[@"duration_ms"] ? [req[@"duration_ms"] intValue] : 100;
  if (durationMs < 0) durationMs = 0;
  if (durationMs > 30000) durationMs = 30000;
  NSArray *mods = req[@"modifiers"];
  CGEventFlags flags = pressModifiers(mods);
  postKey(kc, flags, YES);
  usleep((useconds_t)(durationMs * 1000));
  postKey(kc, flags, NO);
  releaseModifiers(mods);
  writeOk(reqId, @{@"ok" : @YES});
}

static void opReleaseAll(id reqId) {
  CGPoint p = currentCursor();
  // Unconditionally post mouse-up for all three buttons at the current cursor,
  // exactly like the unconditional five-modifier release below. release_all is
  // the compensation sweep a FRESH helper runs after a predecessor died mid-op:
  // this process's own gHeldButtons cannot know what the dead one latched, so a
  // tracked-only sweep would release nothing. An unmatched mouse-up is inert.
  for (NSString *button in @[ @"left", @"right", @"middle" ]) {
    MouseKind mk = mouseKindFor(button);
    postMouse(mk.upType, p, mk.button, 1, 0);
  }
  [gHeldButtons removeAllObjects];
  // Also clear any latched synthetic modifier state (see pressModifiers).
  releaseModifiers(@[ @"command", @"shift", @"control", @"option", @"function" ]);
  writeOk(reqId, @{@"ok" : @YES});
}

static void opTrusted(id reqId) {
  writeOk(reqId, @{@"trusted" : [NSNumber numberWithBool:AXIsProcessTrusted()]});
}

static void opRequestTrust(id reqId) {
  NSDictionary *opts = @{(__bridge id)kAXTrustedCheckOptionPrompt : @YES};
  BOOL trusted = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts);
  writeOk(reqId, @{@"trusted" : [NSNumber numberWithBool:trusted]});
}

static void opScreenCaptureAllowed(id reqId) {
  writeOk(reqId, @{@"allowed" : [NSNumber numberWithBool:CGPreflightScreenCaptureAccess()]});
}

static void opRequestScreenCapture(id reqId) {
  BOOL ok = CGRequestScreenCaptureAccess();
  writeOk(reqId, @{@"allowed" : [NSNumber numberWithBool:ok]});
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

static void handleRequest(NSDictionary *req) {
  id reqId = req[@"id"];
  NSString *op = req[@"op"];
  if (![op isKindOfClass:[NSString class]]) {
    writeError(reqId, @"missing op");
    return;
  }

  if ([op isEqualToString:@"screens"])
    opScreens(reqId);
  else if ([op isEqualToString:@"windows"])
    opWindows(reqId);
  else if ([op isEqualToString:@"cursor"])
    opCursor(reqId);
  else if ([op isEqualToString:@"mouse_move"])
    opMouseMove(reqId, req);
  else if ([op isEqualToString:@"mouse_down"])
    opMouseDown(reqId, req);
  else if ([op isEqualToString:@"mouse_up"])
    opMouseUp(reqId, req);
  else if ([op isEqualToString:@"click"])
    opClick(reqId, req);
  else if ([op isEqualToString:@"drag"])
    opDrag(reqId, req);
  else if ([op isEqualToString:@"scroll"])
    opScroll(reqId, req);
  else if ([op isEqualToString:@"type"])
    opType(reqId, req);
  else if ([op isEqualToString:@"key"])
    opKey(reqId, req);
  else if ([op isEqualToString:@"hold_key"])
    opHoldKey(reqId, req);
  else if ([op isEqualToString:@"release_all"])
    opReleaseAll(reqId);
  else if ([op isEqualToString:@"trusted"])
    opTrusted(reqId);
  else if ([op isEqualToString:@"request_trust"])
    opRequestTrust(reqId);
  else if ([op isEqualToString:@"screen_capture_allowed"])
    opScreenCaptureAllowed(reqId);
  else if ([op isEqualToString:@"request_screen_capture"])
    opRequestScreenCapture(reqId);
  else
    writeError(reqId, [NSString stringWithFormat:@"unknown_op: %@", op]);
}

static void handleLine(NSString *line) {
  NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
  if (!data) {
    writeError(nil, @"invalid_encoding");
    return;
  }
  NSError *err = nil;
  id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
  if (!obj || ![obj isKindOfClass:[NSDictionary class]]) {
    writeError(nil, @"invalid_json");
    return;
  }
  handleRequest((NSDictionary *)obj);
}

static int runServer(void) {
  gHeldButtons = [NSMutableSet set];
  buildNamedKeys();
  buildCharKeyMap();

  char *line = NULL;
  size_t cap = 0;
  ssize_t n;
  while ((n = getline(&line, &cap, stdin)) != -1) {
    @autoreleasepool {
      size_t len = (size_t)n;
      while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r')) len--;
      if (len == 0) continue;
      NSString *s = [[NSString alloc] initWithBytes:line length:len encoding:NSUTF8StringEncoding];
      if (s)
        handleLine(s);
      else
        writeError(nil, @"invalid_encoding");
    }
  }
  free(line);
  return 0;
}

// ---------------------------------------------------------------------------
// --test-target mode (plan §2)
// ---------------------------------------------------------------------------

@interface TargetView : NSView <NSTextFieldDelegate>
- (void)reportEvent:(NSString *)kind extra:(NSDictionary *)extra;
- (NSArray *)modifiersOf:(NSEvent *)e;
@end

@implementation TargetView

- (BOOL)acceptsFirstResponder {
  return YES;
}
- (BOOL)isFlipped {
  return YES;
}

- (void)reportEvent:(NSString *)kind extra:(NSDictionary *)extra {
  NSMutableDictionary *out = [NSMutableDictionary dictionary];
  out[@"event"] = kind;
  [out addEntriesFromDictionary:(extra ?: @{})];
  writeJSONLine(out);
}

- (NSDictionary *)pointOf:(NSEvent *)e {
  NSPoint local = [self convertPoint:e.locationInWindow fromView:nil];
  return @{@"x" : @(local.x), @"y" : @(local.y)};
}

- (NSArray *)modifiersOf:(NSEvent *)e {
  NSMutableArray *mods = [NSMutableArray array];
  NSEventModifierFlags f = e.modifierFlags;
  if (f & NSEventModifierFlagCommand) [mods addObject:@"command"];
  if (f & NSEventModifierFlagShift) [mods addObject:@"shift"];
  if (f & NSEventModifierFlagControl) [mods addObject:@"control"];
  if (f & NSEventModifierFlagOption) [mods addObject:@"option"];
  if (f & NSEventModifierFlagFunction) [mods addObject:@"function"];
  return mods;
}

- (void)reportClick:(NSString *)kind event:(NSEvent *)e {
  NSPoint local = [self convertPoint:e.locationInWindow fromView:nil];
  [self reportEvent:kind
              extra:@{
                @"x" : @(local.x),
                @"y" : @(local.y),
                @"click_count" : @(e.clickCount),
                @"modifiers" : [self modifiersOf:e]
              }];
}

- (void)mouseDown:(NSEvent *)e {
  [self reportClick:@"left_mouse_down" event:e];
}
- (void)mouseUp:(NSEvent *)e {
  [self reportClick:@"left_mouse_up" event:e];
}
- (void)rightMouseDown:(NSEvent *)e {
  [self reportClick:@"right_mouse_down" event:e];
}
- (void)rightMouseUp:(NSEvent *)e {
  [self reportClick:@"right_mouse_up" event:e];
}
- (void)otherMouseDown:(NSEvent *)e {
  [self reportClick:@"middle_mouse_down" event:e];
}
- (void)otherMouseUp:(NSEvent *)e {
  [self reportClick:@"middle_mouse_up" event:e];
}
- (void)mouseDragged:(NSEvent *)e {
  [self reportEvent:@"drag" extra:[self pointOf:e]];
}

- (void)scrollWheel:(NSEvent *)e {
  [self reportEvent:@"scroll"
              extra:@{@"delta_x" : @(e.scrollingDeltaX), @"delta_y" : @(e.scrollingDeltaY)}];
}

// Key events are reported from a local event monitor installed in
// runTestTarget (not from keyDown:), so chords are observed regardless of
// which control is first responder — a focused text field's field editor
// would otherwise swallow them.
- (void)keyDown:(NSEvent *)e {
  (void)e;  // reported by the monitor; swallow to avoid the system beep
}

- (void)controlTextDidChange:(NSNotification *)note {
  NSTextField *field = note.object;
  [self reportEvent:@"text_changed" extra:@{@"text" : field.stringValue ?: @""}];
}

@end

static int runTestTarget(void) {
  @autoreleasepool {
    NSApplication *app = [NSApplication sharedApplication];
    [app setActivationPolicy:NSApplicationActivationPolicyRegular];

    // The target is owned through a stdio pipe (a BEAM Port). When the owner
    // closes the pipe, stdin hits EOF — exit instead of lingering as a
    // headless window on the user's desktop.
    [NSThread detachNewThreadWithBlock:^{
      char buf[256];
      while (fread(buf, 1, sizeof buf, stdin) > 0) {
      }
      exit(0);
    }];

    NSRect frame = NSMakeRect(200, 200, 600, 400);
    NSWindow *window =
        [[NSWindow alloc] initWithContentRect:frame
                                    styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                      backing:NSBackingStoreBuffered
                                        defer:NO];
    [window setTitle:@"catalyst-input test-target"];

    TargetView *view = [[TargetView alloc] initWithFrame:frame];
    [window setContentView:view];

    NSView *redPad = [[NSView alloc] initWithFrame:NSMakeRect(20, 20, 120, 120)];
    redPad.wantsLayer = YES;
    redPad.layer.backgroundColor = [[NSColor systemRedColor] CGColor];
    [view addSubview:redPad];

    NSView *bluePad = [[NSView alloc] initWithFrame:NSMakeRect(160, 20, 120, 120)];
    bluePad.wantsLayer = YES;
    bluePad.layer.backgroundColor = [[NSColor systemBlueColor] CGColor];
    [view addSubview:bluePad];

    NSTextField *textField = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 160, 400, 30)];
    textField.delegate = view;
    [view addSubview:textField];

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(20, 210, 400, 160)];
    scroll.hasVerticalScroller = YES;
    NSTextView *doc = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 400, 800)];
    [doc setString:@"scrollable content\n\n\n\n\n\n\n\n\n\n\n\nend"];
    scroll.documentView = doc;
    [view addSubview:scroll];

    [window makeKeyAndOrderFront:nil];
    // Focus the text field from the start: typed text is observable via
    // text_changed without depending on a click to transfer focus, and the
    // local key monitor below reports chords regardless of the responder.
    [window makeFirstResponder:textField];
    [app activateIgnoringOtherApps:YES];

    // Report every key-down (including cmd-chords) no matter which control is
    // first responder; returning the event keeps normal dispatch working, so
    // typing into the text field still produces text_changed lines too.
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                          handler:^NSEvent *(NSEvent *e) {
                                            [view reportEvent:@"key_down"
                                                        extra:@{
                                                          @"key_code" : @(e.keyCode),
                                                          @"characters" : e.characters ?: @"",
                                                          @"modifiers" : [view modifiersOf:e]
                                                        }];
                                            return e;
                                          }];

    NSRect wf = window.frame;
    writeJSONLine(@{
      @"event" : @"ready",
      @"window_id" : @(window.windowNumber),
      @"frame" : @{
        @"x" : @(wf.origin.x),
        @"y" : @(wf.origin.y),
        @"width" : @(wf.size.width),
        @"height" : @(wf.size.height)
      }
    });

    [app run];
  }
  return 0;
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

int main(int argc, const char *argv[]) {
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--test-target") == 0) return runTestTarget();
  }
  return runServer();
}
