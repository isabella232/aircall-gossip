//
//  GSOutgoingCall.h
//  Gossip
//
//  Created by Chakrit Wichian on 7/12/12.
//

#import "GSCall.h"


@interface GSOutgoingCall : GSCall

@property (nonatomic, copy, readonly) NSString *remoteUri;
@property (nonatomic, copy, readonly) NSString *callerId;
@property (nonatomic, copy, readonly) NSString *userId;
@property (nonatomic, copy, readonly) NSString *internalToUserId;
@property (nonatomic, copy, readonly) NSString *appToApp;

- (id)initWithRemoteUri:(NSString *)remoteUri
            fromAccount:(GSAccount *)account
           withCallerId:(NSString *)callerId
             withUserId:(NSString *)userId
   withInternalToUserId:(NSString *)internalToUserId
           withAppToApp:(NSString *)appToApp;

@end
