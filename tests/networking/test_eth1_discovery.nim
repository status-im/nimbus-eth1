# nimbus-execution-client
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import
  std/net,
  results,
  stew/byteutils,
  testutils/unittests,
  eth/common/base,
  eth/common/base_rlp,
  eth/common/keys,
  eth/enr/enr,
  ./stubloglevel,
  ../../execution_chain/networking/eth1_discovery,
  ../../execution_chain/networking/bootnodes

suite "Eth1 discovery ENR":
  let privKey = PrivateKey.fromHex(
    "a2b50376a79b1a8c8a3296485572bdfbf54708bb46d3c25d73d2723aaaf6a617")[]

  proc newDiscovery(): Eth1Discovery =
    Eth1Discovery.new(
      privKey = privKey,
      enrIp = Opt.some(parseIpAddress("127.0.0.1")),
      enrTcpPort = Opt.some(Port(30303)),
      enrUdpPort = Opt.some(Port(30303)),
      bootstrapNodes = BootstrapNodes(),
      bindPort = Port(30303))

  test "updateForkId encodes `eth` entry as an RLP list":
    let
      disc = newDiscovery()
      forkId = ForkId(hash: [0xf5'u8, 0x7a, 0xab, 0xec].to(Bytes4), next: 0'u64)

    disc.updateForkId(forkId)

    let
      record = disc.getEnr().get()
      ethRaw = record.rawFieldValue("eth").get()

    check ethRaw == hexToSeqByte("c7c684f57aabec80")

  test "`eth` entry round-trips back to the fork id":
    let
      disc = newDiscovery()
      forkId = ForkId(hash: [0x01'u8, 0x02, 0x03, 0x04].to(Bytes4), next: 42'u64)

    disc.updateForkId(forkId)

    let
      ethBytes = disc.getEnr().get().get("eth", seq[byte]).value()
      decoded = decodeEthEntry(ethBytes)
    check decoded == Opt.some(forkId)

  test "`eth` entry ignores additional list elements":
    let forkId = ForkId(hash: [0x01'u8, 0x02, 0x03, 0x04].to(Bytes4), next: 42'u64)

    check decodeEthEntry(rlp.encode((forkId, 7'u64, @[byte 1, 2]))) == Opt.some(forkId)

  test "`eth` entry with an empty list is rejected":
    check decodeEthEntry(@[byte 0xc0]).isNone()

  test "`eth` entry with an invalid fork id is rejected":
    let invalidForkId = (@[byte 0x01, 0x02, 0x03], 42'u64)
    check decodeEthEntry(rlp.encode((invalidForkId,))).isNone()
