// Runtime-isolated declarations for macOS's private virtual-display API.
// Signatures cross-checked with installed UsbDisplay and Chromium's
// ui/display/mac/test/virtual_display_util_mac.mm (blob a160fd6e...), 2026-09-07.
// This executable owns display lifetime; it never opens USB devices.
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#include <signal.h>
#include <unistd.h>

@interface QVirtualDescriptor : NSObject
@property unsigned int vendorID, productID, serialNum, serialNumber;
@property unsigned int maxPixelsWide, maxPixelsHigh;
@property CGSize sizeInMillimeters;
@property CGPoint redPrimary, greenPrimary, bluePrimary, whitePoint;
@property(strong) NSString *name;
@property(strong) id queue;
@end
@interface QVirtualMode : NSObject
- (id)initWithWidth:(unsigned int)w height:(unsigned int)h refreshRate:(double)rate;
@end
@interface QVirtualSettings : NSObject
@property unsigned int hiDPI, rotation;
@property(strong) NSArray *modes;
@end
@interface QVirtualDisplay : NSObject
- (id)initWithDescriptor:(id)descriptor;
- (BOOL)applySettings:(id)settings;
@property(readonly) unsigned int displayID;
@end

static void emit(NSDictionary *record) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:nil];
    fwrite(data.bytes,1,data.length,stdout);fputc('\n',stdout);fflush(stdout);
}
static NSArray *displayList(void) {
    CGDirectDisplayID ids[32];uint32_t count=0;
    if(CGGetActiveDisplayList(32,ids,&count)!=kCGErrorSuccess)return nil;
    NSMutableArray *rows=[NSMutableArray array];
    for(uint32_t i=0;i<count;++i) {
        CGRect b=CGDisplayBounds(ids[i]);
        [rows addObject:@{@"display_id":@(ids[i]),@"x":@(b.origin.x),@"y":@(b.origin.y),
            @"width":@(b.size.width),@"height":@(b.size.height),
            @"vendor_id":@(CGDisplayVendorNumber(ids[i])),@"serial":@(CGDisplaySerialNumber(ids[i])),
            @"mirrored":@((BOOL)(CGDisplayIsInMirrorSet(ids[i])!=0)),@"builtin":@((BOOL)(CGDisplayIsBuiltin(ids[i])!=0))}];
    }
    return rows;
}
static BOOL available(void) {
    return NSClassFromString(@"CGVirtualDisplay") && NSClassFromString(@"CGVirtualDisplayDescriptor") &&
           NSClassFromString(@"CGVirtualDisplayMode") && NSClassFromString(@"CGVirtualDisplaySettings") &&
           [NSClassFromString(@"CGVirtualDisplay") instancesRespondToSelector:@selector(initWithDescriptor:)] &&
           [NSClassFromString(@"CGVirtualDisplay") instancesRespondToSelector:@selector(applySettings:)] &&
           [NSClassFromString(@"CGVirtualDisplayMode") instancesRespondToSelector:@selector(initWithWidth:height:refreshRate:)];
}

@interface DemoView : NSView
@property NSInteger number, tick;
@property(strong) NSString *role;
@end
@implementation DemoView
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSArray *colors=@[[NSColor colorWithSRGBRed:160/255.0 green:30/255.0 blue:35/255.0 alpha:1],
                     [NSColor colorWithSRGBRed:20/255.0 green:110/255.0 blue:50/255.0 alpha:1],
                     [NSColor colorWithSRGBRed:25/255.0 green:65/255.0 blue:170/255.0 alpha:1]];
    [colors[self.number-1] setFill];NSRectFill(self.bounds);
    [[NSColor whiteColor] setStroke];NSFrameRectWithWidth(NSInsetRect(self.bounds,24,24),8);
    NSDictionary *style=@{NSFontAttributeName:[NSFont boldSystemFontOfSize:110],NSForegroundColorAttributeName:NSColor.whiteColor};
    NSString *title=[NSString stringWithFormat:@"%@  %ld",self.role.uppercaseString,(long)self.number];
    NSSize size=[title sizeWithAttributes:style];
    [title drawAtPoint:NSMakePoint((self.bounds.size.width-size.width)/2,800) withAttributes:style];
    NSString *counter=[NSString stringWithFormat:@"LIVE %06ld",(long)(self.number*10000+self.tick)];
    [counter drawAtPoint:NSMakePoint(420,550) withAttributes:style];
    [[NSColor whiteColor] setFill];
    CGFloat x=60+(self.tick*35+self.number*200)%1500;
    NSRectFill(NSMakeRect(x,250,220,50));
}
@end

@interface Host : NSObject <NSApplicationDelegate>
@property(strong) NSMutableDictionary *displays;
@property(strong) NSMutableArray *windows;
@property(strong) NSArray *selectedRoles;
@property(strong) NSTimer *timer;
@property(strong) dispatch_source_t inputSource, termSource, intSource;
@property BOOL demo;
@property int seconds, result, demoFPS;
@property CGDirectDisplayID anchorID;
@property CGRect anchorBounds;
@end
@implementation Host
- (void)stop {
    [NSApp stop:nil];
    [NSApp postEvent:[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint
        modifierFlags:0 timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0] atStart:NO];
}
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    (void)note;
    @try { [self setup]; }
    @catch(NSException *exception) {
        self.result=1;emit(@{@"event":@"failure",@"error":exception.reason ?: @"virtual display failure"});[self stop];
    }
}
- (void)setup {
    self.displays=[NSMutableDictionary dictionary];self.windows=[NSMutableArray array];
    self.anchorID=CGMainDisplayID();self.anchorBounds=CGDisplayBounds(self.anchorID);
    NSArray *roles=@[@"right",@"left",@"top"];
    for(int i=0;i<3;++i) {
        if(![self.selectedRoles containsObject:roles[i]])continue;
        @autoreleasepool {
            QVirtualDescriptor *d=[[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
            d.name=[NSString stringWithFormat:@"Quad %@ %d",roles[i],i+1];
            d.vendorID=0x5155;d.productID=1;d.serialNum=0x51550101+i;
            if([d respondsToSelector:@selector(setSerialNumber:)])d.serialNumber=d.serialNum;
            d.maxPixelsWide=1920;d.maxPixelsHigh=1200;d.sizeInMillimeters=CGSizeMake(530,300);
            d.redPrimary=CGPointMake(.64,.33);d.greenPrimary=CGPointMake(.30,.60);
            d.bluePrimary=CGPointMake(.15,.06);d.whitePoint=CGPointMake(.3127,.3290);
            d.queue=dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0);
            QVirtualDisplay *display=[[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:d];
            if(!display || !display.displayID)[NSException raise:@"Create" format:@"create %@ failed",roles[i]];
            self.displays[roles[i]]=display;
            QVirtualSettings *settings=[[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
            settings.hiDPI=0;settings.rotation=0;
            settings.modes=@[[[NSClassFromString(@"CGVirtualDisplayMode") alloc] initWithWidth:1920 height:1200 refreshRate:60]];
            if(![display applySettings:settings])[NSException raise:@"Mode" format:@"mode %@ failed",roles[i]];
        }
    }
    // Give WindowServer/AppKit time to publish the new screens; no USB yet.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,1000*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        @try { [self arrange]; }
        @catch(NSException *e) {self.result=1;emit(@{@"event":@"failure",@"error":e.reason});[self stop];}
    });
}
- (void)arrange {
    NSArray *roles=@[@"right",@"left",@"top"];
    CGRect anchor=self.anchorBounds;
    struct { int x[3], y[3]; } origins={
        {(int)CGRectGetMaxX(anchor),(int)anchor.origin.x-1920,(int)(CGRectGetMidX(anchor)-960)},
        {(int)anchor.origin.y,(int)anchor.origin.y,(int)anchor.origin.y-1200}};
    CGDisplayConfigRef config=NULL;
    CGError rc=CGBeginDisplayConfiguration(&config);
    if(rc!=kCGErrorSuccess)[NSException raise:@"Layout" format:@"begin config %d",rc];
    rc=CGConfigureDisplayOrigin(config,self.anchorID,(int)anchor.origin.x,(int)anchor.origin.y);
    for(int i=0;i<3 && rc==kCGErrorSuccess;++i) {
        if(![self.selectedRoles containsObject:roles[i]])continue;
        CGDirectDisplayID did=[self.displays[roles[i]] displayID];
        rc=CGConfigureDisplayMirrorOfDisplay(config,did,kCGNullDirectDisplay);
        if(rc==kCGErrorSuccess)rc=CGConfigureDisplayOrigin(config,did,origins.x[i],origins.y[i]);
    }
    if(rc!=kCGErrorSuccess) {CGCancelDisplayConfiguration(config);[NSException raise:@"Layout" format:@"configure %d",rc];}
    rc=CGCompleteDisplayConfiguration(config,kCGConfigureForSession);
    if(rc!=kCGErrorSuccess)[NSException raise:@"Layout" format:@"commit %d",rc];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,500*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        @try {
            NSMutableArray *rows=[NSMutableArray array];NSArray *active=displayList();
            for(int i=0;i<3;++i) {
        if(![self.selectedRoles containsObject:roles[i]])continue;
                CGDirectDisplayID did=[self.displays[roles[i]] displayID];
                NSDictionary *row=nil;
                for(NSDictionary *entry in active)if([entry[@"display_id"] unsignedIntValue]==did)row=entry;
                if(!row || [row[@"mirrored"] boolValue] || [row[@"width"] intValue]!=1920 || [row[@"height"] intValue]!=1200)
                    [NSException raise:@"Readiness" format:@"%@ is not active, independent 1920x1200",roles[i]];
                if([row[@"x"] intValue]!=origins.x[i] || [row[@"y"] intValue]!=origins.y[i])
                    [NSException raise:@"Layout" format:@"%@ origin differs from the physical layout",roles[i]];
                NSMutableDictionary *bound=[row mutableCopy];bound[@"role"]=roles[i];[rows addObject:bound];
                if(self.demo)[self showDemo:did role:roles[i] number:i+1];
            }
            self.timer=[NSTimer scheduledTimerWithTimeInterval:1.0/self.demoFPS repeats:YES block:^(NSTimer *t){
                (void)t;for(NSWindow *w in self.windows){DemoView *v=(DemoView *)w.contentView;v.tick++;v.needsDisplay=YES;}
            }];
            emit(@{@"event":@"ready",@"displays":rows,@"demo":@(self.demo)});
        } @catch(NSException *e) {self.result=1;emit(@{@"event":@"failure",@"error":e.reason});[self stop];}
    });
}
- (void)showDemo:(CGDirectDisplayID)did role:(NSString *)role number:(NSInteger)number {
    NSScreen *screen=nil;
    for(NSScreen *s in NSScreen.screens)if([s.deviceDescription[@"NSScreenNumber"] unsignedIntValue]==did)screen=s;
    if(!screen)[NSException raise:@"Demo" format:@"no AppKit screen for %@",role];
    NSWindow *window=[[NSWindow alloc] initWithContentRect:screen.frame styleMask:NSWindowStyleMaskBorderless
                                                   backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed=NO;
    DemoView *view=[[DemoView alloc] initWithFrame:NSMakeRect(0,0,1920,1200)];view.role=role;view.number=number;
    window.contentView=view;[window setFrame:screen.frame display:YES];
    window.level=NSNormalWindowLevel;[window orderFrontRegardless];[self.windows addObject:window];
}
- (void)cleanup {
    [self.timer invalidate];self.timer=nil;
    for(NSWindow *w in self.windows)[w close];[self.windows removeAllObjects];
    [self.displays removeAllObjects];
}
@end

int main(int argc,const char **argv) {
    @autoreleasepool {
        if(argc==2 && !strcmp(argv[1],"--preflight")) {emit(@{@"available":@(available())});return available()?0:1;}
        if(argc==2 && !strcmp(argv[1],"--list")) {emit(@{@"displays":displayList() ?: @[]});return 0;}
        if(argc<4 || strcmp(argv[1],"--run") || strcmp(argv[2],"--seconds"))return 2;
        BOOL demo=NO;int demoFPS=2;NSArray *selectedRoles=@[@"right",@"left",@"top"];BOOL hasRoles=NO;
        for(int i=4;i<argc;++i) {
            if(!strcmp(argv[i],"--panels") && i+1<argc && !hasRoles) {
                hasRoles=YES;selectedRoles=[[NSString stringWithUTF8String:argv[++i]] componentsSeparatedByString:@","];
                NSSet *allowed=[NSSet setWithArray:@[@"right",@"left",@"top"]];
                NSSet *selected=[NSSet setWithArray:selectedRoles];
                if(!selected.count || selected.count!=selectedRoles.count || ![selected isSubsetOfSet:allowed])return 2;
            }
            else if(!strcmp(argv[i],"--demo") && !demo)demo=YES;
            else if(!strcmp(argv[i],"--demo-fps") && i+1<argc) {
                char *rateEnd=NULL;long rate=strtol(argv[++i],&rateEnd,10);
                if(!*argv[i] || *rateEnd || rate<1 || rate>60)return 2;
                demoFPS=(int)rate;
            } else return 2;
        }
        char *end=NULL;long duration=strtol(argv[3],&end,10);
        if(!*argv[3] || *end || duration<0 || duration>3645 || !available())return 2;
        [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        Host *host=[Host new];host.selectedRoles=selectedRoles;host.demo=demo;host.demoFPS=demoFPS;host.seconds=(int)duration;NSApp.delegate=host;
        signal(SIGTERM,SIG_IGN);signal(SIGINT,SIG_IGN);
        host.termSource=dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,SIGTERM,0,dispatch_get_main_queue());
        dispatch_source_set_event_handler(host.termSource,^{[host stop];});dispatch_resume(host.termSource);
        host.intSource=dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,SIGINT,0,dispatch_get_main_queue());
        dispatch_source_set_event_handler(host.intSource,^{[host stop];});dispatch_resume(host.intSource);
        host.inputSource=dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,STDIN_FILENO,0,dispatch_get_main_queue());
        dispatch_source_set_event_handler(host.inputSource,^{char b[32];if(read(STDIN_FILENO,b,sizeof(b))<=0 || b[0]=='S')[host stop];});
        dispatch_resume(host.inputSource);
        if(duration>0)dispatch_after(dispatch_time(DISPATCH_TIME_NOW,duration*NSEC_PER_SEC),dispatch_get_main_queue(),^{[host stop];});
        [NSApp run];[host cleanup];emit(@{@"event":@"stopped",@"result":@(host.result)});
        return host.result;
    }
}
