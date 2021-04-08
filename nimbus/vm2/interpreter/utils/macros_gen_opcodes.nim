# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# ##################################################################
# Macros to facilitate opcode enum and table creation

import macros, strformat, strutils

# Due to https://github.com/nim-lang/Nim/issues/8007, we can't
# use compile-time Tables of object variants, so instead, we use
# const arrays to map Op --> gas prices.
# Arrays require an enum without hole. This macro will fill the holes
# in the enum.

# This has an added benefits that we can use computed gotos (direct threaded interpreter)
# instead of call or subroutine threading to dispatch opcode.
# see: https://github.com/nim-lang/Nim/issues/7699 (computed gotos, bad codegen with enum with holes)
# see: https://github.com/status-im/nimbus/wiki/Interpreter-optimization-resources
#      for interpreter dispatch strategies

macro fill_enum_holes*(body: untyped): untyped =
  ## Fill the holes of an enum
  ## For example
  ##   type Foo = enum
  ##     A = 0x00,
  ##     B = 0x10

  # Sanity checks
  #
  # StmtList
  #   TypeSection
  #     TypeDef
  #       PragmaExpr
  #         Postfix
  #           Ident "*"
  #           Ident "Op"
  #         Pragma
  #           Ident "pure"
  #       Empty
  #       EnumTy
  #         Empty
  #         EnumFieldDef
  #           Ident "Stop"
  #           IntLit 0
  #         EnumFieldDef
  #           Ident "Add"
  #           IntLit 1
  body[0].expectKind(nnkTypeSection)
  body[0][0][2].expectKind(nnkEnumTy)

  let opcodes = body[0][0][2]

  # We will iterate over all the opcodes
  # check if the i-th value is declared, if not add a no-op
  # and accumulate that in a "dense opcodes" declaration

  var
    opcode = 0
    holes_idx = 1
    dense_opcs = nnkEnumTy.newTree()
  dense_opcs.add newEmptyNode()

  # Iterate on the enum with holes
  while holes_idx < opcodes.len:
    let curr_ident = opcodes[holes_idx]

    if curr_ident.kind in {nnkIdent, nnkEmpty} or
      (curr_ident.kind == nnkEnumFieldDef and
      curr_ident[1].intVal == opcode):

      dense_opcs.add curr_ident
      inc holes_idx
    else:
      dense_opcs.add newIdentNode(&"Nop0x{opcode.toHex(2)}")

    inc opcode

  result = body
  result[0][0][2] = dense_opcs

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
    enumImpl = enumTy.getType[1]
    opctable = body[0]

  result = nnkBracket.newTree()
  var
    opcode = 1 # enumImpl[0] is an empty node
    body_idx = 0

  while opcode < enumImpl.len:
    opctable[body_idx].expectKind(nnkExprColonExpr)
    if eqIdent(enumImpl[opcode], opctable[body_idx][0]):
      result.add opctable[body_idx]
      inc body_idx
    else:
      result.add nop_filler
    inc opcode
