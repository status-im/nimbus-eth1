# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Replay runner

{.push raises:[].}

import
  pkg/chronos,
  ../../../../networking/[p2p, p2p_peers, peer_pool],
  ../../../wire_protocol,
  ../replay_desc

logScope:
  topics = "replay"

# ------------------------------------------------------------------------------
# Private helper(s)
# ------------------------------------------------------------------------------

proc getDispatcher(): Dispatcher =
  ## Return a list of all known protocols and pretend all are supported
  var po = PeerObserver()
  po.addProtocol eth68
  po.addProtocol eth69

  var q: array[MAX_PROTOCOLS,Opt[uint64]]
  q[0] = Opt.none(uint64)
  q[1] = Opt.some(16'u64)
  for n in 2 .. po.protocols.len:
    q[n] = Opt.some(q[n-1].value + po.protocols[n-1].messages[^1].id)

  Dispatcher(protocolOffsets: q)


proc getProtocolStates(): array[MAX_PROTOCOLS,RootRef] =
  ## Pretend that all `getDispatcher()` list items are initialised
  var q: typeof(result)
  q[0] = RootRef(nil)
  q[1] = EthPeerState(initialized: true)
  q[2] = Eth69PeerState(initialized: true)
  q

# ------------------------------------------------------------------------------
# Public constructor(s)
# ------------------------------------------------------------------------------

proc init*(T: type ReplayEthState): T =
  ## For ethxx compatibility
  T(capa:  getDispatcher(),
    prots: getProtocolStates())

proc init*(
    T: type ReplayRunnerRef;
    ctx: BeaconCtxRef;
    startNoisy: uint;
    fakeImport: bool;
      ): T =
  ## ..
  # Enable protocols in dispatcher
  const info = "ReplayRunnerRef(): "
  if 10 <= ctx.handler.version:
    fatal info & "Need original handlers version",
      handlerVersion=ctx.handler.version
    quit(QuitFailure)

  T(ctx:        ctx,
    worker:     ctx.pool.handlers,
    ethState:   ReplayEthState.init(),
    startNoisy: startNoisy,
    fakeImport: fakeImport)


proc destroy*(run: ReplayRunnerRef) =
  discard

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
