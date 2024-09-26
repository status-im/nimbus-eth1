# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

import
  std/[bitops, os, strutils],
  pkg/[chronicles, results],
  ../../nimbus/common,
  ../../nimbus/db/[core_db, era1_db]

const
  baseDir = [".", "..", ".."/"..", $DirSep]
  mainDir = [".", "tests"]
  subDir = ["replay", "custom-network"]

  era1BaseName = "mainnet-00000-5ec1ffb8.era1"

type
  PrngDesc = object
    prng: uint32                       ## random state

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc findFilePathHelper(
    file: string;
    baseDir: openArray[string] = baseDir;
    mainDir: openArray[string] = mainDir;
    subDir: openArray[string] = subDir;
      ): Result[string,void] =
  for dir in baseDir:
    if dir.dirExists:
      for main in mainDir:
        if (dir / main).dirExists:
          for sub in subDir:
            if (dir / main / sub).dirExists:
              let path = dir / main / sub / file
              if path.fileExists:
                return ok(path)
  echo "*** File not found \"", file, "\"."
  err()

# -----------------

proc posixPrngRand(state: var uint32): byte =
  ## POSIX.1-2001 example of a rand() implementation, see manual page rand(3).
  state = state * 1103515245 + 12345;
  let val = (state shr 16) and 32767    # mod 2^31
  (val shr 8).byte                      # Extract second byte

proc randU64(state: var uint32): uint64 =
  var a: array[sizeof result,byte]
  for n in 0 ..< a.len:
    a[n] = state.posixPrngRand
  (addr result).copyMem(unsafeAddr a, sizeof a)

proc randU64(state: var uint32; top: uint64): uint64 =
  let mask = (1 shl (64 - top.countLeadingZeroBits)) - 1
  for _ in 0 ..< 100:
    let w =  mask.uint64 and state.randU64
    if w < top:
      return w
  raiseAssert "Not here (!)"

# -----------------

proc lastBlockNumber(e1db: Era1DbRef): BlockNumber =
  var
    minNum = BlockNumber(1)
    maxNum = BlockNumber(4700013) # MainNet
    middle = (maxNum + minNum) div 2
    delta = maxNum - minNum
  while 1 < delta:
    if e1db.getEthBlock(middle).isOk:
      minNum = middle
    else:
      maxNum = middle
    middle = (maxNum + minNum) div 2
    delta = maxNum - minNum
  minNum

# ------------------------------------------------------------------------------
# Public functions
# ------------------------------------------------------------------------------

proc setTraceLevel* =
  discard
  when defined(chronicles_runtime_filtering) and loggingEnabled:
    setLogLevel(LogLevel.TRACE)

proc setDebugLevel* =
  discard
  when defined(chronicles_runtime_filtering) and loggingEnabled:
    setLogLevel(LogLevel.DEBUG)

proc setErrorLevel* =
  discard
  when defined(chronicles_runtime_filtering) and loggingEnabled:
    setLogLevel(LogLevel.ERROR)

# -------------------

proc newEra1DbInstance*(): Era1DbRef =
  let
    repoFile = era1BaseName.findFilePathHelper().expect "valid path"
    repoDir = repoFile.splitFile.dir
    network = era1BaseName.split('-')[0]

  Era1DbRef.init(repoDir, network).expect "valid repo"

proc randomBlockNumbers*(
    e1db: Era1DbRef;
    nInst: int;
    seed: uint32): seq[BlockNumber] =
  let top = e1db.lastBlockNumber.uint64
  var state = seed
  for _ in 0 ..< nInst:
    result.add  state.randU64 top

proc getBlockList*(e1db: Era1DbRef; first, last: BlockNumber): seq[EthBlock] =
  for bn in first .. last:
    result.add e1db.getEthBlock(bn).expect "valid eth block"

# -------------------

proc newCoreDbInstance*(): CoreDbRef =
  AristoDbMemory.newCoreDbRef()

proc newCommonInstance*(): CommonRef =
  const networkId = MainNet
  CommonRef.new(
    db = AristoDbMemory.newCoreDbRef(),
    networkId = networkId,
    params = networkId.networkParams())

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
