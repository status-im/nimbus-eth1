package main

/*

#include "libnimbus.h"

// receiveHandler gateway function
void receiveHandler_cgo(received_message * msg)
{
	void receiveHandler(received_message*);
	receiveHandler(msg);
}
*/
import "C"