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
  std/[os, sequtils, strformat, times],
  chronicles,
  eth/common,
  results,
  unittest2,
  ../../nimbus/core/chain,
  ../../nimbus/db/ledger,
  ../replay/[pp, undump_blocks, xcheck],
  ./test_helpers

type
  StopMoaningAboutLedger {.used.} = LedgerType

when CoreDbEnableApiProfiling:
  import
    std/sequtils,
    ../../nimbus/db/aristo/[aristo_api, aristo_profile],
    ../../nimbus/db/kvt/kvt_api
  var
    aristoProfData: AristoDbProfListRef
    kvtProfData: KvtDbProfListRef
    cdbProfData: CoreDbProfListRef

when LedgerEnableApiProfiling:
  when not CoreDbEnableApiProfiling:
    import
      std/sequtils
  var
    ldgProfData: LedgerProfListRef

const
  EnableExtraLoggingControl = true
var
  logStartTime {.used.} = Time()
  logSavedEnv {.used.}: (bool,bool,bool,bool)

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

proc setTraceLevel {.used.} =
  when defined(chronicles_runtime_filtering) and loggingEnabled:
    setLogLevel(LogLevel.TRACE)

proc setDebugLevel {.used.} =
  when defined(chronicles_runtime_filtering) and loggingEnabled:
    setLogLevel(LogLevel.DEBUG)

proc setErrorLevel {.used.} =
  when defined(chronicles_runtime_filtering) and loggingEnabled:
    setLogLevel(LogLevel.ERROR)

# --------------

template initLogging(noisy: bool, com: CommonRef) =
  when EnableExtraLoggingControl:
    if noisy:
      setDebugLevel()
      debug "start undumping into persistent blocks"
    logStartTime = Time()
    logSavedEnv = (com.db.trackLegaApi, com.db.trackNewApi,
                   com.db.trackLedgerApi, com.db.localDbOnly)
    setErrorLevel()
    com.db.trackLegaApi = true
    com.db.trackNewApi = true
    com.db.trackLedgerApi = true
    com.db.localDbOnly = true

proc finishLogging(com: CommonRef) =
  when EnableExtraLoggingControl:
    setErrorLevel()
    (com.db.trackLegaApi, com.db.trackNewApi,
     com.db.trackLedgerApi, com.db.localDbOnly) = logSavedEnv


template startLogging(noisy: bool; num: BlockNumber) =
  when EnableExtraLoggingControl:
    if noisy and logStartTime == Time():
      logStartTime = getTime()
      setDebugLevel()
      debug "start logging ...", blockNumber=num

when false:
  template startLogging(noisy: bool) =
    when EnableExtraLoggingControl:
      if noisy and logStartTime == Time():
        logStartTime = getTime()
        setDebugLevel()
        debug "start logging ..."

template stopLogging(noisy: bool) =
  when EnableExtraLoggingControl:
    if logStartTime != Time():
      debug "stop logging", elapsed=(getTime() - logStartTime).pp
      logStartTime = Time()
    setErrorLevel()

template stopLoggingAfter(noisy: bool; code: untyped) =
  ## Turn logging off after executing `block`
  block:
    defer: noisy.stopLogging()
    code

# ------------------------------------------------------------------------------
# Public test function
# ------------------------------------------------------------------------------

proc test_chainSyncProfilingPrint*(
    noisy = false;
    nBlocks: int;
    indent = 2;
      ) =
  if noisy:
    let info =
      if 0 < nBlocks and nBlocks < high(int): " (" & $nBlocks & " blocks)"
      else: ""
    discard info
    var blurb: seq[string]
    when LedgerEnableApiProfiling:
      blurb.add ldgProfData.profilingPrinter(
        names = LedgerFnInx.toSeq.mapIt($it),
        header = "Ledger profiling results" & info,
        indent)
    when CoreDbEnableApiProfiling:
      blurb.add cdbProfData.profilingPrinter(
        names = CoreDbFnInx.toSeq.mapIt($it),
        header = "CoreDb profiling results" & info,
        indent)
      blurb.add aristoProfData.profilingPrinter(
        names = AristoApiProfNames.toSeq.mapIt($it),
        header = "Aristo backend profiling results" & info,
        indent)
      blurb.add kvtProfData.profilingPrinter(
        names = KvtApiProfNames.toSeq.mapIt($it),
        header = "Kvt backend profiling results" & info,
        indent)
    for s in blurb:
      if 0 < s.len: true.say "***", s, "\n"

proc test_chainSync*(
    noisy: bool;
    filePaths: seq[string];
    com: CommonRef;
    numBlocks = high(int);
    enaLogging = true;
    lastOneExtra = true
      ): bool =
  ## Store persistent blocks from dump into chain DB
  let
    sayBlocks = 900
    chain = com.newChain
    lastBlock = max(1, numBlocks).toBlockNumber

  noisy.initLogging com
  defer: com.finishLogging()

  # Profile variables will be non-nil if profiling is available. The profiling
  # API data need to be captured so it will be available after the services
  # have terminated.
  when CoreDbEnableApiProfiling:
    # terminated.
    (aristoProfData, kvtProfData) = com.db.toAristoProfData()
    cdbProfData = com.db.dbProfData()
  when LedgerEnableApiProfiling:
    ldgProfData = com.db.ldgProfData()

  # Scan folder for `era1` files (ignoring the argument file name)
  let
    (dir, _, ext) = filePaths[0].splitFile
    files =
      if filePaths.len == 1 and ext == ".era1":
        (dir / "*" & ext).walkPattern.toSeq
      else:
        filePaths

  for w in files.undumpBlocks:
    let (fromBlock, toBlock) = (w[0][0].blockNumber, w[0][^1].blockNumber)
    if fromBlock == 0.u256:
      xCheck w[0][0] == com.db.getBlockHeader(0.u256)
      continue

    # Process groups of blocks ...
    if toBlock < lastBlock:
      # Message if `[fromBlock,toBlock]` contains a multiple of `sayBlocks`
      if fromBlock + (toBlock mod sayBlocks.u256) <= toBlock:
        noisy.say "***", &"processing ...[#{fromBlock},#{toBlock}]..."
        if enaLogging:
          noisy.startLogging(w[0][0].blockNumber)
      noisy.stopLoggingAfter():
        let runPersistBlocksRc = chain.persistBlocks(w[0], w[1])
        xCheck runPersistBlocksRc == ValidationResult.OK:
          if noisy:
            # Re-run with logging enabled
            setTraceLevel()
            com.db.trackLegaApi = false
            com.db.trackNewApi = false
            com.db.trackLedgerApi = false
            discard chain.persistBlocks(w[0], w[1])
      continue

    # Last group or single block
    #
    # Make sure that the `lastBlock` is the first item of the argument batch.
    # So It might be necessary to Split off all blocks smaller than `lastBlock`
    # and execute them first. Then the next batch starts with the `lastBlock`.
    let
      pivot = (lastBlock - fromBlock).truncate(uint)
      headers9 = w[0][pivot .. ^1]
      bodies9 = w[1][pivot .. ^1]
    doAssert lastBlock == headers9[0].blockNumber

    # Process leading betch before `lastBlock` (if any)
    var dotsOrSpace = "..."
    if fromBlock < lastBlock:
      let
        headers1 = w[0][0 ..< pivot]
        bodies1 = w[1][0 ..< pivot]
      noisy.say "***", &"processing {dotsOrSpace}[#{fromBlock},#{lastBlock-1}]"
      let runPersistBlocks1Rc = chain.persistBlocks(headers1, bodies1)
      xCheck runPersistBlocks1Rc == ValidationResult.OK
      dotsOrSpace = "   "

    noisy.startLogging(headers9[0].blockNumber)
    if lastOneExtra:
      let
        headers0 = headers9[0..0]
        bodies0 = bodies9[0..0]
      noisy.say "***", &"processing {dotsOrSpace}[#{lastBlock},#{lastBlock}]"
      noisy.stopLoggingAfter():
        let runPersistBlocks0Rc = chain.persistBlocks(headers0, bodies0)
        xCheck runPersistBlocks0Rc == ValidationResult.OK
    else:
      noisy.say "***", &"processing {dotsOrSpace}[#{lastBlock},#{toBlock}]"
      noisy.stopLoggingAfter():
        let runPersistBlocks9Rc = chain.persistBlocks(headers9, bodies9)
        xCheck runPersistBlocks9Rc == ValidationResult.OK
    break

  true

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
