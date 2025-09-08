#!/bin/bash

# Compare versions of pinned submodules

cd "$(dirname "${BASH_SOURCE[0]}")"/..

COMMON=$(ls vendor/ vendor/nimbus-eth2/vendor/ -1 | sort | uniq -d | sed -e "sX^Xvendor/X")

diff -u <(git submodule status $COMMON) <(git -C vendor/nimbus-eth2 submodule status $COMMON)
