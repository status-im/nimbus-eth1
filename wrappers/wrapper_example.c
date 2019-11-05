#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <unistd.h>
#include <time.h>
#include <string.h>

#include "libnimbus.h"

void NimMain();

void print_msg(received_message* msg, void* udata) {
  // Note: early null chars will terminate string early
  printf("received message %.*s\n", (int)msg->decodedLen, msg->decoded);
}

const char* channel = "status-test-c";

const char* msg = "testing message";

int main(int argc, char* argv[]) {
  time_t lastmsg;

  NimMain();
  nimbus_start(30303, true, false, 0.002, NULL, false);

  nimbus_join_public_chat(channel, print_msg);

  lastmsg = time(NULL);

  while(1) {
    usleep(1);

    if (lastmsg + 1 <= time(NULL)) {
      lastmsg = time(NULL);
      char buf[4096];
      snprintf(buf, 4095,
        "[\"~#c4\",[\"%s\",\"text/plain\",\"~:public-group-user-message\",%ld,%ld,[\"^ \",\"~:chat-id\",\"%s\",\"~:text\",\"%s\"]]]",
        msg, lastmsg * 1000 * 100, lastmsg * 1000, channel, msg);

      printf("Posting %s\n", buf);
      nimbus_post_public(channel, buf);
    }
    nimbus_poll();
  }
}
