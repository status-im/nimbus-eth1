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
  std/strutils,
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

# Must not use `const` here, see `//github.com/nim-lang/Nim/issues/23295`
# Waiting for fix `//github.com/nim-lang/Nim/pull/23297` (or similar) to
# appear on local `Nim` compiler version.
let
  bulkTest0* = CaptureSpecs(
    builtIn:   true,
    name:      "goerli-some",
    network:   GoerliNet,
    files:     @["goerli68161.txt.gz"],
    numBlocks: 1_000)

  bulkTest1* = CaptureSpecs(
    builtIn:   true,
    name:      "goerli-more",
    network:   GoerliNet,
    files:     @["goerli68161.txt.gz"],
    numBlocks: high(int))

  bulkTest2* = CaptureSpecs(
    builtIn:   true,
    name:      "goerli",
    network:   GoerliNet,
    files:     @[
      "goerli482304.txt.gz",              # on nimbus-eth1-blobs/replay
      "goerli482305-504192.txt.gz"],
    numBlocks: high(int))

  bulkTest3* = CaptureSpecs(
    builtIn:   true,
    name:      "main",
    network:   MainNet,
    files:     @[
      "mainnet332160.txt.gz",             # on nimbus-eth1-blobs/replay
      "mainnet332161-550848.txt.gz",
      "mainnet550849-719232.txt.gz",
      "mainnet719233-843841.txt.gz"],
    numBlocks: high(int))


  # Test samples with all the problems one can expect
  ariTest0* = CaptureSpecs(
    builtIn:   true,
    name:      bulkTest2.name & "-am",
    network:   bulkTest2.network,
    files:     bulkTest2.files,
    numBlocks: high(int),
    dbType:    AristoDbMemory)

  ariTest1* = CaptureSpecs(
    builtIn:   true,
    name:      bulkTest2.name & "-ar",
    network:   bulkTest2.network,
    files:     bulkTest2.files,
    numBlocks: high(int),
    dbType:    AristoDbRocks)

  ariTest2* = CaptureSpecs(
    builtIn:   true,
    name:      bulkTest3.name & "-am",
    network:   bulkTest3.network,
    files:     bulkTest3.files,
    numBlocks: 500_000,
    dbType:    AristoDbMemory)

  ariTest3* = CaptureSpecs(
    builtIn:   true,
    name:      bulkTest3.name & "-ar",
    network:   bulkTest3.network,
    files:     bulkTest3.files,
    numBlocks: high(int),
    dbType:    AristoDbRocks)


  # To be compared against the proof-of-concept implementation as reference
  legaTest0* = CaptureSpecs(
    builtIn:   true,
    name:      ariTest0.name.replace("-am", "-lm"),
    network:   ariTest0.network,
    files:     ariTest0.files,
    numBlocks: ariTest0.numBlocks,
    dbType:    LegacyDbMemory)

  legaTest1* = CaptureSpecs(
    builtIn:   true,
    name:      ariTest1.name.replace("-ar", "-lp"),
    network:   ariTest1.network,
    files:     ariTest1.files,
    numBlocks: ariTest1.numBlocks,
    dbType:    LegacyDbPersistent)

  legaTest2* = CaptureSpecs(
    builtIn:   true,
    name:      ariTest2.name.replace("-ar", "-lm"),
    network:   ariTest2.network,
    files:     ariTest2.files,
    numBlocks: ariTest2.numBlocks,
    dbType:    LegacyDbMemory)

  legaTest3* = CaptureSpecs(
    builtIn:   true,
    name:      ariTest3.name.replace("-ar", "-lp"),
    network:   ariTest3.network,
    files:     ariTest3.files,
    numBlocks: ariTest3.numBlocks,
    dbType:    LegacyDbPersistent)

  # ------------------

  allSamples* = [
    bulkTest0, bulkTest1, bulkTest2, bulkTest3,
    ariTest0, ariTest1, ariTest2, ariTest3,
    legaTest0, legaTest1, legaTest2, legaTest3]

# End
