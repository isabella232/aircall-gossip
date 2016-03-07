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

#import <AVFoundation/AVFoundation.h>


@implementation GSCall {
    pjsua_call_id _callId;
    float _volume;
    float _micVolume;
    float _volumeScale;
}

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

+ (id)incomingCallWithId:(int)callId toAccount:(GSAccount *)account {
    GSIncomingCall *call = [GSIncomingCall alloc];
    call = [call initWithCallId:callId toAccount:account];

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

- (void)dealloc {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center removeObserver:self];

    if (_ringback && _ringback.isPlaying) {
        [_ringback stop];
        _ringback = nil;
    }

    if (_callId != PJSUA_INVALID_ID && pjsua_call_is_active(_callId)) {
        GSLogIfFails(pjsua_call_hangup(_callId, 0, NULL, NULL));
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

- (void)setStatus:(GSCallStatus)status {
    [self willChangeValueForKey:@"status"];
    _status = status;
    [self.delegate callStatusChanged: _status];
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
    // for child overrides only
    return NO;
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
    if ( callId != _callId || _account == nil || accountId != _account.accountId || callId == PJSUA_INVALID_ID)
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
	pjsua_call_info callInfo;
	pj_status_t status = pjsua_call_get_info(_callId, &callInfo);
	if (status == PJ_SUCCESS) {
		pjsua_call_set_hold(_callId, nil);
		pjsua_set_no_snd_dev();
	}
}

- (void)removeHoldCall {
	pjsua_call_info callInfo;
	pj_status_t status = pjsua_call_get_info(_callId, &callInfo);
	if (status == PJ_SUCCESS) {
		pjsua_call_reinvite(_callId, PJ_TRUE, nil);
		pjsua_set_snd_dev(0, 0);
	}
}

- (void)muteMicrophone {
	pjsua_call_info ci;
	pj_status_t status = pjsua_call_get_info(_callId, &ci);
	if (status == PJ_SUCCESS) {
		pjsua_conf_port_id pjsipConfAudioId = ci.conf_slot;
		@try {
			if( pjsipConfAudioId != 0 ) {
				pjsua_conf_disconnect(0, pjsipConfAudioId);
			}
		}
		@catch (NSException *exception) {
			NSLog(@"Unable to mute microphone: %@", exception);
		}
	}
}

- (void)unmuteMicrophone {
	pjsua_call_info ci;
	pj_status_t status = pjsua_call_get_info(_callId, &ci);
	if (status == PJ_SUCCESS) {
		pjsua_conf_port_id pjsipConfAudioId = ci.conf_slot;
		@try {
			if( pjsipConfAudioId != 0 ) {
				pjsua_conf_connect(0,pjsipConfAudioId);
			}
		}
		@catch (NSException *exception) {
			NSLog(@"Unable to un-mute microphone: %@", exception);
		}
	}
}

- (void)useSpeaker {
	/** detect speaker with pjsip **/
//	pjmedia_aud_dev_route route = PJMEDIA_AUD_DEV_ROUTE_LOUDSPEAKER;
//	pjmedia_aud_stream_set_cap(nil, PJMEDIA_AUD_DEV_CAP_INPUT_ROUTE, &route);
//	pj_status_t status = pjsua_snd_set_setting(PJMEDIA_AUD_DEV_CAP_INPUT_ROUTE, &route, PJ_FALSE);
//	if (status != PJ_SUCCESS){
//		NSLog(@"Error enabling loudspeaker");
//	}
	pjsua_call_info ci;


	pjsua_call_get_info(_callId, &ci);
	BOOL success;
	AVAudioSession *session = [AVAudioSession sharedInstance];
	NSError *error = nil;

	success = [session setCategory:AVAudioSessionCategoryPlayAndRecord
					   withOptions:AVAudioSessionCategoryOptionMixWithOthers
							 error:&error];
	if (!success) NSLog(@"AVAudioSession error setCategory: %@", [error localizedDescription]);

	success = [session overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker error:&error];
	if (!success) NSLog(@"AVAudioSession error overrideOutputAudioPort: %@", [error localizedDescription]);

	success = [session setActive:YES error:&error];
	if (!success) NSLog(@"AVAudioSession error setActive: %@", [error localizedDescription]);
}

- (void)stopSpeaker {
	BOOL success;
	AVAudioSession *session = [AVAudioSession sharedInstance];
	NSError *error = nil;

	success = [session setActive:NO error:&error];
	if (!success) NSLog(@"AVAudioSession error setActive: %@", [error localizedDescription]);
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

@end
