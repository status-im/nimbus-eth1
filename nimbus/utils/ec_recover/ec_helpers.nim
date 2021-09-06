# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[sequtils, strutils],
  ../lru_cache,
  ./ec1recover as ec1,
  ./ec2recover as ec2

# ------------------------------------------------------------------------------
# Private, debugging ...
# ------------------------------------------------------------------------------

proc joinXX(s: string): string =
  if s.len <= 30:
    return s
  if (s.len and 1) == 0:
    result = s[0 ..< 8]
  else:
    result = "0" & s[0 ..< 7]
  result &= ".." & s[s.len-16 ..< s.len]

proc joinXX(q: seq[string]): string =
  q.join("").joinXX

proc pp(data: openArray[byte]): string =
  data.toSeq.mapIt(it.toHex(2)).joinXX

proc pp[K: ec1.EcKey32|ec2.EcKey](q: seq[K]): string =
  if 4 < q.len:
    result &= @[q[0].pp, q[1].pp, "..", q[^2].pp, q[^1].pp].join(" ")
  else:
    result &= q.mapIt(it.pp).join(" ")

# ------------------------------------------------------------------------------
# Public
# ------------------------------------------------------------------------------

proc `$`*(er: var ec1.EcRecover): string
    {.gcsafe, raises: [Defect,CatchableError].} =
  result = "#" & $er.len & "=<" &
    toSeq(er.keyItemPairs).mapIt(it[0]).pp & ">"

proc `$`*(er: var ec2.EcRecover): string
    {.gcsafe, raises: [Defect,CatchableError].} =
  result = "#" & $er.len & "=[" &
    toSeq(er.keyItemPairs).mapIt(it[0]).pp & "]"

proc similarKeys*(ec1: var ec1.EcRecover;
                  ec2: var ec2.EcRecover): Result[void,string]
    {.gcsafe, raises: [Defect,CatchableError].} =
  if ec1.len != ec2.len:
    return err("cache lengths differ")
  let
    q1 = toSeq(ec1.keyItemPairs).mapIt(it[0])
    q2 = toSeq(ec2.keyItemPairs).mapIt(it[0])
  if q1 != q2:
    for n in 0 ..< ec1.len:
      if q1[n] != q2[n]:
        return err($(n+1) & "-th items differ")
  ok()

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
