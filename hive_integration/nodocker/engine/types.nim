import
  std/options,
  test_env,
  unittest2,
  web3/ethtypes,
  ../../../nimbus/rpc/merge/mergeutils

export ethtypes

import eth/common/eth_types as common_eth_types

type
  TestSpec* = object
    name*: string
    run*: proc(t: TestEnv): TestStatus
    ttd*: int64
    chainFile*: string
    slotsToFinalized*: int
    slotsToSafe*: int
    enableAuth*: bool

template testCond*(expr: untyped) =
  if not (expr):
    when result is bool:
      return false
    else:
      return TestStatus.Failed

template testCond*(expr, body: untyped) =
  if not (expr):
    body
    when result is bool:
      return false
    else:
      return TestStatus.Failed

proc `$`*(x: Option[common_eth_types.Hash256]): string =
  if x.isNone:
    "none"
  else:
    $x.get()

proc `$`*(x: Option[BlockHash]): string =
  if x.isNone:
    "none"
  else:
    $x.get()

proc `$`*(x: Option[PayloadID]): string =
  if x.isNone:
    "none"
  else:
    x.get().toHex
