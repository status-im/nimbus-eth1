#!/bin/bash
# used in Travis CI scripts

set -e

ROCKSDBVER="5.17.2"

# script arguments
[[ $# -ne 1 ]] && { echo "usage: $0 ci_cache_dir"; exit 1; }
CI_CACHE="$1" # here we cache the installed files

# install from cache and exit, if the version we want is already there
if [[ -n "$CI_CACHE" ]] && ls "$CI_CACHE"/lib/librocksdb* 2>/dev/null | grep -q "$ROCKSDBVER"; then
	sudo cp -a "$CI_CACHE"/* /usr/local/
	exit 0
fi

# build it
echo "Building RocksDB"
curl -O -L -s -S https://github.com/facebook/rocksdb/archive/v$ROCKSDBVER.tar.gz
tar xzf v$ROCKSDBVER.tar.gz
cd rocksdb-$ROCKSDBVER
make DISABLE_WARNING_AS_ERROR=1 -j2 shared_lib

# install it
if [[ -n "../$CI_CACHE" ]]; then
	rm -rf "../$CI_CACHE"
	mkdir "../$CI_CACHE"
	make INSTALL_PATH="../$CI_CACHE" install-shared
	sudo cp -a "../$CI_CACHE"/* /usr/local/
fi

