# Nimbus
# Copyright (c) 2021-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[tables, strutils, times],
  ../../execution_chain/utils/utils,
  unittest2

export
  tables, strutils, unittest2

type
  SimStat* = object
    ok*: int
    skipped*: int
    failed*: int
    failingCases*: seq[string]

proc inc*(stat: var SimStat, name: string, status: TestStatus) =
  echo name, ", ", status
  if status == OK:
    inc stat.ok
  elif status == SKIPPED:
    inc stat.skipped
  else:
    inc stat.failed
    stat.failingCases.add name

proc `$`*(stat: SimStat): string =
  if stat.failingCases.len > 0:
    result.add "  - Failing Cases:\n"
    for c in stat.failingCases:
      result.add "    - $1 \n" % [c]

  result.add "  - ok: $1, skipped: $2, failed: $3" % [$stat.ok, $stat.skipped, $stat.failed]

proc print*(stat: SimStat, dur: Duration, name: string) =
  var f = open(name & ".md", fmWrite)
  f.write("* " & name)
  f.write("\n")
  f.write($stat)
  f.write("\n")
  f.write("  - Elapsed: " & dur.short)
  f.write("\n")
  f.close()
