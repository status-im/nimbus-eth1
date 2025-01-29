# Nimbus
# Copyright (c) 2024-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

{.push raises: [].}

import
  stint,
  eth/common/hashes,
  ../aristo as use_ari,
  ./base/[api_tracking, base_config, base_desc]

export stint, hashes

when CoreDbEnableApiJumpTable:
  discard
else:
  import
    ../aristo/[aristo_desc, aristo_path]

when CoreDbEnableApiTracking:
  import
    chronicles
  logScope:
    topics = "core_db"
  const
    logTxt = "API"

# ---------------

template call(api: AristoApiRef; fn: untyped; args: varargs[untyped]): untyped =
  when CoreDbEnableApiJumpTable:
    api.fn(args)
  else:
    fn(args)

# ------------------------------------------------------------------------------
# Public iterators
# ------------------------------------------------------------------------------

iterator slotPairs*(acc: CoreDbTxRef; accPath: Hash32): (seq[byte], UInt256) =
  acc.setTrackNewApi AccSlotPairsIt
  for (path,data) in acc.aTx.rightPairsStorage accPath:
    yield (acc.ctx.parent.ariApi.call(pathAsBlob, path), data)
  acc.ifTrackNewApi:
    debug logTxt, api, elapsed

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
