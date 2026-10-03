# nimbus-execution-client
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  std/os,
  ./eest_runner,
  ./eest_t8n

from ./eest_shared_releases import eestReleases

const
  baseFolder = "tests/fixtures"
  suiteName = "Transition Tool Test"
  eestType = "blockchain_tests"

const skipFiles = [
  "",
]

runEESTSuite(
  eestReleases,
  skipFiles,
  baseFolder,
  suiteName,
  eestType,
  parallelEnabled = true
)
