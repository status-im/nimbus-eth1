# Nimbus
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  eth/common/blocks,
  eth/common/receipts,
  ../../../db/core_db

type
  BlockDesc* = object
    blk*     : Block
    txFrame* : CoreDbTxRef
    receipts*: seq[Receipt]
    hash*    : Hash32

  BlockPos* = object
    branch*: BranchRef
    index* : int

  BranchRef* = ref object
    blocks*: seq[BlockDesc]
    parent*: BranchRef
      # If parent.isNil: it is a base branch

func tailNumber*(brc: BranchRef): BlockNumber =
  brc.blocks[0].blk.header.number

func headNumber*(brc: BranchRef): BlockNumber =
  brc.blocks[^1].blk.header.number

func tailHash*(brc: BranchRef): Hash32 =
  brc.blocks[0].hash

func headHash*(brc: BranchRef): Hash32 =
  brc.blocks[^1].hash

func len*(brc: BranchRef): int =
  brc.blocks.len

func headTxFrame*(brc: BranchRef): CoreDbTxRef =
  brc.blocks[^1].txFrame

func tailHeader*(brc: BranchRef): Header =
  brc.blocks[0].blk.header

func headHeader*(brc: BranchRef): Header =
  brc.blocks[^1].blk.header

func append*(brc: BranchRef, blk: BlockDesc) =
  brc.blocks.add(blk)

func lastBlockPos*(brc: BranchRef): BlockPos =
  BlockPos(
    branch: brc,
    index : brc.len - 1,
  )

func `==`*(a, b: BranchRef): bool =
  a.headHash == b.headHash

func hasHashAndNumber*(brc: BranchRef, hash: Hash32, number: BlockNumber): bool =
  for i in 0..<brc.len:
    if brc.blocks[i].hash == hash and brc.blocks[i].blk.header.number == number:
      return true

func branch*(header: Header, hash: Hash32, txFrame: CoreDbTxRef): BranchRef =
  BranchRef(
    blocks: @[BlockDesc(
      blk: Block(header: header),
      txFrame: txFrame,
      hash: hash,
      )
    ]
  )

func branch*(parent: BranchRef, blk: Block,
             hash: Hash32, txFrame: CoreDbTxRef,
             receipts: sink seq[Receipt]): BranchRef =
  BranchRef(
    blocks: @[BlockDesc(
      blk: blk,
      txFrame: txFrame,
      receipts: move(receipts),
      hash: hash,
      )
    ],
    parent: parent,
  )

func txFrame*(loc: BlockPos): CoreDbTxRef =
  loc.branch.blocks[loc.index].txFrame

func header*(loc: BlockPos): Header =
  loc.branch.blocks[loc.index].blk.header

func blk*(loc: BlockPos): Block =
  loc.branch.blocks[loc.index].blk

func number*(loc: BlockPos): BlockNumber =
  loc.branch.blocks[loc.index].blk.header.number

func hash*(loc: BlockPos): Hash32 =
  loc.branch.blocks[loc.index].hash

func parentHash*(loc: BlockPos): Hash32 =
  loc.branch.blocks[loc.index].blk.header.parentHash

func tx*(loc: BlockPos, index: uint64): Transaction =
  loc.branch.blocks[loc.index].blk.transactions[index]

func isHead*(loc: BlockPos): bool =
  loc.index == loc.branch.len - 1

func lastBlockPos*(loc: BlockPos): BlockPos =
  loc.branch.lastBlockPos

func appendBlock*(loc: BlockPos,
             blk: Block,
             blkHash: Hash32,
             txFrame: CoreDbTxRef,
             receipts: sink seq[Receipt]) =
  loc.branch.append(BlockDesc(
    blk     : blk,
    txFrame : txFrame,
    receipts: move(receipts),
    hash    : blkHash,
  ))

iterator transactions*(loc: BlockPos): Transaction =
  for tx in loc.branch.blocks[loc.index].blk.transactions:
    yield tx
