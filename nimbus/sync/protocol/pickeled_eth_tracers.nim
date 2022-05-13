# Nimbus - Rapidly converge on and track the canonical chain head of each peer
#
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

template traceReceived*(msg: static[string], args: varargs[untyped]) =
  tracePacket "<< " & prettyEthProtoName & " Received " & msg,
    `args`

template traceGot*(msg: static[string], args: varargs[untyped]) =
  tracePacket "<< " & prettyEthProtoName & " Got " & msg,
    `args`

template traceProtocolViolation*(msg: static[string], args: varargs[untyped]) =
  tracePacketError "<< " & prettyEthProtoName & " Protocol violation, " & msg,
    `args`

template traceRecvError*(msg: static[string], args: varargs[untyped]) =
  traceNetworkError "<< " & prettyEthProtoName & " Error " & msg,
    `args`

template traceTimeoutWaiting*(msg: static[string], args: varargs[untyped]) =
  traceTimeout "<< " & prettyEthProtoName & " Timeout waiting " & msg,
    `args`

template traceSending*(msg: static[string], args: varargs[untyped]) =
  tracePacket ">> " & prettyEthProtoName & " Sending " & msg,
    `args`

template traceReplying*(msg: static[string], args: varargs[untyped]) =
  tracePacket ">> " & prettyEthProtoName & " Replying " & msg,
    `args`

template traceDelaying*(msg: static[string], args: varargs[untyped]) =
  tracePacket ">>" & prettyEthProtoName & " Delaying " & msg,
    `args`

template traceGossipDiscarding*(msg: static[string], args: varargs[untyped]) =
  traceGossip "<< " & prettyEthProtoName & " Discarding " & msg,
    `args`

template traceDiscarding*(msg: static[string], args: varargs[untyped]) =
  tracePacket "<< " & prettyEthProtoName & " Discarding " & msg,
    `args`

# End
