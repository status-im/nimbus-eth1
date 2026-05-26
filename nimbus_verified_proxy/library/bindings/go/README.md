# nimbus-verified-proxy Go bindings

Go bindings for [Nimbus Verified Proxy](https://nimbus.guide/verified-proxy.html) — a light-client-backed Ethereum JSON-RPC proxy that cryptographically verifies responses before returning them.

## Requirements

- Go 1.24+
- CGo (enabled by default)
- C++ standard library (`libstdc++` on Linux/Windows, `libc++` on macOS)

## Installation

```sh
go get github.com/status-im/nimbus-eth1/nimbus_verified_proxy/library/bindings/go
```

The package links against a precompiled static library (`libverifproxy`). After adding the dependency, fetch the library for your platform:

```sh
go get -tool github.com/status-im/nimbus-eth1/nimbus_verified_proxy/library/bindings/go/cmd/verifproxy-setup-libs
go tool verifproxy-setup-libs
```

`verifproxy-setup-libs` downloads the correct `libverifproxy` from the GitHub release matching the module version and writes it into the module cache.

## Usage

```go
import "github.com/status-im/nimbus-eth1/nimbus_verified_proxy/library/bindings/go/verifproxy"

const config = `{
  "eth2Network":      "mainnet",
  "trustedBlockRoot": "<trusted-block-root>",
  "executionApiUrls": "https://your-execution-node",
  "beaconApiUrls":    "https://your-beacon-node",
  "logLevel":         "INFO"
}`

ctx, err := verifproxy.Start(config, nil, nil)
if err != nil {
    log.Fatal(err)
}
defer ctx.Stop()

result, err := ctx.CallRpc("eth_blockNumber", "[]", 30*time.Second)
```

The proxy syncs with the beacon chain in the background. The first few calls may take longer while the light client catches up.

## Configuration

| Field | Description |
|---|---|
| `eth2Network` | Network name: `mainnet`, `sepolia`, or `hoodi` |
| `trustedBlockRoot` | A trusted checkpoint block root (hex) used to bootstrap the light client |
| `executionApiUrls` | Comma-separated execution layer JSON-RPC URLs |
| `beaconApiUrls` | Comma-separated beacon API URLs |
| `logLevel` | Log verbosity: `TRACE`, `DEBUG`, `INFO`, `WARN`, `ERROR`, `FATAL` |
| `logStdout` | Log destination: `Auto`, `None`, or `Stdout` |

## Custom transports

By default HTTP transports are used for both the execution and beacon APIs. You can override them:

```go
execTransport := func(url, method, params string) (json.RawMessage, error) {
    // forward to your own RPC client
}

beaconTransport := func(url, endpoint, params string) (json.RawMessage, error) {
    // forward to your own beacon client
}

ctx, err := verifproxy.Start(config, execTransport, beaconTransport)
```

## API

```go
// Start initialises the proxy and begins light-client sync.
// Pass nil transports to use the default HTTP implementations.
func Start(configJson string, exec ExecTransportFunc, beacon BeaconTransportFunc) (*Context, error)

// CallRpc sends a JSON-RPC call and waits for the verified result.
func (ctx *Context) CallRpc(method, params string, timeout time.Duration) (string, error)

// Stop shuts down the proxy and frees resources.
func (ctx *Context) Stop() error
```

