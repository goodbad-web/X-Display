#import <Foundation/Foundation.h>

@interface CVirtualDisplayHelper : NSObject

+ (nonnull instancetype)sharedHelper;

- (BOOL)createVirtualDisplayWithWidth:(uint32_t)width height:(uint32_t)height error:(NSError * _Nullable * _Nullable)outError;
- (void)destroyVirtualDisplay;

@end
