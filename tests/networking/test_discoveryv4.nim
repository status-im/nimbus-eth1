# nimbus-execution-client
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import
  std/sequtils,
  chronos,
  stew/byteutils,
  testutils/unittests,
  eth/keccak/keccak,
  eth/common/keys,
  ./stubloglevel,
  ../../execution_chain/networking/discoveryv4

proc localAddress(port: int): Address =
  let port = Port(port)
  result = Address(udpPort: port, tcpPort: port,
                   ip: parseIpAddress("127.0.0.1"))

proc initDiscoveryNode(
    privKey: PrivateKey, address: Address,
    bootnodes: seq[ENode]): DiscoveryV4 =
  let node = newDiscoveryV4(privKey, address, bootnodes, address.udpPort)
  node.open()

  return node

proc packData(payload: openArray[byte], pk: PrivateKey): seq[byte] =
  let
    payloadSeq = @payload
    signature = @(pk.sign(payload).toRaw())
    msgHash = Keccak256.digest(signature & payloadSeq)
  result = @(msgHash.data) & signature & payloadSeq

proc nodeIdInNodes(id: NodeId, nodes: openArray[Node]): bool =
  for n in nodes:
    if id == n.id: return true

procSuite "Discovery Tests":
  let
    bootNodeKey = PrivateKey.fromHex(
      "a2b50376a79b1a8c8a3296485572bdfbf54708bb46d3c25d73d2723aaaf6a617")[]
    bootNodeAddr = localAddress(20301)
    bootENode = ENode(pubkey: bootNodeKey.toPublicKey(), address: bootNodeAddr)
    bootNode = initDiscoveryNode(bootNodeKey, bootNodeAddr, @[])
  waitFor bootNode.bootstrap()

  asyncTest "Discover nodes":
    let nodeKeys = [
      PrivateKey.fromHex(
        "a2b50376a79b1a8c8a3296485572bdfbf54708bb46d3c25d73d2723aaaf6a618")[],
      PrivateKey.fromHex(
        "a2b50376a79b1a8c8a3296485572bdfbf54708bb46d3c25d73d2723aaaf6a619")[],
      PrivateKey.fromHex(
        "a2b50376a79b1a8c8a3296485572bdfbf54708bb46d3c25d73d2723aaaf6a620")[]
    ]

    var nodes: seq[DiscoveryV4]
    for i in 0..<nodeKeys.len:
      let node = initDiscoveryNode(nodeKeys[i], localAddress(20302 + i),
        @[bootENode])
      nodes.add(node)

    await allFutures(nodes.mapIt(it.bootstrap()))
    nodes.add(bootNode)

    for i in nodes:
      for j in nodes:
        if j != i:
          check(nodeIdInNodes(i.localNode.id, j.randomNodes(nodes.len - 1)))

  test "Test Vectors":
    # These are the test vectors from EIP-8:
    # https://github.com/ethereum/EIPs/blob/master/EIPS/eip-8.md#rlpx-discovery-protocol
    # However they are unpacked and the expiration is changed from 0x43b9a355
    # to 0x6fd3aed7 so that they remain valid for a while
    let validProtocolData = [
      # ping packet with version 4, additional list elements
      "01ec04cb847f000001820cfa8215a8d790000000000000000000000000000000018208ae820d05846fd3aed70102",
      # ping packet with version 555, additional list elements and additional random data
      "01f83e82022bd79020010db83c4d001500000000abcdef12820cfa8215a8d79020010db885a308d313198a2e037073488208ae82823a846fd3aed7c5010203040531b9019afde696e582a78fa8d95ea13ce3297d4afb8ba6433e4154caa5ac6431af1b80ba76023fa4090c408f6b4bc3701562c031041d4702971d102c9ab7fa5eed4cd6bab8f7af956f7d565ee1917084a95398b6a21eac920fe3dd1345ec0a7ef39367ee69ddf092cbfe5b93e5e568ebc491983c09c76d922dc3",
      # pong packet with additional list elements and additional random data
      "02f846d79020010db885a308d313198a2e037073488208ae82823aa0fbc914b16819237dcd8801d7e53f69e9719adecb3cc0e790c57e91ca4461c954846fd3aed7c6010203c2040506a0c969a58f6f9095004c0177a6b47f451530cab38966a25cca5cb58f055542124e",
      # findnode packet with additional list elements and additional random data
      "03f84eb840ca634cae0d49acb401d8a4c6b6fe8c55b70d115bf400769cc1400f3258cd31387574077f301b421bc84df7266c44e9e6d569fc56be00812904767bf5ccd1fc7f846fd3aed782999983999999280dc62cc8255c73471e0a61da0c89acdc0e035e260add7fc0c04ad9ebf3919644c91cb247affc82b69bd2ca235c71eab8e49737c937a2c396",
      # neighbours packet with additional list elements and additional random data
      "04f9015bf90150f84d846321163782115c82115db8403155e1427f85f10a5c9a7755877748041af1bcd8d474ec065eb33df57a97babf54bfd2103575fa829115d224c523596b401065a97f74010610fce76382c0bf32f84984010203040101b840312c55512422cf9b8a4097e9a6ad79402e87a15ae909a4bfefa22398f03d20951933beea1e4dfa6f968212385e829f04c2d314fc2d4e255e0d3bc08792b069dbf8599020010db83c4d001500000000abcdef12820d05820d05b84038643200b172dcfef857492156971f0e6aa2c538d8b74010f8e140811d53b98c765dd2d96126051913f44582e8c199ad7c6d6819e9a56483f637feaac9448aacf8599020010db885a308d313198a2e037073488203e78203e8b8408dcab8618c3253b558d459da53bd8fa68935a719aff8b811197101a4b2b47dd2d47295286fc00cc081bb542d760717d1bdd6bec2c37cd72eca367d6dd3b9df73846fd3aed7010203b525a138aa34383fec3d2719a0",
    ]
    let
      address = localAddress(20302)
      nodeKey = PrivateKey.fromHex(
        "b71c71a67e1177ad4e901695e1b4b9ee17ae16c6668d313eac2f96dbcda3f291")[]

    for data in validProtocolData:
      # none of these may raise
      check bootNode.receive(address, packData(hexToSeqByte(data), nodeKey)) == Result[void, cstring].ok()

  test "Invalid protocol data":
    let invalidProtocolData = [
      "0x00",   # invalid msg id
      "0x01",   # empty payload
      "0x03b8", # no list but string
      "0x01C0", # empty list
      # FindNode target that is 1 byte too long
      # We currently do not raise on this, so can't really test it
      # "0x03f847b841AA0000000000000000000000000000000000000000000000000000000000000000a99a96bd988e1839272f93257bd9dfb2e558390e1f9bff28cdc8f04c9b5d06b1846fd3aed7",
    ]

    let invalidRlpData = [
      # valid version: "0x04f8a5f89ef84d847f000001827661827669b840ebefe173cab8832f6d6623f2a4d415959c1b80071e6af7d5986417d4bd07df19318b30d3d4fde75b025314ce22a523a714bef6c61838094e5d3640dccc6b9e34f84d847f000001827662827662b840ebefe173cab8832f6d6623f2a4d415959c1b80071e6af7d5986417d4bd07df19318b30d3d4fde75b025314ce22a523a714bef6c61838094e5d3640dccc6b9e348479e7f252",
      # Invalid rlp item length (for the individual node list), causing a next listElem to read wrong data.
      "0x04f8a5f89ef856847f000001827661827669b840ebefe173cab8832f6d6623f2a4d415959c1b80071e6af7d5986417d4bd07df19318b30d3d4fde75b025314ce22a523a714bef6c61838094e5d3640dccc6b9e34f84d847f000001827662827662b8403114ae2fe09b7a71d6693451c0d043df8315fb811e43c7b97ef2ff87409a2601b4425f92ffff80008417d66489cb1f8414d9dd4393ba16ebb455aa47345a222b8479e7f252",
      # Invalid IP length in nodes
      "0x04f8a4f89df84c837f0001827661827669b840ebefe173cab8832f6d6623f2a4d415959c1b80071e6af7d5986417d4bd07df19318b30d3d4fde75b025314ce22a523a714bef6c61838094e5d3640dccc6b9e34f84d847f000001827662827662b840ebefe173cab8832f6d6623f2a4d415959c1b80071e6af7d5986417d4bd07df19318b30d3d4fde75b025314ce22a523a714bef6c61838094e5d3640dccc6b9e348479e7f252",
      # Invalid Public key in nodes
      "0x04f8a5f89ef84d847f000001827661827669b840fbefe173cab8832f6d6623f2a4d415959c1b80071e6af7d5986417d4bd07df19318b30d3d4fde75b025314ce22a523a714bef6c61838094e5d3640dccc6b9e34f84d847f000001827662827662b840ebefe173cab8832f6d6623f2a4d415959c1b80071e6af7d5986417d4bd07df19318b30d3d4fde75b025314ce22a523a714bef6c61838094e5d3640dccc6b9e348479e7f252",
      # Invalid Public key in nodes - too short
      "0x04f8a4f89df84c847f000001827661827669b83fefe173cab8832f6d6623f2a4d415959c1b80071e6af7d5986417d4bd07df19318b30d3d4fde75b025314ce22a523a714bef6c61838094e5d3640dccc6b9e34f84d847f000001827662827662b840ebefe173cab8832f6d6623f2a4d415959c1b80071e6af7d5986417d4bd07df19318b30d3d4fde75b025314ce22a523a714bef6c61838094e5d3640dccc6b9e348479e7f252",
      # nodes list len of 3 (removed port)
      "0x04f8a2f89bf84a847f000001827661b840ebefe173cab8832f6d6623f2a4d415959c1b80071e6af7d5986417d4bd07df19318b30d3d4fde75b025314ce22a523a714bef6c61838094e5d3640dccc6b9e34f84d847f000001827662827662b840ebefe173cab8832f6d6623f2a4d415959c1b80071e6af7d5986417d4bd07df19318b30d3d4fde75b025314ce22a523a714bef6c61838094e5d3640dccc6b9e348479e7f252"
    ]

    let
      address = localAddress(20302)
      nodeKey = PrivateKey.fromHex(
        "a2b50376a79b1a8c8a3296485572bdfbf54708bb46d3c25d73d2723aaaf6a618")[]

    for data in invalidProtocolData:
      check bootNode.receive(address, packData(hexToSeqByte(data), nodeKey)).isErr

    for data in invalidRlpData:
      check bootNode.receive(address, packData(hexToSeqByte(data), nodeKey)).isErr

    # empty msg id and payload, wrong msg mac
    check bootNode.receive(address, packData(@[], nodeKey)).isErr


  asyncTest "Two findNode calls for the same peer in rapid succession":
    let targetKey = PrivateKey.fromHex(
        "a2b50376a79b1a8c8a3296485572bdfbf54708bb46d3c25d73d2723aaaf6a618")[]
    let peerKey = PrivateKey.fromHex(
        "a2b50376a79b1a8c8a3296485572bdfbf54708bb46d3c25d73d2723aaaf6a619")[]

    let targetNodeId = kademlia.toNodeId(targetKey.toPublicKey)
    let peerNode = kademlia.newNode(peerKey.toPublicKey, localAddress(20302))
    let nodesSeen = new(HashSet[Node])

    # Start `findNode` but don't `await` yet, so the reply can't be processed yet.
    let neighbours1Future = bootNode.kademlia.findNode(nodesSeen, targetNodeId, peerNode)

    # This will raise an assertion error if `findNode` doesn't check for and ignore
    # this second call to the same target and peer in rapid succession.
    let neighbours2Future = bootNode.kademlia.findNode(nodesSeen, targetNodeId, peerNode)

    # Just for completeness, verify the result is empty from the second call.
    let neighbours2 = await neighbours2Future
    check(neighbours2.len == 0)

    # Just for completeness, wait for the first result out of order.
    # Max delay 5 seconds.
    discard await neighbours1Future
