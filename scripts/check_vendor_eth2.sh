#!/bin/bash

# Compare versions of pinned submodules

cd "$(dirname "${BASH_SOURCE[0]}")"/..

COMMON=$(ls vendor/ vendor/nimbus-eth2/vendor/ -1 | sort | uniq -d | sed -e "sX^Xvendor/X")

if [[ "$1" == "--update" ]]; then
  for dep in $COMMON; do
    eth2_commit=$(git -C vendor/nimbus-eth2 submodule status "$dep" | awk '{gsub(/[+-]/, "", $1); print $1}')
    if [ -n "$eth2_commit" ]; then
      git -C "$dep" checkout "$eth2_commit"
    fi
  done
else
  for dep in $COMMON; do
    eth1_commit=$(git submodule status "$dep" | awk '{gsub(/[+-]/, "", $1); print $1}')
    eth2_commit=$(git -C vendor/nimbus-eth2 submodule status "$dep" | awk '{gsub(/[+-]/, "", $1); print $1}')
    if [ "$eth1_commit" != "$eth2_commit" ]; then
      eth1_info=$(git -C "$dep" show -s --format="%h %ad %s" --date=short "$eth1_commit")
      eth2_info=$(git -C vendor/nimbus-eth2/"$dep" show -s --format="%h %ad %s" --date=short "$eth2_commit")
      echo "$dep:"
      echo "  eth1: $eth1_info"
      echo "  eth2: $eth2_info"
    fi
  done
fi
