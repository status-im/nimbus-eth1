#!/usr/bin/env bash

# Copyright (c) 2021 Status Research & Development GmbH. Licensed under
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
  GETOPT_BINARY="/usr/local/opt/gnu-getopt/bin/getopt"
  [[ -f "$GETOPT_BINARY" ]] || { echo "GNU getopt not installed. Please run 'brew install gnu-getopt'. Aborting."; exit 1; }
fi

! ${GETOPT_BINARY} --test > /dev/null
if [ ${PIPESTATUS[0]} != 4 ]; then
  echo '`getopt --test` failed in this environment.'
  exit 1
fi

OPTS="h:n:d"
LONGOPTS="help,nodes:,data-dir:,enable-htop,log-level:,base-port:,base-rpc-port:,base-metrics-port:,reuse-existing-data-dir,timeout:,kill-old-processes"

# default values
NUM_NODES="17"
DATA_DIR="local_testnet_data"
USE_HTOP="0"
LOG_LEVEL="TRACE"
BASE_PORT="9000"
BASE_METRICS_PORT="8008"
BASE_RPC_PORT="7000"
REUSE_EXISTING_DATA_DIR="0"
TIMEOUT_DURATION="0"
KILL_OLD_PROCESSES="0"
SCRIPTS_DIR="fluffy/scripts/"

print_help() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS] -- [FLUFFY OPTIONS]
E.g.: $(basename "$0") --nodes ${NUM_NODES} --data-dir "${DATA_DIR}" # defaults

  -h, --help                  this help message
  -n, --nodes                 number of nodes to launch (default: ${NUM_NODES})
  -d, --data-dir              directory where all the node data and logs will end up
                              (default: "${DATA_DIR}")
  --base-port                 bootstrap node's discv5 port (default: ${BASE_PORT})
  --base-rpc-port             bootstrap node's RPC port (default: ${BASE_RPC_PORT})
  --base-metrics-port         bootstrap node's metrics server port (default: ${BASE_METRICS_PORT})
  --enable-htop               use "htop" to see the fluffy processes without doing any tests
  --log-level                 set the log level (default: ${LOG_LEVEL})
  --reuse-existing-data-dir   instead of deleting and recreating the data dir, keep it and reuse everything we can from it
  --timeout                   timeout in seconds (default: ${TIMEOUT_DURATION} - no timeout)
  --kill-old-processes        if any process is found listening on a port we use, kill it (default: disabled)
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
    --enable-htop)
      USE_HTOP="1"
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

# Build the binaries
BINARIES="fluffy"
$MAKE -j ${NPROC} LOG_LEVEL=TRACE ${BINARIES} NIMFLAGS="-d:chronicles_colors=off -d:chronicles_sinks=textlines" #V=2

# Kill child processes on Ctrl-C/SIGTERM/exit, passing the PID of this shell
# instance as the parent and the target process name as a pattern to the
# "pkill" command.
cleanup() {
  pkill -f -P $$ fluffy &>/dev/null || true
  sleep 2
  pkill -f -9 -P $$ fluffy &>/dev/null || true

  # Delete the binaries we just built, because these are with none default logs.
  # TODO: When fluffy gets run time log options a la nimbus-eth2 we can keep
  # the binaries around.
  for BINARY in ${BINARIES}; do
    rm build/${BINARY}
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
NUM_JOBS=${NUM_NODES}

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

for NUM_NODE in $(seq 0 $(( NUM_NODES - 1 ))); do
  NODE_DATA_DIR="${DATA_DIR}/node${NUM_NODE}"
  rm -rf "${NODE_DATA_DIR}"
  "${SCRIPTS_DIR}"/makedir.sh "${NODE_DATA_DIR}" 2>&1
done

echo "Starting ${NUM_NODES} nodes."
for NUM_NODE in $(seq 0 $(( NUM_NODES - 1 ))); do
  NODE_DATA_DIR="${DATA_DIR}/node${NUM_NODE}"

  if [[ ${NUM_NODE} != ${BOOTSTRAP_NODE} ]]; then
    BOOTSTRAP_ARG="--bootstrap-file=${BOOTSTRAP_ENR_FILE} --portal-bootstrap-file=${BOOTSTRAP_ENR_FILE}"

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

  # Increasing the loopback address here with NUM_NODE as listen address to
  # avoid hitting the IP limits in the routing tables.
  # TODO: This simple increase will limit the amount of max nodes to 255.
  # Could also fix this by having a compiler flag that starts the routing tables
  # in fluffy with a very high limit or simply an adjustment in the routing
  # table code that disable the checks on loopback address.

  # macOS doesn't have these default
  if uname | grep -qi darwin; then
    sudo ifconfig lo0 alias 127.0.0.$((1 + NUM_NODE))
  fi
  ./build/fluffy \
    --listen-address:127.0.0.$((1 + NUM_NODE)) \
    --nat:extip:127.0.0.$((1 + NUM_NODE)) \
    --log-level="${LOG_LEVEL}" \
    --udp-port=$(( BASE_PORT + NUM_NODE )) \
    --data-dir="${NODE_DATA_DIR}" \
    ${BOOTSTRAP_ARG} \
    --rpc \
    --rpc-address="127.0.0.1" \
    --rpc-port="$(( BASE_RPC_PORT + NUM_NODE ))" \
    --metrics \
    --metrics-address="127.0.0.1" \
    --metrics-port="$(( BASE_METRICS_PORT + NUM_NODE ))" \
    ${EXTRA_ARGS} \
    > "${DATA_DIR}/log${NUM_NODE}.txt" 2>&1 &

  if [[ "${PIDS}" == "" ]]; then
    PIDS="$!"
  else
    PIDS="${PIDS},$!"
  fi
done

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

# TODO: Move this to a separate script or create nim process that is rpc client
# once things get more complicated
check_nodes() {
  echo "Checking routing table of all nodes."
  for NUM_NODE in $(seq 0 $(( NUM_NODES - 1 ))); do
    if [[ ${NUM_NODE} == ${BOOTSTRAP_NODE} ]]; then
      RPC_PORT="$(( BASE_RPC_PORT + NUM_NODE ))"
      ROUTING_TABLE_NODES=$(curl -s -X POST -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":"id","method":"discv5_routingTableInfo","params":[]}' http://localhost:${RPC_PORT} | jq '.result.buckets' | jq 'flatten' | jq '. | length')
      if [[ $ROUTING_TABLE_NODES != $(( NUM_NODES - 1 )) ]]; then
        echo "Check for node ${NUM_NODE} failed."
        return 1
      fi
    else
      curl -s -X POST -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":"id","method":"discv5_recursiveFindNodes","params":[]}' http://localhost:${RPC_PORT} &>/dev/null
      ROUTING_TABLE_NODES=$(curl -s -X POST -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":"id","method":"discv5_routingTableInfo","params":[]}' http://localhost:${RPC_PORT} | jq '.result.buckets' | jq 'flatten' | jq '. | length')
      if [[ $ROUTING_TABLE_NODES != $(( NUM_NODES - 1 )) ]]; then
        echo "Check for node ${NUM_NODE} failed."
        return 1
      fi
    fi
  done
}

# launch htop and run until `TIMEOUT_DURATION` or check the nodes and quit.
if [[ "$USE_HTOP" == "1" ]]; then
  htop -p "$PIDS"
  cleanup
else
  check_nodes
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
