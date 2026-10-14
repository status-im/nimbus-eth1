# nimbus-execution-client
# Copyright (c) 2018-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import
  std/[json, os],
  unittest2,
  testutils,
  chronos, stew/byteutils,
  eth/rlp,
  ../../execution_chain/networking/[devp2p_wire, p2p],
  ./stubloglevel,
  ./p2p_test_helper

proc testThunk(peer: Peer, payload: seq[byte]) {.async: (raises: [CancelledError, RlpError, EthP2PError]).} =
  var (msgId, msgData) = recvMsgMock(payload)
  await peer.invokeThunk(msgId, msgData)

proc testPayloads(filename: string) =
  let js = json.parseFile(filename)

  suite extractFilename(filename):
    var
      env1 = newTestEnv()
      env2 = newTestEnv()

    env2.node.startListening()
    let res = waitFor env1.node.rlpxConnect(newNode(env2.node.toENode()))
    check res.isOk()

    let peer = res.get()

    for testname, testdata in js:
      test testname:
        let
          payloadHex = testdata{"payload"}
          error = testdata{"error"}

        if payloadHex.isNil or payloadHex.kind != JString:
          skip()
          return

        let payload = hexToSeqByte(payloadHex.str)

        if error.isNil:
          waitFor peer.testThunk(payload)
        else:
          if error.kind != JString:
            skip()
            return

          # TODO: can I convert the error string to an Exception type at runtime?
          expect CatchableError:
            try:
              waitFor peer.testThunk(payload)
            except CatchableError as e:
              check: e.name == error.str
              raise e

    waitFor env1.close()
    waitFor env2.close()

testPayloads(sourceDir / "test_rlpx_thunk.json")

suite "devp2p hello packet decoding (via read)":
  test "version 22 + additional list elements for EIP-8":
    # https://eips.ethereum.org/EIPS/eip-8
    let hello = rlp.decode(
      hexToSeqByte(
        "f87137916b6e6574682f76302e39312f706c616e39cdc5836574683dc6846d6f726b1682270fb840" &
        "fda1cff674c90c9a197539fe3dfb53086ace64f83ed7c6eabec741f7f381cc803e52ab2cd55d5569" &
        "bce4347107a310dfd5f88a010cd2ffd1005ca406f1842877c883666f6f836261720304"
      ),
      HelloPacket,
    )
    check:
      hello.version == 55
      hello.clientId == "kneth/v0.91/plan9"
      hello.capabilities.len == 2
      hello.listenPort == 9999
