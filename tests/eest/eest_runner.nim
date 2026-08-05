# nimbus-execution-client
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  unittest2,
  ./path_handler

const eestTestFilter* {.strdefine.} = ""

func normSep(c: char): char {.inline.} =
  if c == '\\': '/' else: c

func globMatch*(path, filter: string): bool =
  if filter.len == 0:
    return true

  var
    p = 0
    s = 0
    starP = -1
    starS = 0

  while s < path.len:
    if p < filter.len and
        (filter[p] == '?' or filter[p].normSep == path[s].normSep):
      inc p
      inc s
    elif p < filter.len and filter[p] == '*':
      starP = p
      starS = s
      inc p
    elif starP >= 0:
      inc starS
      s = starS
      p = starP + 1
    else:
      return false

  while p < filter.len and filter[p] == '*':
    inc p

  p == filter.len

template runEESTSuite*(
    eestReleases: openArray[string],
    skipFiles: openArray[string],
    baseFolder: string,
    suiteName: string,
    eestType: string,
    testFilter = eestTestFilter,
    statelessEnabled = false,
    parallelEnabled = false
) =
  for eest in eestReleases:
    suite eest & ": " & suiteName:
      for filePath in walkDirRec(baseFolder / eest / eestType):
        when testFilter.len > 0:
          if not globMatch(filePath, testFilter):
            continue
        processFile(handleLongPath(filePath), statelessEnabled, parallelEnabled, @skipFiles)
