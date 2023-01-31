# Nimbus
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/options,
  eth/common/[eth_types, eth_types_rlp],
  eth/bloom as bFilter,
  stint,
  ./rpc_types,
  ./hexstrings

export rpc_types

{.push raises: [].}

proc topicToDigest(t: seq[Topic]): seq[Hash256] =
  var resSeq: seq[Hash256] = @[]
  for top in t:
    let ht = Hash256(data: top)
    resSeq.add(ht)
  return resSeq

proc deriveLogs*(header: BlockHeader, transactions: seq[Transaction], receipts: seq[Receipt]): seq[FilterLog] =
  ## Derive log fields, does not deal with pending log, only the logs with
  ## full data set
  doAssert(len(transactions) == len(receipts))

  var resLogs: seq[FilterLog] = @[]
  var logIndex = 0

  for i, receipt in receipts:
    for log in receipt.logs:
      let filterLog = FilterLog(
         # TODO investigate how to handle this field
        # - in nimbus info about log removel would need to be kept at synchronization
        # level, to keep track about potential re-orgs
        # - in fluffy there is no concept of re-org
        removed: false,
        logIndex: some(encodeQuantity(uint32(logIndex))),
        transactionIndex: some(encodeQuantity(uint32(i))),
        transactionHash: some(transactions[i].rlpHash),
        blockHash: some(header.blockHash),
        blockNumber: some(encodeQuantity(header.blockNumber)),
        address: log.address,
        data: log.data,
        #  TODO topics should probably be kept as Hash256 in receipts
        topics: topicToDigest(log.topics)
      )

      inc logIndex
      resLogs.add(filterLog)

  return resLogs

proc bloomFilter*(
    bloom: eth_types.BloomFilter,
    addresses: seq[EthAddress],
    topics: seq[Option[seq[Hash256]]]): bool =

  let bloomFilter = bFilter.BloomFilter(value:  StUint[2048].fromBytesBE(bloom))

  if len(addresses) > 0:
    var addrIncluded: bool = false
    for address in addresses:
      if bloomFilter.contains(address):
        addrIncluded = true
        break
    if not addrIncluded:
      return false

  for sub in topics:

    if sub.isNone():
      # catch all wildcard
      continue

    let subTops = sub.unsafeGet()
    var topicIncluded = len(subTops) == 0
    for topic in subTops:
      # This is is quite not obvious, but passing topic as MDigest256 fails, as
      # it does not use internal keccak256 hashing. To achieve desired semantics,
      # we need use digest bare bytes so that they will be properly kec256 hashes
      if bloomFilter.contains(topic.data):
        topicIncluded = true
        break

    if not topicIncluded:
      return false

  return true

proc headerBloomFilter*(
    header: BlockHeader,
    addresses: seq[EthAddress],
    topics: seq[Option[seq[Hash256]]]): bool =
  return bloomFilter(header.bloom, addresses, topics)

proc matchTopics(log: FilterLog, topics: seq[Option[seq[Hash256]]]): bool =
  for i, sub in topics:

    if sub.isNone():
      # null subtopic i.e it matches all possible move to nex
      continue

    let subTops = sub.unsafeGet()

    # treat empty as wildcard, although caller should rather use none kind of
    # option to indicate that. If nim would have NonEmptySeq type that would be
    # use case for it.
    var match = len(subTops) == 0

    for topic in subTops:
      if log.topics[i] == topic :
        match = true
        break

    if not match:
      return false

  return true

proc filterLogs*(
    logs: openArray[FilterLog],
    addresses: seq[EthAddress],
    topics: seq[Option[seq[Hash256]]]): seq[FilterLog] =

  var filteredLogs: seq[FilterLog] = newSeq[FilterLog]()

  for log in logs:
    if len(addresses) > 0 and (not addresses.contains(log.address)):
      continue

    if len(topics) > len(log.topics):
      continue

    if not matchTopics(log, topics):
      continue

    filteredLogs.add(log)

  return filteredLogs
