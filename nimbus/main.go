package main

import (
	"fmt"
	"time"
)

// #cgo LDFLAGS: libnimbus_api.a -lm
// #include "test.h"
import "C"

func poll() {

	for {
		fmt.Println("POLLING")
		time.Sleep(1 * time.Microsecond)
		C.nimbus_poll()
	}
}

func main() {

	C.NimMain()
	fmt.Println(C.nimbus_start(30306))
	i := 0
	//C.nimbus_subscribe(C.CString("status-test-c"), nil)

	peer1 := "enode://2d3e27d7846564f9b964308038dfadd4076e4373ac938e020708ad8819fd4fd90e5eb8314140768f782db704cb313b60707b968f8b61108a6fecd705b041746d@192.168.0.33:30303"
	peer2 := "enode://4ea35352702027984a13274f241a56a47854a7fd4b3ba674a596cff917d3c825506431cf149f9f2312a293bb7c2b1cca55db742027090916d01529fe0729643b@206.189.243.178:443"

	peer3 := "enode://94d2403d0c55b5c1627eb032c4c6ea8d30b523ae84661aafa18c539ce3af3f114a5bfe1a3cde7776988a6ab2906169dca8ce6a79e32d30c445629b24e6f59e0a@0.0.0.0:30303"
	fmt.Println(C.nimbus_add_peer(C.CString(peer1)))
	fmt.Println(C.nimbus_add_peer(C.CString(peer2)))

	fmt.Println(C.nimbus_add_peer(C.CString(peer3)))
	for {
		C.nimbus_poll()
		t := time.Now().UnixNano() / int64(time.Millisecond)
		i = i + 1
		time.Sleep(1 * time.Microsecond)
		message := fmt.Sprintf("[\"~#c4\",[\"Message:%d\",\"text/plain\",\"~:public-group-user-message\",%d,%d,[\"^ \",\"~:chat-id\",\"status-test-c\",\"~:text\",\"Message:%d\"]]]", i, t*100, t, i)
		if i%1000 == 0 {
			fmt.Println("posting", message)
			C.nimbus_post(C.CString(message))
		}
	}
}
