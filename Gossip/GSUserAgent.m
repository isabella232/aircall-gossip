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
    
    // create agent
    GSReturnNoIfFails(pjsua_create());
    [self setStatus:GSUserAgentStateCreated];
    
    // configure agent
    pjsua_config uaConfig;
    pjsua_logging_config logConfig;
    pjsua_media_config mediaConfig;

    pjsua_config_default(&uaConfig);
    [GSDispatch configureCallbacksForAgent:&uaConfig];

    pjsua_logging_config_default(&logConfig);
    logConfig.level = _config.logLevel;
    logConfig.console_level = _config.consoleLogLevel;

    pjsua_media_config_default(&mediaConfig);
    mediaConfig.clock_rate = _config.clockRate;
    mediaConfig.snd_clock_rate = _config.soundClockRate;
    mediaConfig.ec_tail_len = 0; // not sure what this does (Siphon use this.)

    GSReturnNoIfFails(pjsua_init(&uaConfig, &logConfig, &mediaConfig));

    // Configure the DNS resolvers to also handle SRV records
    pjsip_endpoint* endpoint = pjsua_get_pjsip_endpt();
    pj_dns_resolver* resolver;
    pj_str_t google_dns = [GSPJUtil PJStringWithString:@"8.8.8.8"];
    struct pj_str_t servers[] = { google_dns };
    GSReturnNoIfFails(pjsip_endpt_create_resolver(endpoint, &resolver));
    GSReturnNoIfFails(pj_dns_resolver_set_ns(resolver, 1, servers, nil));
    GSReturnNoIfFails(pjsip_endpt_set_resolver(endpoint, resolver));

    // create UDP transport
    // TODO: Make configurable? (which transport type to use/other transport opts)
    // TODO: Make separate class? since things like public_addr might be useful to some.
    pjsua_transport_config transportConfig;
    pjsua_transport_config_default(&transportConfig);

    pjsip_transport_type_e transportType = 0;
    switch (_config.transportType) {
        case GSUDPTransportType: transportType = PJSIP_TRANSPORT_UDP; break;
        case GSUDP6TransportType: transportType = PJSIP_TRANSPORT_UDP6; break;
        case GSTCPTransportType: transportType = PJSIP_TRANSPORT_TCP; break;
        case GSTCP6TransportType: transportType = PJSIP_TRANSPORT_TCP6; break;
    }

    GSReturnNoIfFails(pjsua_transport_create(transportType, &transportConfig, &_transportId));
    [self setStatus:GSUserAgentStateConfigured];

    // configure account
    _account = [[GSAccount alloc] init];
    return [_account configure:_config.account];
}


- (BOOL)start {
    GSReturnNoIfFails(pjsua_start());
    [self setStatus:GSUserAgentStateStarted];
    return YES;
}

- (BOOL)reset {
    [_account disconnect];

    // needs to nil account before pjsua_destroy so pjsua_acc_del succeeds.
    _transportId = PJSUA_INVALID_ID;
    _account = nil;
    _config = nil;
    GSReturnNoIfFails(pjsua_destroy());
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
