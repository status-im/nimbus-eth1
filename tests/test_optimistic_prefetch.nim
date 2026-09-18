# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

{.used.}

import
  std/[atomics, importutils, sequtils],
  unittest2,
  taskpools,
  stew/byteutils,
  eth/common/[keys, transaction_utils, block_access_lists],
  ../execution_chain/common,
  ../execution_chain/transaction,
  ../execution_chain/constants,
  ../execution_chain/db/core_db/memory_only,
  ../execution_chain/db/ledger,
  ../execution_chain/evm/[state, types],
  ../execution_chain/core/executor/[process_block_parallel, process_transaction],
  ../execution_chain/utils/utils,
  ../tools/common/helpers

# Prefetch workers reach the block's transactions through a raw pointer. Under
# refc each thread owns its heap and refcounts are plain integers, so a worker
# must not keep a counted reference to a main-thread cell: the two threads race
# on the count and whichever drops it to zero frees it from the wrong heap.

const initcodePadding = 8192

let senderKey = PrivateKey.fromHex(
  "af1a9be9f1a54421cac82943820a0fe0f601bb5f4f6d0bccc81c613f0ce6ae22"
)[]

type PrefetchEnv = object
  com: CommonRef
  vmState: BaseVMState
  sender: Address

proc createTx(nonce: uint64, chainId: ChainId): Transaction =
  # Jump over a fake JUMPDEST inside PUSH data, then deploy one STOP byte
  let tx = Transaction(
    txType: TxLegacy,
    chainId: chainId,
    nonce: AccountNonce(nonce),
    gasPrice: 1,
    gasLimit: 400_000,
    to: Opt.none(Address),
    payload: hexToSeqByte("600656605b005b60016000f3") & newSeq[byte](initcodePadding),
  )
  signTransaction(tx, senderKey, eip155 = true)

proc initEnv(): PrefetchEnv =
  let
    conf = getChainConfig($TestFork.Cancun).expect("ok")
    com = CommonRef.new(
      DefaultDbMemory.newCoreDbRef(),
      conf,
      conf.chainId.NetworkId,
      optimisticStatePrefetch = true,
      parallelSenderRecovery = true,
    )
    sender = createTx(0, conf.chainId).recoverSender().expect("valid signature")
    base = com.db.baseTxFrame()
    funding = LedgerRef.init(base)
  com.taskpool = Taskpool.new(numThreads = 4)

  # Workers read state through the parent frame, so fund the sender there
  funding.setBalance(sender, 1_000_000_000.u256)
  funding.persist()

  let
    parent = Header(stateRoot: EMPTY_ROOT_HASH)
    header = Header(
      number: 1'u64,
      stateRoot: EMPTY_ROOT_HASH,
      parentHash: computeRlpHash(parent),
      timestamp: EthTime(0x1234),
      gasLimit: 30_000_000,
      baseFeePerGas: Opt.some(1.u256),
    )
  PrefetchEnv(
    com: com,
    sender: sender,
    vmState: BaseVMState.new(parent, header, com, base.txFrameBegin()),
  )

proc collectTask(): bool {.nimcall.} =
  GC_fullCollect()
  true

when defined(gcRefc):
  proc cellRefcount(s: seq[byte]): int =
    # refc keeps the count in the cell header right before the payload,
    # shifted past three flag bits
    cast[ptr int](cast[int](cast[pointer](s)) - 2 * sizeof(int))[] shr 3

  suite "Optimistic state prefetch":
    test "worker leaves no reference to the main thread's create payload":
      privateAccess(OptimisticPrefetchCtx)
      privateAccess(OptimisticTxEntry)
      let env = initEnv()
      defer:
        env.com.shutdownTaskpool()

      # The create path must copy the initcode into the EVM code buffer rather
      # than take a reference to the caller's payload
      var probe = @[createTx(0, env.com.chainId)]
      let probeBefore = cellRefcount(probe[0].payload)
      env.vmState.prefetchTransaction(probe[0], env.sender)
      let probeAfter = cellRefcount(probe[0].payload)
      check probeAfter == probeBefore

      var
        txs = @[createTx(0, env.com.chainId)]
        ctx: OptimisticPrefetchCtx
        entry: OptimisticTxEntry
      ctx.parent = env.vmState.parent
      ctx.blockCtx = env.vmState.blockCtx
      ctx.com = env.vmState.com
      ctx.txFrame = env.vmState.ledger.txFrame.parent()
      ctx.cancelled.store(false, moRelease)
      entry.tx = txs[0].addr

      let before = cellRefcount(txs[0].payload)
      let ran = sync(env.com.taskpool.spawn recoverAndPrefetchTask(ctx.addr, entry.addr))
      let after = cellRefcount(txs[0].payload)
      check ran
      check entry.sender == env.sender
      check after == before

    test "concurrent main and worker execution keeps payload refcounts stable":
      let env = initEnv()
      defer:
        env.com.shutdownTaskpool()

      var txs = (0'u64 ..< 4'u64).toSeq().mapIt(createTx(it, env.com.chainId))
      let before = txs.mapIt(cellRefcount(it.payload))

      for _ in 0 ..< 5000:
        env.vmState.withSenderParallel(txs, Opt.none(BlockAccessListRef)):
          env.vmState.prefetchTransaction(tx, sender)

      GC_fullCollect()
      var futs: seq[Flowvar[bool]]
      for _ in 0 ..< 16:
        futs.add env.com.taskpool.spawn collectTask()
      for f in futs.mitems():
        discard sync(f)
      GC_fullCollect()

      let after = txs.mapIt(cellRefcount(it.payload))
      check after == before
