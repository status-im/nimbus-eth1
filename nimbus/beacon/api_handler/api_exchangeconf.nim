# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[strutils],
  eth/common/[base, headers, hashes],
  ../beacon_engine,
  web3/execution_types,
  chronicles

{.push gcsafe, raises:[CatchableError].}

proc exchangeConf*(ben: BeaconEngineRef,
                   conf: TransitionConfigurationV1):
                       TransitionConfigurationV1 =
  trace "Engine API request received",
    meth = "exchangeTransitionConfigurationV1",
    ttd = conf.terminalTotalDifficulty,
    number = uint64(conf.terminalBlockNumber),
    blockHash = conf.terminalBlockHash

  let
    com = ben.com
    db  = com.db
    ttd = com.ttd

  if ttd.isNone:
    raise newException(ValueError, "invalid ttd: EL (none) CL ($1)" % [
      $conf.terminalTotalDifficulty])

  if conf.terminalTotalDifficulty != ttd.get:
    raise newException(ValueError, "invalid ttd: EL ($1) CL ($2)" % [
      $ttd.get, $conf.terminalTotalDifficulty])

  let
    terminalBlockNumber = base.BlockNumber conf.terminalBlockNumber
    terminalBlockHash   = conf.terminalBlockHash

  if terminalBlockHash != default(Hash32):
    let headerHash = db.getBlockHash(terminalBlockNumber).valueOr:
      raise newException(ValueError, "cannot get terminal block hash, number $1, msg: $2" %
        [$terminalBlockNumber, error])

    if terminalBlockHash != headerHash:
      raise newException(ValueError, "invalid terminal block hash, got $1 want $2" %
        [$terminalBlockHash, $headerHash])

    let header = db.getBlockHeader(headerHash).valueOr:
      raise newException(ValueError, "cannot get terminal block header, hash $1, msg: $2" %
        [$terminalBlockHash, error])

    return TransitionConfigurationV1(
      terminalTotalDifficulty: ttd.get,
      terminalBlockHash      : headerHash,
      terminalBlockNumber    : Quantity(header.number)
    )

  if terminalBlockNumber != 0'u64:
    raise newException(ValueError, "invalid terminal block number: $1" % [
      $terminalBlockNumber])

  if terminalBlockHash != default(Hash32):
    raise newException(ValueError, "invalid terminal block hash, no terminal header set")

  TransitionConfigurationV1(terminalTotalDifficulty: ttd.get)
