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

template runEESTSuite*(
    eestReleases: openArray[string],
    skipFiles: openArray[string],
    baseFolder: string,
    suiteName: string,
    eestType: string,
    statelessEnabled = false,
    parallelEnabled = false
) =
  for eest in eestReleases:
    suite eest & ": " & suiteName:
      for filePath in walkDirRec(baseFolder / eest / eestType):
        processFile(handleLongPath(filePath), statelessEnabled, parallelEnabled, @skipFiles)
