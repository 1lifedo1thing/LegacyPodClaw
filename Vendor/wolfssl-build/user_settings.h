/* shared by build-wolfssl.sh and the app so struct layouts always match */
#ifndef LEGACYPODCLAW_WOLFSSL_USER_SETTINGS_H
#define LEGACYPODCLAW_WOLFSSL_USER_SETTINGS_H

#define NO_WOLFSSL_SERVER
#define WOLFSSL_TLS13
#define NO_OLD_TLS
#define HAVE_TLS_EXTENSIONS
#define HAVE_SNI
#define HAVE_SUPPORTED_CURVES
#define HAVE_EXTENDED_MASTER
#define HAVE_ENCRYPT_THEN_MAC
#define HAVE_SERVER_RENEGOTIATION_INFO
#define WOLFSSL_ALT_CERT_CHAINS      /* cloudflare and let's encrypt serve cross-signed chains */
#define KEEP_PEER_CERT               /* spki pinning reads the leaf */
#define WOLFSSL_BASE64_ENCODE

#define HAVE_ECC
#define ECC_TIMING_RESISTANT
#define ECC_SHAMIR
#define HAVE_CURVE25519
#define HAVE_ED25519
#define HAVE_AESGCM
#define GCM_SMALL
#define HAVE_CHACHA
#define HAVE_POLY1305
#define HAVE_HKDF
#define WC_RSA_PSS
#define WC_RSA_BLINDING
#define WOLFSSL_SHA384
#define WOLFSSL_SHA512
#define HAVE_FFDHE_2048

#define NO_DSA
#define NO_RC4
#define NO_MD4
#define NO_DES3
#define NO_PSK
#define NO_PWDBASED

#define WOLFSSL_SP_MATH_ALL
#define SP_WORD_SIZE 32
#define WOLFSSL_HAVE_SP_RSA
#define WOLFSSL_HAVE_SP_ECC
#define WOLFSSL_HAVE_SP_DH
#define TFM_TIMING_RESISTANT
#define SP_INT_BITS 4096             /* isrg root x1 and root yr sign with 4096-bit rsa keys (slack.com) */
#define WOLFSSL_ASN_ALLOW_0_SERIAL   /* api.telegram.org sends its serial-0 go daddy g2 root in the chain */

#define WOLFSSL_SMALL_STACK          /* secondary threads on ios 6 get 512k stacks */
#define NO_FILESYSTEM                /* the ca bundle is loaded from a buffer */
#define WOLFSSL_IGNORE_FILE_WARN
#define NO_MAIN_DRIVER
#define HAVE_HASHDRBG

/* no_filesystem also drops the /dev/urandom seed, so wc_InitRng fails (-199) without this */
#include <fcntl.h>
#include <unistd.h>
static inline int lpc_wolfssl_seed(unsigned char *out, unsigned int sz) {
    int fd = open("/dev/urandom", O_RDONLY);
    if (fd < 0) return -1;
    while (sz > 0) {
        ssize_t n = read(fd, out, sz);
        if (n <= 0) { close(fd); return -1; }
        out += n;
        sz -= (unsigned int)n;
    }
    close(fd);
    return 0;
}
#define CUSTOM_RAND_GENERATE_SEED lpc_wolfssl_seed

#endif
