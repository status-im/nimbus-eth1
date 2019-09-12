package main

import (
	"fmt"
	"runtime"
	"time"
	"unsafe"
)

/*
#cgo LDFLAGS: -Wl,-rpath,'$ORIGIN' -L${SRCDIR}/../build -lnimbus -lm
#include "libnimbus.h"

void receiveHandler_cgo(received_message * msg); // Forward declaration.
*/
import "C"

// Arrange that main.main runs on main thread.
func init() {
	runtime.LockOSThread()
}

func poll() {

	for {
		fmt.Println("POLLING")
		time.Sleep(1 * time.Microsecond)
		C.nimbus_poll()
	}
}

//export receiveHandler
func receiveHandler(msg *C.received_message) {
	fmt.Printf("[nim-status] received message %s\n",
		C.GoStringN((*C.char)(msg.decoded), (C.int)(msg.decodedLen)) )
	fmt.Printf("[nim-status] source public key %x\n", msg.source)
}

func Start() {
	C.NimMain()
	fmt.Println("[nim-status] Start Nimbus")
	C.nimbus_start(30306)
}

func StatusListenAndPost(channel string) {
	fmt.Println("[nim-status] Status Public ListenAndPost")

	// TODO: free the CStrings?
	// TODO: Is this doing a copy or not? If not, shouldn't we see issues when the
	// nim GC kicks in?
	symKeyId := C.GoString(C.nimbus_add_symkey_from_password(C.CString(channel)))
	asymKeyId := C.GoString(C.nimbus_new_keypair())

	options := C.filter_options{symKeyID: C.CString(symKeyId),
		minPow: 0.002,
		topic: C.nimbus_string_to_topic(C.CString(channel)).topic}
	C.nimbus_whisper_subscribe(&options,
		(C.received_msg_handler)(unsafe.Pointer(C.receiveHandler_cgo)))

	postMessage := C.post_message{symKeyID: C.CString(symKeyId),
		sig: C.CString(asymKeyId),
		ttl: 20,
		topic: C.nimbus_string_to_topic(C.CString(channel)).topic,
		powTarget: 0.002,
		powTime: 1.0}

	i := 0
	for {
		C.nimbus_poll()
		t := time.Now().UnixNano() / int64(time.Millisecond)
		i = i + 1
		time.Sleep(1 * time.Microsecond)
		message := fmt.Sprintf("[\"~#c4\",[\"Message:%d\",\"text/plain\",\"~:public-group-user-message\",%d,%d,[\"^ \",\"~:chat-id\",\"%s\",\"~:text\",\"Message:%d\"]]]", i, t*100, t, channel, i)
		if i%1000 == 0 {
			fmt.Println("[nim-status] posting", message)
			postMessage.payload = (C.CString(message))
			C.nimbus_whisper_post(&postMessage)
		}
	}
}

func main() {
	nprocs := runtime.GOMAXPROCS(0)
	fmt.Println("GOMAXPROCS ", nprocs)

	Start()
	StatusListenAndPost("status-test-go")
}
