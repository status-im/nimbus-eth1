# Nimbus - Types, data structures and shared utilities used in network sync
#
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

import
  chronicles,
  eth/common/eth_types,
  stew/byteutils

const
  tracePackets*         = true
    ## Whether to `trace` log each sync network message.
  traceGossips*         = false
    ## Whether to `trace` log each gossip network message.
  traceHandshakes*      = true
    ## Whether to `trace` log each network handshake message.
  traceTimeouts*        = true
    ## Whether to `trace` log each network request timeout.
  traceNetworkErrors*   = true
    ## Whether to `trace` log each network request error.
  tracePacketErrors*    = true
    ## Whether to `trace` log each messages with invalid data.
  traceIndividualNodes* = false
    ## Whether to `trace` log each trie node, account, storage, receipt, etc.

template tracePacket*(msg: static[string], args: varargs[untyped]) =
  if tracePackets: trace `msg`, `args`
template traceGossip*(msg: static[string], args: varargs[untyped]) =
  if traceGossips: trace `msg`, `args`
template traceTimeout*(msg: static[string], args: varargs[untyped]) =
  if traceTimeouts: trace `msg`, `args`
template traceNetworkError*(msg: static[string], args: varargs[untyped]) =
  if traceNetworkErrors: trace `msg`, `args`
template tracePacketError*(msg: static[string], args: varargs[untyped]) =
  if tracePacketErrors: trace `msg`, `args`

func toHex*(hash: Hash256): string =
  ## Shortcut for buteutils.toHex(hash.data)
  hash.data.toHex

func traceStep*(request: BlocksRequest): string =
  var str = if request.reverse: "-" else: "+"
  if request.skip < high(typeof(request.skip)):
    return str & $(request.skip + 1)
  return static($(high(typeof(request.skip)).u256 + 1))

# End
