#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@interface CVirtualDisplayHelper : NSObject

+ (nonnull instancetype)sharedHelper;

- (BOOL)createVirtualDisplayWithWidth:(uint32_t)width height:(uint32_t)height error:(NSError * _Nullable * _Nullable)outError;
- (CGDirectDisplayID)currentDisplayID;
- (void)destroyVirtualDisplay;

@end
