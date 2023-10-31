import
  ../types,
  ../test_env,
  ../base_spec

export
  base_spec,
  test_env,
  types

type
  EngineSpec* = ref object of BaseSpec
    ttd*: int64
    chainFile*: string

method withMainFork*(tc: EngineSpec, fork: EngineFork): BaseSpec {.base.} =
  doAssert(false, "withMainFork not implemented")

method getName*(tc: EngineSpec): string {.base.} =
  doAssert(false, "getName not implemented")

method execute*(tc: EngineSpec, env: TestEnv): bool {.base.} =
  doAssert(false, "execute not implemented")
