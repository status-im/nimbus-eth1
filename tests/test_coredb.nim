# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
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
  ../nimbus/db/core_db/persistent,
  ../nimbus/db/ledger,
  ../nimbus/core/chain,
  ./replay/pp,
  ./test_coredb/[coredb_test_xx, test_chainsync, test_helpers]

const
  # If `true`, this compile time option set up `unittest2` for manual parsing
  unittest2DisableParamFiltering {.booldefine.} = false

  baseDir = [".", "..", ".."/"..", $DirSep]
  repoDir = [".", "tests", "nimbus-eth1-blobs"]
  subDir = ["replay", "test_coredb", "custom-network", "customgenesis"]

  # Reference file for finding some database directory base
  sampleDirRefFile = "coredb_test_xx.nim"

  dbTypeDefault = AristoDbMemory
  ldgTypeDefault = LedgerCache

let
  # Standard test sample
  bChainCapture = bulkTest0

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
    ##       --sample=goerli-lp,goerli-ar
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
    ldgType: LedgerType;
      ): CommonRef =
  let coreDB =
    # Resolve for static `dbType`
    case dbType:
    of AristoDbMemory: AristoDbMemory.newCoreDbRef()
    of AristoDbRocks: AristoDbRocks.newCoreDbRef path
    of AristoDbVoid: AristoDbVoid.newCoreDbRef()
    else: raiseAssert "Oops"

  when false: # or true:
    setDebugLevel()
    coreDB.trackLegaApi = true
    coreDB.trackNewApi = true
    coreDB.localDbOnly = true

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
    networkId = networkId,
    params = params,
    ldgType = ldgType)

  result.initializeEmptyDb

  setErrorLevel()
  coreDB.trackLegaApi = false
  coreDB.trackNewApi = false
  coreDB.localDbOnly = false

# ------------------------------------------------------------------------------
# Test Runners: accounts and accounts storages
# ------------------------------------------------------------------------------

proc chainSyncRunner(
    noisy = true;
    capture = bChainCapture;
    dbType = CoreDbType(0);
    ldgType = ldgTypeDefault;
    profilingOk = false;
    finalDiskCleanUpOk = true;
    enaLoggingOk = false;
    lastOneExtraOk = true;
      ) =

  ## Test backend database and ledger
  let
    fileInfo = capture.files[0]
                      .splitFile.name.split(".")[0]
                      .strip(leading=false, chars={'0'..'9'})
    filePaths = capture.files.mapIt(it.findFilePath(baseDir,repoDir).value)
    baseDir = getTmpDir() / capture.name & "-chain-sync"
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

  suite &"CoreDB and LedgerRef API on {fileInfo}, {dbType}, {ldgType}":

    test &"Ledger API {ldgType}, {numBlocksInfo} blocks":
      let
        com = initRunnerDB(dbDir, capture, dbType, ldgType)
      defer:
        com.db.finish(flush = finalDiskCleanUpOk)
        if profilingOk: noisy.test_chainSyncProfilingPrint numBlocks
        if persistent and finalDiskCleanUpOk: dbDir.flushDbDir

      if noisy:
        com.db.trackNewApi = true
        com.db.trackNewApi = true
        com.db.trackLedgerApi = true
        com.db.localDbOnly = true

      check noisy.test_chainSync(filePaths, com, numBlocks,
        lastOneExtra=lastOneExtraOk, enaLogging=enaLoggingOk)

# ------------------------------------------------------------------------------
# Main function(s)
# ------------------------------------------------------------------------------

proc coreDbMain*(noisy = defined(debug)) =
  noisy.chainSyncRunner()

when isMainModule:
  import
    std/times
  const
    noisy = defined(debug) or true
  var
    sampleList: seq[CaptureSpecs]

  setErrorLevel()

  # This one uses the readily available dump: `bulkTest0` and some huge replay
  # dumps `bulkTest2`, `bulkTest3`, .. from the `nimbus-eth1-blobs` package.
  # For specs see `tests/test_coredb/bulk_test_xx.nim`.

  sampleList = cmdLineConfig().samples
  if sampleList.len == 0:
    sampleList = @[bulkTest0]
    when true:
      sampleList = @[bulkTest2, bulkTest3]
    sampleList = @[ariTest1] # debugging

  var state: (Duration, int)
  for n,capture in sampleList:
    noisy.profileSection("@sample #" & $n, state):
      noisy.chainSyncRunner(
        capture = capture,
        #dbType = ..,
        ldgType=LedgerCache,
        #profilingOk = true,
        #finalDiskCleanUpOk = false,
        #enaLoggingOk = ..,
        #lastOneExtraOk = ..,
      )

  noisy.say "***", "total: ", state[0].pp, " sections: ", state[1]

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
