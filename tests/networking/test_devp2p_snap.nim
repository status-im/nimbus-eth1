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
  unittest2,
  testutils,
  chronos,
  ../../execution_chain/networking/p2p,
  ../../execution_chain/sync/wire_protocol,
  ./stubloglevel,
  ./p2p_test_helper

procSuite "devp2p snap Tests":

  asyncTest "storageRanges - reply to a peer that negotiated snap/2 only":
    var
      env1 = newTestEnv()
      env2 = newTestEnv()

    discard env1.node.addSnapHandlerCapability()
    discard env2.node.addSnapHandlerCapability()

    env2.node.startListening()

    let connRes = await env1.node.rlpxConnect(newNode(env2.node.toENode()))
    check connRes.isOk()

    # Both nodes offer snap/1 and snap/2 but the handshake keeps snap/2 only.
    let peer = connRes.get()
    check:
      peer.supports(snap2)
      not peer.supports(snap1)

    let
      responder = Responder(peer: peer, reqId: 1)
      slots = @[@[StorageItem(slotHash: default(Hash32), slotData: @[1.byte])]]

    await responder.storageRanges(slots, @[])
    await responder.storageRanges(slots, @[ProofNode(@[0x80.byte])])

    check peer.connectionState == ConnectionState.Connected

    await env2.close()
    await env1.close()
