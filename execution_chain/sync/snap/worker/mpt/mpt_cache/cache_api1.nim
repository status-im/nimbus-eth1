# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed

{.push raises: [].}

import
  ./[cache_const, cache_desc, cache_r_cmd]

# ------------------------------------------------------------------------------
# Public API for internal use
# ------------------------------------------------------------------------------

template get1*(
    db: MptAsmRef;
    col: MptAsmCol;
      ): untyped =
  db.adb.rGet @[byte col]

template put1*(
    db: MptAsmRef;
    col: MptAsmCol;
    data: openArray[byte];
      ): untyped =
  db.adb.rPut(@[byte col], data)

template del1*(
    db: MptAsmRef;
    col: MptAsmCol;
      ): untyped =
  db.adb.rDel @[byte col]

template clr1*(
    db: MptAsmRef;
    col: MptAsmCol;
      ): untyped =
  db.adb.rClear col

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
