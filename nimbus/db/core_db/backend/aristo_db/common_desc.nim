# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  std/strutils,
  ../../../../errors,
  "../../.."/aristo,
  ../../base/base_desc

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

func isAristo*(db: CoreDbRef): bool =
  db.dbType in {AristoDbMemory, AristoDbRocks, AristoDbVoid}

func toStr*(n: VertexID): string =
  result = "$"
  if n.isValid:
    result &= n.uint64.toHex.strip(
      leading=true, trailing=false, chars={'0'}).toLowerAscii
  else:
    result &= "ø"

func errorPrint*(e: CoreDbErrorRef): string =
  if not e.isNil:
    result = if e.isAristo: "Aristo" else: "Kvt"
    result &= ", ctx=" & $e.ctx & ", "
    if e.isAristo:
      if e.vid.isValid:
        result &= "vid=" & e.vid.toStr & ", "
      result &= "error=" & $e.aErr
    else:
      result &= "error=" & $e.kErr

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
