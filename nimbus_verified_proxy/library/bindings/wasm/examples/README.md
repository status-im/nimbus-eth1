# Verified Proxy WASM Example

A minimal browser demo that runs the verified proxy as a WASM module.

## Prerequisites

- Python 3
- A WASM build of the verified proxy (see below)

## Build the WASM module

From the repo root:

```sh
make nimbus_verified_proxy_wasm
```

The build outputs `verifproxy_wasm.js` and `verifproxy_wasm.wasm` into `build/nimbus_verified_proxy_wasm/`.

## Run the example

1. Copy `index.html` and `server.py` from this directory into `build/nimbus_verified_proxy_wasm/`:

   ```sh
   cp nimbus_verified_proxy/library/bindings/wasm/examples/index.html \
      nimbus_verified_proxy/library/bindings/wasm/examples/server.py \
      build/nimbus_verified_proxy_wasm/
   ```

2. Start the server from the build directory:

   ```sh
   cd build/nimbus_verified_proxy_wasm
   python3 server.py
   ```

3. Open [http://localhost:8080/index.html](http://localhost:8080/index.html) in a browser.

The server also exposes a CORS proxy at `/proxy?url=<encoded-url>` so the page can reach local or remote Ethereum nodes without browser CORS restrictions.
