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
    name*: string            ## Sample name, also used as db directory
    case builtIn*: bool
    of true:
      network*: NetworkId    ## Built-in network ID (unless `config` below)
    else:
      genesis*: string       ## Optional config file (instead of `network`)
    files*: seq[string]      ## Names of capture files
    numBlocks*: int          ## Number of blocks to load
    dbType*: CoreDbType      ## Use `CoreDbType(0)` for default

func cloneWith(
    dsc: CaptureSpecs;
    name = "";
    network = NetworkId(0);
    genesis = "";
    files = seq[string].default;
    numBlocks = 0;
    dbType = CoreDbType(0);
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


# Must not use `const` here, see `//github.com/nim-lang/Nim/issues/23295`
# Waiting for fix `//github.com/nim-lang/Nim/pull/23297` (or similar) to
# appear on local `Nim` compiler version.
let
  goerliSample =  CaptureSpecs(
    builtIn: true,
    name:    "goerli",
    network: GoerliNet,
    files:   @["goerli68161.txt.gz"])     # lon local replay folder

  goerliSampleEx = CaptureSpecs(
    builtIn: true,
    name:    "goerli",
    network: GoerliNet,
    files:   @[
        "goerli482304.txt.gz",            # on nimbus-eth1-blobs/replay
        "goerli482305-504192.txt.gz"])

  mainSampleEx = CaptureSpecs(
    builtIn: true,
    name:    "main",
    network: MainNet,
    files:   @[
      "mainnet332160.txt.gz",             # on nimbus-eth1-blobs/replay
      "mainnet332161-550848.txt.gz",
      "mainnet550849-719232.txt.gz",
      "mainnet719233-843841.txt.gz"])

  mainEra1* = CaptureSpecs(
    builtIn: true,
    name:    "main-era1",
    network: MainNet,
    files:  @["00000.era1"], # ext `.era1` will run over all avail files
    numBlocks: high(int),
    dbType: AristoDbRocks)

  # ------------------

  bulkTest0* = goerliSample
    .cloneWith(
      name      = "-some",
      numBlocks = 1_000)

  bulkTest1* = goerliSample
    .cloneWith(
      name      = "-more",
      numBlocks = high(int))

  bulkTest2* = goerliSampleEx
    .cloneWith(
      numBlocks = high(int))

  bulkTest3* = mainSampleEx
    .cloneWith(
      numBlocks = high(int))

  # Test samples with all the problems one can expect
  ariTest0* = goerliSampleEx
    .cloneWith(
      name      = "-am",
      numBlocks = high(int),
      dbType    = AristoDbMemory)

  ariTest1* = goerliSampleEx
    .cloneWith(
      name      = "-ar",
      numBlocks = high(int),
      dbType    = AristoDbRocks)

  ariTest2* = mainSampleEx
    .cloneWith(
      name      = "-am",
      numBlocks = 500_000,
      dbType    = AristoDbMemory)

  ariTest3* = mainSampleEx
    .cloneWith(
      name      = "-ar",
      numBlocks = high(int),
      dbType    = AristoDbRocks)

  # To be compared against the proof-of-concept implementation as
  # reference

  legaTest0* = goerliSampleEx
    .cloneWith(
      name      = "-lm",
      numBlocks = 500, # high(int),
      dbType    = LegacyDbMemory)

  legaTest1* = goerliSampleEx
    .cloneWith(
      name      = "-lp",
      numBlocks = high(int),
      dbType    = LegacyDbPersistent)

  legaTest2* = mainSampleEx
    .cloneWith(
      name      = "-lm",
      numBlocks = 500_000,
      dbType    = LegacyDbMemory)

  legaTest3* = mainSampleEx
    .cloneWith(
      name      = "-lp",
      numBlocks = high(int),
      dbType    = LegacyDbPersistent)

  # ------------------

  allSamples* = [
    mainEra1,
    bulkTest0, bulkTest1, bulkTest2, bulkTest3,
    ariTest0, ariTest1, ariTest2, ariTest3,
    legaTest0, legaTest1, legaTest2, legaTest3]

# End
