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
  std/[distros, os, strformat, strutils],
  ../nimbus/[chain_config, config, genesis],
  ../nimbus/db/[db_chain, select_backend],
  eth/[common, p2p, trie/db],
  unittest2

const
  baseDir = [".", "tests", ".." / "tests", $DirSep] # path containg repo
  repoDir = ["status", "replay"]                    # alternative repo paths
  jFile = "nimbus_kintsugi.json"

let
  isUbuntu32bit = detectOs(Ubuntu) and int.sizeof == 4

  # There is a problem with the Github/CI which results in spurious crashes
  # when leaving the `runner()` if the persistent BaseChainDB initialisation
  # was present. The Github/CI set up for Linux/i386 is
  #
  #    Ubuntu 10.04.06 LTS
  #       with repo kernel 5.4.0-1065-azure (see  'uname -a')
  #
  #    base OS architecture is amd64
  #       with i386 foreign architecture
  #
  #    nimbus binary is an
  #       ELF 32-bit LSB shared object,
  #       Intel 80386, version 1 (SYSV), dynamically linked,
  #
  disablePersistentDB = isUbuntu32bit

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
    # Typically under Windows: there might be stale file locks.
    try: dataDir.removeDir except: discard

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

    tmpDir = if disablePersistentDB: "*notused*"
             else: filePath.splitFile.dir / "tmp"

  defer:
    if not disablePersistentDB: tmpDir.flushDbDir

  suite &"Kintsugi test scenario":
    var
      params: NetworkParams
      mdb, ddb: BaseChainDB

    test &"Load params from {fileInfo}":
      check filePath.loadNetworkParams(params)

    test &"Construct in-memory BaseChainDB":
      mdb = newBaseChainDB(
        newMemoryDb(),
        id = params.config.chainID.NetworkId,
        params = params)

    test &"Construct persistent BaseChainDB on {tmpDir}":
      if disablePersistentDB:
        skip()
      else:
        # Before allocating the database, the data directory needs to be
        # cleared. There might be left overs from a previous crash or
        # because there were file locks under Windows which prevented a
        # previous clean up.
        tmpDir.flushDbDir

        # The effect of this constructor is roughly equivalent to the command
        # line invocation of nimbus as
        #
        #    nimbus \
        #       --data-dir:$tmpDir \
        #       --custom-network:$filePath \
        #       --prune-mode:full ...
        #
        # as described in https://github.com/status-im/nimbus-eth1/issues/932.
        ddb = newBaseChainDB(
          tmpDir.newChainDb.trieDB,
          id = params.config.chainID.NetworkId,
          params = params)

    test "Initialise in-memory Genesis":
      mdb.initializeEmptyDb

    #[
    test "Initialise persistent Genesis, expect AssertionError":
      if disablePersistentDB:
        skip()
      else:
        expect AssertionError:
          ddb.initializeEmptyDb
    #]#

    test "Initialise persistent Genesis (kludge)":
      if disablePersistentDB:
        skip()
      else:
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
