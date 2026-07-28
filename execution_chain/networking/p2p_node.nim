# nimbus-execution-client
# Copyright (c) 2018-2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import
  std/[net, hashes, sets],
  stint,
  chronicles,
  eth/keccak/keccak,
  eth/common/keys,
  eth/enode/enode

export enode, sets

type
  NodeId* = UInt256

  Node* = ref object
    node*: ENode
    id*: NodeId

func toNodeId*(pk: PublicKey): NodeId =
  readUintBE[256](Keccak256.digest(pk.toRaw()).data)

func newNode*(pk: PublicKey, address: Address): Node =
  Node(node: ENode(pubkey: pk, address: address), id: pk.toNodeId())

func newNode*(enode: ENode): Node =
  Node(node: enode, id: enode.pubkey.toNodeId())

func `==`*(a, b: Node): bool =
  if a.isNil: b.isNil
  elif b.isNil: false
  else: a.id == b.id

func hash*(n: Node): Hash =
  hash(n.id)

func `$`*(n: Node): string =
  if n == nil:
    "Node[local]"
  else:
    "Node[" & $n.node.address.ip & ":" & $n.node.address.udpPort.uint16 & "]"

chronicles.formatIt(Node): $it
chronicles.formatIt(seq[Node]): $it
