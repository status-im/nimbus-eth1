# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  std/[os, osproc],
  unittest2,
  ./eest_helpers,
  ./eest_engine

const
  baseFolder = "tests/fixtures"
  eestType = "engine_tests"
  eestReleases = [
    "eest_develop",
    "eest_static",
    # "eest_stable",
    # "eest_devnet"
  ]

const skipFiles = [
  "CALLBlake2f_MaxRounds.json", # Doesn't work in github CI
]

runEESTSuite(
  eestReleases,
  skipFiles,
  baseFolder,
  eestType
)