# Nimbus
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

{.push raises: [], gcsafe.}

import
  eth/common,
  ../../execution_chain/db/core_db,
  ../../execution_chain/common/chain_config

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
    network = 0.u256;
    genesis = "";
    files = seq[string].default;
    numBlocks = 0;
    dbType = CoreDbType(0);
    dbName = "";
      ): CaptureSpecs =
  var res =
    if network != 0.u256:
      CaptureSpecs(
        name: dsc.name,
        builtIn: true,
        network: network,
        files: dsc.files,
        numBlocks: dsc.numBlocks,
        dbType: dsc.dbType,
        dbName: dsc.dbName)
    elif 0 < genesis.len:
      CaptureSpecs(
        name: dsc.name,
        builtIn: false,
        genesis: genesis,
        files: dsc.files,
        numBlocks: dsc.numBlocks,
        dbType: dsc.dbType,
        dbName: dsc.dbName)
    else:
      dsc
  if 0 < name.len:
    if name[0] == '-':
      res.name &= name
    elif name[0] == '+' and 1 < name.len:
      res.name &= name[1 .. ^1]
    else:
      res.name = name
  if 0 < files.len:
    res.files = files
  if 0 < numBlocks:
    res.numBlocks = numBlocks
  if dbType != CoreDbType(0):
    res.dbType = dbType
  if dbName == "":
    res.dbName = res.name
  else:
    res.dbName = dbName
  res


const
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
    # The extern repo is identified by a tag file
    files:   @["mainnet-extern.era1"])        # on external repo

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

  # -----------------------

  mainTest5m* = mainSampleEx
    .cloneWith(
      name      = "-ex-am",
      numBlocks = 500_000)

  mainTest6r* = mainSampleEx
    .cloneWith(
      name      = "-ex-ar-some",
      numBlocks = 1_000_000,
      dbType    = AristoDbRocks,
      dbName    = "main-open") # for resuming on the same persistent DB

  mainTest7r* = mainSampleEx
    .cloneWith(
      name      = "-ex-ar-more",
      numBlocks = 1_500_000,
      dbType    = AristoDbRocks,
      dbName    = "main-open") # for resuming on the same persistent DB

  mainTest8r* = mainSampleEx
    .cloneWith(
      name      = "-ex-ar-more2",
      numBlocks = 2_000_000,
      dbType    = AristoDbRocks,
      dbName    = "main-open") # for resuming on the same persistent DB

  mainTest9r* = mainSampleEx
    .cloneWith(
      name      = "-ex-ar",
      numBlocks = high(int),
      dbType    = AristoDbRocks,
      dbName    = "main-open") # for resuming on the same persistent DB

  # ------------------

  allSamples* = [
    mainTest0m, mainTest1m, mainTest2r, mainTest3r, mainTest4r,
    mainTest5m, mainTest6r, mainTest7r, mainTest8r, mainTest9r,
  ]

# End
