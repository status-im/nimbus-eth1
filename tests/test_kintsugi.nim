# Nimbus
# Copyright (c) 2018-2019 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[os, strformat, strutils],
  ../nimbus/[chain_config, config, genesis],
  ../nimbus/db/[db_chain, select_backend],
  eth/[common, p2p, trie/db],
  unittest2

const
  baseDir = [".", "tests", ".." / "tests", $DirSep] # path containg repo
  repoDir = ["status", "replay"]                    # alternative repo paths
  jFile = "nimbus_kintsugi.json"

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

proc findFilePath(file: string): string =
  result = "?unknown?" / file
  for dir in baseDir:
    for repo in repoDir:
      let path = dir / repo / file
      if path.fileExists:
        return path

proc flushDbDir(s: string) =
  let dataDir = s / "nimbus"
  if (dataDir / "data").dirExists:
    dataDir.removeDir

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------


# ------------------------------------------------------------------------------
# Test Runner
# ------------------------------------------------------------------------------

proc runner(noisy = true; file = jFile) =
  let
    fileInfo = file.splitFile.name.split(".")[0]
    filePath = file.findFilePath
    tmpDir = filePath.splitFile.dir / "tmp"
  var
    mdb, ddb: BaseChainDB
  defer:
    tmpDir.flushDbDir
    discard

  suite &"Kintsugi test scenario":
    var params: NetworkParams

    test &"Load params from {fileInfo}":
      check filePath.loadNetworkParams(params)

    test &"Construct in-memory BaseChainDB":
      mdb = newBaseChainDB(
        newMemoryDb(),
        id = params.config.chainID.NetworkId,
        params = params)

    test &"Construct persistent BaseChainDB on {tmpDir}":
      ddb = newBaseChainDB(
        tmpDir.newChainDb.trieDB,
        id = params.config.chainID.NetworkId,
        params = params)

    test &"Initialise in-memory Gensis":
      mdb.initializeEmptyDb

    test &"Initialise persistent Gensis, expect AssertionError":
      expect AssertionError:
        ddb.initializeEmptyDb

# ------------------------------------------------------------------------------
# Main function(s)
# ------------------------------------------------------------------------------

proc kintsugiMain*(noisy = defined(debug)) =
  noisy.runner

when isMainModule:
  var noisy = defined(debug)
  #noisy = true

  noisy.runner

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
