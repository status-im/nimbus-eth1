# Nimbus
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/options,
  eth/common/[eth_types, eth_types_rlp],
  eth/bloom as bFilter,
  stint,
  ../beacon/web3_eth_conv,
  ./rpc_types

export rpc_types

type
  BlockHeader = eth_types.BlockHeader

{.push raises: [].}

proc topicToDigest(t: seq[eth_types.Topic]): seq[Web3Topic] =
  var resSeq: seq[Web3Topic] = @[]
  for top in t:
    let ht = Web3Topic(top)
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
        logIndex: some(w3Qty(logIndex)),
        transactionIndex: some(w3Qty(i)),
        transactionHash: some(w3Hash transactions[i].rlpHash),
        blockHash: some(w3Hash header.blockHash),
        blockNumber: some(w3Qty(header.blockNumber.truncate(uint64))),
        address: w3Addr log.address,
        data: log.data,
        #  TODO topics should probably be kept as Hash256 in receipts
        topics: topicToDigest(log.topics)
      )

      inc logIndex
      resLogs.add(filterLog)

  return resLogs

func participateInFilter(x: AddressOrList): bool =
  if x.kind == slkNull:
    return false
  if x.kind == slkList:
    if x.list.len == 0:
      return false
  true

proc bloomFilter*(
    bloom: eth_types.BloomFilter,
    addresses: AddressOrList,
    topics: seq[TopicOrList]): bool =

  let bloomFilter = bFilter.BloomFilter(value:  StUint[2048].fromBytesBE(bloom))

  if addresses.participateInFilter():
    var addrIncluded: bool = false
    if addresses.kind == slkSingle:
      addrIncluded = bloomFilter.contains(addresses.single.bytes)
    elif addresses.kind == slkList:
      for address in addresses.list:
        if bloomFilter.contains(address.bytes):
          addrIncluded = true
          break
    if not addrIncluded:
      return false

  for sub in topics:
    if sub.kind == slkNull:
      # catch all wildcard
      continue

    var topicIncluded = false
    if sub.kind == slkSingle:
      if bloomFilter.contains(sub.single.bytes):
        topicIncluded = true
    else:
      topicIncluded = sub.list.len == 0
      for topic in sub.list:
        # This is is quite not obvious, but passing topic as MDigest256 fails, as
        # it does not use internal keccak256 hashing. To achieve desired semantics,
        # we need use digest bare bytes so that they will be properly kec256 hashes
        if bloomFilter.contains(topic.bytes):
          topicIncluded = true
          break

    if not topicIncluded:
      return false

  return true

proc headerBloomFilter*(
    header: BlockHeader,
    addresses: AddressOrList,
    topics: seq[TopicOrList]): bool =
  return bloomFilter(header.bloom, addresses, topics)

proc matchTopics(log: FilterLog, topics: seq[TopicOrList]): bool =
  for i, sub in topics:

    if sub.kind == slkNull:
      # null subtopic i.e it matches all possible move to nex
      continue

    var match = false
    if sub.kind == slkSingle:
      match = log.topics[i] == sub.single
    else:
      # treat empty as wildcard, although caller should rather use none kind of
      # option to indicate that. If nim would have NonEmptySeq type that would be
      # use case for it.
      match = sub.list.len == 0
      for topic in sub.list:
        if log.topics[i] == topic:
          match = true
          break

    if not match:
      return false

  return true

proc filterLogs*(
    logs: openArray[FilterLog],
    addresses: AddressOrList,
    topics: seq[TopicOrList]): seq[FilterLog] =

  var filteredLogs: seq[FilterLog] = newSeq[FilterLog]()

  for log in logs:
    if addresses.kind == slkSingle and (addresses.single != log.address):
      continue

    if addresses.kind == slkList and
       addresses.list.len > 0 and
       (not addresses.list.contains(log.address)):
      continue

    if len(topics) > len(log.topics):
      continue

    if not matchTopics(log, topics):
      continue

    filteredLogs.add(log)

  return filteredLogs
