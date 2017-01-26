//
//  GSIncomingCall.m
//  Gossip
//
//  Created by Chakrit Wichian on 7/12/12.
//

#import "GSIncomingCall.h"
#import "GSCall+Private.h"
#import "PJSIP.h"
#import "Util.h"


@implementation GSIncomingCall

- (id)initWithCallId:(int)callId toAccount:(GSAccount *)account withMsg:(NSString *)msg {
    if (self = [super initWithAccount:account]) {
        [self setCallId:callId];
        [self setCallMsg:msg];
    }
    return self;
}


- (BOOL)begin {
    if (self.callId == PJSUA_INVALID_ID) {
        return false;
    } else {
        pj_status_t status = pjsua_call_answer(self.callId, PJSIP_SC_OK, NULL, NULL);
        return status == PJ_SUCCESS;
    }
}

@end
