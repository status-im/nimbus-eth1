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

# ---------------

func toError*(e: KvtError; s: string; error = Unspecified): CoreDbError =
  CoreDbError(
    error:    error,
    ctx:      s,
    isAristo: false,
    kErr:     e)

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
