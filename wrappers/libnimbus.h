#ifndef __LIBNIMBUS_H__
#define __LIBNIMBUS_H__

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
  const uint8_t* decoded; /* Decoded payload */
  size_t decodedLen;  /* Decoded payload length */
  const uint8_t* source; /* 64 bytes public key, can be nil */
  const uint8_t* recipientPublicKey; /* 64 bytes public key, can be nil */
  uint32_t timestamp; /* Timestamp of creation message, expiry - ttl  */
  uint32_t ttl; /* TTL of message */
  uint8_t topic[4]; /* Topic of message */
  double pow; /* PoW value of received message */
  uint8_t hash[32]; /* Hash of message */
} received_message;

typedef struct {
  const uint8_t* symKeyID; /* 32 bytes identifier for symmetric key, set to nil if none */
  const uint8_t* privateKeyID; /* 32 bytes identifier for asymmetric key, set to nil if none */
  const uint8_t* source; /* 64 bytes public key, set to nil if none */
  double minPow; /* Minimum PoW that message must have */
  uint8_t topic[4]; /* Will default to 0x00000000 if not provided */
  int allowP2P;
} filter_options;

typedef struct {
  const uint8_t* symKeyID; /* 32 bytes identifier for symmetric key, set to nil if none */
  const uint8_t* pubKey; /* 64 bytes public key, set to nil if none */
  const uint8_t* sourceID; /* 32 bytes identifier for asymmetric key, set to nil if none */
  uint32_t ttl; /* TTL of message */
  uint8_t topic[4]; /* Will default to 0x00000000 if not provided */
  uint8_t* payload; /* Payload to be send, can be len=0 but can not be nil */
  size_t payloadLen; /* Payload length */
  uint8_t* padding; /* Custom padding, can be set to nil */
  size_t paddingLen; /* Padding length */
  double powTime; /* Maximum time to calculate PoW */
  double powTarget; /* Minimum PoW target to reach before stopping */
} post_message;

typedef struct {
  uint8_t topic[4];
} topic;

typedef void (*received_msg_handler)(received_message* msg, void* udata);

/** Buffer lengths, can be used in go for convenience */
#define ID_LEN 32
#define SYMKEY_LEN 32
#define PRIVKEY_LEN 32
#define BLOOM_LEN 64

/** Initialize Nim and the Status library. Must be called before anything else
 * of the API. Also, all following calls must come from the same thread as from
 * which this call was done.
 */
void NimMain();

/** Start Ethereum node with Whisper capability and connect to Status fleet.
 * Optionally start discovery and listen for incoming connections.
 * The minPow value is the minimum required PoW that this node will allow.
 * When privkey is null, a new keypair will be generated.
 */
bool nimbus_start(uint16_t port, bool startListening, bool enableDiscovery,
  double minPow, const uint8_t* privkey, bool staging);

/** Add peers to connect to - must be called after nimbus_start */
bool nimbus_add_peer(const char* nodeId);

/**
 * Should be called in regularly - for example in a busy loop (beautiful!) on
 * dedicated thread.
 */
void nimbus_poll();

/** Asymmetric Keys API */

/** Raw 32 byte arrays are passed as IDs. The caller needs to provide a pointer
 * to 32 bytes allocation for this. */
bool nimbus_new_keypair(uint8_t id[ID_LEN]);
bool nimbus_add_keypair(const uint8_t privkey[PRIVKEY_LEN], uint8_t id[ID_LEN]);
bool nimbus_delete_keypair(const uint8_t id[ID_LEN]);
bool nimbus_get_private_key(const uint8_t id[ID_LEN],
  uint8_t privkey[PRIVKEY_LEN]);

/** Symmetric Keys API */

/** Raw 32 byte arrays are passed as IDs. The caller needs to provide a pointer
 * to 32 bytes allocation for this. */
bool nimbus_add_symkey(const uint8_t symkey[SYMKEY_LEN], uint8_t id[ID_LEN]);
bool nimbus_add_symkey_from_password(const char* password, uint8_t id[ID_LEN]);
bool nimbus_delete_symkey(const uint8_t id[ID_LEN]);
bool nimbus_get_symkey(const uint8_t id[ID_LEN], uint8_t symkey[SYMKEY_LEN]);

/** Whisper message posting and receiving API */

/* Post Whisper message to the queue */
bool nimbus_post(post_message* msg);
/** Subscribe to given filter. The void pointer udata will be passed to the
 * received_msg_handler callback.
 */
bool nimbus_subscribe_filter(filter_options* filter_options,
  received_msg_handler msg, void* udata, uint8_t id[ID_LEN]);
bool nimbus_unsubscribe_filter(const uint8_t id[ID_LEN]);

/** Get the minimum required PoW of this node */
double nimbus_get_min_pow();

/** Get the currently set bloom filter of this node. This will automatically
 *update for each filter subsribed to.
 */
void nimbus_get_bloom_filter(uint8_t bloomfilter[BLOOM_LEN]);

/** Example helper, can be removed */
topic nimbus_channel_to_topic(const char* channel);

/** Very limited Status chat API */

void nimbus_post_public(const char* channel, const char* payload);
void nimbus_join_public_chat(const char* channel, received_msg_handler msg);

#ifdef __cplusplus
}
#endif

#endif //__LIBNIMBUS_H__
