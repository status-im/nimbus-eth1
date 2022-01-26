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
  isLinux32bit = defined(linux) and int.sizeof == 4

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

  # There is a crash problem with the persistent BaseChainDB initialisation
  # and clean up on the Github/CI Linux/i386 engines running Ubuntu 18.04.06.
  # It will result in spurious segfaults for some reason.
  #
  # This could not be reproduced on a virtual Qemu machine running
  # Debian/bullseye i386, see also
  # https://github.com/status-im/nimbus-eth2/issues/3121, some observations
  # similar to this one.
  when isLinux32bit:
    let tmpDir = "*notused*"
  else:
    let tmpDir = filePath.splitFile.dir / "tmp"
    defer: tmpDir.flushDbDir

  suite &"Kintsugi test scenario":
    var
      params: NetworkParams
      mdb: BaseChainDB

    when not isLinux32bit:
      var ddb: BaseChainDB

    test &"Load params from {fileInfo}":
      check filePath.loadNetworkParams(params)

    test &"Construct in-memory BaseChainDB":
      mdb = newBaseChainDB(
        newMemoryDb(),
        id = params.config.chainID.NetworkId,
        params = params)

    test &"Construct persistent BaseChainDB on {tmpDir}":
      when isLinux32bit:
        # Crazy enough, on the Github/CI Linux/i386 engines running
        # Ubuntu 18.04.06, some of the VM variants crash already if
        # the constructor below is present without even applying it
        # (e.g. as `ddb.initializeEmptyDb`.)
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

    test "Initialise persistent Genesis, expect AssertionError":
      when isLinux32bit:
        skip()
      else:
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
