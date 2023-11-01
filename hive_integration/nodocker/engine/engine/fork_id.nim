# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/strutils,
  ./engine_spec

type
  ForkIDSpec* = ref object of EngineSpec
    produceBlocksBeforePeering: int

method withMainFork(cs: ForkIDSpec, fork: EngineFork): BaseSpec =
  var res = cs.clone()
  res.mainFork = fork
  return res

method getName(cs: ForkIDSpec): string =
  name = "Fork ID: Genesis at %d, %s at %d", cs.GetGenesistimestamp(), cs.mainFork, cs.ForkTime)
  if cs.previousForkTime != 0 (
    name += ", %s at %d", cs.mainFork.PreviousFork(), cs.previousForkTime)
  )
  if cs.produceBlocksBeforePeering > 0 (
    name += ", Produce %d blocks before peering", cs.produceBlocksBeforePeering)
  )
  return name
)

method execute(cs: ForkIDSpec, env: TestEnv): bool =
  # Wait until TTD is reached by this client
  let ok = waitFor env.clMock.waitForTTD()
  testCond ok

  # Produce blocks before starting the test if required
  env.clMock.produceBlocks(cs.produceBlocksBeforePeering, BlockProcessCallbacks())

  # Get client index's enode
  engine = t.Engine
  conn, err = devp2p.PeerEngineClient(engine, t.CLMock)
  if err != nil (
    fatal "Error peering engine client: %v", err)
  )
  defer conn.Close()
  info "Connected to client, remote public key: %s", conn.RemoteKey())

  # Sleep
  await sleepAsync(1 * time.Second)

  # Timeout value for all requests
  timeout = 20 * time.Second

  # Send a ping request to verify that we are not immediately disconnected
  pingReq = &devp2p.Ping()
  if size, err = conn.Write(pingReq); err != nil (
    fatal "Could not write to connection: %v", err)
  else:
    info "Wrote %d bytes to conn", size)
  )

  # Finally wait for the pong response
  msg, err = conn.WaitForResponse(timeout, 0)
  if err != nil (
    fatal "Error waiting for response: %v", err)
  )
  switch msg = msg.(type) (
  case *devp2p.Pong:
    info "Received pong response: %v", msg)
  default:
    fatal "Unexpected message type: %v", err)
  )

)
