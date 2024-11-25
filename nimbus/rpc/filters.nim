# Nimbus
# Copyright (c) 2022-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  chronicles,
  std/options,
  eth/common/eth_types_rlp,
  web3/eth_api_types,
  eth/bloom as bFilter,
  stint,
  ./rpc_types

export rpc_types

{.push raises: [].}

proc deriveLogs*(header: Header, transactions: seq[Transaction], receipts: seq[Receipt]): Opt[seq[FilterLog]] =
  ## Derive log fields, does not deal with pending log, only the logs with
  ## full data set
  if len(transactions) == len(receipts):
    warn "Transactions and receipts length mismatch",
      txs = transactions.len, receipts = receipts.len
    return Opt.none(seq[FilterLog])

  var resLogs: seq[FilterLog] = @[]
  var logIndex = 0'u64

  for i, receipt in receipts:
    for log in receipt.logs:
      let filterLog = FilterLog(
         # TODO investigate how to handle this field
        # - in nimbus info about log removel would need to be kept at synchronization
        # level, to keep track about potential re-orgs
        # - in fluffy there is no concept of re-org
        removed: false,
        logIndex: Opt.some(Quantity(logIndex)),
        transactionIndex: Opt.some(Quantity(i)),
        transactionHash: Opt.some(transactions[i].rlpHash),
        blockHash: Opt.some(header.blockHash),
        blockNumber: Opt.some(Quantity(header.number)),
        address: log.address,
        data: log.data,
        #  TODO topics should probably be kept as Hash32 in receipts
        topics: log.topics
      )

      inc logIndex
      resLogs.add(filterLog)

  return Opt.some(resLogs)

func participateInFilter(x: AddressOrList): bool =
  if x.kind == slkNull:
    return false
  if x.kind == slkList:
    if x.list.len == 0:
      return false
  true

proc bloomFilter*(
    bloom: Bloom,
    addresses: AddressOrList,
    topics: seq[TopicOrList]): bool =

  let bloomFilter = bFilter.BloomFilter(value: bloom.to(StUint[2048]))

  if addresses.participateInFilter():
    var addrIncluded: bool = false
    if addresses.kind == slkSingle:
      addrIncluded = bloomFilter.contains(addresses.single.data)
    elif addresses.kind == slkList:
      for address in addresses.list:
        if bloomFilter.contains(address.data):
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
      if bloomFilter.contains(sub.single.data):
        topicIncluded = true
    else:
      topicIncluded = sub.list.len == 0
      for topic in sub.list:
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
    header: Header,
    addresses: AddressOrList,
    topics: seq[TopicOrList]): bool =
  return bloomFilter(header.logsBloom, addresses, topics)

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
