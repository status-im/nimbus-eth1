#!/bin/bash

# this one is required
set -e

# script arguments
[[ $# -ne 2 ]] && { echo "usage: $0 nim_dir nim_binary"; exit 1; }
NIM_DIR="$1"
NIM_BINARY="$2"

# compare binary mtime to the date of the last commit
! [[ -e $NIM_BINARY && $(stat -c%Y $NIM_BINARY) -gt $(cd "$NIM_DIR"; git log --pretty=format:%cd -n 1 --date=unix) ]]

