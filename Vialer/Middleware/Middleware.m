//
//  Middleware.m
//  Copyright © 2016 VoIPGRID. All rights reserved.
//

#import "Middleware.h"

#import "APNSHandler.h"
#import <CocoaLumberjack/CocoaLumberjack.h>
#import "GAITracker.h"
#import "ReachabilityManager.h"
#import "SIPUtils.h"
#import "SSKeychain.h"
#import "SystemUser.h"
#import "VoIPGRIDRequestOperationManager+Middleware.h"

static const DDLogLevel ddLogLevel = DDLogLevelVerbose;

static NSString * const MiddlewareAPNSPayloadKeyType       = @"type";
static NSString * const MiddlewareAPNSPayloadKeyCall       = @"call";
static NSString * const MiddlewareAPNSPayloadKeyCheckin    = @"checkin";
static NSString * const MiddlewareAPNSPayloadKeyMessage    = @"message";

NSString *const MiddlewareAPNSPayloadKeyResponseAPI = @"response_api";

@interface Middleware ()
@property (strong, nonatomic) VoIPGRIDRequestOperationManager *middlewareRequestOperationManager;
@property (weak, nonatomic) SystemUser *systemUser;
@property (strong, nonatomic) ReachabilityManager *reachabilityManager;
@property (strong, nonatomic) NSDate *responseTimer;
@end

@implementation Middleware

#pragma mark - Lifecycle
- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:SystemUserSIPCredentialsChangedNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:SystemUserSIPDisabledNotification object:nil];
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(updateAPNSTokenOnSIPCredentialsChange) name:SystemUserSIPCredentialsChangedNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(deleteSIPAccountFromMiddleware) name:SystemUserSIPDisabledNotification object:nil];
    }
    return self;
}

#pragma mark - properties
- (SystemUser *)systemUser {
    if (!_systemUser) {
        _systemUser = [SystemUser currentUser];
    }
    return _systemUser;
}

- (VoIPGRIDRequestOperationManager *)middlewareRequestOperationManager {
    if (!_middlewareRequestOperationManager) {
        NSURL *baseURL = [NSURL URLWithString: [Configuration UrlForKey:ConfigurationMiddleWareBaseURLString]];
        _middlewareRequestOperationManager = [[VoIPGRIDRequestOperationManager alloc] initWithBaseURL:baseURL];
        _middlewareRequestOperationManager.responseSerializer = [AFHTTPResponseSerializer serializer];

        //To have DELETE also put it's parameters into the request body: (Default on JSON Serializer is to put them in URI)
        _middlewareRequestOperationManager.requestSerializer.HTTPMethodsEncodingParametersInURI = [NSSet setWithObjects:@"GET", @"HEAD", nil];
    }

    if (self.systemUser.username) {
        [_middlewareRequestOperationManager.requestSerializer setAuthorizationHeaderFieldWithUsername:self.systemUser.username password:self.systemUser.password];
    }
    return _middlewareRequestOperationManager;
}

- (ReachabilityManager *)reachabilityManager {
    if (!_reachabilityManager) {
        _reachabilityManager = [[ReachabilityManager alloc] init];
    }
    return _reachabilityManager;
}

#pragma mark - actions
- (void)handleReceivedAPSNPayload:(NSDictionary *)payload {
    NSString *payloadType = payload[MiddlewareAPNSPayloadKeyType];
    DDLogDebug(@"Push message received from middleware.\nPayload: %@", payload);

    // Set current time to measure response time.
    self.responseTimer = [NSDate date];

    if ([payloadType isEqualToString:MiddlewareAPNSPayloadKeyCall]) {
        // Incoming call.

        if ([self.reachabilityManager currentReachabilityStatus] == ReachabilityManagerStatusHighSpeed && [SystemUser currentUser].sipEnabled) {
            // User has good enough connection and is SIP Enabled.
            // Register the account with the endpoint.
            BOOL success = [SIPUtils registerSIPAccountWithEndpoint];
            if (success) {
                // Registration with the endpoint is a success respond OK to the middleware.
                DDLogDebug(@"SIP Endpoint registration success! Sending Available = YES to middleware");
                [self respondToMiddleware:payload isAvailable:YES];
            } else {
                DDLogDebug(@"SIP Endpoint registration FAILED. Senting Available = NO to middleware");
                // Endpoint registration has failed. Respond not available to the middleware.
                [self respondToMiddleware:payload isAvailable:NO];
            }
        } else {
            // User is not SIP enabled or the connection is not good enough.
            // Sent not available to the middleware.
            DDLogDebug(@"Not accepting call, connection quality insufficient or SIP Disabled, Sending Available = NO to middleware");
            [self respondToMiddleware:payload isAvailable:NO];
        }
    } else if ([payloadType isEqualToString:MiddlewareAPNSPayloadKeyCheckin]) {

    } else if ([payloadType isEqualToString:MiddlewareAPNSPayloadKeyMessage]) {

    }
}

- (void)respondToMiddleware:(NSDictionary *)payload isAvailable:(BOOL)available {
    // Track the response that is sent to the middleware.
    if (available) {
        [GAITracker acceptedPushNotificationEvent];
    } else {
        [GAITracker rejectedPushNotificationEvent];
    }

    [self.middlewareRequestOperationManager sentCallResponseToMiddleware:payload isAvailable:available withCompletion:^(NSError * _Nullable error) {

        // Whole response cycle completed, log duration.
        NSTimeInterval responseTime = [[NSDate date] timeIntervalSinceDate:self.responseTimer];
        [GAITracker timeToRespondToIncomingPushNotification:responseTime];

        if (error) {
            DDLogError(@"The middleware responded with an error: %@", error);
        } else {
            DDLogDebug(@"Succsesfully sent \"availabe: %@\" to middleware", available ? @"YES" : @"NO");
        }
    }];
}

/**
 *  Invoked when the SystemUserSIPCredentialsChangedNotification is received.
 */
- (void)updateAPNSTokenOnSIPCredentialsChange {
    if (self.systemUser.sipEnabled) {
        DDLogInfo(@"Sip Credentials have changed, updating Middleware");
        [self sentAPNSToken:[APNSHandler storedAPNSToken]];
    }
}

- (void)deleteSIPAccountFromMiddleware {
    DDLogInfo(@"User disabled SIP, unregistering from middleware");
    [self deleteDeviceRegistrationFromMiddleware];
}

- (void)deleteDeviceRegistrationFromMiddleware {
    NSString *storedAPNSToken = [APNSHandler storedAPNSToken];
    NSString *sipAccount = self.systemUser.sipAccount;

    if (sipAccount && storedAPNSToken) {
        [self.middlewareRequestOperationManager deleteDeviceRecordWithAPNSToken:storedAPNSToken sipAccount:sipAccount withCompletion:^(NSError *error) {
            if (error) {
                DDLogError(@"Error deleting device record from middleware. %@", error);
            } else {
                DDLogDebug(@"Middleware device record deleted successfully");
            }
        }];
    } else {
        DDLogDebug(@"Not deleting device registration from middleware, SIP Account(%@) not set or no APNS Token(%@) stored.",
                   sipAccount, storedAPNSToken);
    }
}

- (void)sentAPNSToken:(NSString *)apnsToken {
    if (self.systemUser.sipEnabled) {
        [self.middlewareRequestOperationManager updateDeviceRecordWithAPNSToken:apnsToken sipAccount:self.systemUser.sipAccount withCompletion:^(NSError *error) {
            if (error) {
                DDLogError(@"Device registration with Middleware failed. %@", error);
                // Disable SIP to give some feedback to the user.
                self.systemUser.sipEnabled = NO;
                // And log the problem to track failures.
                [GAITracker regististrationFailedWithMiddleWareException];
            } else {
                DDLogDebug(@"Middelware registration successfull");
            }
        }];
    }
}

@end