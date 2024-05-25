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
  eth/common,
  ../../nimbus/db/core_db,
  ../../nimbus/common/chain_config

type
  CaptureSpecs* = object
    name*: string            ## Sample name, also used as default db directory
    case builtIn*: bool
    of true:
      network*: NetworkId    ## Built-in network ID (unless `config` below)
    else:
      genesis*: string       ## Optional config file (instead of `network`)
    files*: seq[string]      ## Names of capture files
    numBlocks*: int          ## Number of blocks to load
    dbType*: CoreDbType      ## Use `CoreDbType(0)` for default
    dbName*: string          ## Dedicated name for database directory

func cloneWith(
    dsc: CaptureSpecs;
    name = "";
    network = NetworkId(0);
    genesis = "";
    files = seq[string].default;
    numBlocks = 0;
    dbType = CoreDbType(0);
    dbName = "";
      ): CaptureSpecs =
  result = dsc
  if network != NetworkId(0):
    result.builtIn = true
    result.network = network
  elif 0 < genesis.len:
    result.builtIn = false
    result.genesis = genesis
  if 0 < name.len:
    if name[0] == '-':
      result.name &= name
    elif name[0] == '+' and 1 < name.len:
      result.name &= name[1 .. ^1]
    else:
      result.name = name
  if 0 < files.len:
    result.files = files
  if 0 < numBlocks:
    result.numBlocks = numBlocks
  if dbType != CoreDbType(0):
    result.dbType = dbType
  if dbName == "":
    result.dbName = result.name
  else:
    result.dbName = dbName


# Must not use `const` here, see `//github.com/nim-lang/Nim/issues/23295`
# Waiting for fix `//github.com/nim-lang/Nim/pull/23297` (or similar) to
# appear on local `Nim` compiler version.
let
  mainSample = CaptureSpecs(
    builtIn: true,
    name:    "main",
    network: MainNet,
    files:  @["mainnet-00000-5ec1ffb8.era1"], # on local replay folder
    numBlocks: high(int),
    dbType: AristoDbRocks)

  mainSampleEx = CaptureSpecs(
    builtIn: true,
    name:    "main",
    network: MainNet,
    # will run over all avail files in parent folder
    files:   @["00000.era1"])                 # on external repo

  # ------------------

  # Supposed to run mostly on defaults, object name tag: m=memory, r=rocksDB
  mainTest0m* = mainSample
    .cloneWith(
      name      = "-am-some",
      numBlocks = 1_000)

  mainTest1m* = mainSample
    .cloneWith(
      name      = "-am",
      numBlocks = high(int))

  mainTest2r* = mainSample
    .cloneWith(
      name      = "-ar-some",
      numBlocks = 500,
      dbType    = AristoDbRocks,
      dbName    = "main-open") # for resuming on the same persistent DB

  mainTest3r* = mainSample
    .cloneWith(
      name      = "-ar-more",
      numBlocks = 1_000,
      dbType    = AristoDbRocks,
      dbName    = "main-open") # for resuming on the same persistent DB

  mainTest4r* = mainSample
    .cloneWith(
      name      = "-ar",
      dbType    = AristoDbRocks,
      dbName    = "main-open") # for resuming on the same persistent DB


  mainTest5m* = mainSampleEx
    .cloneWith(
      name      = "-ex-am",
      numBlocks = 500_000)

  mainTest6r* = mainSampleEx
    .cloneWith(
      name      = "-ex-ar",
      numBlocks = high(int),
      dbType    = AristoDbRocks)


  # ------------------

  allSamples* = [
    mainTest0m, mainTest1m,
    mainTest2r, mainTest3r, mainTest4r,
    mainTest5m, mainTest6r
  ]

# End
