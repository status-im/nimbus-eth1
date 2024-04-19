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
  std/[algorithm, os, sequtils],
  eth/common,
  results,
  ../../nimbus/utils/prettify,
  ../../nimbus/db/aristo/aristo_profile,
  ../replay/pp

# ------------------------------------------------------------------------------
# Private helpers
# ------------------------------------------------------------------------------

func pp(
    w: AristoDbProfStats,
    spaced = false;
    count = true;
      ): string =
  result = "("
  if w.count < 2:
    result &= w.mean.pp
  else:
    let space = if spaced: " " else: ""
    if count:
      result &= $w.count
    else:
      result &= w.total.pp
    result &= "," & space & w.mean.pp
    if w.devRatio != 0.0: # when all items are the same
      let dr = if 0.2 < w.devRatio: w.devRatio.toPC(0) else: w.devRatio.toPC(1)
      result &= space & "±" & space & dr
  result &= ")"

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

# ------------------------------------------------------------------------------
# Public helpers
# ------------------------------------------------------------------------------

proc findFilePathHelper*(
    file: string;
    baseDir: openArray[string];
    repoDir: openArray[string];
    subDir: openArray[string];
      ): Result[string,void] =
  for dir in baseDir:
    if dir.dirExists:
      for repo in repoDir:
        if (dir / repo).dirExists:
          for sub in subDir:
            if (dir / repo / sub).dirExists:
              let path = dir / repo / sub / file
              if path.fileExists:
                return ok(path)
  echo "*** File not found \"", file, "\"."
  err()


proc profilingPrinter*(
    data: AristoDbProfListRef;
    names: openArray[string];
    header: string;
    indent = 4;
      ): string =
  if not data.isNil:
    let
      pfx = indent.toPfx
      pfx2 = pfx & "  "
    result = header & ":"
    let names = @names

    proc pp(w: uint, spaced: bool): string =
      let (a,z) = (if data.list[w].masked: ("[","]") else: ("",""))
      a & names[w] & data.stats(w).pp(spaced=spaced) & z

    result &= "\n" & pfx & "by accumulated duration per procedure"
    for (ela,fns) in data.byElapsed:
      result &= pfx2 & ela.pp & ": " & fns.mapIt(it.pp true).sorted.join(", ")

    result &=  "\n" & pfx & "by number of visits"
    for (count,fns) in data.byVisits:
      result &= pfx2 & $count & ": " & fns.mapIt(it.pp false).sorted.join(", ")

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
