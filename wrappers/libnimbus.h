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
  uint32_t timestamp;
  uint32_t ttl;
  uint8_t topic[4];
  double pow;
  uint8_t hash[32];
} received_message;

typedef struct {
  const char* symKeyID;
  const char* privateKeyID;
  uint8_t sig[64];
  double minPow;
  uint8_t topic[4];
} filter_options;

typedef struct {
  const char* symKeyID;
  uint8_t pubKey[64];
  const char* sig;
  uint32_t ttl;
  uint8_t topic[4];
  char* payload;
  char* padding;
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

void nimbus_post(const char* channel, const char* payload);
void nimbus_subscribe(const char* channel, received_msg_handler msg);

/* Whisper API */

topic nimbus_string_to_topic(const char* s);
/* Generate asymmetric keypair */
const char* nimbus_new_keypair();
/* Generate symmetric key from password */
const char* nimbus_add_symkey_from_password(const char* password);
/* Subscribe to given filter */
void nimbus_whisper_subscribe(filter_options* filter_options,
  received_msg_handler msg);
/* Post Whisper message */
void nimbus_whisper_post(post_message* msg);

#ifdef __cplusplus
}
#endif

#endif //__LIBNIMBUS_H__

