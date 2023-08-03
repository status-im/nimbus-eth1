# Nimbus
# Copyright (c) 2018-2019 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## This test has two different parts:
##
## :CI:
##   This was roughly inspired by repeated failings of running nimbus
##   similar to
##   ::
##     nimbus \
##       --data-dir:./kintsugi/tmp \
##       --custom-network:kintsugi-network.json \
##       --bootstrap-file:kintsugi-bootnodes.txt \
##       --prune-mode:full ...
##
##   from `issue 932` <https://github.com/status-im/nimbus-eth1/issues/932>`_.
##
## :TDD (invoked as local executable):
##   Test driven develomment to prepare for The Merge using real data, in
##   particular studying TTD.
##

import
  std/os,
  chronicles,
  results,
  unittest2,
  ../nimbus/core/chain, # must be early (compilation annoyance)
  ../nimbus/config,
  ../nimbus/common/common,
  ./replay/[undump_blocks, pp]

type
  ReplaySession = object
    fancyName: string     # display name
    genesisFile: string   # json file base name
    termTotalDff: UInt256 # terminal total difficulty (to verify)
    mergeFork: uint64     # block number, merge fork (to verify)
    captures: seq[string] # list of gzipped RPL data dumps
    ttdReachedAt: uint64  # block number where total difficulty becomes `true`
    failBlockAt:  uint64  # stop here and expect that block to fail

const
  baseDir = [".", "..", ".."/"..", $DirSep]
  repoDir = [".", "tests"/"replay", "tests"/"customgenesis",
             "nimbus-eth1-blobs"/"replay",
             "nimbus-eth1-blobs"/"custom-network"]

  devnet4 = ReplaySession(
    fancyName:    "Devnet4",
    genesisFile:  "devnet4.json",
    captures:     @["devnetfour5664.txt.gz"],
    termTotalDff: 5_000_000_000.u256,
    mergeFork:    100,
    ttdReachedAt: 5645,
    # Previously failed at `ttdReachedAt` (needed `state.nim` fix/update)
    failBlockAt:  99999999)

  devnet5 = ReplaySession(
    fancyName:    "Devnet5",
    genesisFile:  "devnet5.json",
    captures:     @["devnetfive43968.txt.gz"],
    termTotalDff: 500_000_000_000.u256,
    mergeFork:    1000,
    ttdReachedAt: 43711,
    failBlockAt:  99999999)

  kiln = ReplaySession(
    fancyName:    "Kiln",
    genesisFile:  "kiln.json",
    captures:     @[
      "kiln048000.txt.gz",
      "kiln048001-55296.txt.gz",
      # "kiln055297-109056.txt.gz",
      # "kiln109057-119837.txt.gz",
    ],
    termTotalDff: 20_000_000_000_000.u256,
    mergeFork:    1000,
    ttdReachedAt: 55127,
    failBlockAt:  1000) # Kludge, some change at the `merge` logic?

# Block chains shared between test suites
var
  mcom: CommonRef         # memory DB
  dcom: CommonRef         # perstent DB on disk
  ddbDir: string          # data directory for disk database
  sSpcs: ReplaySession    # current replay session specs

const
  # FIXED: Persistent database crash on `Devnet4` replay if the database
  # directory was acidentally deleted (due to a stray "defer:" directive.)
  ddbCrashBlockNumber = 2105

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

proc findFilePath(file: string): Result[string,void] =
  for dir in baseDir:
    for repo in repoDir:
      let path = dir / repo / file
      if path.fileExists:
        return ok(path)
  err()

proc flushDbDir(s: string) =
  if s != "":
    let dataDir = s / "nimbus"
    if (dataDir / "data").dirExists:
      # Typically under Windows: there might be stale file locks.
      try: dataDir.removeDir except: discard
    block dontClearUnlessEmpty:
      for w in s.walkDir:
        break dontClearUnlessEmpty
      try: s.removeDir except: discard

proc say*(noisy = false; pfx = "***"; args: varargs[string, `$`]) =
  if noisy:
    if args.len == 0:
      echo "*** ", pfx
    elif 0 < pfx.len and pfx[^1] != ' ':
      echo pfx, " ", args.toSeq.join
    else:
      echo pfx, args.toSeq.join

proc setTraceLevel =
  discard
  when defined(chronicles_runtime_filtering) and loggingEnabled:
    setLogLevel(LogLevel.TRACE)

proc setErrorLevel =
  discard
  when defined(chronicles_runtime_filtering) and loggingEnabled:
    setLogLevel(LogLevel.ERROR)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc ddbCleanUp(dir: string) =
  ddbDir = dir
  dir.flushDbDir

proc ddbCleanUp =
  ddbDir.ddbCleanUp

proc isOk(rc: ValidationResult): bool =
  rc == ValidationResult.OK

proc ttdReached(com: CommonRef): bool =
  if com.ttd.isSome:
    return com.ttd.get <= com.db.headTotalDifficulty()

proc importBlocks(c: ChainRef; h: seq[BlockHeader]; b: seq[BlockBody];
                  noisy = false): bool =
  ## On error, the block number of the failng block is returned
  let
    (first, last) = (h[0].blockNumber, h[^1].blockNumber)
    nTxs = b.mapIt(it.transactions.len).foldl(a+b)
    nUnc = b.mapIt(it.uncles.len).foldl(a+b)
    tddOk = c.com.ttdReached
    bRng = if 1 < h.len: &"s [#{first}..#{last}]={h.len}" else: &"   #{first}"
    blurb = &"persistBlocks([#{first}..#"

  catchException("persistBlocks()", trace = true):
    if c.persistBlocks(h, b).isOk:
      noisy.say "***", &"block{bRng} #txs={nTxs} #uncles={nUnc}"
      if not tddOk and c.com.ttdReached:
        noisy.say "***", &"block{bRng} => tddReached"
      return true

  noisy.say "***", &"block{bRng} #txs={nTxs} #uncles={nUnc} -- failed"

# ------------------------------------------------------------------------------
# Test Runner
# ------------------------------------------------------------------------------

proc genesisLoadRunner(noisy = true;
                       captureSession = devnet4;
                       persistPruneTrie = true) =
  sSpcs = captureSession

  let
    gFileInfo = sSpcs.genesisFile.splitFile.name.split(".")[0]
    gFilePath = sSpcs.genesisFile.findFilePath.value

    tmpDir = gFilePath.splitFile.dir / "tmp"

    persistPruneInfo = if persistPruneTrie: "pruning enabled"
                       else:                "no pruning"

  suite &"{sSpcs.fancyName} custom network genesis & database setup":
    var
      params: NetworkParams

    test &"Load params from {gFileInfo}":
      noisy.say "***", "custom-file=", gFilePath
      check gFilePath.loadNetworkParams(params)

    test "Construct in-memory ChainDBRef, pruning enabled":
      mcom = CommonRef.new(
        newCoreDbRef LegacyDbMemory,
        networkId = params.config.chainId.NetworkId,
        params = params)

      check mcom.ttd.get == sSpcs.termTotalDff
      check mcom.toHardFork(sSpcs.mergeFork.toBlockNumber.blockNumberToForkDeterminationInfo) == MergeFork

    test &"Construct persistent ChainDBRef on {tmpDir}, {persistPruneInfo}":
      # Before allocating the database, the data directory needs to be
      # cleared. There might be left overs from a previous crash or
      # because there were file locks under Windows which prevented a
      # previous clean up.
      tmpDir.ddbCleanUp

      # Constructor ...
      dcom = CommonRef.new(
        newCoreDbRef(LegacyDbPersistent, tmpDir),
        networkId = params.config.chainId.NetworkId,
        pruneTrie = persistPruneTrie,
        params = params)

      check dcom.ttd.get == sSpcs.termTotalDff
      check dcom.toHardFork(sSpcs.mergeFork.toBlockNumber.blockNumberToForkDeterminationInfo) == MergeFork

    test "Initialise in-memory Genesis":
      mcom.initializeEmptyDb

      # Verify variant of `toBlockHeader()`. The function `pp()` is used
      # (rather than blockHash()) for readable error report (if any).
      let
        storedhHeaderPP = mcom.db.getBlockHeader(0.u256).pp
        onTheFlyHeaderPP = mcom.genesisHeader.pp
      check storedhHeaderPP == onTheFlyHeaderPP

    test "Initialise persistent Genesis":
      dcom.initializeEmptyDb

      # Must be the same as the in-memory DB value
      check dcom.db.getBlockHash(0.u256) == mcom.db.getBlockHash(0.u256)

      let
        storedhHeaderPP = dcom.db.getBlockHeader(0.u256).pp
        onTheFlyHeaderPP = dcom.genesisHeader.pp
      check storedhHeaderPP == onTheFlyHeaderPP


proc testnetChainRunner(noisy = true;
                        memoryDB = true;
                        stopAfterBlock = 999999999) =
  let
    cFileInfo = sSpcs.captures[0].splitFile.name.split(".")[0]
    cFilePath = sSpcs.captures.mapIt(it.findFilePath.value)
    dbInfo = if memoryDB: "in-memory" else: "persistent"

    pivotBlockNumber = sSpcs.failBlockAt.u256
    lastBlockNumber = stopAfterBlock.u256
    ttdBlockNumber = sSpcs.ttdReachedAt.u256

  suite &"Block chain DB inspector for {sSpcs.fancyName}":
    var
      bcom: CommonRef
      chn: ChainRef
      pivotHeader: BlockHeader
      pivotBody: BlockBody

    test &"Inherit {dbInfo} block chain DB from previous session":
      check not mcom.isNil
      check not dcom.isNil

      # Whatever DB suits, mdb: in-memory, ddb: persistet/on-disk
      bcom = if memoryDB: mcom else: dcom

      chn = bcom.newChain
      noisy.say "***", "ttd",
        " db.config.TTD=", chn.com.ttd
        # " db.arrowGlacierBlock=0x", chn.db.config.arrowGlacierBlock.toHex

    test &"Replay {cFileInfo} capture, may fail ~#{pivotBlockNumber} "&
        &"(slow -- time for coffee break)":
      noisy.say "***", "capture-files=[", cFilePath.join(","), "]"
      discard

    test &"Processing {sSpcs.fancyName} blocks":
      for w in cFilePath.mapIt(it.string).undumpBlocks:
        let (fromBlock, toBlock) = (w[0][0].blockNumber, w[0][^1].blockNumber)

        # Install & verify Genesis
        if w[0][0].blockNumber == 0.u256:
          doAssert w[0][0] == bcom.db.getBlockHeader(0.u256)
          continue

        # Persist blocks, full range before `pivotBlockNumber`
        if toBlock < pivotBlockNumber:
          if not chn.importBlocks(w[0], w[1], noisy):
            # Just a guess -- might be any block in that range
            (pivotHeader, pivotBody) = (w[0][0],w[1][0])
            break
          if chn.com.ttdReached:
            check ttdBlockNumber <= toBlock
          else:
            check toBlock < ttdBlockNumber
          if lastBlockNumber <= toBlock:
            break

        else:
          let top = (pivotBlockNumber - fromBlock).truncate(uint64).int

          # Load the blocks before the pivot block
          if 0 < top:
            check chn.importBlocks(w[0][0 ..< top],w[1][0 ..< top], noisy)

          (pivotHeader, pivotBody) = (w[0][top],w[1][top])
          break

    test &"Processing {sSpcs.fancyName} block #{pivotHeader.blockNumber}, "&
        &"persistBlocks() will fail":

      setTraceLevel()

      if pivotHeader.blockNumber == 0:
        skip()
      else:
        # Expecting that the import fails at the current block ...
        check not chn.importBlocks(@[pivotHeader], @[pivotBody], noisy)

# ------------------------------------------------------------------------------
# Main function(s)
# ------------------------------------------------------------------------------

proc customNetworkMain*(noisy = defined(debug)) =
  defer: ddbCleanUp()
  noisy.genesisLoadRunner

when isMainModule:
  let noisy = defined(debug) or true
  setErrorLevel()

  noisy.showElapsed("customNetwork"):
    defer: ddbCleanUp()

    noisy.genesisLoadRunner(
      # any of: devnet4, devnet5, kiln, etc.
      captureSession = kiln)

    # Note that the `testnetChainRunner()` finds the replay dump files
    # typically on the `nimbus-eth1-blobs` module.
    noisy.testnetChainRunner(
      stopAfterBlock = 999999999)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
