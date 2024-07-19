# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import ../types, ../test_env, ./helpers

type
  CancunTestContext* = object
    env*: TestEnv
    txPool*: TestBlobTxPool

  # Interface to represent a single step in a test vector
  TestStep* = ref object of RootRef # Executes the step

  # Contains the base spec for all cancun tests.
  CancunSpec* = ref object of BaseSpec
    getPayloadDelay*: int # Delay between FcU and GetPayload calls
    testSequence*: seq[TestStep]

method execute*(step: TestStep, ctx: CancunTestContext): bool {.base.} =
  true

method description*(step: TestStep): string {.base.} =
  discard
