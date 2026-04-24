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
  std/typetraits,
  unittest2,
  testutils,
  chronos,
  eth/rlp,
  ../../execution_chain/networking/p2p,
  ../../execution_chain/sync/wire_protocol,
  ./stubloglevel,
  ./p2p_test_helper


procSuite "devp2p eth/71 Tests":

  asyncTest "getBlockAccessLists - BAL unavailable":
    var
      env1 = newTestEnv()
      env2 = newTestEnv()

    env2.node.startListening()

    let connRes = await env1.node.rlpxConnect(newNode(env2.node.toENode()))
    check connRes.isOk()

    let peer = connRes.get()
    check peer.supports(eth71)

    let 
      req = BlockAccessListsRequest(blockHashes: @[default(Hash32), default(Hash32)])
      respOpt = await peer.getBlockAccessLists(req, timeout = chronos.seconds(3))
    check respOpt.isSome()

    let resp = respOpt.get()
    check resp.accessLists.len() == req.blockHashes.len()

    for balBytes in resp.accessLists:
      check:
        distinctBase(balBytes) == @[0x80.byte]
        rlp.encode(balBytes) == @[0x80.byte]

    env2.close()
    env1.close()

