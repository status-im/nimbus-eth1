#!/bin/sh

rel_path="$(dirname $0)"
abs_path="$(cd $rel_path; pwd)"

# used by libp2p/go-libp2p-daemon
export GOPATH="${abs_path}/vendor/go"

# make it an absolute path, so we can call this script from other dirs
export PATH="${abs_path}/vendor/Nim/bin:${GOPATH}/bin:${PATH}"

# Nimble needs this to be an absolute path
export NIMBLE_DIR="${abs_path}/vendor/.nimble"

# used by nim-beacon-chain/tests/simulation/start.sh
export BUILD_OUTPUTS_DIR="${abs_path}/build"

exec "$@"

