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
  "../../.."/[aristo, kvt],
  ../../base/base_desc

type
  AristoApiRlpError* = object of CoreDbApiError
    ## For re-routing exceptions in iterator closure

  AristoCoreDbError* = ref object of CoreDbErrorRef
    ## Error return code
    ctx*: string     ## Context where the exception or error occured
    case isAristo*: bool
    of true:
      root*: VertexID
      aErr*: AristoError
    else:
      kErr*: KvtError

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

func isAristo*(be: CoreDbRef): bool =
  be.dbType in {AristoDbMemory, AristoDbRocks}

func toStr*(n: VertexID): string =
  result = "$"
  if n.isValid:
    result &= n.uint64.toHex.strip(
      leading=true, trailing=false, chars={'0'}).toLowerAscii
  else:
    result &= "ø"

func errorPrint*(e: CoreDbErrorRef): string =
  if not e.isNil:
    let e = e.AristoCoreDbError
    result = if e.isAristo: "Aristo" else: "Kvt"
    result &= ", ctx=" & $e.ctx & ", "
    if e.isAristo:
      if e.root.isValid:
        result &= "root=" & e.root.toStr & ", "
      result &= "error=" & $e.aErr
    else:
      result &= "error=" & $e.kErr

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
