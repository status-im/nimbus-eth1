#!/bin/sh

PWD_CMD="pwd"
# get native Windows paths on Mingw
uname | grep -qi mingw && PWD_CMD="pwd -W"

rel_path="$(dirname $0)"
abs_path="$(cd $rel_path; pwd)"
# do we still need this?
abs_path_native="$(cd $rel_path; ${PWD_CMD})"

export NIMBUS_ENV_DIR="${abs_path}"

# used by libp2p/go-libp2p-daemon
export GOPATH="${abs_path}/vendor/go"
export GO111MODULE=on

#- make it an absolute path, so we can call this script from other dirs
#- we can't use native Windows paths in here, because colons can't be escaped in PATH
export PATH="${abs_path}/vendor/Nim/bin:${GOPATH}/bin:${PATH}"

# Nimble needs this to be an absolute path
export NIMBLE_DIR="${abs_path}/vendor/.nimble"

# used by nim-beacon-chain/tests/simulation/start.sh
export BUILD_OUTPUTS_DIR="${abs_path}/build"

# change the prompt in shells that source this file
export PS1="${PS1%\\\$ } [Nimbus env]\\$ "

exec "$@"

