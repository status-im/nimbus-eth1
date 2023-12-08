# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[strutils],
  eth/common,
  ../web3_eth_conv,
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
    terminalBlockNumber = u256 conf.terminalBlockNumber
    terminalBlockHash   = ethHash conf.terminalBlockHash

  if terminalBlockHash != common.Hash256():
    var headerHash: common.Hash256

    if not db.getBlockHash(terminalBlockNumber, headerHash):
      raise newException(ValueError, "cannot get terminal block hash, number $1" %
        [$terminalBlockNumber])

    if terminalBlockHash != headerHash:
      raise newException(ValueError, "invalid terminal block hash, got $1 want $2" %
        [$terminalBlockHash, $headerHash])

    var header: common.BlockHeader
    if not db.getBlockHeader(headerHash, header):
      raise newException(ValueError, "cannot get terminal block header, hash $1" %
        [$terminalBlockHash])

    return TransitionConfigurationV1(
      terminalTotalDifficulty: ttd.get,
      terminalBlockHash      : w3Hash headerHash,
      terminalBlockNumber    : w3Qty header.blockNumber
    )

  if terminalBlockNumber.isZero.not:
    raise newException(ValueError, "invalid terminal block number: $1" % [
      $terminalBlockNumber])

  if terminalBlockHash != common.Hash256():
    raise newException(ValueError, "invalid terminal block hash, no terminal header set")

  TransitionConfigurationV1(terminalTotalDifficulty: ttd.get)
