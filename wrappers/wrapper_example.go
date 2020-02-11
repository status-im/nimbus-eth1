package main

import (
	"fmt"
	"runtime"
	"time"
	"unsafe"
)

/*
#include <stdlib.h>

// Passing "-lnimbus" to the Go linker through "-extldflags" is not enough. We need it in here, for some reason.
#cgo LDFLAGS: -Wl,-rpath,'$ORIGIN' -L${SRCDIR}/../build -lnimbus
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
	receivedMsg := C.GoBytes(unsafe.Pointer(msg.decoded), C.int(msg.decodedLen))
	fmt.Printf("[nim-status] received message %s\n", string(receivedMsg))
}

func Start() {
	C.NimMain()
	fmt.Println("[nim-status] Start Nimbus")
	if C.nimbus_start(30306, true, false, 0.002, nil, false) == false {
		panic("Can't start nimbus")
	}

	peer1 := C.CString("enode://2d3e27d7846564f9b964308038dfadd4076e4373ac938e020708ad8819fd4fd90e5eb8314140768f782db704cb313b60707b968f8b61108a6fecd705b041746d@192.168.0.33:30303")
	defer C.free(unsafe.Pointer(peer1))
	C.nimbus_add_peer(peer1)
}

func StatusListenAndPost(channel string) {
	fmt.Println("[nim-status] Status Public ListenAndPost")
	channelC := C.CString(channel)
	defer C.free(unsafe.Pointer(channelC))

	C.nimbus_join_public_chat(channelC,
		(C.received_msg_handler)(unsafe.Pointer(C.receiveHandler_cgo)))
	i := 0
	for {
		//fmt.Println("[nim-status] ListenAndPost (post @i==1000) i= ", i)
		C.nimbus_poll()
		t := time.Now().UnixNano() / int64(time.Millisecond)
		i = i + 1
		time.Sleep(1 * time.Microsecond)
		message := fmt.Sprintf("[\"~#c4\",[\"Message:%d\",\"text/plain\",\"~:public-group-user-message\",%d,%d,[\"^ \",\"~:chat-id\",\"%s\",\"~:text\",\"Message:%d\"]]]", i, t*100, t, channel, i)
		if i%1000 == 0 {
			fmt.Println("[nim-status] posting", message)
			messageC := C.CString(message)
			C.nimbus_post_public(channelC, messageC)
			C.free(unsafe.Pointer(messageC))
		}
	}
}

func main() {
	fmt.Println("Hi main")

	nprocs := runtime.GOMAXPROCS(0)
	fmt.Println("GOMAXPROCS ", nprocs)

	Start()
	StatusListenAndPost("status-test-go")
}
