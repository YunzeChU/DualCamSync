#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN
/// A narrow exception boundary for AVFoundation's Objective-C setter.
@interface CaptureOutputSettingsGuard : NSObject
+ (nullable NSString *)failureForSettings:(NSDictionary<NSString *, id> *)settings
             output:(AVCaptureMovieFileOutput *)output
         connection:(AVCaptureConnection *)connection
    NS_SWIFT_NAME(failure(forSettings:output:connection:));
@end
NS_ASSUME_NONNULL_END
