//
//  GSCall+Private.h
//  Gossip
//
//  Created by Chakrit Wichian on 7/12/12.
//

#import "GSCall.h"


@interface GSCall (Private)

// private setter for internal use
- (void)setCallId:(int)callId;
- (void)setCallMsg:(NSString *)msg;
- (void)setStatus:(GSCallStatus)status;

@end
