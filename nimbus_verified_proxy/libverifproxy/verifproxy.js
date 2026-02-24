// nimbus_verified_proxy
// Copyright (c) 2024-2026 Status Research & Development GmbH
// Licensed and distributed under either of
//   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
//   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
// at your option. This file may not be copied, modified, or distributed except according to those terms.

import VerifProxyModule from './verifproxy_wasm.js';

/**
 * Create and start a nimbus verified proxy instance in WASM.
 *
 * @param {string} configJson - JSON configuration string (same schema as the C library).
 * @returns {Promise<{call: function, stop: function}>} Proxy handle.
 *
 * The returned object exposes:
 *   call(name, params=[])  Promise — dispatches an RPC call; resolves with
 *                                    the parsed JSON result, rejects on error.
 *   stop()                 void    — signals the proxy to stop.
 */
export async function createVerifProxy(configJson) {
  // Map from integer callId → { resolve, reject }
  const pending = new Map();
  let nextId = 1;

  const Module = await VerifProxyModule({
    /**
     * Called synchronously from C via EM_ASM when an API call completes.
     * By the time this function runs, the pointer is still valid; C frees
     * the Nim-allocated string after EM_ASM returns.
     *
     * @param {number} status  - RET_SUCCESS (0) or negative error code
     * @param {number} resPtr  - pointer into WASM linear memory
     * @param {number} callId  - integer id matching a pending Promise (0 = startup)
     */
    verifProxyCallback(status, resPtr, callId) {
      const res = Module.UTF8ToString(resPtr);
      if (callId === 0) {
        // callId 0 is reserved for the startVerifProxy startup callback.
        // It is only invoked on error.
        if (status < 0) console.error('VerifProxy startup error:', res);
        return;
      }
      const p = pending.get(callId);
      if (!p) return;
      pending.delete(callId);
      if (status >= 0) {
        p.resolve(JSON.parse(res));
      } else {
        p.reject(new Error(res));
      }
    },

    /**
     * Called synchronously from C via EM_ASM when Nim needs to make an
     * outbound HTTP request.  Issues an async fetch and, when it settles,
     * calls Module._wasm_deliver_transport to resume the Nim future.
     *
     * @param {number} ctxPtr      - opaque Context pointer
     * @param {number} urlPtr      - pointer to the target URL string
     * @param {number} namePtr     - pointer to the RPC method name string
     * @param {number} paramsPtr   - pointer to the JSON params string (Nim-allocated;
     *                               must be freed here via _freeNimAllocatedString)
     * @param {number} cbPtr       - function-table index of the Nim transport callback
     * @param {number} userDataPtr - opaque userData pointer to relay back to the callback
     */
    verifProxyTransport(ctxPtr, urlPtr, namePtr, paramsPtr, cbPtr, userDataPtr) {
      const url    = Module.UTF8ToString(urlPtr);
      const name   = Module.UTF8ToString(namePtr);
      const params = Module.UTF8ToString(paramsPtr);
      // Free the Nim-allocated params buffer now that we have a JS copy.
      Module._freeNimAllocatedString(paramsPtr);

      fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          jsonrpc: '2.0',
          id: 1,
          method: name,
          params: JSON.parse(params),
        }),
      })
        .then(r => r.text())
        .then(result => {
          const buf = Module.stringToNewUTF8(result);
          Module._wasm_deliver_transport(cbPtr, ctxPtr, 0, buf, userDataPtr);
          Module._free(buf);
        })
        .catch(err => {
          const buf = Module.stringToNewUTF8(err.message);
          Module._wasm_deliver_transport(cbPtr, ctxPtr, -1, buf, userDataPtr);
          Module._free(buf);
        });
    },
  });

  // Allocate a C string for the config, start the proxy, then free immediately.
  const cfgPtr = Module.stringToNewUTF8(configJson);
  Module._wasm_start(cfgPtr);
  Module._free(cfgPtr);

  return {
    /**
     * Dispatch an RPC call.
     *
     * @param {string}   name   - RPC method name, e.g. 'eth_blockNumber'
     * @param {Array}    params - method parameters (default: empty array)
     * @returns {Promise<any>}  - resolves with parsed JSON result
     */
    call(name, params = []) {
      return new Promise((resolve, reject) => {
        const id = nextId++;
        pending.set(id, { resolve, reject });
        const n = Module.stringToNewUTF8(name);
        const p = Module.stringToNewUTF8(JSON.stringify(params));
        Module._wasm_call(n, p, id);
        Module._free(n);
        Module._free(p);
      });
    },

    /**
     * Stop the running proxy (signals the emscripten main loop to cancel).
     */
    stop() {
      Module._wasm_stop();
    },
  };
}
