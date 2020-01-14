# Introduction
`wakunode` is a cli application that allows you to run a
[Waku](https://github.com/vacp2p/specs/blob/master/waku.md) enabled node.

The application and Waku specification are still experimental and fully in flux.

Additionally the original Whisper (EIP-627) protocol can also be enabled as can
an experimental Whisper - Waku bridging option.

# How to Build & Run

```bash
make wakunode
./build/wakunode --help
```

# Testing Waku Protocol
One can set up several nodes, get them connected and then instruct them via the
JSON-RPC interface. This can be done via e.g. web3.js, nim-web3 (needs to be
updated) or simply curl your way out.

The JSON-RPC interface is currently the same as the one of Whisper. The only
difference is the addition of broadcasting the topics interest when a filter
with a certain set of topics is subcribed.

Example of a quick simulation test using this approach:
```bash
./waku/start_network.sh
# Or when multitail is installed
USE_MULTITAIL="yes" ./waku/start_network.sh

./build/quicksim
```

# Using Metrics

Metrics are available for valid envelopes and dropped envelopes.

To compile in an HTTP endpoint for accessing the metrics we need to provide the
`insecure` flag:
```bash
make NIMFLAGS="-d:insecure" wakunode
./build/wakunode --metrics-server
```

Ensure your Prometheus config `prometheus.yml` contains the targets you care about, e.g.:

```
scrape_configs:
  - job_name: "waku"
    static_configs:
      - targets: ['localhost:8008', 'localhost:8009', 'localhost:8010']
```

For visualisation, similar steps can be used as is written down for Nimbus
[here](https://github.com/status-im/nimbus#metric-visualisation).

There is a similar example dashboard that includes visualisation of the
envelopes available at `waku/examples/waku-grafana-dashboard.json`.
