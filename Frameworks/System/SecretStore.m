/*
 * SecretStore.m
 * LegacyPodClaw - API keys and tokens, held in the keychain by clawpodd
 */

#import "SecretStore.h"
#import "SecretProtocol.h"

#define CP_SECRET_TIMEOUT_MS 2000

@implementation CPSecretStore

/* keep in step with the list in clawpodd, which refuses any other key */
+ (NSArray *)allSecretKeys {
    return @[@"apiKey", @"authToken", @"authPassword", @"deviceToken",
        @"openaiApiKey", @"googleApiKey", @"groqApiKey", @"togetherApiKey", @"openrouterApiKey",
        @"mistralApiKey", @"deepseekApiKey", @"customApiKey",
        @"telegramBotToken", @"discordBotToken", @"slackBotToken", @"slackAppToken",
        @"ircPassword", @"webhookCallbackToken"];
}

+ (BOOL)isSecretKey:(NSString *)key {
    static NSSet *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = [[NSSet alloc] initWithArray:[self allSecretKeys]];
    });
    return [key isKindOfClass:[NSString class]] && [keys containsObject:key];
}

static int32_t SendSecretRequest(uint32_t op, NSString *key, NSData *value, NSString **outValue) {
    const char *ckey = [key UTF8String];
    if (!ckey || strlen(ckey) >= CP_SECRET_KEY_MAX) return CPSecretStatusBadRequest;
    if ([value length] > CP_SECRET_VALUE_MAX) return CPSecretStatusBadRequest;

    mach_port_t service = MACH_PORT_NULL;
    if (bootstrap_look_up(bootstrap_port, CP_SECRET_SERVICE, &service) != KERN_SUCCESS)
        return CPSecretStatusUnavailable;

    mach_port_t replyPort = MACH_PORT_NULL;
    if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &replyPort) != KERN_SUCCESS) {
        mach_port_deallocate(mach_task_self(), service);
        return CPSecretStatusUnavailable;
    }

    union {
        CPSecretRequest request;
        struct { CPSecretReply reply; mach_msg_trailer_t trailer; } in;
    } msg;
    memset(&msg, 0, sizeof(msg));
    msg.request.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE);
    msg.request.header.msgh_size = sizeof(CPSecretRequest);
    msg.request.header.msgh_remote_port = service;
    msg.request.header.msgh_local_port = replyPort;
    msg.request.header.msgh_id = CP_SECRET_MSG_ID;
    msg.request.op = op;
    strlcpy(msg.request.key, ckey, sizeof(msg.request.key));
    msg.request.valueLength = (uint32_t)[value length];
    if (value) memcpy(msg.request.value, [value bytes], [value length]);

    kern_return_t kr = mach_msg(&msg.request.header,
                                MACH_SEND_MSG | MACH_RCV_MSG | MACH_SEND_TIMEOUT | MACH_RCV_TIMEOUT,
                                sizeof(CPSecretRequest), sizeof(msg), replyPort,
                                CP_SECRET_TIMEOUT_MS, MACH_PORT_NULL);

    /* a failed send hands the message and its port rights back to us */
    if (kr == MACH_SEND_TIMED_OUT || kr == MACH_SEND_INTERRUPTED || kr == MACH_SEND_INVALID_DEST)
        mach_msg_destroy(&msg.request.header);

    int32_t status = CPSecretStatusUnavailable;
    if (kr == KERN_SUCCESS && msg.in.reply.header.msgh_size == sizeof(CPSecretReply)
        && msg.in.reply.header.msgh_id == CP_SECRET_MSG_ID + 100
        && !(msg.in.reply.header.msgh_bits & MACH_MSGH_BITS_COMPLEX)
        && msg.in.reply.valueLength <= CP_SECRET_VALUE_MAX) {
        status = msg.in.reply.status;
        if (status == CPSecretStatusOK && outValue && msg.in.reply.valueLength > 0) {
            *outValue = [[[NSString alloc] initWithBytes:msg.in.reply.value
                                                  length:msg.in.reply.valueLength
                                                encoding:NSUTF8StringEncoding] autorelease];
        }
    }
    CPSecretWipe(&msg, sizeof(msg));

    mach_port_mod_refs(mach_task_self(), replyPort, MACH_PORT_RIGHT_RECEIVE, -1);
    mach_port_deallocate(mach_task_self(), service);
    return status;
}

+ (NSString *)secretForKey:(NSString *)key {
    if (![self isSecretKey:key]) return nil;
    NSString *value = nil;
    if (SendSecretRequest(CPSecretOpGet, key, nil, &value) != CPSecretStatusOK) return nil;
    return value;
}

+ (BOOL)setSecret:(NSString *)value forKey:(NSString *)key {
    if (![self isSecretKey:key]) return NO;
    if (![value isKindOfClass:[NSString class]] || [value length] == 0)
        return SendSecretRequest(CPSecretOpDelete, key, nil, NULL) == CPSecretStatusOK;
    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
    return SendSecretRequest(CPSecretOpSet, key, data, NULL) == CPSecretStatusOK;
}

@end
