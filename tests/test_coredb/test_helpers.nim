# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or
# distributed except according to those terms.

import
  std/[sequtils, times],
  eth/common,
  ../../nimbus/utils/prettify,
  ../replay/pp

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Public pretty printing
# ------------------------------------------------------------------------------

proc say*(noisy = false; pfx = "***"; args: varargs[string, `$`]) =
  if noisy:
    if args.len == 0:
      echo "*** ", pfx
    elif 0 < pfx.len and pfx[^1] != ' ':
      echo pfx, " ", args.toSeq.join
    else:
      echo pfx, args.toSeq.join

proc toPfx*(indent: int): string =
  "\n" & " ".repeat(indent)

func pp*(
    w: tuple[n: int, mean: Duration, stdDev: Duration, devRatio: float];
    spaced = false;
      ): string =
  result = "("
  if w.n < 2:
    result &= w.mean.pp
  else:
    let space = if spaced: " " else: ""
    result &= $w.n & "," & space & w.mean.pp
    if w.devRatio != 0.0: # when all items are the same
      let dr = if 0.2 < w.devRatio: w.devRatio.toPC(0) else: w.devRatio.toPC(1)
      result &= space & "±" & space & dr
  result &= ")"

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
