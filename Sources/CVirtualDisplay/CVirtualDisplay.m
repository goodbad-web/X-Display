#import "CVirtualDisplay.h"
#import <dlfcn.h>

@implementation CVirtualDisplayHelper {
    void * _avdHandle;
    id _displayController;
    id _virtualDisplay;
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
        _avdHandle = NULL;
        _displayController = nil;
        _virtualDisplay = nil;
    }
    return self;
}

- (BOOL)createVirtualDisplayWithWidth:(uint32_t)width height:(uint32_t)height error:(NSError **)outError {
    if (_virtualDisplay) {
        return YES; // Already created
    }

    // Dynamic load of AppleVirtualDisplay.framework
    NSString *path = @"/System/Library/PrivateFrameworks/AppleVirtualDisplay.framework/AppleVirtualDisplay";
    _avdHandle = dlopen([path UTF8String], RTLD_LAZY);
    if (!_avdHandle) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"CVirtualDisplay" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Failed to dlopen AppleVirtualDisplay.framework"}];
        }
        return NO;
    }

    Class controllerClass = NSClassFromString(@"AVDVirtualDisplayController");
    Class settingsClass = NSClassFromString(@"AVDVirtualDisplaySettings");

    if (!controllerClass || !settingsClass) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"CVirtualDisplay" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Private classes not found in AppleVirtualDisplay.framework"}];
        }
        return NO;
    }

    _displayController = [[controllerClass alloc] init];
    id settings = [[settingsClass alloc] init];

    // Configure virtual display size
    [settings setValue:@(width) forKey:@"width"];
    [settings setValue:@(height) forKey:@"height"];

    // Selector: - (id)createVirtualDisplayWithSettings:(id)settings queue:(id)queue error:(id*)error;
    SEL createSelector = NSSelectorFromString(@"createVirtualDisplayWithSettings:queue:error:");
    if (![_displayController respondsToSelector:createSelector]) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"CVirtualDisplay" code:3 userInfo:@{NSLocalizedDescriptionKey: @"AVDVirtualDisplayController does not respond to createVirtualDisplaySelector"}];
        }
        return NO;
    }

    // Dynamic invocation utilizing NSInvocation
    NSMethodSignature *sig = [_displayController methodSignatureForSelector:createSelector];
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:sig];
    [invocation setTarget:_displayController];
    [invocation setSelector:createSelector];

    dispatch_queue_t queue = dispatch_get_main_queue();
    __autoreleasing NSError *creationError = nil;
    NSError *__autoreleasing *errPtr = &creationError;

    [invocation setArgument:&settings atIndex:2];
    [invocation setArgument:&queue atIndex:3];
    [invocation setArgument:&errPtr atIndex:4];

    [invocation invoke];

    __unsafe_unretained id displayResult = nil;
    [invocation getReturnValue:&displayResult];

    if (!displayResult || creationError) {
        if (outError) {
            *outError = creationError ? creationError : [NSError errorWithDomain:@"CVirtualDisplay" code:4 userInfo:@{NSLocalizedDescriptionKey: @"Failed to create virtual display"}];
        }
        return NO;
    }

    _virtualDisplay = displayResult;
    return YES;
}

- (void)destroyVirtualDisplay {
    if (_virtualDisplay) {
        // Releases the display and its controller reference
        _virtualDisplay = nil;
        _displayController = nil;
    }
    if (_avdHandle) {
        dlclose(_avdHandle);
        _avdHandle = NULL;
    }
}

- (void)dealloc {
    [self destroyVirtualDisplay];
}

@end
