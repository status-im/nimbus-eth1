#!/bin/bash

# Create a set of states, each advanced by 100k blocks

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

mkdir -p "$DATA_DIR"
[ "$5" ] && cp -ar "$5"/* "$DATA_DIR"

while true;
do
  "$SCRIPT_DIR/../build/nimbus" import \
    --data-dir:"${DATA_DIR}" \
    --era1-dir:"$2" \
    --era-dir:"$3" \
    --debug-csv-stats:"$4/stats-${DATE}-${REV}.csv" \
    --max-blocks:1000000
  cp -ar "$1/${DATE}-${REV}" "$1/${DATE}-${REV}"-$(printf "%04d" $counter)
  counter=$((counter+1))
done
