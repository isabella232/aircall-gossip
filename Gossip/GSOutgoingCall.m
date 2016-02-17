//
//  GSOutgoingCall.m
//  Gossip
//
//  Created by Chakrit Wichian on 7/12/12.
//

#import "GSOutgoingCall.h"
#import "GSCall+Private.h"
#import "PJSIP.h"
#import "Util.h"


@implementation GSOutgoingCall

@synthesize remoteUri = _remoteUri;
@synthesize callerId = _callerId;
@synthesize userId = _userId;
@synthesize internalToUserId = _internalToUserId;
@synthesize appToApp = _appToApp;

- (id)initWithRemoteUri:(NSString *)remoteUri
            fromAccount:(GSAccount *)account
           withCallerId:(NSString *)callerId
             withUserId:(NSString *)userId
   withInternalToUserId:(NSString *)internalToUserId
           withAppToApp:(NSString *)appToApp
{
    if (self = [super initWithAccount:account]) {
        _remoteUri = [remoteUri copy];
        _callerId = [callerId copy];
        _userId = [userId copy];
        _internalToUserId = [internalToUserId copy];
        _appToApp = [appToApp copy];
    }
    return self;
}

- (void)dealloc {
    _remoteUri = nil;
    _callerId = nil;
    _userId = nil;
    _internalToUserId = nil;
    _appToApp = nil;
}


- (BOOL)begin {
    if (![_remoteUri hasPrefix:@"sip:"])
        _remoteUri = [@"sip:" stringByAppendingString:_remoteUri];
    
    // Extra headers:
    pjsua_msg_data msg_data;
    pjsua_msg_data_init(&msg_data);
    pj_pool_t *pool;

    pj_caching_pool cp;
    pj_caching_pool_init(&cp, &pj_pool_factory_default_policy, 0);
    pool = pj_pool_create(&cp.factory, "header", 1000, 1000, NULL);
    
    pj_str_t hNameCaller = pj_str((char *)"X-PH-CALLERID");
    pj_str_t hValueCaller = [GSPJUtil PJStringWithString:_callerId];
    pjsip_generic_string_hdr* add_hdr_caller = pjsip_generic_string_hdr_create(pool,
                                                                               &hNameCaller,
                                                                               &hValueCaller);
    pj_list_push_back(&msg_data.hdr_list, add_hdr_caller);
    
    pj_str_t hNameUser = pj_str((char *)"X-PH-USERID");
    pj_str_t hValueUser = [GSPJUtil PJStringWithString:_userId];
    pjsip_generic_string_hdr* add_hdr_user = pjsip_generic_string_hdr_create(pool, &hNameUser, &hValueUser);
    pj_list_push_back(&msg_data.hdr_list, add_hdr_user);

    pj_str_t hInternalUser = pj_str((char *)"X-PH-INTERNALTOUSERID");
    pj_str_t hValueInternal = [GSPJUtil PJStringWithString:_internalToUserId];
    pjsip_generic_string_hdr* add_hdr_internal_user = pjsip_generic_string_hdr_create(pool,
                                                                                      &hInternalUser,
                                                                                      &hValueInternal);
    pj_list_push_back(&msg_data.hdr_list, add_hdr_internal_user);

    pj_str_t hApptoApp = pj_str((char *)"X-PH-APPTOAPP");
    pj_str_t hValueAppToApp = [GSPJUtil PJStringWithString:_appToApp];
    pjsip_generic_string_hdr* add_hdr_app_to_app = pjsip_generic_string_hdr_create(pool, &hApptoApp, &hValueAppToApp);
    pj_list_push_back(&msg_data.hdr_list, add_hdr_app_to_app);
    // End Extra headers

    pj_str_t remoteUri = [GSPJUtil PJStringWithString:_remoteUri];
    
    pjsua_call_setting callSetting;
    pjsua_call_setting_default(&callSetting);
    callSetting.aud_cnt = 1;
    callSetting.vid_cnt = 0; // TODO: Video calling support?
    
    pjsua_call_id callId;
    GSReturnNoIfFails(pjsua_call_make_call(self.account.accountId, &remoteUri, &callSetting, NULL, &msg_data, &callId));
    
    [self setCallId:callId];
    pj_pool_release(pool);
    return YES;
}

- (BOOL)end {
    if (self.callId == PJSUA_INVALID_ID) {
        NSLog(@"Call has not begun yet.");
    } else {
        GSReturnNoIfFails(pjsua_call_hangup(self.callId, 0, NULL, NULL));
    }
    [self setStatus:GSCallStatusDisconnected];
    [self setCallId:PJSUA_INVALID_ID];
    return YES;
}

@end
