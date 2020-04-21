# Introduction
`wakunode` is a cli application that allows you to run a
[Waku](https://specs.vac.dev/waku/waku.html) enabled node.

The Waku specification is still in draft and thus this implementation will
change accordingly.

Additionally the original Whisper (EIP-627) protocol can also be enabled as can
an experimental Whisper - Waku bridging option.

# How to Build & Run

## Prerequisites

* GNU Make, Bash and the usual POSIX utilities. Git 2.9.4 or newer.
* PCRE

More information on the installation of these can be found [here](https://github.com/status-im/nimbus#prerequisites).

## Build & Run

```bash
# The first `make` invocation will update all Git submodules.
# You'll run `make update` after each `git pull`, in the future, to keep those submodules up to date.
make wakunode

# See available command line options
./build/wakunode --help

# Connect the client directly with the Status test fleet
./build/wakunode --log-level:debug --discovery:off --fleet:test --log-metrics
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

# Testing Waku Protocol
One can set up several nodes, get them connected and then instruct them via the
JSON-RPC interface. This can be done via e.g. web3.js, nim-web3 (needs to be
updated) or simply curl your way out.

The JSON-RPC interface is currently the same as the one of Whisper. The only
difference is the addition of broadcasting the topics interest when a filter
with a certain set of topics is subcribed.

Example of a quick simulation using this approach:
```bash
# Build wakunode + quicksim
make NIMFLAGS="-d:insecure" wakusim

# Start the simulation nodes, this currently requires multitail to be installed
./build/start_network --topology:FullMesh --amount:6 --test-node-peers:2
# In another shell run
./build/quicksim
```

The `start_network` tool will also provide a `prometheus.yml` with targets
set to all simulation nodes that are started. This way you can easily start
prometheus with this config, e.g.:

```bash
cd waku/metrics/prometheus
prometheus
```

A Grafana dashboard containing the example dashboard for each simulation node
is also generated and can be imported in case you have Grafana running.
This dashboard can be found at `./waku/metrics/waku-sim-all-nodes-grafana-dashboard.json`

# Spec support

*This section last updated April 21, 2020*

This client of Waku is spec compliant with [Waku spec v1.0](https://specs.vac.dev/waku/waku.html).

It doesn't yet implement the following recommended features:
- No support for rate limiting
- No support for DNS discovery to find Waku nodes
- It doesn't disconnect a peer if it receives a message before a Status message
- No support for negotiation with peer supporting multiple versions via Devp2p capabilities in `Hello` packet

Additionally it makes the following choices:
- It doesn't send message confirmations
- It has partial support for accounting:
  - Accounting of total resource usage and total circulated envelopes is done through metrics But no accounting is done for individual peers.
