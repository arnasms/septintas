#import "VirtualDisplayShim.h"
#import <CoreGraphics/CoreGraphics.h>

@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, retain) NSString *name;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) CGPoint redPrimary;
@property (nonatomic) CGPoint greenPrimary;
@property (nonatomic) CGPoint bluePrimary;
@property (nonatomic) CGPoint whitePoint;
- (void)setDispatchQueue:(dispatch_queue_t)queue;
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic, retain) NSArray *modes;
@property (nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
@property (nonatomic, readonly) unsigned int displayID;
- (instancetype)initWithDescriptor:(id)descriptor;
- (BOOL)applySettings:(id)settings;
@end

@implementation I7VirtualDisplay {
    CGVirtualDisplay *_display;
}

- (instancetype)initWithName:(NSString *)name
                maxPixelSize:(CGSize)maxPixelSize
           sizeInMillimeters:(CGSize)sizeInMillimeters
                   modeWidth:(uint32_t)width
                  modeHeight:(uint32_t)height {
    self = [super init];
    if (!self) return nil;

    CGVirtualDisplayDescriptor *descriptor = [NSClassFromString(@"CGVirtualDisplayDescriptor") new];
    if (!descriptor) return nil;
    [descriptor setDispatchQueue:dispatch_get_main_queue()];
    descriptor.name = name;
    descriptor.maxPixelsWide = (unsigned int)maxPixelSize.width;
    descriptor.maxPixelsHigh = (unsigned int)maxPixelSize.height;
    descriptor.sizeInMillimeters = sizeInMillimeters;
    // Fixed IDs, so macOS remembers where you arranged this display and which size you picked.
    descriptor.vendorID = 0x6937;
    descriptor.productID = 0x7001;
    descriptor.serialNum = 1;
    descriptor.redPrimary = CGPointMake(0.64, 0.33);
    descriptor.greenPrimary = CGPointMake(0.30, 0.60);
    descriptor.bluePrimary = CGPointMake(0.15, 0.06);
    descriptor.whitePoint = CGPointMake(0.3127, 0.3290);

    _display = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
    if (!_display) return nil;

    // A single mode with HiDPI off is the only setup that reliably gives this exact size: with
    // HiDPI on, macOS picks its own, usually double what was asked for.
    CGVirtualDisplaySettings *settings = [NSClassFromString(@"CGVirtualDisplaySettings") new];
    settings.hiDPI = 0;
    settings.modes = @[[[NSClassFromString(@"CGVirtualDisplayMode") alloc] initWithWidth:width height:height refreshRate:60]];
    if (![_display applySettings:settings]) return nil;
    return self;
}

- (uint32_t)displayID {
    return _display.displayID;
}

@end
