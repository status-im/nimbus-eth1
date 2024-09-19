#!/bin/bash

# Create a set of states, each advanced by 1M blocks

set -e

trap "exit" INT

if [ -z "$4" ]
  then
    echo "Syntax: make_states.sh datadir era1dir eradir statsdir [startdir]"
    exit 1;
fi

counter=0

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
DATE="$(date -u +%Y%m%d_%H%M)"
REV=$(git rev-parse --short=8 HEAD)
DATA_DIR="$1/${DATE}-${REV}"
ERA_DIR="$2"
ERA1_DIR="$3"
STATS_DIR="$4"

shift 4

mkdir -p "$DATA_DIR"
[ -d "$1" ] && { cp -ar "$1"/* "$DATA_DIR" ; shift ; }

while true;
do
  "$SCRIPT_DIR/../build/nimbus" import \
    --data-dir:"${DATA_DIR}" \
    --era1-dir:"${ERA_DIR}" \
    --era-dir:"${ERA1_DIR}" \
    --debug-csv-stats:"${STATS_DIR}/stats-${DATE}-${REV}.csv" \
    --max-blocks:1000000 "$@"
  cp -ar "${DATA_DIR}" "${DATA_DIR}-$(printf "%04d" $counter)"
  counter=$((counter+1))
done
