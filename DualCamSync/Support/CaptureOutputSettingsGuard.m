#import "CaptureOutputSettingsGuard.h"

@implementation CaptureOutputSettingsGuard
+ (NSString *)failureForSettings:(NSDictionary<NSString *,id> *)settings
             output:(AVCaptureMovieFileOutput *)output
         connection:(AVCaptureConnection *)connection {
    @try {
        if (![output.connections containsObject:connection]) {
            return @"Connection does not belong to output";
        }
        [output setOutputSettings:settings forConnection:connection];
        return nil;
    } @catch (NSException *exception) {
        return [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason ?: @"Unknown reason"];
    }
}
@end
