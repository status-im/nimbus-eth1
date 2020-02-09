package main

import (
	"encoding/hex"
	"fmt"
	"runtime"
	"time"
	"unsafe"
)

/*
#include <stdlib.h>
#include <stdbool.h>

// Passing "-lnimbus" to the Go linker through "-extldflags" is not enough. We need it in here, for some reason.
#cgo LDFLAGS: -Wl,-rpath,'$ORIGIN' -L${SRCDIR}/../build -lnimbus
#include "libnimbus.h"

void receiveHandler_cgo(received_message * msg, void* udata); // Forward declaration.
*/
import "C"

// Arrange that main.main runs on main thread.
func init() {
	runtime.LockOSThread()
}

//export receiveHandler
func receiveHandler(msg *C.received_message, udata unsafe.Pointer) {
	receivedMsg := C.GoBytes(unsafe.Pointer(msg.decoded), C.int(msg.decodedLen))
	fmt.Printf("[nim-status] received message %s\n", string(receivedMsg))
	if msg.source != nil {
		source := C.GoBytes(unsafe.Pointer(msg.source), 64)
		fmt.Printf("[nim-status] source public key %x\n", string(source))
	}
	msgCount := (*int)(udata)
	*msgCount += 1
	fmt.Printf("[nim-status] message count %d\n", *msgCount)
}

func Start() {
	C.NimMain()
	fmt.Println("[nim-status] Start Nimbus")

	privKeyHex := "a2b50376a79b1a8c8a3296485572bdfbf54708bb46d3c25d73d2723aaaf6a617"
	data, err := hex.DecodeString(privKeyHex)
	if err != nil {
		panic(err)
	}
	privKey := (*C.uint8_t)(C.CBytes(data))
	defer C.free(unsafe.Pointer(privKey))

	if C.nimbus_start(30306, true, false, 0.002, privKey, false) == false {
		panic("Can't start nimbus")
	}
}

func StatusListenAndPost(channel string) {
	fmt.Println("[nim-status] Status Public ListenAndPost")

	channelC := C.CString(channel)
	defer C.free(unsafe.Pointer(channelC))

	tmp := C.malloc(C.size_t(C.ID_LEN))
	if C.nimbus_add_symkey_from_password(channelC, (*C.uint8_t)(tmp)) == false {
		C.free(unsafe.Pointer(tmp))
		panic("Cannot create symmetric key")
	}
	// No need to do this back and forth GO <-> C, just showing how it might work
	// in implementations (when wrapped in calls passing Go Bytes or Strings).
	symKeyId := C.GoBytes(tmp, C.ID_LEN)
	C.free(unsafe.Pointer(tmp))
	symKeyIdC := (*C.uint8_t)(C.CBytes(symKeyId))
	defer C.free(unsafe.Pointer(symKeyIdC))

	tmp = C.malloc(C.size_t(C.ID_LEN))
	if C.nimbus_new_keypair((*C.uint8_t)(tmp)) == false {
		C.free(unsafe.Pointer(tmp))
		panic("Cannot create asymmetric keypair")
	}
	// No need to do this back and forth GO <-> C, just showing how it might work
	// in implementations (when wrapped in calls passing Go Bytes or Strings).
	asymKeyId := C.GoBytes(tmp, C.ID_LEN)
	C.free(unsafe.Pointer(tmp))
	asymKeyIdC := (*C.uint8_t)(C.CBytes(asymKeyId))
	defer C.free(unsafe.Pointer(asymKeyIdC))

	var msgCount int = 0

	options := C.filter_options{symKeyID: symKeyIdC,
		minPow: 0.002,
		topic:  C.nimbus_channel_to_topic(channelC).topic}

	tmp = C.malloc(C.size_t(C.ID_LEN))
	if C.nimbus_subscribe_filter(&options,
		(C.received_msg_handler)(unsafe.Pointer(C.receiveHandler_cgo)),
		unsafe.Pointer(&msgCount), (*C.uint8_t)(tmp)) == false {
		C.free(unsafe.Pointer(tmp))
		panic("Cannot subscribe filter")
	}
	filterId := C.GoBytes(tmp, C.ID_LEN)
	C.free(unsafe.Pointer(tmp))
	fmt.Printf("[nim-status] filter subscribed, id: %s\n",
		hex.EncodeToString(filterId))

	postMessage := C.post_message{symKeyID: symKeyIdC,
		sourceID:  asymKeyIdC,
		ttl:       20,
		topic:     C.nimbus_channel_to_topic(channelC).topic,
		powTarget: 0.002,
		powTime:   1.0}

	i := 0
	for {
		C.nimbus_poll()
		t := time.Now().UnixNano() / int64(time.Millisecond)
		i = i + 1
		time.Sleep(1 * time.Microsecond)
		message := fmt.Sprintf("[\"~#c4\",[\"Message:%d\",\"text/plain\",\"~:public-group-user-message\",%d,%d,[\"^ \",\"~:chat-id\",\"%s\",\"~:text\",\"Message:%d\"]]]", i, t*100, t, channel, i)
		if i%1000 == 0 {
			fmt.Printf("[nim-status] posting msg number %d: %s\n", msgCount, message)
			postMessage.payload = (*C.uint8_t)(C.CBytes([]byte(message)))
			postMessage.payloadLen = (C.size_t)(len([]byte(message)))
			defer C.free(unsafe.Pointer(postMessage.payload))
			if C.nimbus_post(&postMessage) == false {
				fmt.Println("[nim-status] message could not be added to queue")
			}
		}
	}
}

func main() {
	nprocs := runtime.GOMAXPROCS(0)
	fmt.Println("GOMAXPROCS ", nprocs)

	Start()
	StatusListenAndPost("status-test-go")
}
