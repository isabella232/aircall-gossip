//
//  GSCall.m
//  Gossip
//
//  Created by Chakrit Wichian on 7/9/12.
//

#import "GSCall.h"
#import "GSCall+Private.h"
#import "GSAccount+Private.h"
#import "GSDispatch.h"
#import "GSIncomingCall.h"
#import "GSOutgoingCall.h"
#import "GSRingback.h"
#import "GSUserAgent+Private.h"
#import "PJSIP.h"
#import "Util.h"


@implementation GSCall {
    pjsua_call_id _callId;
    NSString *_msg;
    float _volume;
    float _micVolume;
    float _volumeScale;
}

bool activeSessionAudio = false;

+ (id)outgoingCallToUri:(NSString *)remoteUri
            fromAccount:(GSAccount *)account
           withCallerId:(NSString *)callerId
             withUserId:(NSString *)userId
   withInternalToUserId:(NSString *)internalToUserId
           withAppToApp:(NSString *)appToApp
{
    GSOutgoingCall *call = [GSOutgoingCall alloc];
    call = [call initWithRemoteUri:remoteUri
                       fromAccount:account
                      withCallerId:callerId
                        withUserId:userId
              withInternalToUserId:internalToUserId
                      withAppToApp:appToApp];
    
    return call;
}

+ (id)incomingCallWithId:(int)callId toAccount:(GSAccount *)account withMsg:(NSString *)msg {
    GSIncomingCall *call = [GSIncomingCall alloc];
    call = [call initWithCallId:callId toAccount:account withMsg:msg];

    return call;
}


- (id)init {
    return [self initWithAccount:nil];
}

- (id)initWithAccount:(GSAccount *)account {
    if (self = [super init]) {
        GSAccountConfiguration *config = account.configuration;

        _account = account;
        _status = GSCallStatusReady;
        _callId = PJSUA_INVALID_ID;
        
        _ringback = nil;
        if (config.enableRingback) {
            _ringback = [GSRingback ringbackWithSoundNamed:config.ringbackFilename];
        }

        _volumeScale = [GSUserAgent sharedAgent].configuration.volumeScale;
        _volume = 1.0 / _volumeScale;
        _micVolume = 1.0 / _volumeScale;

        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserver:self
                   selector:@selector(callStateDidChange:)
                       name:GSSIPCallStateDidChangeNotification
                     object:[GSDispatch class]];
        [center addObserver:self
                   selector:@selector(callMediaStateDidChange:)
                       name:GSSIPCallMediaStateDidChangeNotification
                     object:[GSDispatch class]];
    }
    return self;
}

- (BOOL)isActive {
    if (_callId == PJSUA_INVALID_ID || _callId == 0) {
        return NO;
    }

    return (pjsua_call_is_active(_callId)) ? YES : NO;
}

- (void)dealloc {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center removeObserver:self];

    if (_ringback && _ringback.isPlaying) {
        [_ringback stop];
        _ringback = nil;
    }

    if ([self isActive]) {
        [self end];
    }
    
    _account = nil;
    _callId = PJSUA_INVALID_ID;
    _ringback = nil;
}


- (int)callId {
    return _callId;
}

- (void)setCallId:(int)callId {
    [self willChangeValueForKey:@"callId"];
    _callId = callId;
    [self didChangeValueForKey:@"callId"];
}

- (void)setCallMsg:(NSString *)msg {
    _msg = msg;
}

- (void)setStatus:(GSCallStatus)status {
    [self willChangeValueForKey:@"status"];
    _status = status;
    [self.delegate callStatusChanged: _status withCallId: [self callId]];
    [self didChangeValueForKey:@"status"];
}


- (float)volume {
    return _volume;
}

- (BOOL)setVolume:(float)volume {
    [self willChangeValueForKey:@"volume"];
    BOOL result = [self adjustVolume:volume mic:_micVolume];
    [self didChangeValueForKey:@"volume"];
    
    return result;
}

- (float)micVolume {
    return _micVolume;
}

- (BOOL)setMicVolume:(float)micVolume {
    [self willChangeValueForKey:@"micVolume"];
    BOOL result = [self adjustVolume:_volume mic:micVolume];
    [self didChangeValueForKey:@"micVolume"];
    
    return result;
}


- (BOOL)begin {
    // for child overrides only
    return NO;
}

- (BOOL)end {
    if ( _callId != PJSUA_INVALID_ID && (self.status != GSCallStatusDisconnected || self.account.status == GSAccountStatusConnected)) {
        pj_status_t status = pjsua_call_hangup(_callId, 0, NULL, NULL);
        if (status == PJ_SUCCESS) {
            [self setStatus:GSCallStatusDisconnected];
            [self setCallId:PJSUA_INVALID_ID];
            return YES;
        } else {
            NSLog(@"Error hanging up call %@", self);
        }
    }

    return false;
}


- (BOOL)sendDTMFDigits:(NSString *)digits {
    pj_str_t pjDigits = [GSPJUtil PJStringWithString:digits];
    pjsua_call_dial_dtmf(_callId, &pjDigits);
    return NO;
}


- (void)startRingback {
    if (!_ringback || _ringback.isPlaying)
        return;

    [_ringback play];
}

- (void)stopRingback {
    if (!(_ringback && _ringback.isPlaying))
        return;

    [_ringback stop];
}


- (void)callStateDidChange:(NSNotification *)notif {
    pjsua_call_id callId = GSNotifGetInt(notif, GSSIPCallIdKey);
    pjsua_acc_id accountId = GSNotifGetInt(notif, GSSIPAccountIdKey);
    if ( callId != _callId || callId == PJSUA_INVALID_ID || _account == nil )
        return;
    if ( accountId != _account.accountId )
        return;

    pjsua_call_info callInfo;
    pjsua_call_get_info(_callId, &callInfo);
    
    GSCallStatus callStatus;
    switch (callInfo.state) {
        case PJSIP_INV_STATE_NULL: {
            callStatus = GSCallStatusReady;
        } break;
        case PJSIP_INV_STATE_CALLING: {
            callStatus = GSCallStatusCalling;
        } break;
        case PJSIP_INV_STATE_INCOMING: {
            callStatus = GSCallStatusCalling;
        } break;
        case PJSIP_INV_STATE_EARLY:
        case PJSIP_INV_STATE_CONNECTING: {
            [self startRingback];
            callStatus = GSCallStatusConnecting;
        } break;
        case PJSIP_INV_STATE_CONFIRMED: {
            [self stopRingback];
            callStatus = GSCallStatusConnected;
        } break;
            
        case PJSIP_INV_STATE_DISCONNECTED: {
            [self stopRingback];
            callStatus = GSCallStatusDisconnected;
        } break;
    }
    
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf setStatus:callStatus]; });
}

- (void)callMediaStateDidChange:(NSNotification *)notif {
    pjsua_call_id callId = GSNotifGetInt(notif, GSSIPCallIdKey);
    if (callId != _callId)
        return;

    pjsua_call_info callInfo;
    GSReturnIfFails(pjsua_call_get_info(_callId, &callInfo));
    
    if (callInfo.media_status == PJSUA_CALL_MEDIA_ACTIVE) {
        pjsua_conf_port_id callPort = pjsua_call_get_conf_port(_callId);
        GSReturnIfFails(pjsua_conf_connect(callPort, 0));
        GSReturnIfFails(pjsua_conf_connect(0, callPort));
        
        [self adjustVolume:_volume mic:_micVolume];
    }
}


- (BOOL)adjustVolume:(float)volume mic:(float)micVolume {
    GSAssert(0.0 <= volume && volume <= 1.0, @"Volume value must be between 0.0 and 1.0");
    GSAssert(0.0 <= micVolume && micVolume <= 1.0, @"Mic Volume must be between 0.0 and 1.0");
    
    _volume = volume;
    _micVolume = micVolume;
    if (_callId == PJSUA_INVALID_ID)
        return YES;
    
    pjsua_call_info callInfo;
    pjsua_call_get_info(_callId, &callInfo);
    if (callInfo.media_status == PJSUA_CALL_MEDIA_ACTIVE) {
        
        // scale volume as per configured volume scale
        volume *= _volumeScale;
        micVolume *= _volumeScale;
        pjsua_conf_port_id callPort = pjsua_call_get_conf_port(_callId);
        GSReturnNoIfFails(pjsua_conf_adjust_rx_level(callPort, volume));
        GSReturnNoIfFails(pjsua_conf_adjust_tx_level(callPort, micVolume));
    }
    
    // send volume change notification
    NSDictionary *info = nil;
    info = [NSDictionary dictionaryWithObjectsAndKeys:
            [NSNumber numberWithFloat:volume], GSVolumeKey,
            [NSNumber numberWithFloat:micVolume], GSMicVolumeKey, nil];
    
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center postNotificationName:GSVolumeDidChangeNotification
                          object:self
                        userInfo:info];
    
    return YES;
}

- (NSString *)getFrom {
    pjsua_call_info callInfo;
    pjsua_call_get_info(_callId, &callInfo);

    NSString *fromSip = [NSString stringWithFormat:@"%s", callInfo.remote_info.ptr];
    fromSip = [fromSip componentsSeparatedByString:@":"][1];
    return [fromSip componentsSeparatedByString:@"@"][0];
}


- (void)holdCall {
    if (self.status == GSCallStatusConnected && ![self isOnRemoteHold]) {
        pjsua_call_set_hold(_callId, nil);
        pjsua_set_no_snd_dev();
    }
}

- (void)removeHoldCall {
    if (self.status == GSCallStatusConnected) {
        pjsua_call_reinvite(_callId, PJ_TRUE, nil);
        pjsua_set_snd_dev(0, 0);
    }
}

- (BOOL)isOnRemoteHold {
    if (_callId == PJSUA_INVALID_ID) {
        return NO;
    }

    pjsua_call_info callInfo;
    pjsua_call_get_info(_callId, &callInfo);

    return (callInfo.media_status == PJSUA_CALL_MEDIA_REMOTE_HOLD) ? YES : NO;
}

- (BOOL)muteMicrophone {
    if ([self isMicrophoneMuted] || self.status != GSCallStatusConnected) {
        return false;
    }

    pjsua_call_info callInfo;
    pjsua_call_get_info(_callId, &callInfo);

    pj_status_t status = pjsua_conf_disconnect(0, callInfo.conf_slot);
    if (status == PJ_SUCCESS) {
        [self setMicrophoneMuted:YES];
        return true;
    } else {
        NSLog(@"Error muting microphone in call %@", self);
    }
    return false;
}

- (BOOL)unmuteMicrophone {
    if (![self isMicrophoneMuted] || self.status != GSCallStatusConnected) {
        return false;
    }

    pjsua_call_info callInfo;
    pjsua_call_get_info(_callId, &callInfo);

    pj_status_t status = pjsua_conf_connect(0, callInfo.conf_slot);
    if (status == PJ_SUCCESS) {
        [self setMicrophoneMuted:NO];
        return true;
    } else {
        NSLog(@"Error unmuting microphone in call %@", self);
    }
    return false;
}


// Retreive custom headers from a call (inbound)
- (NSString *)getCustomHeader:(NSString *)key {
    if (_msg == nil)
        return @"";

    NSArray *headers = [_msg componentsSeparatedByString:@"\n"];

    for (NSString *tmpHeader in headers) {
        if ([tmpHeader rangeOfString:key options:NSCaseInsensitiveSearch].location != NSNotFound) {
            NSString *headerValue = [tmpHeader componentsSeparatedByString:@":"][1];
            return [headerValue stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }
    }

    return @"";
}

// Get Current Mic level
- (float)getCurrentMicVolume {
    unsigned int micVolume = 0;
    unsigned int speakerVolume = 0;

    if (_callId == PJSUA_INVALID_ID) {
        return (float)micVolume;
    }

    pjsua_call_info callInfo;
    GSReturnValueIfFails(pjsua_call_get_info(_callId, &callInfo), (float)micVolume);

    if (callInfo.media_status == PJSUA_CALL_MEDIA_ACTIVE) {
        pjsua_conf_port_id callPort = pjsua_call_get_conf_port(_callId);
        if (callPort != PJSUA_INVALID_ID) {
            pjsua_conf_get_signal_level(callPort, &micVolume, &speakerVolume);
        }
    }
    return (float)micVolume;
}


- (BOOL)openAudioSession {
    pj_status_t status = pjsua_set_snd_dev(0, 0);
    activeSessionAudio = status == PJ_SUCCESS;
    return activeSessionAudio;
}

- (void)closeAudioSession {
    if (activeSessionAudio) {
        pjsua_set_no_snd_dev();
    }
    activeSessionAudio = false;
}


@end
