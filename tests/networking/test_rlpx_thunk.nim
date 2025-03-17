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
  std/[json, os],
  unittest2,
  chronos, stew/byteutils,
  ../../execution_chain/networking/p2p,
  ./stubloglevel,
  ./p2p_test_helper,
  ./eth_protocol

let rng = newRng()

type ClientServerPair = tuple
  client, server: EthereumNode

proc setupClientServer(): ClientServerPair =
  let
    client = setupTestNode(rng, eth)
    server = setupTestNode(rng, eth)
  server.startListening()
  (client, server)

proc connectClient(cs: ClientServerPair): Result[Peer,RlpxError] =
  waitFor cs.client.rlpxConnect(newNode(cs.server.toENode()))


proc testThunk(peer: Peer, payload: openArray[byte]) =
  var (msgId, msgData) = recvMsgMock(payload)
  waitFor peer.invokeThunk(msgId, msgData)


proc testPayloads(filename: string) =
  suite extractFilename(filename):
    let
      js = json.parseFile(filename)
      cs = setupClientServer()
      res = cs.connectClient()

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
          peer.testThunk(payload)
        else:
          if error.kind != JString:
            skip()
            return

          # TODO: can I convert the error string to an Exception type at runtime?
          expect CatchableError:
            try:
              peer.testThunk(payload)
            except CatchableError as e:
              check: e.name == error.str
              raise e


proc testRejectHello() =
  suite "Reject incoming connection":
    let cs = setupClientServer()
    cs.server.maxPeers = 0 # so incoming messages will be rejected

    test "Hello message TooManyPeersError reply":
      let rc = cs.connectClient()
      check rc.isErr()
      check rc.error == TooManyPeersError


testPayloads(sourceDir / "test_rlpx_thunk.json")
testRejectHello()
