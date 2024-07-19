# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[sets],
  eth/common/eth_types as common,
  ".."/[types, stack],
  ../interpreter/op_codes,
  ../../db/access_list,
  ../evm_errors

type AccessListTracer* = ref object of TracerRef
  list: access_list.AccessList
  excl: HashSet[EthAddress]

proc new*(
    T: type AccessListTracer,
    acl: common.AccessList,
    sender: EthAddress,
    to: EthAddress,
    precompiles: openArray[EthAddress],
): T =
  let act = T()
  act.excl.incl sender
  act.excl.incl to

  for address in precompiles:
    act.excl.incl address

  for acp in acl:
    if acp.address notin act.excl:
      act.list.add acp.address
    for slot in acp.storageKeys:
      act.list.add(acp.address, UInt256.fromBytesBE(slot))

  act

# Opcode level
method captureOpStart*(
    act: AccessListTracer,
    c: Computation,
    fixed: bool,
    pc: int,
    op: Op,
    gas: GasInt,
    depth: int,
): int {.gcsafe.} =
  let stackLen = c.stack.len
  if (op in [Sload, Sstore]) and (stackLen >= 1):
    let slot = c.stack.peekInt().expect("stack is not empty")
    act.list.add(c.msg.contractAddress, slot)

  if (op in [ExtCodeCopy, ExtCodeHash, ExtCodeSize, Balance, SelfDestruct]) and
      (stackLen >= 1):
    let address = c.stack.peekAddress().expect("stack is not empty")
    if address notin act.excl:
      act.list.add address

  if (op in [DelegateCall, Call, StaticCall, CallCode]) and (stackLen >= 5):
    let address = c.stack[^2, EthAddress].expect("stack contains more than 5 elements")
    if address notin act.excl:
      act.list.add address

  # AccessListTracer is not using captureOpEnd
  # no need to return op index

func equal*(ac: AccessListTracer, other: AccessListTracer): bool =
  ac.list.equal(other.list)

func accessList*(ac: AccessListTracer): common.AccessList =
  ac.list.getAccessList()
