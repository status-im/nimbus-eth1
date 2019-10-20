#ifndef __LIBNIMBUS_H__
#define __LIBNIMBUS_H__

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
  uint8_t* decoded;
  size_t decodedLen;
  uint32_t timestamp;
  uint32_t ttl;
  uint8_t topic[4];
  double pow;
  uint8_t hash[32];
} received_message;

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

#ifdef __cplusplus
}
#endif

#endif //__LIBNIMBUS_H__

