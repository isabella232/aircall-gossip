//
//  GSUserAgent.m
//  Gossip
//
//  Created by Chakrit Wichian on 7/5/12.
//

#import "GSUserAgent.h"
#import "GSUserAgent+Private.h"
#import "GSCodecInfo.h"
#import "GSCodecInfo+Private.h"
#import "GSDispatch.h"
#import "PJSIP.h"
#import "Util.h"




@implementation GSUserAgent {
    GSConfiguration *_config;
    pjsua_transport_id _transportId;
}

@synthesize account = _account;
@synthesize status = _status;

+ (GSUserAgent *)sharedAgent {
    static dispatch_once_t onceToken;
    static GSUserAgent *agent = nil;
    dispatch_once(&onceToken, ^{ agent = [[GSUserAgent alloc] init]; });
    
    return agent;
}


- (id)init {
    if (self = [super init]) {
        _account = nil;
        _config = nil;
        
        _transportId = PJSUA_INVALID_ID;
        _status = GSUserAgentStateUninitialized;
    }
    return self;
}

- (void)dealloc {
    if (_transportId != PJSUA_INVALID_ID) {
        pjsua_transport_close(_transportId, PJ_TRUE);
        _transportId = PJSUA_INVALID_ID;
    }
    
    if (_status >= GSUserAgentStateConfigured) {
        pjsua_destroy();
    }
    
    _account = nil;
    _config = nil;
    _status = GSUserAgentStateDestroyed;
}


- (GSConfiguration *)configuration {
    return _config;
}

- (GSUserAgentState)status {
    return _status;
}

- (void)setStatus:(GSUserAgentState)status {
    [self willChangeValueForKey:@"status"];
    _status = status;
    [self.delegate agentStatusChanged: _status];
    [self didChangeValueForKey:@"status"];
}


- (BOOL)configure:(GSConfiguration *)config {
    if (_config) [self reset];
    _config = [config copy];

    if (_status != GSUserAgentStateUninitialized && _status != GSUserAgentStateDestroyed) {
        return [_account configure: nil];
    }
    [[self pjsuaLock] lock];

    [self setStatus: GSUserAgentStateCreated];

    // Create PJSUA on the main thread to make all subsequent calls from the main
    // thread.
    pj_status_t status = pjsua_create();
    if (status != PJ_SUCCESS) {
        NSLog(@"Error creating PJSUA");
        [self setStatus: GSUserAgentStateDestroyed];
        [[self pjsuaLock] unlock];
        return [_account configure: nil];
    }

    pj_thread_desc aPJThreadDesc;
    if (!pj_thread_is_registered()) {
        pj_thread_t *pjThread;
        status = pj_thread_register(NULL, aPJThreadDesc, &pjThread);
        if (status != PJ_SUCCESS) {
            NSLog(@"Error registering thread at PJSUA");
        }
    }

    pjsua_config userAgentConfig;
    pjsua_logging_config loggingConfig;
    pjsua_media_config mediaConfig;
    pjsua_transport_config transportConfig;

    pjsua_config_default(&userAgentConfig);
    [GSDispatch configureCallbacksForAgent:&userAgentConfig];

    pjsua_logging_config_default(&loggingConfig);
    loggingConfig.level = _config.logLevel;
    loggingConfig.console_level = _config.consoleLogLevel;

    pjsua_media_config_default(&mediaConfig);
    mediaConfig.no_vad = true;
    mediaConfig.enable_ice = false;
    mediaConfig.snd_auto_close_time = 1;

//    // BDSOUND config?
    mediaConfig.ec_tail_len = 0;
    mediaConfig.snd_play_latency = 0;
    mediaConfig.snd_rec_latency = 0;

    status = pjsua_init(&userAgentConfig, &loggingConfig, &mediaConfig);
    if (status != PJ_SUCCESS) {
        NSLog(@"Error initializing PJSUA");
        [self reset];
        [[self pjsuaLock] unlock];
        return [_account configure: nil];
    }

    // create UDP transport
    // TODO: Make configurable? (which transport type to use/other transport opts)
    // TODO: Make separate class? since things like public_addr might be useful to some.
    pjsua_transport_config_default(&transportConfig);

    pjsip_transport_type_e transportType = 0;
    switch (_config.transportType) {
        case GSUDPTransportType: transportType = PJSIP_TRANSPORT_UDP; break;
        case GSUDP6TransportType: transportType = PJSIP_TRANSPORT_UDP6; break;
        case GSTCPTransportType: transportType = PJSIP_TRANSPORT_TCP; break;
        case GSTCP6TransportType: transportType = PJSIP_TRANSPORT_TCP6; break;
    }

    status = pjsua_transport_create(transportType, &transportConfig, &_transportId);
    if (status != PJ_SUCCESS) {
        NSLog(@"Error creating transport");
        [self reset];
        [[self pjsuaLock] unlock];
        return [_account configure: nil];
    }

    [self setStatus:GSUserAgentStateConfigured];

    // configure account
    _account = [[GSAccount alloc] init];
    return [_account configure:_config.account];
}


- (BOOL)start {
    // Start PJSUA.
    pj_status_t status = pjsua_start();
    if (status != PJ_SUCCESS) {
        NSLog(@"Error starting PJSUA");
        [self reset];
        [[self pjsuaLock] unlock];
        return false;
    }
    [self setStatus:GSUserAgentStateStarted];
    return YES;
}

- (BOOL)reset {
    pj_status_t status;
    pj_thread_desc aPJThreadDesc;

    if (!pj_thread_is_registered()) {
        pj_thread_t *pjThread;
        pj_status_t status = pj_thread_register(NULL, aPJThreadDesc, &pjThread);

        if (status != PJ_SUCCESS) {
            NSLog(@"Error registering thread at PJSUA");
        }
    }

    [[self pjsuaLock] lock];

    [_account disconnect];

    // needs to nil account before pjsua_destroy so pjsua_acc_del succeeds.
    _transportId = PJSUA_INVALID_ID;
    _account = nil;
    _config = nil;
    // Destroy PJSUA.
    status = pjsua_destroy();

    if (status != PJ_SUCCESS) {
        NSLog(@"Error stopping SIP user agent");
        return false;
    }
    [self setStatus:GSUserAgentStateDestroyed];
    return YES;
}


- (NSArray *)arrayOfAvailableCodecs {
    GSAssert(!!_config, @"Gossip: User agent not configured.");

    NSMutableArray *arr = [[NSMutableArray alloc] init];

    unsigned int count = 255;
    pjsua_codec_info codecs[count];
    GSReturnNilIfFails(pjsua_enum_codecs(codecs, &count));

    for (int i = 0; i < count; i++) {
        pjsua_codec_info pjCodec = codecs[i];
        
        GSCodecInfo *codec = [GSCodecInfo alloc];
        codec = [codec initWithCodecInfo:&pjCodec];
        [arr addObject:codec];
    }

    return [NSArray arrayWithArray:arr];
}

- (NSMutableArray*)getDevicesList {
    NSMutableArray *devicesArr = [[NSMutableArray alloc] init];
    if (_status < GSUserAgentStateConfigured) {
        return devicesArr;
    }

    [self updateAudioDevices];

    int dev_count;
    pjmedia_aud_dev_index dev_idx;
    pj_status_t status;
    dev_count = pjmedia_aud_dev_count();
    printf("Got %d audio devices\n", dev_count);
    if (dev_count == 0)
        return devicesArr;

    for (dev_idx = 0; dev_idx < dev_count; ++dev_idx) {
        pjmedia_aud_dev_info info;
        status = pjmedia_aud_dev_get_info(dev_idx, &info);
        
        if (status != PJ_SUCCESS)
            continue;

        NSString *name = [NSString stringWithFormat:@"%s", info.name];
        
        NSNumber *isBuiltIn = [NSNumber numberWithBool:NO];
        if ([name rangeOfString:@"Built-in"].location != NSNotFound) {
            isBuiltIn = [NSNumber numberWithBool:YES];
        }

        // Sometime, Mac OSX return `Built-in Microph` instead of `Built-in Microphone`
        if ([name rangeOfString:@"Microph"].location != NSNotFound && [name rangeOfString:@"Microphone"].location == NSNotFound) {
            name = [NSString stringWithFormat:@"%@%s", name, "one"];
        }
        
        

        NSString *index = [NSString stringWithFormat:@"%i", dev_idx];
        NSString *input = [NSString stringWithFormat:@"%i", info.input_count];
        NSString *output = [NSString stringWithFormat:@"%i", info.output_count];
        NSDictionary *dict = @{
                               @"index": index,
                               @"name" : name,
                               @"input" :  input,
                               @"output" :  output,
                               @"isBuiltIn" : isBuiltIn
                               };

        [devicesArr addObject:dict];
        
        printf("%d. %s (in=%d, out=%d)\n",
               dev_idx, info.name,
               info.input_count, info.output_count);
    }

    return devicesArr;
}

- (BOOL)setSoundInputDevice:(NSInteger)input soundOutputDevice:(NSInteger)output {
    if (_status < GSUserAgentStateConfigured)
        return NO;

    pj_status_t status = pjsua_set_snd_dev((int)input, (int)output);

    return (status == PJ_SUCCESS) ? YES : NO;
}

// This method will leave application silent. |setSoundInputDevice:soundOutputDevice:| must be called after calling this
// method to set sound IO. Usually application controller is responsible of sending
// |setSoundInputDevice:soundOutputDevice:| to set sound IO after this method is called.
- (void)updateAudioDevices {
    if (_status < GSUserAgentStateConfigured) {
        return;
    }

    // Stop sound device and disconnect it from the conference.
    if (pjsua_set_null_snd_dev() != PJ_SUCCESS)
        return;

    // Reinit sound device.
    if (pjmedia_snd_deinit() != PJ_SUCCESS)
        return;

    pj_pool_factory *factory = pjsua_get_pool_factory();
    if (factory == NULL)
        return;

    pjmedia_snd_init(factory);
}

@end
