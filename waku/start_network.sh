#!/bin/bash

set -e

# TODO: improve this bin location
WAKU_NODE_BIN="./build/wakunode"
NODE_PK="5dc5381cae54ba3174dc0d46040fe11614d0cc94d41185922585198b4fcef9d3"
NODE_ENODE="enode://e5fd642a0f630bbb1e4cd7df629d7b8b019457a9a74f983c0484a045cebb176def86a54185b50bbba6bbf97779173695e92835d63109c23471e6da382f922fdb@0.0.0.0:30303"
DEFAULTS="--log-level:DEBUG --discovery:off --log-metrics --metrics-server"
LIGHT_NODE="--light-node:1"
WAKU_LIGHT_NODE="--waku-mode:WakuChan ${LIGHT_NODE}"
METRICS_DIR="./waku/metrics"

# multitail support
MULTITAIL="${MULTITAIL:-multitail}" # to allow overriding the program name
USE_MULTITAIL="${USE_MULTITAIL:-no}" # make it an opt-in
type "$MULTITAIL" &>/dev/null || USE_MULTITAIL="no"

# TODO: This is based on the nim-beacon-chain eth2_network_simulation but quite
# the much worse version due to the custom nodes we need. Need to rework this
# to be less hardcoded, but might use a Nim application for this, hence the
# quick and dirty way for now.

mkdir -p "${METRICS_DIR}"/prometheus/
cat > "${METRICS_DIR}/prometheus/prometheus.yml" <<EOF
global:
  scrape_interval: 1s

scrape_configs:
  - job_name: "wakusim"
    static_configs:
    - targets: ['127.0.0.1:8008']
      labels:
        node: '0'
    - targets: ['127.0.0.1:8009']
      labels:
        node: '1'
    - targets: ['127.0.0.1:8010']
      labels:
        node: '2'
    - targets: ['127.0.0.1:8011']
      labels:
        node: '3'
    - targets: ['127.0.0.1:8012']
      labels:
        node: '4'
EOF

# use the exported Grafana dashboard for a single node to create one for all nodes
"./build/process_dashboard" \
  --nodes=5 \
  --in="waku/examples/waku-grafana-dashboard.json" \
  --out="${METRICS_DIR}/waku-sim-all-nodes-grafana-dashboard.json"

if [[ "$USE_MULTITAIL" != "no" ]]; then
  SLEEP=0
  # Direct connect with staticnodes, simple star topology for now
  # Master node to connect to
  CMD="$WAKU_NODE_BIN $DEFAULTS --rpc --nodekey:${NODE_PK} --waku-mode:WakuSan"
  COMMANDS+=( " -cT ansi -t 'master node' -l 'sleep $SLEEP; $CMD; echo [node execution completed]; while true; do sleep 100; done'" )

  SLEEP=1
  # Node under test 1: light waku node (topics)
  CMD="$WAKU_NODE_BIN $DEFAULTS --rpc --staticnodes:${NODE_ENODE} --ports-shift:1 ${WAKU_LIGHT_NODE}"
  COMMANDS+=( " -cT ansi -t 'light waku node' -l 'sleep $SLEEP; $CMD; echo [node execution completed]; while true; do sleep 100; done'" )
  # Node under test 2: light node (bloomfilter)
  CMD="$WAKU_NODE_BIN $DEFAULTS --rpc --staticnodes:${NODE_ENODE} --ports-shift:2 ${LIGHT_NODE}"
  COMMANDS+=( " -cT ansi -t 'light node' -l 'sleep $SLEEP; $CMD; echo [node execution completed]; while true; do sleep 100; done'" )
  # Node under test 3: full node
  CMD="$WAKU_NODE_BIN $DEFAULTS --rpc --staticnodes:${NODE_ENODE} --ports-shift:3"
  COMMANDS+=( " -cT ansi -t 'full node' -l 'sleep $SLEEP; $CMD; echo [node execution completed]; while true; do sleep 100; done'" )
  # Traffic generation node(s)
  CMD="$WAKU_NODE_BIN $DEFAULTS --rpc --staticnodes:${NODE_ENODE} --ports-shift:4"
  COMMANDS+=( " -cT ansi -t 'traffic full node' -l 'sleep $SLEEP; $CMD; echo [node execution completed]; while true; do sleep 100; done'" )
else
  # Direct connect with staticnodes, simple star topology for now
  # Master node to connect to
  CMD="$WAKU_NODE_BIN $DEFAULTS --rpc --nodekey:${NODE_PK} --waku-mode:WakuSan"
  eval ${CMD} &
  sleep 1
  # Node under test 1: light waku node (topics)
  CMD="$WAKU_NODE_BIN $DEFAULTS --rpc --staticnodes:${NODE_ENODE} --ports-shift:1 ${WAKU_LIGHT_NODE}"
  eval ${CMD} &
  # Node under test 2: light node (bloomfilter)
  CMD="$WAKU_NODE_BIN $DEFAULTS --rpc --staticnodes:${NODE_ENODE} --ports-shift:2 ${LIGHT_NODE}"
  eval ${CMD} &
  # Node under test 3: full node
  CMD="$WAKU_NODE_BIN $DEFAULTS --rpc --staticnodes:${NODE_ENODE} --ports-shift:3"
  eval ${CMD} &
  # Traffic generation node(s)
  CMD="$WAKU_NODE_BIN $DEFAULTS --rpc --staticnodes:${NODE_ENODE} --ports-shift:4"
  eval ${CMD} &
fi

if [[ "$USE_MULTITAIL" != "no" ]]; then
  eval $MULTITAIL -s 2 -M 0 -x \"Waku Simulation\" "${COMMANDS[@]}"
else
  wait # Stop when all nodes have gone down
fi
