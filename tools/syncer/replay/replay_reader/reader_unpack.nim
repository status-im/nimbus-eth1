# Nimbus
# Copyright (c) 2025-2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

## Replay environment

{.push raises:[].}

import
  std/[net, strutils],
  pkg/[chronicles, chronos, eth/common, results, stew/interval_set],
  pkg/json_serialization/pkg/results,
  pkg/eth/common/eth_types_json_serialization,
  ../replay_desc,
  ./reader_helpers

logScope:
  topics = "replay reader"

type
  JsonKind = object
    ## For extracting record type only (use with flavor: `SingleField`)
    kind: TraceRecType

  BnPair = object
    ## For parsing `BnRange`
    least: BlockNumber
    last: BlockNumber

const
  DontQuit = low(int)
    ## To be used with `onCloseException()`

# ------------------------------------------------------------------------------
# Private JSON config
# ------------------------------------------------------------------------------

createJsonFlavor SingleField,
  requireAllFields = false

JsonKind.useDefaultSerializationIn SingleField

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

template onException(
    info: static[string];
    quitCode: static[int];
    code: untyped) =
  try:
    code
  except CatchableError as e:
    const blurb = info & ": Replay stream reader exception"
    when quitCode == DontQuit:
      error blurb, error=($e.name), msg=e.msg
    else:
      fatal blurb & " -- STOP", error=($e.name), msg=e.msg
      quit(quitCode)

func fromHex(c: char): int =
  case c
  of '0'..'9': ord(c) - ord('0')
  of 'a'..'f': ord(c) - ord('a') + 10
  of 'A'..'F': ord(c) - ord('A') + 10
  else: -1


proc toIp4Address(s: string): Opt[IpAddress] =
  ## Parse IPv4 dotted address string
  ##
  # Make sure that `nibbles.len` == 4
  let dgts = s.split('.')
  if dgts.len != 4:
    return err()

  var ip4 = IpAddress(family: IpAddressFamily.IPv4)
  for n in 0 .. 3:
    "toIp4Address()".onException(DontQuit):
      ip4.address_v4[n] = dgts[n].parseUInt().uint8
      continue
    return err()
  ok(move ip4)


proc toIp6Address(s: string): Opt[IpAddress] =
  ## Parse IPv6 address string
  ##
  # Make sure that `nibbles.len` == 8
  var xDgts = s.split(':')
  if xDgts.len < 3 or 8 < xDgts.len:
    return err()
  # Take care of shortcuts like "::ffff:6366:d1" or "::1"
  var (start, pfxLen) = (0, 0)
  if xDgts.len < 8:
    # A shortcut for missing zeros must start with "::"
    if xDgts[0].len == 0 and xDgts[1].len == 0:
      (start, pfxLen) = (2, 8 - xDgts.len)
    else:
      return err()

  var ip6 = IpAddress(family: IpAddressFamily.IPv6)
  for n in start ..< xDgts.len:
    if xDgts[n].len != 0:
      "toIp6Address()".onException(DontQuit):
         let
           u16 = xDgts[n].parseHexInt().uint16
           pos = 2 * (pfxLen + n)
         ip6.address_v6[pos] = (u16 shr 8).uint8
         ip6.address_v6[pos+1] = (u16 and 255).uint8
         continue
      return err()
  ok(move ip6)

# ------------------------------------------------------------------------------
# Private JSON mixin helpers for decoder
# ------------------------------------------------------------------------------

proc readValue(
    r: var JsonReader;
    v: var chronos.Duration;
      ) {.raises: [IOError, SerializationError].} =
  let kind = r.tokKind
  case kind:
  of JsonValueKind.Number:
    var u64: uint64
    r.readValue(u64)
    v = nanoseconds(cast[int64](u64))
  else:
    r.raiseUnexpectedValue("Invalid Duiration value type: " & $kind)

proc readValue(
    r: var JsonReader;
    v: var IpAddress;
      ) {.raises: [IOError, SerializationError].} =
  let kind = r.tokKind
  case kind:
  of JsonValueKind.String:
    var ipString: string
    r.readValue(ipString)
    if 0 <= ipString.find('.'):
      v = ipString.toIp4Address.valueOr:
        r.raiseUnexpectedValue("Invalid IPv4 address value: " & $ipString)
    else:
      v = ipString.toIp6Address.valueOr:
        r.raiseUnexpectedValue("Invalid IPv6 address value: " & $ipString)
  else:
    r.raiseUnexpectedValue("Invalid IP address value type: " & $kind)

proc readValue(
    r: var JsonReader;
    v: var Port;
      ) {.raises: [IOError, SerializationError].} =
  let kind = r.tokKind
  case kind:
  of JsonValueKind.Number:
    var u64: uint64
    r.readValue(u64)
    if 0xffffu < u64:
      r.raiseUnexpectedValue("Invalid Port value: " & $u64)
    v = Port(cast[uint16](u64))
  else:
    r.raiseUnexpectedValue("Invalid Port value type: " & $kind)

proc readValue(
    r: var JsonReader;
    v: var UInt256;
      ) {.raises: [IOError, SerializationError].} =
  ## Modified copy from `common.chain_config.nim` needed for parsing
  ## a `NetworkId` type value.
  ##
  var (accu, ok) = (0.u256, true)
  let kind = r.tokKind
  case kind:
  of JsonValueKind.Number:
    try:
      r.customIntValueIt:
        accu = accu * 10 + it.u256
    except CatchableError:
      ok = false
  of JsonValueKind.String:
    try:
      var (sLen, base) = (0, 10)
      r.customStringValueIt:
        if ok:
          var num = it.fromHex
          if base <= num:
            ok = false # cannot be larger than base
          elif sLen < 2:
            if 0 <= num:
              accu = accu * base.u256 + num.u256
            elif sLen == 1 and it in {'x', 'X'}:
              base = 16 # handle "0x" prefix
            else:
              ok = false
            sLen.inc
          elif num < 0:
            ok = false # not a hex digit
          elif base == 10:
            accu = accu * 10 + num.u256
          else:
            accu = accu * 16 + num.u256
    except CatchableError:
      r.raiseUnexpectedValue("UInt256 string parse error")
  else:
    r.raiseUnexpectedValue("Invalid UInt256 value type: " & $kind &
      " (expect int or hex/int string)")
  if not ok:
    r.raiseUnexpectedValue("UInt256 parse error")
  v = accu

proc readValue(
    r: var JsonReader;
    v: var BnRange;
      ) {.raises: [IOError, SerializationError].} =
  let kind = r.tokKind
  case kind:
  of JsonValueKind.Object:
    var bnPair: BnPair
    r.readValue(bnPair)
    v = BnRange.new(bnPair.least, bnPair.last)
  else:
    r.raiseUnexpectedValue("Invalid BnRange value type: " & $kind)

# ------------------------------------------------------------------------------
# Private functions
# ------------------------------------------------------------------------------

proc getRecType(s: string; info: static[string]): TraceRecType =
  (info & ".getRecType()").onException(DontQuit):
    let j = SingleField.decode(s, JsonKind)
    return j.kind
  TraceRecType(0)

proc init(T: type; s: string; info: static[string]): T =
  (info & ".init()").onException(DontQuit):
    var rec = Json.decode(s, JTraceRecord[typeof result.bag])
    return T(recType: rec.kind, bag: rec.bag)
  T(nil)

# ------------------------------------------------------------------------------
# Public record decoder functions
# ------------------------------------------------------------------------------

proc unpack*(line: string): ReplayPayloadRef =
  ## Decode a JSON string argument `line` and convert it to an internal object.
  ## The function always returns a non-nil value.
  ##
  const info = "unpack"

  template replayTypeExpr(t: TraceRecType, T: type): untyped =
    ## Mixin for `withReplayTypeExpr()`
    when t == TraceRecType(0):
      return T(recType: TraceRecType(0))
    else:
      return T.init(line, info)

  # Big switch for allocating different JSON parsers depending on record type.
  line.getRecType(info).withReplayTypeExpr()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
