# Nimbus
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import ../types, ../test_env, ../base_spec

export base_spec, test_env, types

type EngineSpec* = ref object of BaseSpec
  ttd*: int64
  chainFile*: string
  enableConfigureCLMock*: bool

method withMainFork*(tc: EngineSpec, fork: EngineFork): BaseSpec {.base.} =
  doAssert(false, "withMainFork not implemented")

method getName*(tc: EngineSpec): string {.base.} =
  doAssert(false, "getName not implemented")

method execute*(tc: EngineSpec, env: TestEnv): bool {.base.} =
  doAssert(false, "execute not implemented")
