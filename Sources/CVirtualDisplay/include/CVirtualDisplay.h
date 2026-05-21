#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@interface CVirtualDisplayHelper : NSObject

+ (nonnull instancetype)sharedHelper;

- (BOOL)createVirtualDisplayWithWidth:(uint32_t)width height:(uint32_t)height error:(NSError * _Nullable * _Nullable)outError;
- (BOOL)createVirtualDisplayWithLogicalWidth:(uint32_t)logicalWidth
                               logicalHeight:(uint32_t)logicalHeight
                                  pixelWidth:(uint32_t)pixelWidth
                                 pixelHeight:(uint32_t)pixelHeight
                                      hiDPI:(BOOL)hiDPI
                                      error:(NSError * _Nullable * _Nullable)outError;
- (CGDirectDisplayID)currentDisplayID;
- (void)destroyVirtualDisplay;

@end
