# fluffy
# Copyright (c) 2024-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import ssz_serialization/types, stew/byteutils

type
  YamlTestProofBellatrix* = object
    execution_block_header*: string # Not part of the actual proof
    execution_block_proof*: array[11, string]
    beacon_block_root*: string
    beacon_block_proof*: array[14, string]
    slot*: uint64

  YamlTestProofCapella* = object
    execution_block_header*: string # Not part of the actual proof
    execution_block_proof*: array[11, string]
    beacon_block_root*: string
    beacon_block_proof*: array[13, string]
    slot*: uint64

  YamlTestProofDeneb* = object
    execution_block_header*: string # Not part of the actual proof
    execution_block_proof*: array[12, string]
    beacon_block_root*: string
    beacon_block_proof*: array[13, string]
    slot*: uint64

proc fromHex*[n](T: type array[n, Digest], a: array[n, string]): T =
  var res: T
  for i in 0 ..< a.len:
    res[i] = Digest.fromHex(a[i])

  res

proc toHex*[n](a: array[n, Digest], T: type array[n, string]): T =
  var res: T
  for i in 0 ..< a.len:
    res[i] = to0xHex(a[i].data)

  res
