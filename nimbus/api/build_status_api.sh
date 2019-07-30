#!/bin/sh

echo "[Cleaning up caches...]"
rm -rf nimcache/
rm -f libnimbus_api.so

# ../env.sh nim c  --opt:speed --lineTrace:off --verbosity:2 status_api
# gcc status_api.c ./libnimbus_api.so -lm -o xx

# debug info
../../env.sh nim c --debuginfo --opt:speed --lineTrace:off --verbosity:2 status_api
gcc status_api.c ./libnimbus_api.so -lm -g -o status_api_test
