# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  strformat, macros, sequtils,
  ../types, ../constants, ../errors, ../computation, .. / vm / [stack, code_stream], .. / utils / [padding, bytes], stint

{.this: computation.}
{.experimental.}

using
  computation: var BaseComputation

proc pop*(computation) =
  discard stack.popInt()

macro pushXX(size: static[int]): untyped =
  let computation = ident("computation")
  let value = ident("value")
  let name = ident(&"push{size}")
  result = quote:
    proc `name`*(`computation`: var BaseComputation) =
      let `value` = `computation`.code.read(`size`)
      let stripped = `value`.toString.strip(0.char)
      if stripped.len == 0:
        `computation`.stack.push(0.u256)
      else:
        let paddedValue = `value`.padRight(`size`, 0.byte)
        `computation`.stack.push(paddedValue)


pushXX(1)
pushXX(2)
pushXX(3)
pushXX(4)
pushXX(5)
pushXX(6)
pushXX(7)
pushXX(8)
pushXX(9)
pushXX(10)
pushXX(11)
pushXX(12)
pushXX(13)
pushXX(14)
pushXX(15)
pushXX(16)
pushXX(17)
pushXX(18)
pushXX(19)
pushXX(20)
pushXX(21)
pushXX(22)
pushXX(23)
pushXX(24)
pushXX(25)
pushXX(26)
pushXX(27)
pushXX(28)
pushXX(29)
pushXX(30)
pushXX(31)
pushXX(32)
