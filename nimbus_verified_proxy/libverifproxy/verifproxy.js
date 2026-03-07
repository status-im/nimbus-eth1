// nimbus_verified_proxy
// Copyright (c) 2026 Status Research & Development GmbH
// Licensed and distributed under either of
//   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
//   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
// at your option. This file may not be copied, modified, or distributed except according to those terms.

import VerifProxyModule from './verifproxy_wasm.js';   // emcc output (-sEXPORT_ES6=1 default export)

const TAG = '[verifproxy]';

const _mod = await VerifProxyModule({
  // Capture Nim / Emscripten stdout and stderr.
  print:    msg => console.log(TAG, msg),
  printErr: msg => console.error(TAG, msg),
  // Called when the WASM module calls emscripten_abort() / abort().
  onAbort:  msg => console.error(`${TAG} WASM abort:`, msg),
});

const _transport = _mod.addFunction((ctxPtr, urlPtr, namePtr, paramsPtr, cbPtr, userDataPtr) => {
  const url = _modUTF8ToString(urlPtr);
  const name = _modUTF8ToString(namePtr);
  const params = _modUTF8ToString(paramsPtr);

  _mod._nvp_free_string(urlPtr);
  _mod._nvp_free_string(paramsPtr);

  console.debug(TAG, 'transport fired', { url, name, params, cbPtr, userDataPtr });

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
      console.debug(TAG, 'transport ok', { name, cbPtr });
      const buf = Module.stringToNewUTF8(result);
      _mod._nvp_deliver_transport(cbPtr, ctxPtr, 0, buf, userDataPtr)
      _mod._free(buf);
    })
    .catch(err => {
      console.error(TAG, 'fetch error', { name, err });
      const buf = Module.stringToNewUTF8(err.message);
      _mod._wasm_deliver_transport(cbFnPtr, ctxPtr, -1, buf, userDataPtr)
      _mod._free(buf);
    });
  },
  'viiiiii',
);

function _makeCallback(resolve, reject) {
  const fp = _mod.addFunction((ctxPtr, status, resPtr, userDataPtr) => {
      const body = _mod.UTF8ToString(resPtr);
      _mod._nvp_free_string(resPtr);   // free Nim-allocated string
      _mod.removeFunction(fp);              // release the table slot

      if (status === 0) {
          resolve(body);
      } else {
          const err = new Error(body);
          err.status = status;
          reject(err);
      }
  }, 'viiii');
  return fp;
}

export function proxy_start(config) {
  return new Promise((resolve, reject) => {
      const cb = _makeCallback(resolve, reject);
      _mod.ccall('nvp_start', null, ['string', 'number', 'number'], [config, cb, _transport]);
  });
}

export function proxy_call(url, params) {
  return new Promise((resolve, reject) => {
      const cb = _makeCallback(resolve, reject);
      _mod.ccall('nvp_wasm_call', null, ['string', 'string', 'number'], [url, params, cb]);
  });
}

export function proxy_stop() {
    _mod.removeFunction(_transport)
    _mod._nvp_stop();
}
