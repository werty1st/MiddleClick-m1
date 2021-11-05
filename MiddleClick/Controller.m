#import "Controller.h"
#include "TrayMenu.h"
#import <Cocoa/Cocoa.h>
#include <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#include <math.h>
#include <unistd.h>

#pragma mark Multitouch API

typedef struct {
  float x, y;
} mtPoint;
typedef struct {
  mtPoint pos, vel;
} mtReadout;

typedef struct {
  int frame;
  double timestamp;
  int identifier, state, foo3, foo4;
  mtReadout normalized;
  float size;
  int zero1;
  float angle, majorAxis, minorAxis; // ellipsoid
  mtReadout mm;
  int zero2[2];
  float unk2;
} Finger;

typedef void* MTDeviceRef;
typedef int (*MTContactCallbackFunction)(int, Finger*, int, double, int);
MTDeviceRef MTDeviceCreateDefault(void);
CFMutableArrayRef MTDeviceCreateList(void);
void MTRegisterContactFrameCallback(MTDeviceRef, MTContactCallbackFunction);
void MTDeviceStart(MTDeviceRef, int); // thanks comex
void MTDeviceStop(MTDeviceRef);

#pragma mark Globals

NSDate* touchStartTime;
float middleclickX, middleclickY;
float middleclickX2, middleclickY2;

BOOL needToClick;
long fingersQua;
BOOL threeDown;
BOOL maybeMiddleClick;
BOOL wasThreeDown;

#pragma mark Implementation

@implementation Controller {
  NSTimer* _restartTimer;
}

- (void)start
{
  threeDown = NO;
  wasThreeDown = NO;
  
  fingersQua = [[NSUserDefaults standardUserDefaults] integerForKey:@"fingers"];
  
  needToClick =
  [[NSUserDefaults standardUserDefaults] boolForKey:@"needClick"];
  
  NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
  [NSApplication sharedApplication];
  
  // Get list of all multi touch devices
  NSMutableArray* deviceList = (NSMutableArray*)MTDeviceCreateList(); // grab our device list
  
  // Iterate and register callbacks for multitouch devices.
  for (int i = 0; i < [deviceList count]; i++) // iterate available devices
  {
    MTRegisterContactFrameCallback((MTDeviceRef)[deviceList objectAtIndex:i],
                                   touchCallback); // assign callback for device
    MTDeviceStart((MTDeviceRef)[deviceList objectAtIndex:i],
                  0); // start sending events
  }
  
  // register a callback to know when osx come back from sleep
  [[[NSWorkspace sharedWorkspace] notificationCenter]
   addObserver:self
   selector:@selector(receiveWakeNote:)
   name:NSWorkspaceDidWakeNotification
   object:NULL];
  
  // Register IOService notifications for added devices.
  IONotificationPortRef port = IONotificationPortCreate(kIOMasterPortDefault);
  CFRunLoopAddSource(CFRunLoopGetMain(),
                     IONotificationPortGetRunLoopSource(port),
                     kCFRunLoopDefaultMode);
  io_iterator_t handle;
  kern_return_t err = IOServiceAddMatchingNotification(
                                                       port, kIOFirstMatchNotification,
                                                       IOServiceMatching("AppleMultitouchDevice"), multitouchDeviceAddedCallback,
                                                       self, &handle);
  if (err) {
    NSLog(@"Failed to register notification for touchpad attach: %xd, will not "
          @"handle newly "
          @"attached devices",
          err);
    IONotificationPortDestroy(port);
  } else {
    //removed because of this:
    //https://stackoverflow.com/questions/1209130/iphone-sdk-exc-bad-access-with-cfrelease-for-abaddressbookref
    /// Iterate through all the existing entries to arm the notification.
//    io_object_t item;
//    while ((item = IOIteratorNext(handle))) {
//      CFRelease( (void*) (long) item);
//    }
  }
  
  // when displays are reconfigured restart of the app is needed, so add a calback to the
  // reconifguration of Core Graphics
  CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallBack, self);
  
  // we only want to see left mouse down and left mouse up, because we only want
  // to change that one
  CGEventMask eventMask = (CGEventMaskBit(kCGEventLeftMouseDown) | CGEventMaskBit(kCGEventLeftMouseUp));
  
  // create eventTap which listens for core grpahic events with the filter
  // sepcified above (so left mouse down and up again)
  CFMachPortRef eventTap = CGEventTapCreate(
                                            kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
                                            eventMask, mouseCallback, NULL);
  
  if (eventTap) {
    // Add to the current run loop.
    CFRunLoopSourceRef runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource,
                       kCFRunLoopCommonModes);
    
    // Enable the event tap.
    CGEventTapEnable(eventTap, true);
    
    // release pool before exit
    [pool release];
  } else {
    NSLog(@"Couldn't create event tap! Check accessibility permissions.");
    [[NSUserDefaults standardUserDefaults] setBool:1 forKey:@"NSStatusItem Visible Item-0"];
    [self scheduleRestart:5];
  }
}

/// Schedule app to be restarted, if a restart is pending, delay it.
- (void)scheduleRestart:(NSTimeInterval)delay
{
  [_restartTimer invalidate]; // Invalidate any existing timer.
  
  _restartTimer = [NSTimer scheduledTimerWithTimeInterval:delay
                                                  repeats:NO
                                                    block:^(NSTimer* timer) {
                                                      restartApp();
                                                    }];
}

// Callback for system wake up. This restarts the app to initialize callbacks.
- (void)receiveWakeNote:(NSNotification*)note
{
  [self scheduleRestart:10];
}

- (BOOL)getClickMode
{
  return needToClick;
}

- (void)setMode:(BOOL)click
{
  [[NSUserDefaults standardUserDefaults] setBool:click forKey:@"needClick"];
  needToClick = click;
}

// listening to mouse clicks to replace them with middle clicks if there are 3
// fingers down at the time of clicking this is done by replacing the left click
// down with a other click down and setting the button number to middle click
// when 3 fingers are down when clicking, and by replacing left click up with
// other click up and setting three button number to middle click when 3 fingers
// were down when the last click went down.
CGEventRef mouseCallback(CGEventTapProxy proxy, CGEventType type,
                         CGEventRef event, void* refcon)
{
  if (needToClick) {
    if (threeDown && type == kCGEventLeftMouseDown) {
      wasThreeDown = YES;
      CGEventSetType(event, kCGEventOtherMouseDown);
      CGEventSetIntegerValueField(event, kCGMouseEventButtonNumber,
                                  kCGMouseButtonCenter);
      threeDown = NO;
    }
    
    if (wasThreeDown && type == kCGEventLeftMouseUp) {
      wasThreeDown = NO;
      CGEventSetType(event, kCGEventOtherMouseUp);
      CGEventSetIntegerValueField(event, kCGMouseEventButtonNumber,
                                  kCGMouseButtonCenter);
    }
  }
  return event;
}

// mulittouch callback, see what is touched. If 3 are on the mouse set
// threedowns, else unset threedowns.
int touchCallback(int device, Finger* data, int nFingers, double timestamp,
                  int frame)
{
  NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
  fingersQua = [[NSUserDefaults standardUserDefaults] integerForKey:@"fingers"];
  
  if (needToClick) {
    if (nFingers == fingersQua) {
      if (!threeDown) {
        threeDown = YES;
      }
    }
    
    if (nFingers != fingersQua) {
      if (threeDown) {
        threeDown = NO;
      }
    }
  } else {
    if (nFingers == 0) {
      touchStartTime = NULL;
      if (middleclickX + middleclickY) {
        float delta = ABS(middleclickX - middleclickX2) + ABS(middleclickY - middleclickY2);
        if (delta < 0.4f) {
          // Emulate a middle click
          
          // get the current pointer location
          CGEventRef ourEvent = CGEventCreate(NULL);
          CGPoint ourLoc = CGEventGetLocation(ourEvent);
          
          CGEventPost(kCGHIDEventTap,
                      CGEventCreateMouseEvent(NULL, kCGEventOtherMouseDown,
                                              ourLoc, kCGMouseButtonCenter));
          CGEventPost(kCGHIDEventTap,
                      CGEventCreateMouseEvent(NULL, kCGEventOtherMouseUp,
                                              ourLoc, kCGMouseButtonCenter));
        }
      }
    } else if (nFingers > 0 && touchStartTime == NULL) {
      NSDate* now = [[NSDate alloc] init];
      touchStartTime = [now retain];
      [now release];
      
      maybeMiddleClick = YES;
      middleclickX = 0.0f;
      middleclickY = 0.0f;
    } else {
      if (maybeMiddleClick == YES) {
        NSTimeInterval elapsedTime = -[touchStartTime timeIntervalSinceNow];
        if (elapsedTime > 0.5f)
          maybeMiddleClick = NO;
      }
    }
    
    if (nFingers > fingersQua) {
      maybeMiddleClick = NO;
      middleclickX = 0.0f;
      middleclickY = 0.0f;
    }
    
    if (nFingers == fingersQua) {
      Finger* f1 = &data[0];
      Finger* f2 = &data[1];
      Finger* f3 = &data[2];
      
      if (maybeMiddleClick == YES) {
        middleclickX = (f1->normalized.pos.x + f2->normalized.pos.x + f3->normalized.pos.x);
        middleclickY = (f1->normalized.pos.y + f2->normalized.pos.y + f3->normalized.pos.y);
        middleclickX2 = middleclickX;
        middleclickY2 = middleclickY;
        maybeMiddleClick = NO;
      } else {
        middleclickX2 = (f1->normalized.pos.x + f2->normalized.pos.x + f3->normalized.pos.x);
        middleclickY2 = (f1->normalized.pos.y + f2->normalized.pos.y + f3->normalized.pos.y);
      }
    }
  }
  
  [pool release];
  return 0;
}

/// Relaunch the app when devices are connected/invalidated.
static void restartApp()
{
  NSTask *task = [[[NSTask alloc] init] autorelease];
  NSMutableArray *args = [NSMutableArray array];
  [args addObject:@"-c"];
  [args addObject:[NSString stringWithFormat:@"sleep %f; open \"%@\"", 1.0, [[NSBundle mainBundle] bundlePath]]];
  [task setLaunchPath:@"/bin/sh"];
  [task setArguments:args];
  [task launch];
  NSLog(@"Restarting app...");
  
  [NSApp terminate:NULL];
}

/// Callback when a multitouch device is added.
void multitouchDeviceAddedCallback(void* _controller,
                                   io_iterator_t iterator)
{
  //removed because of this:
  //https://stackoverflow.com/questions/1209130/iphone-sdk-exc-bad-access-with-cfrelease-for-abaddressbookref
  /// Loop through all the returned items.
//  io_object_t item;
//  while ((item = IOIteratorNext(iterator))) {
//      CFRelease( (void*) (long) item);
//  }
  
  NSLog(@"Multitouch device added, restarting...");
  Controller* controller = (Controller*)_controller;
  [controller scheduleRestart:2];
}

void displayReconfigurationCallBack(CGDirectDisplayID display, CGDisplayChangeSummaryFlags flags, void* _controller)
{
  if(flags & kCGDisplaySetModeFlag || flags & kCGDisplayAddFlag || flags & kCGDisplayRemoveFlag || flags & kCGDisplayDisabledFlag)
  {
    NSLog(@"Display reconfigured, restarting...");
    Controller* controller = (Controller*)_controller;
    [controller scheduleRestart:2];
  }
}



@end
