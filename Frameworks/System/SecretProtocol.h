/*
 * SecretProtocol.h
 * LegacyPodClaw - wire format between CPSecretStore and clawpodd
 */

#ifndef CP_SECRET_PROTOCOL_H
#define CP_SECRET_PROTOCOL_H

#include <mach/mach.h>
#include <stdint.h>

/* the ios sdk ships no servers/bootstrap.h, but libSystem exports these */
extern mach_port_t bootstrap_port;
kern_return_t bootstrap_look_up(mach_port_t bp, const char *service_name, mach_port_t *sp);
kern_return_t bootstrap_check_in(mach_port_t bp, const char *service_name, mach_port_t *sp);

#define CP_SECRET_SERVICE "pro.matthesketh.legacypodclaw.secrets"
#define CP_SECRET_MSG_ID 0x4c504301
#define CP_SECRET_KEY_MAX 32
#define CP_SECRET_VALUE_MAX 4096

enum {
    CPSecretOpGet = 1,
    CPSecretOpSet = 2,
    CPSecretOpDelete = 3,
};

enum {
    CPSecretStatusOK = 0,
    CPSecretStatusNotFound = 1,
    CPSecretStatusDenied = 2,
    CPSecretStatusBadRequest = 3,
    /* keychain is locked before first unlock, or securityd refused */
    CPSecretStatusUnavailable = 4,
};

typedef struct {
    mach_msg_header_t header;
    uint32_t op;
    char key[CP_SECRET_KEY_MAX];
    uint32_t valueLength;
    char value[CP_SECRET_VALUE_MAX];
} CPSecretRequest;

typedef struct {
    mach_msg_header_t header;
    int32_t status;
    uint32_t valueLength;
    char value[CP_SECRET_VALUE_MAX];
} CPSecretReply;

static inline void CPSecretWipe(void *buf, size_t len) {
    /* volatile stops the compiler from dropping a wipe of a dead buffer */
    volatile unsigned char *p = (volatile unsigned char *)buf;
    while (len--) *p++ = 0;
}

#endif
