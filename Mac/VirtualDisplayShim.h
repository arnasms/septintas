#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Thin wrapper over macOS's private CGVirtualDisplay classes, looked up at runtime.
/// The display exists for as long as this object does.
@interface I7VirtualDisplay : NSObject
@property (nonatomic, readonly) uint32_t displayID;
- (nullable instancetype)initWithName:(NSString *)name
                         maxPixelSize:(CGSize)maxPixelSize
                    sizeInMillimeters:(CGSize)sizeInMillimeters
                            modeWidth:(uint32_t)width
                           modeHeight:(uint32_t)height;
@end

NS_ASSUME_NONNULL_END
