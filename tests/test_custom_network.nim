# Nimbus
# Copyright (c) 2018-2019 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## This unit test was roughly inspired by repeated failings of running nimbus
## similar to
## ::
##    nimbus \
##       --data-dir:./kintsugi/tmp \
##       --custom-network:kintsugi-network.json \
##       --bootstrap-file:kintsugi-bootnodes.txt \
##       --prune-mode:full ...
##
## from `issue 932` <https://github.com/status-im/nimbus-eth1/issues/932>`_.

import
  std/[distros, os, strformat, strutils, sequtils],
  ../nimbus/[chain_config, config, genesis],
  ../nimbus/db/[db_chain, select_backend],
  ./replay/pp,
  eth/[common, p2p, trie/db],
  nimcrypto/hash,
  unittest2

const
  baseDir = [".", "tests", ".." / "tests", $DirSep]   # path containg repo
  repoDir = ["customgenesis", "."]                    # alternative repo paths
  jFile = "kintsugi.json"


when not defined(linux):
  const isUbuntu32bit = false
else:
  # The `detectOs(Ubuntu)` directive is not Windows compatible, causes an
  # error when running the system command `lsb_release -d` in the background.
  let isUbuntu32bit = detectOs(Ubuntu) and int.sizeof == 4

let
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

proc say*(noisy = false; pfx = "***"; args: varargs[string, `$`]) =
  if noisy:
    if args.len == 0:
      echo "*** ", pfx
    elif 0 < pfx.len and pfx[^1] != ' ':
      echo pfx, " ", args.toSeq.join
    else:
      echo pfx, args.toSeq.join

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

  suite "Kintsugi custom network test scenario":
    var
      params: NetworkParams
      mdb, ddb: BaseChainDB

    test &"Load params from {fileInfo}":
      noisy.say "***", "custom-file=", filePath
      check filePath.loadNetworkParams(params)

    test "Construct in-memory BaseChainDB":
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

        # Constructor ...
        ddb = newBaseChainDB(
          tmpDir.newChainDb.trieDB,
          id = params.config.chainID.NetworkId,
          pruneTrie = true,
          params = params)

    test "Initialise in-memory Genesis":
      mdb.initializeEmptyDb

      # Verify variant of `toBlockHeader()`. The function `pp()` is used
      # (rather than blockHash()) for readable error report (if any).
      let
        storedhHeaderPP = mdb.getBlockHeader(0.u256).pp
        onTheFlyHeaderPP = mdb.toGenesisHeader.pp
      check storedhHeaderPP == onTheFlyHeaderPP

    test "Initialise persistent Genesis":
      if disablePersistentDB:
        skip()
      else:
        ddb.initializeEmptyDb

        # Must be the same as the in-memory DB value
        check ddb.getBlockHash(0.u256) == mdb.getBlockHash(0.u256)

        let
          storedhHeaderPP = ddb.getBlockHeader(0.u256).pp
          onTheFlyHeaderPP = ddb.toGenesisHeader.pp
        check storedhHeaderPP == onTheFlyHeaderPP

# ------------------------------------------------------------------------------
# Main function(s)
# ------------------------------------------------------------------------------

proc customNetworkMain*(noisy = defined(debug)) =
  noisy.runner

when isMainModule:
  var noisy = defined(debug)
  noisy = true
  noisy.runner

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
