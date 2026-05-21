#import "CVirtualDisplay.h"
#import <CoreGraphics/CoreGraphics.h>

// Redeclare private CoreGraphics classes for virtual display support
@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) uint32_t maxPixelsWide;
@property (nonatomic) uint32_t maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) uint32_t productID;
@property (nonatomic) uint32_t vendorID;
@property (nonatomic) uint32_t serialNum;
@property (nonatomic) CGPoint redPrimary;
@property (nonatomic) CGPoint greenPrimary;
@property (nonatomic) CGPoint bluePrimary;
@property (nonatomic) CGPoint whitePoint;
@property (nonatomic, strong) dispatch_queue_t queue;
@end

@interface CGVirtualDisplayMode : NSObject
@property (nonatomic) uint32_t width;
@property (nonatomic) uint32_t height;
@property (nonatomic) double refreshRate;
- (instancetype)initWithWidth:(uint32_t)width height:(uint32_t)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic, copy) NSArray<CGVirtualDisplayMode *> *modes;
@property (nonatomic) uint32_t hiDPI;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (nonatomic, readonly) CGDirectDisplayID displayID;
@property (nonatomic, readonly) NSArray<CGVirtualDisplayMode *> *modes;
@end

@implementation CVirtualDisplayHelper {
    CGVirtualDisplay * _virtualDisplay;
}

+ (instancetype)sharedHelper {
    static CVirtualDisplayHelper *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _virtualDisplay = nil;
    }
    return self;
}

- (BOOL)createVirtualDisplayWithWidth:(uint32_t)width height:(uint32_t)height error:(NSError **)outError {
    NSLog(@"[CVirtualDisplayHelper] Starting createVirtualDisplayWithWidth: %u x %u", width, height);
    if (_virtualDisplay) {
        NSLog(@"[CVirtualDisplayHelper] Virtual display already exists.");
        return YES; // Already created
    }

    NSLog(@"[CVirtualDisplayHelper] Loading private classes...");
    Class descriptorClass = NSClassFromString(@"CGVirtualDisplayDescriptor");
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    Class settingsClass = NSClassFromString(@"CGVirtualDisplaySettings");
    Class displayClass = NSClassFromString(@"CGVirtualDisplay");

    NSLog(@"[CVirtualDisplayHelper] descriptorClass: %@, modeClass: %@, settingsClass: %@, displayClass: %@", descriptorClass, modeClass, settingsClass, displayClass);
    if (!descriptorClass || !modeClass || !settingsClass || !displayClass) {
        NSLog(@"[CVirtualDisplayHelper] Error: Private classes not found.");
        if (outError) {
            *outError = [NSError errorWithDomain:@"CVirtualDisplay" code:1 userInfo:@{NSLocalizedDescriptionKey: @"CGVirtualDisplay private classes are not available in CoreGraphics."}];
        }
        return NO;
    }

    if (![displayClass instancesRespondToSelector:@selector(initWithDescriptor:)] ||
        ![displayClass instancesRespondToSelector:@selector(applySettings:)] ||
        ![settingsClass instancesRespondToSelector:@selector(init)] ||
        ![settingsClass instancesRespondToSelector:@selector(setModes:)] ||
        ![modeClass instancesRespondToSelector:@selector(initWithWidth:height:refreshRate:)]) {
        NSLog(@"[CVirtualDisplayHelper] Error: Required private selectors are not available.");
        if (outError) {
            *outError = [NSError errorWithDomain:@"CVirtualDisplay"
                                            code:3
                                        userInfo:@{NSLocalizedDescriptionKey: @"Required CGVirtualDisplay selectors are unavailable."}];
        }
        return NO;
    }

    NSLog(@"[CVirtualDisplayHelper] Initializing CGVirtualDisplayDescriptor...");
    CGVirtualDisplayDescriptor *descriptor = [[descriptorClass alloc] init];
    descriptor.name = @"X-Display Virtual Display";
    descriptor.maxPixelsWide = width;
    descriptor.maxPixelsHigh = height;
    descriptor.redPrimary = CGPointMake(0.6797, 0.3203);
    descriptor.greenPrimary = CGPointMake(0.2559, 0.6983);
    descriptor.bluePrimary = CGPointMake(0.1494, 0.0557);
    descriptor.whitePoint = CGPointMake(0.3125, 0.3291);
    descriptor.queue = dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0);
    
    // Standard screen density calculation (110 PPI is typical for virtual displays)
    descriptor.sizeInMillimeters = CGSizeMake(25.4 * width / 110.0, 25.4 * height / 110.0);
    descriptor.productID = 0x1234;
    descriptor.vendorID = 0x5678;
    descriptor.serialNum = 0x0001;

    NSLog(@"[CVirtualDisplayHelper] Initializing CGVirtualDisplaySettings...");
    CGVirtualDisplaySettings *settings = [[settingsClass alloc] init];
    settings.hiDPI = 0;

    NSLog(@"[CVirtualDisplayHelper] Initializing CGVirtualDisplayMode...");
    uint32_t modeWidth = width;
    uint32_t modeHeight = height;
    if (settings.hiDPI) {
        modeWidth /= 2;
        modeHeight /= 2;
    }
    CGVirtualDisplayMode *mode = [[modeClass alloc] initWithWidth:modeWidth height:modeHeight refreshRate:60.0];
    NSLog(@"[CVirtualDisplayHelper] Allocated mode: %@", mode);
    settings.modes = @[mode];

    NSLog(@"[CVirtualDisplayHelper] Allocating CGVirtualDisplay...");
    CGVirtualDisplay *virtualDisplay = [[displayClass alloc] initWithDescriptor:descriptor];
    NSLog(@"[CVirtualDisplayHelper] Allocated display: %@", virtualDisplay);
    if (!virtualDisplay) {
        NSLog(@"[CVirtualDisplayHelper] Error: Failed to initialize CGVirtualDisplay.");
        if (outError) {
            *outError = [NSError errorWithDomain:@"CVirtualDisplay" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Failed to initialize CGVirtualDisplay."}];
        }
        return NO;
    }

    NSLog(@"[CVirtualDisplayHelper] Applying settings to display...");
    BOOL applied = [virtualDisplay applySettings:settings];
    if (!applied) {
        NSLog(@"[CVirtualDisplayHelper] Error: Failed to apply virtual display settings.");
        if (outError) {
            *outError = [NSError errorWithDomain:@"CVirtualDisplay" code:4 userInfo:@{NSLocalizedDescriptionKey: @"Failed to apply CGVirtualDisplaySettings."}];
        }
        return NO;
    }

    NSLog(@"[CVirtualDisplayHelper] Saving virtualDisplay reference...");
    _virtualDisplay = virtualDisplay;
    NSLog(@"[CVirtualDisplayHelper] Virtual display creation completed successfully!");
    return YES;
}

- (void)destroyVirtualDisplay {
    if (_virtualDisplay) {
        _virtualDisplay = nil;
    }
}

- (CGDirectDisplayID)currentDisplayID {
    if (!_virtualDisplay) {
        return kCGNullDirectDisplay;
    }
    return _virtualDisplay.displayID;
}

- (void)dealloc {
    [self destroyVirtualDisplay];
}

@end
