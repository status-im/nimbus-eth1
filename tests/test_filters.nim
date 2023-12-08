# Copyright (c) 2022-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.


import
  std/[options, strutils, typetraits],
  unittest2,
  eth/[common/eth_types],
  nimcrypto/hash,
  stew/byteutils,
  ../nimbus/rpc/filters,
  ../nimbus/beacon/web3_eth_conv,
  ./test_block_fixture

let allLogs = deriveLogs(blockHeader4514995, blockBody4514995.transactions, receipts4514995)

func w3Hash(x: string): Web3Hash =
  Web3Hash hexToByteArray[32](x)

proc filtersMain*() =
  # All magic numbers and addresses in following tests are confirmed with geth eth_getLogs,
  # responses
  suite "Log filters":
    # specific tests comparing results with geth
    test "Proper log number and indexes":
      check:
        len(allLogs) == 54

      for i, log in allLogs:
        check:
          log.logIndex.unsafeGet() == w3Qty(i.uint64)

    test "Filter with empty parameters should return all logs":
      let addrs = newSeq[EthAddress]()
      let filtered = filterLogs(allLogs, addrs, @[])
      check:
        len(filtered) == len(allLogs)

    test "Filter and BloomFilter for one address with one valid log":
      let address = hexToByteArray[20]("0x0e0989b1f9b8a38983c2ba8053269ca62ec9b195")
      let filteredLogs = filterLogs(allLogs, @[address], @[])

      check:
        headerBloomFilter(blockHeader4514995, @[address], @[])
        len(filteredLogs) == 1
        filteredLogs[0].address == w3Addr address

    test "Filter and BloomFilter for one address with multiple valid logs":
      let address = hexToByteArray[20]("0x878d7ed5c194349f37b18688964e8db1eb0fcca1")
      let filteredLogs = filterLogs(allLogs, @[address], @[])

      check:
        headerBloomFilter(blockHeader4514995, @[address], @[])
        len(filteredLogs) == 2

      for log in filteredLogs:
        check:
          log.address == w3Addr address

    test "Filter and BloomFilter for multiple address with multiple valid logs":
      let address = hexToByteArray[20]("0x878d7ed5c194349f37b18688964e8db1eb0fcca1")
      let address1 = hexToByteArray[20]("0x0e0989b1f9b8a38983c2ba8053269ca62ec9b195")
      let filteredLogs = filterLogs(allLogs, @[address, address1], @[])

      check:
        headerBloomFilter(blockHeader4514995, @[address, address1], @[])
        len(filteredLogs) == 3

    test "Filter topics, too many filters":
      let filteredLogs =
        filterLogs(
          allLogs,
          @[],
          @[
            none[seq[Web3Hash]](),
            none[seq[Web3Hash]](),
            none[seq[Web3Hash]](),
            none[seq[Web3Hash]](),
            none[seq[Web3Hash]]()
          ]
        )

      check:
        len(filteredLogs) == 0

    test "Filter topics, specific topic at first position":
      let topic = w3Hash("0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef")

      let filteredLogs =
        filterLogs(
          allLogs,
          @[],
          @[some(@[topic])]
        )

      check:
        len(filteredLogs) == 15


      for log in filteredLogs:
        check:
          log.topics[0] == topic

    test "Filter topics, specific topic at first position and second position":
      let topic = w3Hash("0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef")
      let topic1 = w3Hash("0x000000000000000000000000919040a01a0adcef25ed6ecbc6ab2a86ca6d77df")

      let filteredLogs =
        filterLogs(
          allLogs,
          @[],
          @[some(@[topic]), some(@[topic1])]
        )

      check:
        len(filteredLogs) == 1


      for log in filteredLogs:
        check:
          log.topics[0] == topic
          log.topics[1] == topic1

    test "Filter topics, specific topic at first position and third position":
      let topic = w3Hash("0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef")
      let topic1 = w3Hash("0x000000000000000000000000fdc183d01a793613736cd40a5a578f49add1772b")

      let filteredLogs =
        filterLogs(
          allLogs,
          @[],
          @[some(@[topic]), none[seq[Web3Hash]](), some(@[topic1])]
        )

      check:
        len(filteredLogs) == 1

      for log in filteredLogs:
        check:
          log.topics[0] == topic
          log.topics[2] == topic1

    test "Filter topics, or query at first position":
      let topic = w3Hash("0x4a504a94899432a9846e1aa406dceb1bcfd538bb839071d49d1e5e23f5be30ef")
      let topic1 = w3Hash("0x526441bb6c1aba3c9a4a6ca1d6545da9c2333c8c48343ef398eb858d72b79236")

      let filteredLogs =
        filterLogs(
          allLogs,
          @[],
          @[
            some(@[topic, topic1])
          ]
        )

      check:
        len(filteredLogs) == 2

      for log in filteredLogs:
        check:
          log.topics[0] == topic or log.topics[0] == topic1

    test "Filter topics, or query at first position and or query at second position":
      let topic = w3Hash("0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef")
      let topic1 = w3Hash("0xa64da754fccf55aa65a1f0128a648633fade3884b236e879ee9f64c78df5d5d7")

      let topic2 = w3Hash("0x000000000000000000000000e16c02eac87920033ac72fc55ee1df3151c75786")
      let topic3 = w3Hash("0x000000000000000000000000b626a5facc4de1c813f5293ec3be31979f1d1c78")

      let filteredLogs =
        filterLogs(
          allLogs,
          @[],
          @[
            some(@[topic, topic1]),
            some(@[topic2, topic3])
          ]
        )

      check:
        len(filteredLogs) == 2

      for log in filteredLogs:
        check:
          log.topics[0] == topic or log.topics[0] == topic1
          log.topics[1] == topic2 or log.topics[1] == topic3

    # general propety based tests
    test "Specific address query should provide results only with given address":
      for log in allLogs:
        let filtered = filterLogs(allLogs, @[log.address], @[])

        check:
          len(filtered) > 0

        for filteredLog in filtered:
          check:
            filteredLog.address == log.address

when isMainModule:
  filtersMain()
