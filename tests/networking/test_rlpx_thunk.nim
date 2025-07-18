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
  ./p2p_test_helper

var
  env1 = newTestEnv()
  env2 = newTestEnv()

env2.node.startListening()
let res = waitFor env1.node.rlpxConnect(newNode(env2.node.toENode()))
check res.isOk()

let peer = res.get()

proc testThunk(payload: openArray[byte]) =
  var (msgId, msgData) = recvMsgMock(payload)
  waitFor peer.invokeThunk(msgId, msgData)

proc testPayloads(filename: string) =
  let js = json.parseFile(filename)

  suite extractFilename(filename):
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
          testThunk(payload)
        else:
          if error.kind != JString:
            skip()
            return

          # TODO: can I convert the error string to an Exception type at runtime?
          expect CatchableError:
            try:
              testThunk(payload)
            except CatchableError as e:
              check: e.name == error.str
              raise e

    env1.close()
    env2.close()

testPayloads(sourceDir / "test_rlpx_thunk.json")
