#!/bin/bash

# Create a set of states, each advanced by 1M blocks

set -e

trap "exit" INT

if [ -z "$4" ]
  then
    echo "Syntax: make_states.sh datadir era1dir eradir statsdir [startdir]"
    echo "        make_states.sh --ere datadir eredir statsdir [startdir]"
    exit 1;
fi

counter=0

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
DATE="$(date -u +%Y%m%d_%H%M)"
REV=$(git rev-parse --short=8 HEAD)

if [ "$1" == "--ere" ]; then
  DATA_DIR="$2/${DATE}-${REV}"
  HISTORY_ARGS=(--ere-dir:"$3")
else
  DATA_DIR="$1/${DATE}-${REV}"
  HISTORY_ARGS=(--era1-dir:"$2" --era-dir:"$3")
fi
STATS_DIR="$4"

shift 4

mkdir -p "$DATA_DIR"
[ -d "$1" ] && { cp -ar "$1"/* "$DATA_DIR" ; shift ; }

while true;
do
  SECONDS=0
  "$SCRIPT_DIR/../build/nimbus" import \
    --data-dir:"${DATA_DIR}" \
    "${HISTORY_ARGS[@]}" \
    --debug-csv-stats:"${STATS_DIR}/stats-${DATE}-${REV}.csv" \
    --max-blocks:${MAX_BLOCKS:-1000000} "$@"
  cp -ar "${DATA_DIR}" "${DATA_DIR}-$(printf "%04d" $counter)"
  counter=$((counter+1))

  if (( $SECONDS < 10 )); then
    echo "Done"
    exit 0
  fi
done
