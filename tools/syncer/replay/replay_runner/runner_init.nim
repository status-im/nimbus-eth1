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
  ../../../../execution_chain/networking/[p2p, p2p_peers, peer_pool],
  ../../../../execution_chain/sync/wire_protocol,
  ./runner_desc

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


proc init(T: type ReplayEthState): T =
  ## For ethxx compatibility
  T(capa:  getDispatcher(),
    prots: getProtocolStates())

# ------------------------------------------------------------------------------
# Public constructor(s)
# ------------------------------------------------------------------------------

proc initRunner*(rpl: ReplayRunnerRef) =
  ## Initialise dispatcher
  const info = "ReplayRunnerRef(): "
  if ReplayRunnerID != rpl.ctx.handler.version:
    fatal info & "Need original handlers version",
      handlerVersion=rpl.ctx.handler.version
    quit(QuitFailure)

  rpl.ethState = ReplayEthState.init()


proc destroyRunner*(run: ReplayRunnerRef) =
  discard

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
