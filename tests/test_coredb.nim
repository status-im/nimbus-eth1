# Nimbus
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

## Testing `CoreDB` wrapper implementation

import
  std/[os, strformat, strutils],
  chronicles,
  eth/common,
  results,
  unittest2,
  ../execution_chain/db/opts,
  ../execution_chain/db/core_db/persistent,
  ../execution_chain/core/chain,
  ./replay/pp,
  ./test_coredb/[
    coredb_test_xx, test_chainsync, test_helpers]

const
  # If `true`, this compile time option set up `unittest2` for manual parsing
  unittest2DisableParamFiltering {.booldefine.} = false

  baseDir = [".", "..", ".."/"..", $DirSep]
  repoDir = [".", "tests"]
  subDir = ["replay", "test_coredb", "custom-network", "main-era1"]

  # Reference file for finding some database directory base
  sampleDirRefFile = "coredb_test_xx.nim"

  dbTypeDefault = AristoDbMemory

let
  # Standard test sample
  memorySampleDefault = mainTest0m
  persistentSampleDefault = mainTest2r

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

when unittest2DisableParamFiltering:
  import algorithm

  # Filter out local options and pass on the rest to `unittest2`
  proc cmdLineConfig(): tuple[samples: seq[CaptureSpecs]] {.used.} =
    ## This helper allows to pass additional command line options to the
    ## unit test.
    ##
    ## Example:
    ## ::
    ##   nim c -r ...\
    ##    -d:unittest2DisableParamFiltering \
    ##    ./tests/test_coredb.nim \
    ##       --output-level=VERBOSE \
    ##       --sample=main-am,main-ar
    ## or
    ## ::
    ##   nim c ... -d:unittest2DisableParamFiltering ./tests/test_coredb.nim
    ##   ./tests/test_coredb.out --output-level=VERBOSE --sample=goerli-ar
    ##   ...
    ##
    ## At the moment, only the `--sample=` additional option is provided.
    ##
    # Define sample list from the command line (if any)
    const optPfx =  "--sample=" # Custom option with sample list

    proc parseError(s = "") =
      let msg = if 0 < s.len: "Unsupported \"" & optPfx & "\" list item: " & s
                else: "Empty \"" & optPfx & " list"
      echo "*** ", getAppFilename().splitFile.name, ": ", msg
      echo "    Available: ", allSamples.mapIt(it.name).sorted.join(" ")
      quit(99)

    var other: seq[string] # Options for manual parsing by `unittest2`

    for arg in commandLineParams():
      if optPfx.len <= arg.len and arg[0 ..< optPfx.len] == optPfx:
        for w in arg[optPfx.len ..< arg.len].split(",").mapIt(it.strip):
          block findSample:
            for sample in allSamples:
              if w.cmpIgnoreCase(sample.name) == 0:
                result.samples.add sample
                break findSample
            w.parseError()
        if result.samples.len == 0:
          parseError()
      else:
        other.add arg

    # Setup `unittest2`
    other.parseParameters

else:
  # Kill the compilation process iff the directive `cmdLineConfig()` is used
  template cmdLineConfig(): untyped {.used.} =
    {.error: "cmdLineConfig() needs compiler option "&
      " -d:unittest2DisableParamFiltering".}


proc findFilePath(
    file: string;
    baseDir: openArray[string] = baseDir;
    repoDir: openArray[string] = repoDir;
    subDir: openArray[string] = subDir;
      ): Result[string,void] =
  file.findFilePathHelper(baseDir, repoDir, subDir)


proc getTmpDir(sampleDir = sampleDirRefFile): string =
  sampleDir.findFilePath.value.splitFile.dir


proc flushDbDir(s: string) =
  if s != "":
    let dataDir = s / "nimbus"
    if (dataDir / "data").dirExists:
      # Typically under Windows: there might be stale file locks.
      try: dataDir.removeDir except CatchableError: discard
    block dontClearUnlessEmpty:
      for w in s.walkDir:
        break dontClearUnlessEmpty
      try: s.removeDir except CatchableError: discard

# ----------------

proc setTraceLevel {.used.} =
  discard
  when defined(chronicles_runtime_filtering) and loggingEnabled:
    setLogLevel(LogLevel.TRACE)

proc setDebugLevel {.used.} =
  discard
  when defined(chronicles_runtime_filtering) and loggingEnabled:
    setLogLevel(LogLevel.DEBUG)

proc setErrorLevel {.used.} =
  discard
  when defined(chronicles_runtime_filtering) and loggingEnabled:
    setLogLevel(LogLevel.ERROR)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc initRunnerDB(
    path: string;
    specs: CaptureSpecs;
    dbType: CoreDbType;
    pruneHistory: bool;
     ): CommonRef =
  let coreDB =
    # Resolve for static `dbType`
    case dbType:
    of AristoDbMemory: AristoDbMemory.newCoreDbRef()
    of AristoDbRocks: AristoDbRocks.newCoreDbRef(path, DbOptions.init())
    of AristoDbVoid: AristoDbVoid.newCoreDbRef()
    else: raiseAssert $dbType

  when false: # or true:
    setDebugLevel()
    coreDB.trackLegaApi = true
    coreDB.trackNewApi = true

  var
    params: NetworkParams
    networkId: NetworkId
  if specs.builtIn:
    networkId = specs.network
    params = networkId.networkParams()
  else:
    doAssert specs.genesis.findFilePath.value.loadNetworkParams(params)
    networkId = params.config.chainId.NetworkId

  result = CommonRef.new(
    db = coreDB,
    taskpool = nil,
    networkId = networkId,
    params = params,
    pruneHistory = pruneHistory)

  setErrorLevel()
  when CoreDbEnableApiTracking:
    coreDB.trackCoreDbApi = false
    coreDB.trackLedgerApi = false

# ------------------------------------------------------------------------------
# Test Runners: accounts and accounts storages
# ------------------------------------------------------------------------------

proc chainSyncRunner(
    noisy = true;
    capture = memorySampleDefault;
    dbType =  CoreDbType(0);
    pruneHistory = false;
    profilingOk = false;
    finalDiskCleanUpOk = true;
    enaLoggingOk = false;
    lastOneExtraOk = true;
    oldLogAlign = false;
      ) =

  ## Test backend database and ledger
  let
    fileInfo = capture.files[0]
                      .splitFile.name.split(".")[0]
                      .strip(leading=false, chars={'0'..'9'})
    filePaths = capture.files.mapIt(it.findFilePath(baseDir,repoDir).value)
    baseDir = getTmpDir() / capture.dbName & "-chain-sync"
    dbDir = baseDir / "tmp"
    numBlocks = capture.numBlocks
    numBlocksInfo = if numBlocks == high(int): "all" else: $numBlocks

    dbType = block:
      # Decreasing priority: dbType, capture.dbType, dbTypeDefault
      var effDbType = dbTypeDefault
      if dbType != CoreDbType(0):
        effDbType = dbType
      elif capture.dbType != CoreDbType(0):
        effDbType = capture.dbType
      effDbType

    persistent = dbType in CoreDbPersistentTypes

  defer:
    if persistent: baseDir.flushDbDir

  suite &"CoreDB and LedgerRef API on {fileInfo}, {dbType}":

    test &"Ledger API {numBlocksInfo} blocks":
      let
        com = initRunnerDB(dbDir, capture, dbType, pruneHistory)
      defer:
        com.db.finish(eradicate = finalDiskCleanUpOk)
        if profilingOk: noisy.test_chainSyncProfilingPrint numBlocks
        if persistent and finalDiskCleanUpOk: dbDir.flushDbDir

      when CoreDbEnableApiTracking:
        if noisy:
          com.db.trackCoreDbApi = true
          com.db.trackLedgerApi = true

      check noisy.test_chainSync(filePaths, com, numBlocks,
        lastOneExtra=lastOneExtraOk, enaLogging=enaLoggingOk,
        oldLogAlign=oldLogAlign)


proc persistentSyncPreLoadAndResumeRunner(
    noisy = true;
    capture = persistentSampleDefault;
    dbType = CoreDbType(0);
    profilingOk = false;
    pruneHistory = false;
    finalDiskCleanUpOk = true;
    enaLoggingOk = false;
    lastOneExtraOk = true;
    oldLogAlign = false;
      ) =
  ## Test backend database and ledger
  let
    filePaths = capture.files.mapIt(it.findFilePath(baseDir,repoDir).value)
    baseDir = getTmpDir() / capture.dbName & "-chain-sync"
    dbDir = baseDir / "tmp"

    dbType = block:
      # Decreasing priority: dbType, capture.dbType, dbTypeDefault
      var effDbType = dbTypeDefault
      if dbType != CoreDbType(0):
        effDbType = dbType
      elif capture.dbType != CoreDbType(0):
        effDbType = capture.dbType
      effDbType

  doAssert dbType in CoreDbPersistentTypes
  defer: baseDir.flushDbDir

  let
    firstPart = min(capture.numBlocks div 2, 200_000)
    secndPart = capture.numBlocks
    secndPartInfo = if secndPart == high(int): "all" else: $secndPart

  suite &"CoreDB pre-load and resume test ..{firstPart}..{secndPartInfo}":

    test "Populate db by initial sample parts":
      let
        com = initRunnerDB(dbDir, capture, dbType, pruneHistory)
      defer:
        com.db.finish(eradicate = finalDiskCleanUpOk)
        if profilingOk: noisy.test_chainSyncProfilingPrint firstPart

      when CoreDbEnableApiTracking:
        if noisy:
          com.db.trackCoreDbApi = true
          com.db.trackLedgerApi = true

      check noisy.test_chainSync(filePaths, com, firstPart,
        lastOneExtra=lastOneExtraOk, enaLogging=enaLoggingOk,
        oldLogAlign=oldLogAlign)

    test &"Continue with rest of sample":
      let
        com = initRunnerDB(dbDir, capture, dbType, pruneHistory)
      defer:
        com.db.finish(eradicate = finalDiskCleanUpOk)
        if profilingOk: noisy.test_chainSyncProfilingPrint secndPart
        if finalDiskCleanUpOk: dbDir.flushDbDir

      when CoreDbEnableApiTracking:
        if noisy:
          com.db.trackCoreDbApi = true
          com.db.trackLedgerApi = true

      check noisy.test_chainSync(filePaths, com, secndPart,
        lastOneExtra=lastOneExtraOk, enaLogging=enaLoggingOk,
        oldLogAlign=oldLogAlign)

# ------------------------------------------------------------------------------
# Main function(s)
# ------------------------------------------------------------------------------

proc coreDbMain*(noisy = defined(debug)) =
  noisy.chainSyncRunner()
  noisy.persistentSyncPreLoadAndResumeRunner()

when isMainModule:
  const
    noisy {.used.} = defined(debug) or true
  var
    sampleList: seq[CaptureSpecs]

  setErrorLevel()

  when true and false:
    false.coreDbMain()

  sampleList = cmdLineConfig().samples
  if sampleList.len == 0:
    sampleList = @[memorySampleDefault]

  when true: # and false:
    import std/times
    var state: (Duration, int)
    for n,capture in sampleList:
      noisy.profileSection("@sample #" & $n, state):
        noisy.chainSyncRunner(
          #dbType = CdbAristoDualRocks,
          capture = capture,
          #pruneHistory = true,
          #profilingOk = true,
          #finalDiskCleanUpOk = false,
          oldLogAlign = true
        )

    noisy.say "***", "total: ", state[0].pp, " sections: ", state[1]

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
