#include <stdint.h>
#include <stddef.h>

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
void nimbus_start(uint16_t port);
void nimbus_poll();
void NimMain();
void nimbus_post(const char* payload);
void nimbus_subscribe(const char* channel, received_msg_handler msg);
void nimbus_add_peer(const char* nodeId);
