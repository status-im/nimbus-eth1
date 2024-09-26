# Nimbus
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at
#     https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at
#     https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed
# except according to those terms.

import
  stew/byteutils,
  ../../nimbus/core/chain/forked_chain,
  ../../nimbus/core/pow/difficulty,
  ../../nimbus/config,
  ../../nimbus/common,
  ../../nimbus/sync/beacon/skeleton_desc

const
  genesisFile = "tests/customgenesis/post-merge.json"

type
  Subchain* = object
    head*: uint64
    tail*: uint64

  TestEnv* = object
    conf* : NimbusConf
    chain*: ForkedChainRef

  CCModify = proc(cc: NetworkParams)

let
  block49* = BlockHeader(
    number: 49.BlockNumber
  )
  block49B* = BlockHeader(
    number: 49.BlockNumber,
    extraData: @['B'.byte]
  )
  block50* = BlockHeader(
    number: 50.BlockNumber,
    parentHash: block49.blockHash
  )
  block50B* = BlockHeader(
    number: 50.BlockNumber,
    parentHash: block49.blockHash,
    gasLimit: 999.GasInt,
  )
  block51* = BlockHeader(
    number: 51.BlockNumber,
    parentHash: block50.blockHash
  )

proc setupEnv*(extraValidation: bool = false, ccm: CCModify = nil): TestEnv =
  let
    conf = makeConfig(@[
      "--custom-network:" & genesisFile
    ])

  if ccm.isNil.not:
    ccm(conf.networkParams)

  let
    com = CommonRef.new(
      newCoreDbRef DefaultDbMemory,
      conf.networkId,
      conf.networkParams
    )
    chain = newForkedChain(com, com.genesisHeader, extraValidation = extraValidation)

  TestEnv(
    conf : conf,
    chain: chain,
  )

func subchain*(head, tail: uint64): Subchain =
  Subchain(head: head, tail: tail)

func header*(bn: uint64, temp, parent: BlockHeader, diff: uint64): BlockHeader =
  BlockHeader(
    number: bn.BlockNumber,
    parentHash : parent.blockHash,
    difficulty : diff.u256,
    timestamp  : parent.timestamp + 1,
    gasLimit   : temp.gasLimit,
    stateRoot  : temp.stateRoot,
    txRoot     : temp.txRoot,
    baseFeePerGas  : temp.baseFeePerGas,
    receiptsRoot   : temp.receiptsRoot,
    ommersHash     : temp.ommersHash,
    withdrawalsRoot: temp.withdrawalsRoot,
    blobGasUsed    : temp.blobGasUsed,
    excessBlobGas  : temp.excessBlobGas,
    parentBeaconBlockRoot: temp.parentBeaconBlockRoot,
  )

func header*(com: CommonRef, bn: uint64, temp, parent: BlockHeader): BlockHeader =
  result = header(bn, temp, parent, 0)
  result.difficulty = com.calcDifficulty(result.timestamp, parent)

func header*(bn: uint64, temp, parent: BlockHeader,
             diff: uint64, stateRoot: string): BlockHeader =
  result = header(bn, temp, parent, diff)
  result.stateRoot = Hash32(hextoByteArray[32](stateRoot))

func header*(com: CommonRef, bn: uint64, temp, parent: BlockHeader,
             stateRoot: string): BlockHeader =
  result = com.header(bn, temp, parent)
  result.stateRoot = Hash32(hextoByteArray[32](stateRoot))

func emptyBody*(): BlockBody =
  BlockBody(
    transactions: @[],
    uncles: @[],
    withdrawals: Opt.none(seq[Withdrawal]),
  )

template fillCanonical(skel, z, stat) =
  if z.status == stat and FillCanonical in z.status:
    let xx = skel.fillCanonicalChain()
    check xx.isOk
    if xx.isErr:
      debugEcho "FillCanonicalChain: ", xx.error
      break

template initSyncT*(skel, blk: untyped, r = false) =
  let x = skel.initSync(blk)
  check x.isOk
  if x.isErr:
    debugEcho "initSync:", x.error
    break
  let z = x.get
  check z.reorg == r

template setHeadT*(skel, blk, frc, r) =
  let x = skel.setHead(blk, frc)
  check x.isOk
  if x.isErr:
    debugEcho "setHead:", x.error
    break
  let z = x.get
  check z.reorg == r

template initSyncT*(skel, blk, r, stat) =
  let x = skel.initSync(blk)
  check x.isOk
  if x.isErr:
    debugEcho "initSync:", x.error
    break
  let z = x.get
  check z.reorg == r
  check z.status == stat
  fillCanonical(skel, z, stat)

template setHeadT*(skel, blk, frc, r, stat) =
  let x = skel.setHead(blk, frc)
  check x.isOk
  if x.isErr:
    debugEcho "setHead:", x.error
    break
  let z = x.get
  check z.reorg == r
  check z.status == stat
  fillCanonical(skel, z, stat)

template putBlocksT*(skel, blocks, numBlocks, stat) =
  let x = skel.putBlocks(blocks)
  check x.isOk
  if x.isErr:
    debugEcho "putBlocks: ", x.error
    break
  let z = x.get
  check z.number == numBlocks
  check z.status == stat
  fillCanonical(skel, z, stat)

template isLinkedT*(skel, r) =
  let x = skel.isLinked()
  check x.isOk
  if x.isErr:
    debugEcho "isLinked: ", x.error
    break
  check x.get == r

template getHeaderClean*(skel, headers) =
  for header in headers:
    var r = skel.getHeader(header.u64, true)
    check r.isOk
    check r.get.isNone
    r = skel.getHeader(header.blockHash, true)
    check r.isOk
    check r.get.isNone
