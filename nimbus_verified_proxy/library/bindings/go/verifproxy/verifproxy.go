// nimbus_verified_proxy
// Copyright (c) 2026 Status Research & Development GmbH
// Licensed and distributed under either of
//   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
//   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
// at your option. This file may not be copied, modified, or distributed except according to those terms.

package verifproxy

/*
#cgo CFLAGS: -I${SRCDIR}
#cgo linux LDFLAGS: ${SRCDIR}/lib/libverifproxy.a -lm -lpthread -lstdc++
#cgo darwin LDFLAGS: ${SRCDIR}/lib/libverifproxy.a -framework Security -lc++
#cgo windows LDFLAGS: ${SRCDIR}/lib/libverifproxy.lib -lbcrypt -lpthread -lws2_32 -lstdc++

#include "verifproxy.h"
#include <stdlib.h>

extern void goCallbackWrapper(Context *ctx, int status, char *result, void *userData);
extern void goExecTransportWrapper(Context *ctx, TransportDeliveryCallback cb, void *ud);
extern void goBeaconTransportWrapper(Context *ctx, TransportDeliveryCallback cb, void *ud);

__attribute__((weak)) void cGoCallback(Context *ctx, int status, char *result, void *userData) {
    goCallbackWrapper(ctx, status, result, userData);
}

__attribute__((weak)) void cGoExecTransport(Context *ctx, TransportDeliveryCallback cb, void *ud) {
    goExecTransportWrapper(ctx, cb, ud);
}

__attribute__((weak)) void cGoBeaconTransport(Context *ctx, TransportDeliveryCallback cb, void *ud) {
    goBeaconTransportWrapper(ctx, cb, ud);
}

static void callDeliveryCb(TransportDeliveryCallback cb, int status, char *res, void *ud) {
    cb(status, res, ud);
}

static inline Context *callStartVerifProxy(char *configJson) {
    return startVerifProxy(configJson,
        (ExecutionTransportProc)cGoExecTransport,
        (BeaconTransportProc)cGoBeaconTransport);
}

static inline void callNvp(Context *ctx, char *method, char *params, CallBackProc cb, uintptr_t userData) {
    proxyCall(ctx, method, params, cb, (void *)userData);
}
*/
import "C"
import (
	"encoding/json"
	"errors"
	"runtime"
	"runtime/cgo"
	"sync"
	"time"
	"unsafe"
)

type ExecTransportFunc func(url, method, params string) (json.RawMessage, error)
type BeaconTransportFunc func(url, endpoint, params string) (json.RawMessage, error)

func DefaultExecTransport(url, method, params string) (json.RawMessage, error) {
	return SendRPC(url, method, params)
}

func DefaultBeaconTransport(url, endpoint, params string) (json.RawMessage, error) {
	return SendBeaconRequest(url, endpoint, params)
}

const requestTimeout = 5 * time.Second

type VerifyProxyResult struct {
	status   int
	response string
}

type VerifyProxyCallArgs struct {
	method     string
	params     string
	resultChan chan VerifyProxyResult
}

type Context struct {
	ctxPtr          *C.Context
	stopChan        chan VerifyProxyResult
	executeTaskChan chan VerifyProxyCallArgs
	execTransport   ExecTransportFunc
	beaconTransport BeaconTransportFunc
}

var (
	errEmptyContext = errors.New("empty context")
	startOnce       sync.Once
	ctxMapMu        sync.RWMutex
	ctxMap          = map[uintptr]*Context{}
)

func registerCtx(cCtx *C.Context, goCtx *Context) {
	ctxMapMu.Lock()
	ctxMap[uintptr(unsafe.Pointer(cCtx))] = goCtx
	ctxMapMu.Unlock()
}

func unregisterCtx(cCtx *C.Context) {
	ctxMapMu.Lock()
	delete(ctxMap, uintptr(unsafe.Pointer(cCtx)))
	ctxMapMu.Unlock()
}

func lookupCtx(cCtx *C.Context) *Context {
	ctxMapMu.RLock()
	goCtx := ctxMap[uintptr(unsafe.Pointer(cCtx))]
	ctxMapMu.RUnlock()
	return goCtx
}

//export goCallbackWrapper
func goCallbackWrapper(_ *C.Context, status C.int, result *C.char, userData unsafe.Pointer) {
	h := cgo.Handle(userData)
	defer h.Delete()

	ch := h.Value().(chan VerifyProxyResult)
	resultStr := C.GoString(result)
	C.freeNimAllocatedString(result)

	ch <- VerifyProxyResult{status: int(status), response: resultStr}
}

//export goExecTransportWrapper
func goExecTransportWrapper(cCtx *C.Context, cb C.TransportDeliveryCallback, ud unsafe.Pointer) {
	goCtx := lookupCtx(cCtx)

	url := C.GoString(C.execCtxUrl(ud))
	method := C.GoString(C.execCtxName(ud))
	params := C.GoString(C.execCtxParams(ud))

	resp, err := goCtx.execTransport(url, method, params)
	if err != nil {
		cErr := C.CString(err.Error())
		defer C.free(unsafe.Pointer(cErr))
		C.callDeliveryCb(cb, C.RET_ERROR, cErr, ud)
		return
	}
	cResp := C.CString(string(resp))
	defer C.free(unsafe.Pointer(cResp))
	C.callDeliveryCb(cb, C.RET_SUCCESS, cResp, ud)
}

//export goBeaconTransportWrapper
func goBeaconTransportWrapper(cCtx *C.Context, cb C.TransportDeliveryCallback, ud unsafe.Pointer) {
	goCtx := lookupCtx(cCtx)

	url := C.GoString(C.beaconCtxUrl(ud))
	endpoint := C.GoString(C.beaconCtxEndpoint(ud))
	params := C.GoString(C.beaconCtxParams(ud))

	resp, err := goCtx.beaconTransport(url, endpoint, params)
	if err != nil {
		cErr := C.CString(err.Error())
		defer C.free(unsafe.Pointer(cErr))
		C.callDeliveryCb(cb, C.RET_ERROR, cErr, ud)
		return
	}
	cResp := C.CString(string(resp))
	defer C.free(unsafe.Pointer(cResp))
	C.callDeliveryCb(cb, C.RET_SUCCESS, cResp, ud)
}

func (ctx *Context) Stop() error {
	if ctx == nil {
		return errEmptyContext
	}
	ctx.stopChan <- VerifyProxyResult{status: int(C.RET_CANCELLED), response: "cancelled by user"}
	return nil
}

func Start(configJson string, execTransport ExecTransportFunc, beaconTransport BeaconTransportFunc) (*Context, error) {
	if execTransport == nil {
		execTransport = DefaultExecTransport
	}
	if beaconTransport == nil {
		beaconTransport = DefaultBeaconTransport
	}

	goCtx := &Context{
		stopChan:        make(chan VerifyProxyResult, 1),
		executeTaskChan: make(chan VerifyProxyCallArgs, 64),
		execTransport:   execTransport,
		beaconTransport: beaconTransport,
	}

	startOnce.Do(func() { C.NimMain() })

	cConfigJson := C.CString(configJson)
	defer C.free(unsafe.Pointer(cConfigJson))

	var wg sync.WaitGroup
	wg.Add(1)

	go func() {
		runtime.LockOSThread()
		defer runtime.UnlockOSThread()

		h := cgo.NewHandle(goCtx.stopChan)
		defer h.Delete()

		ctxPtr := C.callStartVerifProxy(cConfigJson)
		if ctxPtr == nil {
			wg.Done()
			return
		}
		goCtx.ctxPtr = ctxPtr
		registerCtx(ctxPtr, goCtx)
		wg.Done()

	loop:
		for {
			select {
			case callArgs := <-goCtx.executeTaskChan:
				h := cgo.NewHandle(callArgs.resultChan)
				cMethod := C.CString(callArgs.method)
				cParams := C.CString(callArgs.params)
				C.callNvp(ctxPtr, cMethod, cParams, (*[0]byte)(C.cGoCallback), C.uintptr_t(h))
				C.free(unsafe.Pointer(cMethod))
				C.free(unsafe.Pointer(cParams))
			case <-goCtx.stopChan:
				unregisterCtx(ctxPtr)
				C.stopVerifProxy(ctxPtr)
				C.freeContext(ctxPtr)
				break loop
			default:
				C.processVerifProxyTasks(ctxPtr)
			}
		}
	}()

	wg.Wait()
	return goCtx, nil
}

func (ctx *Context) CallRpc(method string, params string, timeout time.Duration) (string, error) {
	if ctx == nil {
		return "", errEmptyContext
	}
	if timeout <= 0 {
		timeout = requestTimeout
	}

	resultChan := make(chan VerifyProxyResult, 1)
	ctx.executeTaskChan <- VerifyProxyCallArgs{method: method, params: params, resultChan: resultChan}

	select {
	case result := <-resultChan:
		if result.status == int(C.RET_SUCCESS) {
			return result.response, nil
		}
		return "", errors.New(result.response)
	case <-time.After(timeout):
		return "", errors.New("request timed out")
	}
}
