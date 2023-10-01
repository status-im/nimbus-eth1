import
  ../types,
  ../test_env,
  ./helpers

type
  CancunTestContext* = object
    env*: TestEnv
    txPool*: TestBlobTxPool

  # Interface to represent a single step in a test vector
  TestStep* = ref object of RootRef
    # Executes the step

  # Contains the base spec for all cancun tests.
  CancunSpec* = ref object of BaseSpec
    getPayloadDelay*: int # Delay between FcU and GetPayload calls
    testSequence*: seq[TestStep]

method execute*(step: TestStep, ctx: CancunTestContext): bool {.base.} =
  true

method description*(step: TestStep): string {.base.} =
  discard
