# Nimbus
# Copyright (c) 2018-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# ##################################################################
# Macros to facilitate opcode enum and table creation

import stew/shims/macros

macro fill_enum_table_holes*(enumTy: typedesc[enum], nop_filler, body: untyped): untyped =
  ## Fill the holes of table mapping for enum with a default value
  ##
  ## For example for enum
  ##   type Foo = enum
  ##     A = 0x00,
  ##     B = 0x01,
  ##     C = 0x02
  ## let foo = fill_enum_table_holes(Foo, 999):
  ##   [A: 10, C: 20]
  ##
  ## will result into `[A: 10, B: 999, C: 20]`

  # Sanity checks - body
  # StmtList
  #   Bracket
  #     ExprColonExpr
  #       Ident "Stop"
  #       Command
  #         Ident "fixed"
  #         Ident "GasZero"
  #     ExprColonExpr
  #       Ident "Add"
  #       Command
  #         Ident "fixed"
  #         Ident "GasVeryLow"
  body[0].expectKind(nnkBracket)

  let
    opctable = body[0]

  result = nnkBracket.newTree()
  var
    body_idx = 0

  for field in enumFields(enumTy):
    opctable[body_idx].expectKind(nnkExprColonExpr)
    if eqIdent(field.name, opctable[body_idx][0]):
      result.add opctable[body_idx]
      inc body_idx
    else:
      result.add nop_filler
