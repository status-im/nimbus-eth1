#!/bin/sh

#echo "[Cleaning up caches...]"
#rm -rf nimcache/
#rm libnimbus_api.a

../env.sh nim c --opt:speed --lineTrace:off --verbosity:2 status_api

gcc status_api.c ./libnimbus_api.so -lm -o xx

./xx

