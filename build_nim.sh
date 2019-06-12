#!/bin/bash

set -e

# Git commits
CSOURCES_COMMIT="b56e49bbedf62db22eb26388f98262e2948b2cbc" # 0.19.0
NIMBLE_COMMIT="c8d79fc0228682677330a9f57d14389aaa641153" # Mar 26 10:06:06 2019

# script arguments
[[ $# -ne 4 ]] && { echo "usage: $0 nim_dir csources_dir nimble_dir ci_cache_dir"; exit 1; }
NIM_DIR="$1"
CSOURCES_DIR="$2"
NIMBLE_DIR="$3"
CI_CACHE="$4"

## env vars
# verbosity level
[[ -z "$V" ]] && V=0
[[ -z "$CC" ]] && CC="gcc"
# to build csources in parallel, set MAKE="make -jN"
[[ -z "$MAKE" ]] && MAKE="make"
# for 32-bit binaries on a 64-bit Windows host
UCPU=""
[[ "$ARCH_OVERRIDE" == "x86" ]] && UCPU="ucpu=i686"
[[ -z "$NIM_BUILD_MSG" ]] && NIM_BUILD_MSG="Building the Nim compiler"

# Windows detection
if uname | grep -qi mingw; then
	ON_WINDOWS=1
	EXE_SUFFIX=".exe"
else
	ON_WINDOWS=0
	EXE_SUFFIX=""
fi

NIM_BINARY="${NIM_DIR}/bin/nim${EXE_SUFFIX}"

nim_needs_rebuilding() {
	REBUILD=0
	NO_REBUILD=1

	if [[ ! -e "$NIM_DIR" ]]; then
		git clone --depth=1 https://github.com/status-im/Nim.git "$NIM_DIR"
	fi

	if [[ -n "$CI_CACHE" && -d "$CI_CACHE" ]]; then
		cp -a "$CI_CACHE"/* "$NIM_DIR"/bin/ || true # let this one fail with an empty cache dir
	fi

	# compare binary mtime to the date of the last commit (keep in mind that Git doesn't preserve file timestamps)
	if [[ -e "$NIM_BINARY" && $(stat -c%Y "$NIM_BINARY") -gt $(cd "$NIM_DIR"; git log --pretty=format:%cd -n 1 --date=unix) ]]; then
		return $NO_REBUILD
	else
		return $REBUILD
	fi
}

build_nim() {
	echo -e "$NIM_BUILD_MSG"
	[[ "$V" == "0" ]] && exec &>/dev/null

	# working directory
	pushd "$NIM_DIR"

	# Git repos for csources and Nimble
	if [[ ! -d "$CSOURCES_DIR" ]]; then
		mkdir -p "$CSOURCES_DIR"
		pushd "$CSOURCES_DIR"
		git clone https://github.com/nim-lang/csources.git .
		git checkout $CSOURCES_COMMIT
		popd
	fi
	if [[ "$CSOURCES_DIR" != "csources" ]]; then
		rm -rf csources
		ln -s "$CSOURCES_DIR" csources
	fi

	if [[ ! -d "$NIMBLE_DIR" ]]; then
		mkdir -p "$NIMBLE_DIR"
		pushd "$NIMBLE_DIR"
		git clone https://github.com/nim-lang/nimble.git .
		git checkout $NIMBLE_COMMIT
		# we have to delete .git or koch.nim will checkout a branch tip, overriding our target commit
		rm -rf .git
		popd
	fi
	if [[ "$NIMBLE_DIR" != "dist/nimble" ]]; then
		mkdir -p dist
		rm -rf dist/nimble
		ln -s ../"$NIMBLE_DIR" dist/nimble
	fi

	# bootstrap the Nim compiler and build the tools
	rm -rf bin/nim_csources
	pushd csources
	if [[ "$ON_WINDOWS" == "0" ]]; then
		$MAKE clean
		$MAKE LD=$CC
	else
		$MAKE myos=windows $UCPU clean
		$MAKE myos=windows $UCPU CC=gcc LD=gcc
	fi
	popd
	if [[ -e csources/bin ]]; then
		cp -a csources/bin/nim bin/nim
		cp -a csources/bin/nim bin/nim_csources
		rm -rf csources/bin
	else
		cp -a bin/nim bin/nim_csources
	fi
	sed 's/koch tools/koch --stable tools/' build_all.sh > build_all_custom.sh
	sh build_all_custom.sh
	rm build_all_custom.sh

	# update the CI cache
	popd # we were in $NIM_DIR
	if [[ -n "$CI_CACHE" ]]; then
		rm -rf "$CI_CACHE"
		mkdir "$CI_CACHE"
		cp -a "$NIM_DIR"/bin/* "$CI_CACHE"/
	fi
}

if nim_needs_rebuilding; then
	build_nim
fi

