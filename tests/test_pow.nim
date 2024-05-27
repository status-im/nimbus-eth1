# Nimbus
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[os, sequtils, strformat, strutils, times],
  ./replay/[pp, gunzip],
  ../nimbus/core/[pow, pow/pow_cache],
  eth/common,
  stew/endians2,
  unittest2

const
  baseDir = [".", "tests", ".." / "tests", $DirSep] # path containg repo
  repoDir = ["replay"]                              # alternative repos

  specsDump = "mainspecs2k.txt.gz"

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

proc say*(noisy = false; pfx = "***"; args: varargs[string, `$`]) =
  if noisy:
    if args.len == 0:
      echo "*** ", pfx
    elif 0 < pfx.len and pfx[^1] != ' ':
      echo pfx, " ", args.toSeq.join
    else:
      echo pfx, args.toSeq.join

proc findFilePath(file: string): string =
  result = "?unknown?" / file
  for dir in baseDir:
    for repo in repoDir:
      let path = dir / repo / file
      if path.fileExists:
        return path

# ------------------------------------------------------------------------------
# Test Runners
# ------------------------------------------------------------------------------

proc runPowTests(noisy = true; file = specsDump;
                 nVerify = int.high; nFakeMiner = 0, nRealMiner = 0) =
  let
    filePath = file.findFilePath
    fileInfo = file.splitFile.name.split(".")[0]

    powCache = PowCacheRef.new # so we can inspect the LRU caches
    pow = PowRef.new(powCache)

  var specsList: seq[PowSpecs]

  suite &"PoW: Header test specs from {fileInfo} capture":
    block:
      test "Loading from capture":
        for (lno,line) in gunzipLines(filePath):
          let specs = line.undumpPowSpecs
          if 0 < specs.blockNumber:
            specsList.add specs
            check line == specs.dumpPowSpecs
        noisy.say "***", " block range #",
          specsList[0].blockNumber, " .. #", specsList[^1].blockNumber

    # Adjust number of tests
    let
      startVerify = max(0, specsList.len - nVerify)
      nDoVerify = specsList.len - startVerify

    block:
      test &"Running single getPowDigest() to fill the cache":
        if nVerify <= 0:
          skip()
        else:
          noisy.showElapsed(&"first getPowDigest() instance"):
            let p = specsList[startVerify]
            check pow.getPowDigest(p).mixDigest == p.mixDigest

      test &"Running getPowDigest() on {nDoVerify} specs records":
        if nVerify <= 0:
          skip()
        else:
          noisy.showElapsed(&"all {nDoVerify} getPowDigest() instances"):
            for n in startVerify ..< specsList.len:
              let p = specsList[n]
              check pow.getPowDigest(p).mixDigest == p.mixDigest

# ------------------------------------------------------------------------------
# Main function(s)
# ------------------------------------------------------------------------------

proc powMain*(noisy = defined(debug)) =
  noisy.runPowTests(nVerify = 100)

when isMainModule:
  # Note:
  #   0 < nFakeMiner: allow ~20 minuntes for building lookup table
  #   0 < nRealMiner: takes days/months/years ...
  true.runPowTests(nVerify = 200, nFakeMiner = 200, nRealMiner = 5)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
