#import <Foundation/Foundation.h>

// Check the system path to the requesting Mac without sending game data.
@interface MotionNetworkCheck : NSObject
- (void)startWithHost:(NSString *)host port:(uint16_t)port
             changed:(void (^)(NSString *message, BOOL needsSettings))changed;
- (void)cancel;
@end
