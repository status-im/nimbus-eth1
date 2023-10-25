# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
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
      aVid*: VertexID
      aErr*: AristoError
    else:
      kErr*: KvtError

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

func isAristo*(be: CoreDbRef): bool =
  be.dbType in {AristoDbMemory, AristoDbRocks}

func errorPrint*(e: CoreDbErrorRef): string =
  if not e.isNil:
    let e = e.AristoCoreDbError
    result = if e.isAristo: "Aristo: " else: "Kvt: "
    result &= "ctx=\"" & $e.ctx & "\"" & ", "
    if e.isAristo:
      if e.aVid.isValid:
        result &= "vid=\"" & $e.aVid & "\"" & ", "
      result &= "error=\"" & $e.aErr & "\""
    else:
      result &= "error=\"" & $e.kErr & "\""

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
