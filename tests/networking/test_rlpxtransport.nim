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
  unittest2,
  chronos/unittest2/asynctests,
  eth/common/keys,
  ../../execution_chain/networking/rlpx/rlpxtransport

suite "RLPx transport":
  setup:
    let
      rng = newRng()
      keys1 = KeyPair.random(rng[])
      keys2 = KeyPair.random(rng[])
      server = createStreamServer(initTAddress("127.0.0.1:0"), {ReuseAddr})

  teardown:
    waitFor server.closeWait()

  asyncTest "Connect/accept":
    const msg = @[byte 0, 1, 2, 3]
    proc serveClient(server: StreamServer) {.async.} =
      let transp = await server.accept()
      let a = await RlpxTransport.accept(rng, keys1, transp)
      await a.sendMsg(msg)
      await a.closeWait()

    let serverFut = server.serveClient()
    defer:
      await serverFut.wait(1.seconds)

    let client =
      await RlpxTransport.connect(rng, keys2, server.localAddress(), keys1.pubkey)

    defer:
      await client.closeWait()
    let rmsg = await client.recvMsg().wait(1.seconds)

    check:
      msg == rmsg

    await serverFut

  asyncTest "Detect invalid pubkey":
    proc serveClient(server: StreamServer) {.async.} =
      let transp = await server.accept()
      discard await RlpxTransport.accept(rng, keys1, transp)
      raiseAssert "should fail to accept due to pubkey error"

    let serverFut = server.serveClient()
    defer:
      expect(RlpxTransportError):
        await serverFut.wait(1.seconds)

    let keys3 = KeyPair.random(rng[])

    # accept side should close connections
    expect(TransportError):
      discard
        await RlpxTransport.connect(rng, keys2, server.localAddress(), keys3.pubkey)
