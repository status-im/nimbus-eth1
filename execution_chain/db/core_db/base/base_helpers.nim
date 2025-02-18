# Nimbus
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.push raises: [].}

import
  "../.."/[aristo, kvt],
  ./base_desc

# ------------------------------------------------------------------------------
# Public constructor helper
# ------------------------------------------------------------------------------

proc bless*(db: CoreDbRef): CoreDbRef =
  ## Verify descriptor
  db

proc bless*(db: CoreDbRef; ctx: CoreDbCtxRef): CoreDbCtxRef =
  ctx.parent = db
  ctx

proc bless*(ctx: CoreDbCtxRef; dsc: CoreDbTxRef): auto =
  dsc.ctx = ctx
  dsc

# ------------------------------------------------------------------------------
# Public KVT helpers
# ------------------------------------------------------------------------------
template kvt*(tx: CoreDbTxRef): KvtDbRef =
  tx.ctx.kvt

# ---------------

func toError*(e: KvtError; s: string; error = Unspecified): CoreDbError =
  CoreDbError(
    error:    error,
    ctx:      s,
    isAristo: false,
    kErr:     e)

# ------------------------------------------------------------------------------
# Public Aristo helpers
# ------------------------------------------------------------------------------

template mpt*(tx: CoreDbTxRef): AristoDbRef =
  tx.ctx.mpt

# ---------------

func toError*(e: AristoError; s: string; error = Unspecified): CoreDbError =
  CoreDbError(
    error:    error,
    ctx:      s,
    isAristo: true,
    aErr:     e)

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
