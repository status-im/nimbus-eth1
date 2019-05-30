#!/bin/sh

../env.sh nim c status_api
gcc status_api.c nimbus_api.lib -lm -o xx

./xx

