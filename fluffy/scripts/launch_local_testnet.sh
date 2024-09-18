#!/usr/bin/env bash

# Copyright (c) 2021-2024 Status Research & Development GmbH. Licensed under
# either of:
# - Apache License, version 2.0
# - MIT license
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

# This script is for a big part a copy of the nimbus-eth2 launch_local_testnet
# script. This script however does not expect fluffy nodes to exit 0 in the good
# case, but instead the json-rpc interface is used to check whether certain
# values are what we expect them to be.

set -e

cd "$(dirname "${BASH_SOURCE[0]}")"/../..

####################
# argument parsing #
####################

GETOPT_BINARY="getopt"
if uname | grep -qi darwin; then
  # macOS
  GETOPT_BINARY=$(find /opt/homebrew/opt/gnu-getopt/bin/getopt /usr/local/opt/gnu-getopt/bin/getopt 2> /dev/null | head -n1 || true)
  [[ -f "$GETOPT_BINARY" ]] || { echo "GNU getopt not installed. Please run 'brew install gnu-getopt'. Aborting."; exit 1; }
fi

! ${GETOPT_BINARY} --test > /dev/null
if [ ${PIPESTATUS[0]} != 4 ]; then
  echo '`getopt --test` failed in this environment.'
  exit 1
fi

OPTS="h:n:d"
LONGOPTS="help,nodes:,data-dir:,run-tests,log-level:,base-port:,base-rpc-port:,trusted-block-root:,portal-bridge,base-metrics-port:,reuse-existing-data-dir,timeout:,kill-old-processes,skip-build,portal-subnetworks:,disable-state-root-validation,radius:"

# default values

NUM_NODES="8" # With the default radius of 254 which should result in ~1/4th
# of the data set stored on each node at least 8 nodes are recommended to
# provide complete coverage of the data set with approx replication factor of 2.
RADIUS="static:254"
DATA_DIR="local_testnet_data"
RUN_TESTS="0"
LOG_LEVEL="INFO"
BASE_PORT="9000"
BASE_METRICS_PORT="8008"
BASE_RPC_PORT="10000"
REUSE_EXISTING_DATA_DIR="0"
TIMEOUT_DURATION="0"
KILL_OLD_PROCESSES="0"
SCRIPTS_DIR="fluffy/scripts/"
PORTAL_BRIDGE="0"
TRUSTED_BLOCK_ROOT=""
# REST_URL="http://127.0.0.1:5052"
REST_URL="http://testing.mainnet.beacon-api.nimbus.team"
SKIP_BUILD="0"
PORTAL_SUBNETWORKS="beacon,history,state"
DISABLE_STATE_ROOT_VALIDATION="0"

print_help() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS] -- [FLUFFY OPTIONS]
E.g.: $(basename "$0") --nodes ${NUM_NODES} --data-dir "${DATA_DIR}" # defaults

  -h, --help                        this help message
  -n, --nodes                       number of nodes to launch. Minimum 3 nodes (default: ${NUM_NODES})
  -d, --data-dir                    directory where all the node data and logs will end up
                                    (default: "${DATA_DIR}")
  --base-port                       bootstrap node's discv5 port (default: ${BASE_PORT})
  --base-rpc-port                   bootstrap node's RPC port (default: ${BASE_RPC_PORT})
  --base-metrics-port               bootstrap node's metrics server port (default: ${BASE_METRICS_PORT})
  --portal-bridge                   run a portal bridge attached to the bootstrap node
  --trusted-block-root              recent trusted finalized block root to initialize the consensus light client from
  --run-tests                       when enabled run tests else use "htop" to see the fluffy processes without doing any tests
  --log-level                       set the log level (default: ${LOG_LEVEL})
  --reuse-existing-data-dir         instead of deleting and recreating the data dir, keep it and reuse everything we can from it
  --timeout                         timeout in seconds (default: ${TIMEOUT_DURATION} - no timeout)
  --kill-old-processes              if any process is found listening on a port we use, kill it (default: disabled)
  --skip-build                      skip building the binaries (default: disabled)
  --portal-subnetworks              comma separated list of subnetworks to enable (default: ${PORTAL_SUBNETWORKS})
  --disable-state-root-validation   disable state root validation for the state subnetwork (default: disabled)
  --radius                          set the radius to be used by the nodes (default: ${RADIUS})
EOF
}

! PARSED=$(${GETOPT_BINARY} --options=${OPTS} --longoptions=${LONGOPTS} --name "$0" -- "$@")
if [ ${PIPESTATUS[0]} != 0 ]; then
  # getopt has complained about wrong arguments to stdout
  exit 1
fi

# read getopt's output this way to handle the quoting right
eval set -- "$PARSED"
while true; do
  case "$1" in
    -h|--help)
      print_help
      exit
      ;;
    -n|--nodes)
      NUM_NODES="$2"
      shift 2
      ;;
    -d|--data-dir)
      DATA_DIR="$2"
      shift 2
      ;;
    --run-tests)
      RUN_TESTS="1"
      shift
      ;;
    --log-level)
      LOG_LEVEL="$2"
      shift 2
      ;;
    --base-port)
      BASE_PORT="$2"
      shift 2
      ;;
    --base-rpc-port)
      BASE_RPC_PORT="$2"
      shift 2
      ;;
    --trusted-block-root)
      TRUSTED_BLOCK_ROOT="$2"
      shift 2
      ;;
    --portal-bridge)
      PORTAL_BRIDGE="1"
      shift
      ;;
    --base-metrics-port)
      BASE_METRICS_PORT="$2"
      shift 2
      ;;
    --reuse-existing-data-dir)
      REUSE_EXISTING_DATA_DIR="1"
      shift
      ;;
    --timeout)
      TIMEOUT_DURATION="$2"
      shift 2
      ;;
    --kill-old-processes)
      KILL_OLD_PROCESSES="1"
      shift
      ;;
    --skip-build)
      SKIP_BUILD="1"
      shift
      ;;
    --portal-subnetworks)
      PORTAL_SUBNETWORKS="$2"
      shift 2
      ;;
    --disable-state-root-validation)
      DISABLE_STATE_ROOT_VALIDATION="1"
      shift
      ;;
    --radius)
      RADIUS="$2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      echo "argument parsing error"
      print_help
      exit 1
  esac
done

# when sourcing env.sh, it will try to execute $@, so empty it
EXTRA_ARGS="$@"
if [[ $# != 0 ]]; then
  shift $#
fi

if [[ $((NUM_NODES)) -lt 3 ]]; then
  echo "--nodes is less than minimum of 3. Must have at least 3 nodes in order for the network to be stable."
  exit 1
fi

if [[ "$REUSE_EXISTING_DATA_DIR" == "0" ]]; then
  rm -rf "${DATA_DIR}"
fi

"${SCRIPTS_DIR}"/makedir.sh "${DATA_DIR}"

HAVE_LSOF=0

# Windows detection
if uname | grep -qiE "mingw|msys"; then
  MAKE="mingw32-make"
else
  MAKE="make"
  which lsof &>/dev/null && HAVE_LSOF=1 || { echo "'lsof' not installed and we need it to check for ports already in use. Aborting."; exit 1; }
fi

# number of CPU cores
if uname | grep -qi darwin; then
  NPROC="$(sysctl -n hw.logicalcpu)"
else
  NPROC="$(nproc)"
fi

# kill lingering processes from a previous run
if [[ "${HAVE_LSOF}" == "1" ]]; then
  for NUM_NODE in $(seq 0 $(( NUM_NODES - 1 ))); do
    for PORT in $(( BASE_PORT + NUM_NODE )) $(( BASE_METRICS_PORT + NUM_NODE )) $(( BASE_RPC_PORT + NUM_NODE )); do
      for PID in $(lsof -n -i tcp:${PORT} -sTCP:LISTEN -t); do
        echo -n "Found old process listening on port ${PORT}, with PID ${PID}. "
        if [[ "${KILL_OLD_PROCESSES}" == "1" ]]; then
          echo "Killing it."
          kill -9 ${PID} || true
        else
          echo "Aborting."
          exit 1
        fi
      done
    done
  done
fi

BINARIES="fluffy"
if [[ "${PORTAL_BRIDGE}" == "1" ]]; then
  BINARIES="${BINARIES} portal_bridge"
fi

if [[ "${SKIP_BUILD}" == "1" ]]; then
  echo "Skipped build. Using existing binaries if they exist."
else
  # Build the binaries
  $MAKE -j ${NPROC} LOG_LEVEL=TRACE ${BINARIES}

  if [[ "$RUN_TESTS" == "1" ]]; then
    TEST_BINARIES="test_portal_testnet"
    $MAKE -j ${NPROC} LOG_LEVEL=INFO ${TEST_BINARIES}
  fi
fi

# Kill child processes on Ctrl-C/SIGTERM/exit, passing the PID of this shell
# instance as the parent and the target process name as a pattern to the
# "pkill" command.
cleanup() {
  for BINARY in ${BINARIES}; do
    pkill -f -P $$ ${BINARY} &>/dev/null || true
  done
  sleep 2
  for BINARY in ${BINARIES}; do
    pkill -f -9 -P $$ ${BINARY} &>/dev/null || true
  done
}
trap 'cleanup' SIGINT SIGTERM EXIT

# timeout - implemented with a background job
timeout_reached() {
  echo -e "\nTimeout reached. Aborting.\n"
  cleanup
}
trap 'timeout_reached' SIGALRM

# TODO: This doesn't seem to work in Windows CI as it can't find the process
# with WATCHER_PID when doing the taskkill later on.
if [[ "${TIMEOUT_DURATION}" != "0" ]]; then
  export PARENT_PID=$$
  ( sleep ${TIMEOUT_DURATION} && kill -ALRM ${PARENT_PID} ) 2>/dev/null & WATCHER_PID=$!
fi

PIDS=""
NUM_JOBS=$(( NUM_NODES + PORTAL_BRIDGE ))

dump_logs() {
  LOG_LINES=20
  for LOG in "${DATA_DIR}"/log*.txt; do
    echo "Last ${LOG_LINES} lines of ${LOG}:"
    tail -n ${LOG_LINES} "${LOG}"
    echo "======"
  done
}

BOOTSTRAP_NODE=0
BOOTSTRAP_TIMEOUT=5 # in seconds
BOOTSTRAP_ENR_FILE="${DATA_DIR}/node${BOOTSTRAP_NODE}/fluffy_node.enr"

TRUSTED_BLOCK_ROOT_ARG=""
if [[ -n ${TRUSTED_BLOCK_ROOT} ]]; then
  TRUSTED_BLOCK_ROOT_ARG="--trusted-block-root=${TRUSTED_BLOCK_ROOT}"
fi

for NUM_NODE in $(seq 0 $(( NUM_NODES - 1 ))); do
  NODE_DATA_DIR="${DATA_DIR}/node${NUM_NODE}"
  rm -rf "${NODE_DATA_DIR}"
  "${SCRIPTS_DIR}"/makedir.sh "${NODE_DATA_DIR}" 2>&1
done

echo "Starting ${NUM_NODES} nodes."
for NUM_NODE in $(seq 0 $(( NUM_NODES - 1 ))); do
  # Reset arguments
  BOOTSTRAP_ARG=""

  NODE_DATA_DIR="${DATA_DIR}/node${NUM_NODE}"

  RADIUS_ARG="--radius=${RADIUS}"

  if [[ ${NUM_NODE} != ${BOOTSTRAP_NODE} ]]; then
    BOOTSTRAP_ARG="--bootstrap-file=${BOOTSTRAP_ENR_FILE}"

    # Wait for the bootstrap node to write out its enr file
    START_TIMESTAMP=$(date +%s)
    while [[ ! -f "${BOOTSTRAP_ENR_FILE}" ]]; do
      sleep 0.1
      NOW_TIMESTAMP=$(date +%s)
      if [[ "$(( NOW_TIMESTAMP - START_TIMESTAMP - GENESIS_OFFSET ))" -ge "$BOOTSTRAP_TIMEOUT" ]]; then
        echo "Bootstrap node failed to start in ${BOOTSTRAP_TIMEOUT} seconds. Aborting."
        dump_logs
        exit 1
      fi
    done
  fi

  # Running with bits-per-hop of 1 to make the lookups more likely requiring
  # to request to nodes over the network instead of having most of them in the
  # own routing table.
  ./build/fluffy \
    --listen-address:127.0.0.1 \
    --nat:extip:127.0.0.1 \
    --log-level="${LOG_LEVEL}" \
    --udp-port=$(( BASE_PORT + NUM_NODE )) \
    --data-dir="${NODE_DATA_DIR}" \
    --network="none" \
    ${BOOTSTRAP_ARG} \
    --rpc \
    --rpc-address="127.0.0.1" \
    --rpc-port="$(( BASE_RPC_PORT + NUM_NODE ))" \
    --metrics \
    --metrics-address="127.0.0.1" \
    --metrics-port="$(( BASE_METRICS_PORT + NUM_NODE ))" \
    --table-ip-limit=1024 \
    --bucket-ip-limit=24 \
    --bits-per-hop=1 \
    --portal-subnetworks="${PORTAL_SUBNETWORKS}" \
    --disable-state-root-validation="${DISABLE_STATE_ROOT_VALIDATION}" \
    ${TRUSTED_BLOCK_ROOT_ARG} \
    ${RADIUS_ARG} \
    ${EXTRA_ARGS} \
    > "${DATA_DIR}/log${NUM_NODE}.txt" 2>&1 &

  if [[ "${PIDS}" == "" ]]; then
    PIDS="$!"
  else
    PIDS="${PIDS},$!"
  fi
done

if [[ "$PORTAL_BRIDGE" == "1" ]]; then
  # Give the nodes time to connect before the bridge (node 0) starts gossip
  sleep 10
  echo "Starting portal bridge for beacon network."
  ./build/portal_bridge beacon \
    --rest-url="${REST_URL}" \
    --portal-rpc-url="http://127.0.0.1:${BASE_RPC_PORT}"
    --backfill-amount=128 \
    ${TRUSTED_BLOCK_ROOT_ARG} \
    > "${DATA_DIR}/log_portal_bridge.txt" 2>&1 &

  PIDS="${PIDS},$!"
fi

# give the regular nodes time to crash
sleep 5
BG_JOBS="$(jobs | wc -l | tr -d ' ')"
if [[ "${TIMEOUT_DURATION}" != "0" ]]; then
  BG_JOBS=$(( BG_JOBS - 1 )) # minus the timeout bg job
fi
if [[ "$BG_JOBS" != "$NUM_JOBS" ]]; then
  echo "$(( NUM_JOBS - BG_JOBS )) fluffy instance(s) exited early. Aborting."
  dump_logs
  exit 1
fi

# launch htop and run until `TIMEOUT_DURATION` or check the nodes and quit.
if [[ "$RUN_TESTS" == "0" ]]; then
  htop -p "$PIDS"
  cleanup
else
  # Need to let to settle the network a bit, as currently at start discv5 and
  # the Portal networks all send messages at once to the same nodes, causing
  # messages to drop when handshakes are going on.
  sleep 5
  ./build/test_portal_testnet --node-count:${NUM_NODES}
  FAILED=$?
  if [[ "$FAILED" != "0" ]]; then
    dump_logs
    if [[ "${TIMEOUT_DURATION}" != "0" ]]; then
      if uname | grep -qiE "mingw|msys"; then
        echo ${WATCHER_PID}
        taskkill //F //PID ${WATCHER_PID}
      else
        pkill -HUP -P ${WATCHER_PID}
      fi
    fi
    exit 1
  fi
fi

if [[ "${TIMEOUT_DURATION}" != "0" ]]; then
  if uname | grep -qiE "mingw|msys"; then
    taskkill //F //PID ${WATCHER_PID}
  else
    pkill -HUP -P ${WATCHER_PID}
  fi
fi
