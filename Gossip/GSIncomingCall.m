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
        NSLog(@"Call has already ended.");
    } else {
        GSReturnNoIfFails(pjsua_call_answer(self.callId, 200, NULL, NULL));
    }
    return YES;
}

@end
