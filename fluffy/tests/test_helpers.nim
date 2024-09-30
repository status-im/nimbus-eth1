# Nimbus - Portal Network
# Copyright (c) 2021-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  std/net,
  eth/common/keys,
  eth/p2p/discoveryv5/[enr, node, routing_table],
  eth/p2p/discoveryv5/protocol as discv5_protocol

proc localAddress*(port: int): Address {.raises: [ValueError].} =
  Address(ip: parseIpAddress("127.0.0.1"), port: Port(port))

proc initDiscoveryNode*(
    rng: ref HmacDrbgContext,
    privKey: PrivateKey,
    address: Address,
    bootstrapRecords: openArray[Record] = [],
    localEnrFields: openArray[(string, seq[byte])] = [],
    previousRecord = Opt.none(enr.Record),
): discv5_protocol.Protocol {.raises: [CatchableError].} =
  # set bucketIpLimit to allow bucket split
  let config = DiscoveryConfig.init(1000, 24, 5)

  result = newProtocol(
    privKey,
    Opt.some(address.ip),
    Opt.some(address.port),
    Opt.some(address.port),
    bindPort = address.port,
    bootstrapRecords = bootstrapRecords,
    localEnrFields = localEnrFields,
    previousRecord = previousRecord,
    config = config,
    rng = rng,
  )

  result.open()

proc genByteSeq*(length: int): seq[byte] =
  var i = 0
  var resultSeq = newSeq[byte](length)
  while i < length:
    resultSeq[i] = byte(i)
    inc i
  return resultSeq
