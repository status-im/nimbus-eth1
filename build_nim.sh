#!/bin/bash

set -e

# Git commits
CSOURCES_COMMIT="b56e49bbedf62db22eb26388f98262e2948b2cbc" # 0.19.0
NIMBLE_COMMIT="c8d79fc0228682677330a9f57d14389aaa641153" # Mar 26 10:06:06 2019

# script arguments
[[ $# -ne 3 ]] && { echo "usage: $0 nim_dir csources_dir nimble_dir"; exit 1; }
NIM_DIR="$1"
CSOURCES_DIR="$2"
NIMBLE_DIR="$3"

## env vars
# verbosity level
[[ -z "$V" ]] && V=0
[[ "$V" == "0" ]] && exec &>/dev/null
[[ -z "$CC" ]] && CC="gcc"
# to build csources in parallel, set MAKE="make -jN"
[[ -z "$MAKE" ]] && MAKE="make"
# for 32-bit binaries on a 64-bit Windows host
UCPU=""
[[ "$ARCH_OVERRIDE" == "x86" ]] && UCPU="ucpu=i686"

# Windows detection
ON_WINDOWS=0
uname | grep -qi mingw && ON_WINDOWS=1

# working directory
cd "$NIM_DIR"

# Git repos for csources and Nimble
[[ -d "$CSOURCES_DIR" ]] || { \
	mkdir -p "$CSOURCES_DIR" && \
	cd "$CSOURCES_DIR" && \
	git clone https://github.com/nim-lang/csources.git . && \
	git checkout $CSOURCES_COMMIT && \
	cd - >/dev/null; \
}
[[ "$CSOURCES_DIR" != "csources" ]] && \
rm -rf csources && \
ln -s "$CSOURCES_DIR" csources

# we have to delete .git or koch.nim will checkout a branch tip
[[ -d "$NIMBLE_DIR" ]] || { \
	mkdir -p "$NIMBLE_DIR" && \
	cd "$NIMBLE_DIR" && \
	git clone https://github.com/nim-lang/nimble.git . && \
	git checkout $NIMBLE_COMMIT && \
	rm -rf .git && \
	cd - >/dev/null; \
}
[[ "$NIMBLE_DIR" != "dist/nimble" ]] && \
mkdir -p dist && \
rm -rf dist/nimble && \
ln -s ../"$NIMBLE_DIR" dist/nimble

# bootstrap the Nim compiler and build the tools
rm -rf bin/nim_csources && \
cd csources && { \
	[[ "$ON_WINDOWS" == "0" ]] && { \
		$MAKE clean && \
		$MAKE LD=$CC; \
	} || { \
		$MAKE myos=windows $UCPU clean && \
		$MAKE myos=windows $UCPU CC=gcc LD=gcc; \
	}; \
} && \
cd - >/dev/null && { \
	[ -e csources/bin ] && { \
		cp -a csources/bin/nim bin/nim && \
		cp -a csources/bin/nim bin/nim_csources && \
		rm -rf csources/bin; \
	} || { \
		cp -a bin/nim bin/nim_csources; \
	}; \
} && { \
	sed 's/koch tools/koch --stable tools/' build_all.sh > build_all_custom.sh; \
	sh build_all_custom.sh; \
	rm build_all_custom.sh; \
}

