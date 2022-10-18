# Nimbus - Portal Network
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  stew/shims/net,
  eth/keys,
  eth/p2p/discoveryv5/[enr, node, routing_table],
  eth/p2p/discoveryv5/protocol as discv5_protocol,
  ../network/history/accumulator

proc localAddress*(port: int): Address =
  Address(ip: ValidIpAddress.init("127.0.0.1"), port: Port(port))

proc initDiscoveryNode*(
    rng: ref HmacDrbgContext,
    privKey: PrivateKey,
    address: Address,
    bootstrapRecords: openArray[Record] = [],
    localEnrFields: openArray[(string, seq[byte])] = [],
    previousRecord = none[enr.Record]()): discv5_protocol.Protocol =
  # set bucketIpLimit to allow bucket split
  let config = DiscoveryConfig.init(1000, 24, 5)

  result = newProtocol(privKey,
    some(address.ip),
    some(address.port), some(address.port),
    bindPort = address.port,
    bootstrapRecords = bootstrapRecords,
    localEnrFields = localEnrFields,
    previousRecord = previousRecord,
    config = config,
    rng = rng)

  result.open()

proc genByteSeq*(length: int): seq[byte] =
  var i = 0
  var resultSeq = newSeq[byte](length)
  while i < length:
    resultSeq[i] = byte(i)
    inc i
  return resultSeq

func buildAccumulator*(
    headers: seq[BlockHeader]): Result[FinishedAccumulator, string] =
  var accumulator: Accumulator
  for header in headers:
    updateAccumulator(accumulator, header)

    if header.blockNumber.truncate(uint64) == mergeBlockNumber - 1:
      return ok(finishAccumulator(accumulator))

  err("Not enough headers provided to finish the accumulator")

func buildAccumulatorData*(headers: seq[BlockHeader]):
    Result[(FinishedAccumulator, seq[EpochAccumulator]), string] =
  var accumulator: Accumulator
  var epochAccumulators: seq[EpochAccumulator]
  for header in headers:
    updateAccumulator(accumulator, header)

    if accumulator.currentEpoch.len() == epochSize:
      epochAccumulators.add(accumulator.currentEpoch)

    if header.blockNumber.truncate(uint64) == mergeBlockNumber - 1:
      epochAccumulators.add(accumulator.currentEpoch)

      return ok((finishAccumulator(accumulator), epochAccumulators))

  err("Not enough headers provided to finish the accumulator")
