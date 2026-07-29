// nimbus_verified_proxy
// Copyright (c) 2026 Status Research & Development GmbH
// Licensed and distributed under either of
//   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
//   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
// at your option. This file may not be copied, modified, or distributed except according to those terms.

import VerifProxyModule from './verifproxy_wasm.js';   // emcc output (-sEXPORT_ES6=1 default export)

async function defaultExecutionTransport(url, name, params) {
  const r = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: name, params }),
  });
  if (!r.ok) throw new Error(`HTTP ${r.status}: ${await r.text()}`);
  const rpc = await r.json();
  if (rpc.error) throw new Error(rpc.error.message ?? JSON.stringify(rpc.error));
  return JSON.stringify(rpc.result ?? null);
}

async function defaultBeaconTransport(url, endpoint, params) {
  const base = '/eth/v1/beacon/light_client';
  let fetchUrl;
  switch (endpoint) {
    case 'getLightClientBootstrap':
      fetchUrl = `${url}${base}/bootstrap/0x${params.block_root}`; break;
    case 'getLightClientUpdatesByRange':
      fetchUrl = `${url}${base}/updates?start_period=${params.start_period}&count=${params.count}`; break;
    case 'getLightClientOptimisticUpdate':
      fetchUrl = `${url}${base}/optimistic_update`; break;
    case 'getLightClientFinalityUpdate':
      fetchUrl = `${url}${base}/finality_update`; break;
    default:
      throw new Error(`unknown beacon endpoint: ${endpoint}`);
  }
  const r = await fetch(fetchUrl, { headers: { 'Accept': 'application/json' } });
  return r.text();
}

export default class NimbusVerifiedProxy {
  #mod        = null;
  #execFp     = null;
  #beaconFp   = null;
  #intervalId = null;
  #unifiedCb  = null;
  #callbacks  = new Map();
  #nextId     = 1;

  constructor() {}

  // Loads the WASM module, registers user-supplied transports, and starts the proxy.
  //
  // executionTransport(url, name, params) - async, must return the bare JSON result string.
  // beaconTransport(url, endpoint, params) - async, must return the raw response body string.
  async init(config, { executionTransport = defaultExecutionTransport, beaconTransport = defaultBeaconTransport } = {}) {
    this.#mod = await VerifProxyModule({
      print:    msg => console.log('[verifproxy]', msg),
      printErr: msg => console.error('[verifproxy]', msg),
      onAbort:  msg => console.error('[verifproxy] WASM abort:', msg),
    });
    const mod = this.#mod;

    // Execution transport: (ctx, cb, userData) - 3 pointer-sized args hence viii
    this.#execFp = mod.addFunction((ctxPtr, cbPtr, userDataPtr) => {
      const url    = mod.UTF8ToString(mod._wasmExecCtxUrl(userDataPtr));
      const name   = mod.UTF8ToString(mod._wasmExecCtxName(userDataPtr));
      const params = JSON.parse(mod.UTF8ToString(mod._wasmExecCtxParams(userDataPtr)));
      Promise.resolve(executionTransport(url, name, params))
        .then(result => {
          const buf = mod.stringToNewUTF8(result);
          mod._wasmDeliverExecutionTransport(0, buf, userDataPtr);
          mod._free(buf);
        })
        .catch(err => {
          const buf = mod.stringToNewUTF8(err.message);
          mod._wasmDeliverExecutionTransport(-1, buf, userDataPtr);
          mod._free(buf);
        });
    }, 'viii');

    // Beacon transport: (ctx, cb, userData) - 3 pointer-sized args hence viii
    this.#beaconFp = mod.addFunction((ctxPtr, cbPtr, userDataPtr) => {
      const url      = mod.UTF8ToString(mod._wasmBeaconCtxUrl(userDataPtr));
      const endpoint = mod.UTF8ToString(mod._wasmBeaconCtxEndpoint(userDataPtr));
      const params   = JSON.parse(mod.UTF8ToString(mod._wasmBeaconCtxParams(userDataPtr)));
      Promise.resolve(beaconTransport(url, endpoint, params))
        .then(result => {
          const buf = mod.stringToNewUTF8(result);
          mod._wasmDeliverBeaconTransport(0, buf, userDataPtr);
          mod._free(buf);
        })
        .catch(err => {
          const buf = mod.stringToNewUTF8(err.message);
          mod._wasmDeliverBeaconTransport(-1, buf, userDataPtr);
          mod._free(buf);
        });
    }, 'viii');

    // Unified RPC callback: dispatches to pending promises by id (userData)
    this.#unifiedCb = mod.addFunction((ctxPtr, status, resPtr, id) => {
      const entry = this.#callbacks.get(id);
      if (!entry) return;  // stale or already resolved

      this.#callbacks.delete(id);

      const body = mod.UTF8ToString(resPtr);
      mod._wasmFreeString(resPtr);

      if (status === 0) {
        entry.resolve(body);
      } else {
        const err = new Error(body);
        err.status = status;
        entry.reject(err);
      }
    }, 'viiii');

    const ret = mod.ccall(
      'wasmStart', 'number', ['string', 'number', 'number'],
      [config, this.#execFp, this.#beaconFp]
    );
    if (ret !== 0) throw new Error(`wasmStart failed with code ${ret}`);
    this.#intervalId = setInterval(() => {
      try {
        mod._wasmProcessTasks();
      } catch (e) {
        this.destroy();
        throw e;
      }
    }, 0);
  }

  call(name, params) {
    return new Promise((resolve, reject) => {
      const id = this.#nextId++;
      this.#callbacks.set(id, { resolve, reject });
      this.#mod.ccall(
        'wasmCall',
        null,
        ['string', 'string', 'number', 'number'],
        [name, params, this.#unifiedCb, id]
      );
    });
  }

  destroy() {
    if (this.#intervalId !== null) {
      clearInterval(this.#intervalId);
      this.#intervalId = null;
    }
    if (this.#execFp !== null) {
      this.#mod.removeFunction(this.#execFp);
      this.#execFp = null;
    }
    if (this.#beaconFp !== null) {
      this.#mod.removeFunction(this.#beaconFp);
      this.#beaconFp = null;
    }
    if (this.#unifiedCb !== null) {
      this.#mod.removeFunction(this.#unifiedCb);
      this.#unifiedCb = null;
    }
    // Reject any pending callbacks
    for (const entry of this.#callbacks.values()) {
      entry.reject(new Error('proxy destroyed'));
    }
    this.#callbacks.clear();
    this.#mod._wasmStop();
  }

}
