# nimbus-execution-client
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  testutils/fuzzing, chronos,
  ../../../../execution_chain/networking/[p2p, rlpx, p2p_types],
  ../../p2p_test_helper

var
  env1: TestEnv
  env2: TestEnv
  peer: Peer

let rng = newRng()
# This is not a good example of a fuzzing test and it would be much better
# to mock more to get rid of anything sockets, async, etc.
# However, it can and has provided reasonably quick results anyhow.
init:
  env1 = newTestEnv()
  env2 = newTestEnv()

  env2.node.startListening()
  let res = waitFor env1.node.rlpxConnect(newNode(env2.node.toENode()))
  if res.isErr():
    quit 1
  else:
    peer = res.get()

test:
  aflLoop: # This appears to have unstable results with afl-clang-fast, probably
           # because of undeterministic behaviour due to usage of network/async.
    try:
      var (msgId, msgData) = recvMsgMock(payload)
      waitFor peer.invokeThunk(msgId, msgData)
    except CatchableError as e:
      debug "Test caused CatchableError", exception=e.name, trace=e.repr, msg=e.msg
