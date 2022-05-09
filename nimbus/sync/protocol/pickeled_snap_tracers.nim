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
  tracePacket "<< " & prettySnapProtoName & " Received " & msg,
    `args`

template traceGot*(msg: static[string], args: varargs[untyped]) =
  tracePacket "<< " & prettySnapProtoName & " Got " & msg,
    `args`

template traceProtocolViolation*(msg: static[string], args: varargs[untyped]) =
  tracePacketError "<< " & prettySnapProtoName & " Protocol violation, " & msg,
    `args`

template traceRecvError*(msg: static[string], args: varargs[untyped]) =
  traceNetworkError "<< " & prettySnapProtoName & " Error " & msg,
    `args`

template traceTimeoutWaiting*(msg: static[string], args: varargs[untyped]) =
  traceTimeout "<< " & prettySnapProtoName & " Timeout waiting " & msg,
    `args`

template traceSending*(msg: static[string], args: varargs[untyped]) =
  tracePacket ">> " & prettySnapProtoName & " Sending " & msg,
    `args`

template traceReplying*(msg: static[string], args: varargs[untyped]) =
  tracePacket ">> " & prettySnapProtoName & " Replying " & msg,
    `args`

# End
