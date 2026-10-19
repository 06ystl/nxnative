#import "MotionNetworkCheck.h"
#import <Network/Network.h>
#include <errno.h>

@interface MotionNetworkCheck ()
@property nw_connection_t connection;
@property (copy) void (^changed)(NSString *message, BOOL needsSettings);
@property NSUInteger generation;
@end

@implementation MotionNetworkCheck
- (void)cancel {
    self.generation++;
    nw_connection_t connection = self.connection;
    self.connection = nil;
    self.changed = nil;
    if (connection) nw_connection_cancel(connection);
}

- (void)startWithHost:(NSString *)host port:(uint16_t)port
             changed:(void (^)(NSString *message, BOOL needsSettings))changed {
    [self cancel];
    self.changed = changed;
    NSUInteger generation = self.generation;
    NSString *service = [NSString stringWithFormat:@"%hu", port];
    nw_endpoint_t endpoint = nw_endpoint_create_host(host.UTF8String, service.UTF8String);
    // A TCP handshake invokes Apple's connection/permission machinery. No
    // application data is sent and the game's UDP socket is not involved.
    nw_parameters_t parameters = nw_parameters_create_secure_tcp(
        NW_PARAMETERS_DISABLE_PROTOCOL, NW_PARAMETERS_DEFAULT_CONFIGURATION);
    self.connection = nw_connection_create(endpoint, parameters);
    __weak MotionNetworkCheck *weakSelf = self;
    nw_connection_set_state_changed_handler(self.connection, ^(nw_connection_state_t state, nw_error_t error) {
        MotionNetworkCheck *self = weakSelf;
        if (!self || generation != self.generation || !self.connection) return;
        nw_path_t path = nw_connection_copy_current_path(self.connection);
        nw_path_unsatisfied_reason_t reason = path ? nw_path_get_unsatisfied_reason(path) : nw_path_unsatisfied_reason_not_available;
        NSString *message = nil;
        switch (reason) {
            case nw_path_unsatisfied_reason_local_network_denied:
                message = @"Local Network access is denied by iOS. Allow this app in Settings > Privacy & Security > Local Network.";
                break;
            case nw_path_unsatisfied_reason_wifi_denied:
                message = @"Wi-Fi access is denied by iOS. Allow Wi-Fi/Wireless Data for this app in Settings.";
                break;
            case nw_path_unsatisfied_reason_cellular_denied:
                message = @"Cellular access is denied by iOS. Connect the phone and Mac to the same Wi-Fi network.";
                break;
            case nw_path_unsatisfied_reason_vpn_inactive:
                message = @"iOS requires a VPN that is not active. Check the phone's VPN settings.";
                break;
            default:
                break;
        }
        BOOL finished = state == nw_connection_state_ready || state == nw_connection_state_failed;
        if (!message && finished) {
            BOOL routeAllowed = state == nw_connection_state_ready ||
                (error && nw_error_get_error_domain(error) == nw_error_domain_posix &&
                 nw_error_get_error_code(error) == ECONNREFUSED);
            if (routeAllowed)
                message = @"The system allows a connection to the Mac. The motion UDP send still failed.";
            else {
                int domain = error ? (int)nw_error_get_error_domain(error) : 0;
                int code = error ? nw_error_get_error_code(error) : 0;
                message = [NSString stringWithFormat:@"The Mac connection check failed (network domain %d, code %d).", domain, code];
            }
        }
        BOOL needsSettings = reason == nw_path_unsatisfied_reason_local_network_denied ||
                             reason == nw_path_unsatisfied_reason_wifi_denied;
        if (message && self.changed) self.changed(message, needsSettings);
        // A waiting connection stays alive so granting a pending permission
        // can update its path. Explicit Stop cancels this check immediately.
        if (finished && generation == self.generation) [self cancel];
    });
    nw_connection_set_queue(self.connection, dispatch_get_main_queue());
    nw_connection_start(self.connection);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        MotionNetworkCheck *self = weakSelf;
        if (!self || generation != self.generation || !self.connection) return;
        nw_path_t path = nw_connection_copy_current_path(self.connection);
        if (!path || nw_path_get_unsatisfied_reason(path) == nw_path_unsatisfied_reason_not_available) {
            if (self.changed) self.changed(@"The Mac connection check timed out. iOS did not report a permission denial.", NO);
            [self cancel];
        }
    });
}
- (void)dealloc {
    if (_connection) nw_connection_cancel(_connection);
}
@end
