package main

/*

#include "libnimbus.h"

// receiveHandler gateway function
void receiveHandler_cgo(received_message * msg, void* udata)
{
	void receiveHandler(received_message* msg, void* udata);
	receiveHandler(msg, udata);
}
*/
import "C"