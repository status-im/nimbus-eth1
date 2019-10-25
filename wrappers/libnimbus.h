#ifndef __LIBNIMBUS_H__
#define __LIBNIMBUS_H__

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
  int8_t* decoded;
  size_t decodedLen;
  uint8_t source[64];
  uint8_t recipientPublicKey[64];
  uint32_t timestamp;
  uint32_t ttl;
  uint8_t topic[4];
  double pow;
  uint8_t hash[32];
} received_message;

typedef struct {
  const char* symKeyID;
  const char* privateKeyID;
  uint8_t* source; // 64 bytes public key
  double minPow;
  uint8_t topic[4];
  int allowP2P;
} filter_options;

typedef struct {
  const char* symKeyID;
  uint8_t* pubKey; // 64 bytes public key
  const char* sourceID;
  uint32_t ttl;
  uint8_t topic[4]; // default 0 is OK
  const char* payload; // could also provide uint8_t* + size_t
  const char* padding; // could also provide uint8_t* + size_t
  double powTime;
  double powTarget;
} post_message;

typedef struct {
  uint8_t topic[4];
} topic;

typedef void (*received_msg_handler)(received_message* msg);

/** Initialize Nim and the status library */
void NimMain();

/** Start nimbus event loop, connect to bootnodes etc */
void nimbus_start(uint16_t port);

/** Add peers to connect to - must be called after nimbus_start */
void nimbus_add_peer(const char* nodeId);

/**
 * Should be called in regularly - for example in a busy loop (beautiful!) on
 * dedicated thread.
 */
void nimbus_poll();

void nimbus_post_public(const char* channel, const char* payload);
void nimbus_join_public_chat(const char* channel, received_msg_handler msg);

/* Whisper API */

/* Helper, can be removed */
topic nimbus_string_to_topic(const char* s);

/* Asymmetric Keys API */

const char* nimbus_new_keypair();
const char* nimbus_add_keypair(const uint8_t* privkey);
int nimbus_delete_keypair(const char* id);
int nimbus_get_private_key(const char* id, uint8_t* privkey);

/* Symmetric Keys API */

const char* nimbus_add_symkey(const uint8_t* symkey);
const char* nimbus_add_symkey_from_password(const char* password);
int nimbus_delete_symkey(const char* id);
int nimbus_get_symkey(const char* id, uint8_t* symkey);

/* Whisper message posting and receiving API */

/* Subscribe to given filter */
const char* nimbus_subscribe_filter(filter_options* filter_options,
  received_msg_handler msg);
int nimbus_unsubscribe_filter(const char* id);
/* Post Whisper message */
int nimbus_post(post_message* msg);

#ifdef __cplusplus
}
#endif

#endif //__LIBNIMBUS_H__
