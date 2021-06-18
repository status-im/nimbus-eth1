# Nimbus
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/[tables, strutils, unittest],
  testutils/markdown_reports

export
  tables, strutils, unittest,
  markdown_reports

template runTest*(suiteName: string, caseFolder: string, body: untyped) =
  disableParamFiltering()
  suite suiteName:
    var status = initOrderedTable[string, OrderedTable[string, Status]]()
    for fileName {.inject.} in walkDirRec(
                    caseFolder, yieldFilter = {pcFile,pcLinkToFile}):

      if not fileName.endsWith(".json"):
        continue

      let (folder, name) = fileName.splitPath()
      let last = folder.splitPath().tail
      if last notin status:
        status[last] = initOrderedTable[string, Status]()

      test fileName:
        # we set this here because exceptions might be raised in the handler
        status[last][name] = Status.Fail
        body
        if testStatusIMPL == OK:
          status[last][name] = Status.OK
        elif testStatusIMPL == SKIPPED:
          status[last][name] = Status.Skip

    generateReport(suiteName, status)
