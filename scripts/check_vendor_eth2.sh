#!/bin/bash

# Compare versions of pinned submodules

cd "$(dirname "${BASH_SOURCE[0]}")"/..

COMMON=$(ls vendor/ vendor/nimbus-eth2/vendor/ -1 | sort | uniq -d | sed -e "sX^Xvendor/X")

if [[ "$1" == "--update" ]]; then
  for dep in $COMMON; do
    eth1_commit=$(git submodule status "$dep" | awk '{gsub(/[+-]/, "", $1); print $1}')
    eth2_commit=$(git -C vendor/nimbus-eth2 submodule status "$dep" | awk '{gsub(/[+-]/, "", $1); print $1}')
    if [ -n "$eth2_commit" ] && [ "$eth1_commit" != "$eth2_commit" ]; then
      # eth2 commit is an ancestor of the eth1 commit -> eth1 is newer
      if git -C "$dep" merge-base --is-ancestor "$eth2_commit" "$eth1_commit"; then
        if [[ "$2" == "--downgrade" ]]; then
          git -C "$dep" checkout "$eth2_commit"
        else
          echo "skipping $dep: eth1 is ahead of eth2 (use --downgrade to force)"
        fi
      else
        git -C "$dep" checkout "$eth2_commit"
      fi
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
  for dep in $(ls vendor/nimbus-eth2/vendor/ -1); do
    if [ ! -d "vendor/$dep" ]; then
      url=$(git -C vendor/nimbus-eth2 config --file .gitmodules --get "submodule.vendor/$dep.url")
      echo "missing: $dep"
      echo "  git submodule add $url vendor/$dep"
    fi
  done
fi
