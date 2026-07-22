# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## Repro for the beacon syncer stall observed on hoodi (2026-07-17).
##
## The `EL` head froze because two things happened at once:
##
## * `el_sync` died on a transient engine-API error and could not restart, and
## * the devp2p beacon syncer never took over - it had been wedged all along.
##
## This module covers the second part. The wedge is self locking:
## ::
##    headNum > topNum   -> session unfinished  -> hdrCache stays `locked`
##    mode == locked     -> every FCU is a no-op -> no new sync target
##    avail == 0         -> topNum never moves   -> headNum > topNum
##
## The observable signature in the production log was 264 `Forkchoice requested
## sync to new head` messages against zero `State changed`, zero `Imported
## blocks` and zero `Suspending syncer` messages, for a full hour, with 25 peers
## connected the whole time.

{.push raises: [].}

import
  pkg/chronicles,
  pkg/chronos,
  pkg/unittest2,
  std/os,
  ../execution_chain/common,
  ../execution_chain/conf,
  ../execution_chain/utils/utils,
  ../execution_chain/core/chain/forked_chain,
  ../execution_chain/core/chain/header_chain_cache,
  ../execution_chain/db/ledger,
  ../execution_chain/db/opts,
  ../execution_chain/db/core_db/[memory_only, persistent],
  ../execution_chain/sync/beacon/worker/worker_desc,
  ../execution_chain/sync/beacon/worker/update,
  ../execution_chain/sync/beacon/worker/blocks/blocks_unproc,
  ../execution_chain/sync/beacon/worker/blocks/blocks_helpers

const
  genesisFile = "tests/customgenesis/cancun123.json"
  senderAddr = address"73cf19657412508833f618a15e8251306b3e6ee5"
  syncInfo = "test_beacon_sync_stall"

# ------------------------------------------------------------------------------
# Private helpers, environment (mirrors `tests/test_forked_chain.nim`)
# ------------------------------------------------------------------------------

let dbRoot = getTempDir() / "nimbus-test-beacon-sync-stall"
var dbSeq = 0

try:
  removeDir dbRoot                       # leftovers from an earlier run
except OSError:
  discard

proc setupCom(): CommonRef =
  ## `HeaderChainRef.init()` needs `synchronizerKvt()`, which is `RocksDb` only
  ## (see `db/kvt_cf.nim`), so this cannot run on `DefaultDbMemory`.
  inc dbSeq
  let
    path = dbRoot / $dbSeq
    config = makeConfig(@["--network:" & genesisFile])
    db = AristoDbRocks.newCoreDbRef(path, DbOptions.init(), wipe = true)
  CommonRef.new(db, config.networkId, config.networkParams)

proc makeBlk(txFrame: CoreDbTxRef, number: BlockNumber, parentBlk: Block): Block =
  template parent(): Header =
    parentBlk.header

  var wds = newSeqOfCap[Withdrawal](number.int)
  for i in 0 ..< number:
    wds.add Withdrawal(
      index: i, validatorIndex: 1, address: senderAddr, amount: 1
    )

  let ledger = LedgerRef.init(txFrame)
  for wd in wds:
    ledger.addBalance(wd.address, wd.weiAmount)
  ledger.persist()

  let
    wdRoot = calcWithdrawalsRoot(wds)
    body = BlockBody(withdrawals: Opt.some(move(wds)))
    header = Header(
      number: number,
      parentHash: parent.computeBlockHash,
      difficulty: 0.u256,
      timestamp: parent.timestamp + 1,
      gasLimit: parent.gasLimit,
      stateRoot: ledger.getStateRoot(),
      transactionsRoot: parent.txRoot,
      baseFeePerGas: parent.baseFeePerGas,
      receiptsRoot: parent.receiptsRoot,
      ommersHash: parent.ommersHash,
      withdrawalsRoot: Opt.some(wdRoot),
      blobGasUsed: parent.blobGasUsed,
      excessBlobGas: parent.excessBlobGas,
      parentBeaconBlockRoot: parent.parentBeaconBlockRoot,
    )

  Block.init(header, body)

func blockHash(x: Block): Hash32 =
  x.header.computeBlockHash

# ------------------------------------------------------------------------------
# Private helpers, syncer descriptor
# ------------------------------------------------------------------------------

proc setupCtx(chain: ForkedChainRef, hdrCache: HeaderChainRef): BeaconCtxRef =
  ## Bare bones global syncer descriptor. There is no network involved here,
  ## so `node` stays `nil` and `nSyncPeers()` is stubbed out - the state
  ## machine only ever reads it for logging.
  let ctx = BeaconCtxRef(
    pool: BeaconCtxData(chain: chain, hdrCache: hdrCache)
  )
  ctx.nSyncPeers = proc(): int = 0
  ctx.blocksUnprocInit()
  ctx

# ------------------------------------------------------------------------------
# Test suite
# ------------------------------------------------------------------------------

suite "Beacon syncer stall (hoodi 2026-07-17)":
  # A chain of 12 blocks. Only 1..3 get imported into the `FC` module, so
  # `hashToBlock` ends at 3 and blocks 4..12 are what a syncer would have to
  # fetch. Base stays at genesis (0).
  var
    com = setupCom()
    genesis = Block.init(com.genesisHeader, BlockBody())
    blocks: seq[Block] = @[genesis]

  block:
    let txFrame = com.db.baseTxFrame().txFrameBegin
    for n in 1'u64 .. 12'u64:
      blocks.add txFrame.makeBlk(n, blocks[^1])
    txFrame.dispose()

  # ----------------------------------------------------------------------------

  test "C1: a `locked` header cache defers a new forkchoice head until it closes":
    # Characterisation of `headUpdateFromCL()`: it only opens a session when
    # `mode == closed`, so while `locked` a new FCU updates `consHead` only. We
    # deliberately do NOT change this - the fix works by making sure a session
    # always *closes* (see C2/C3b), after which the next FCU is honoured. This
    # test pins the design so the reasoning behind the fix stays visible.
    let
      chain = ForkedChainRef.init(setupCom())
      hdrCache = HeaderChainRef.init(chain)
    var nNotify = 0

    hdrCache.start(proc() = inc nNotify)

    for n in 1 .. 3:
      check (waitFor chain.importBlock(blocks[n])).isOk
    check chain.baseNumber == 0'u64

    # -- first FCU: opens a session towards block 8 ----------------------------
    hdrCache.headTargetUpdate(blocks[8].header, blocks[3].blockHash)
    check hdrCache.state == collecting
    check nNotify == 1
    check hdrCache.head.number == 8'u64

    # -- fill the header chain down to a parent known to `FC` ------------------
    # `put()` takes headers in reverse, starting one below the session head.
    check hdrCache.put(@[
        blocks[7].header, blocks[6].header, blocks[5].header, blocks[4].header
      ]).isOk
    check hdrCache.state == ready
    check hdrCache.antecedent.number == 4'u64

    check hdrCache.commit().isOk
    check hdrCache.state == locked

    # -- second FCU: a strictly higher head, exactly as the `CL` keeps sending
    #    while the `EL` is behind -------------------------------------------
    hdrCache.headTargetUpdate(blocks[12].header, blocks[3].blockHash)

    # `consHead` *is* updated - this is what feeds `nec_sync_consensus_head`,
    # which in production climbed to 3_230_960 while the syncer never moved.
    check hdrCache.latestConsHeadNumber == 12'u64

    # The sync target and the notification are deferred while `locked`; the
    # session must first complete before a fresh target is accepted.
    check hdrCache.head.number == 8'u64
    check nNotify == 1

  # ----------------------------------------------------------------------------

  test "C2: a session el_sync already completed no longer wedges (the fix)":
    let
      chain = ForkedChainRef.init(setupCom())
      hdrCache = HeaderChainRef.init(chain)
    var nNotify = 0

    hdrCache.start(proc() = inc nNotify)

    # `el_sync` has imported *past* the session target (8): FC latest is 10.
    for n in 1 .. 10:
      check (waitFor chain.importBlock(blocks[n])).isOk
    check chain.latestNumber == 10'u64

    # Drive the cache to `locked` with target head 8, as in the wedge.
    hdrCache.headTargetUpdate(blocks[8].header, blocks[3].blockHash)
    check hdrCache.put(@[
        blocks[7].header, blocks[6].header, blocks[5].header, blocks[4].header
      ]).isOk
    check hdrCache.commit().isOk
    check hdrCache.state == locked

    # Syncer sits in `blocks` with an unfinished session (topNum 5 < headNum 8)
    # and nothing queued - the exact wedge shape.
    let ctx = setupCtx(chain, hdrCache)
    ctx.pool.syncState = BeaconState.blocks
    ctx.subState.topNum = 5'u64
    ctx.subState.headNum = 8'u64
    ctx.subState.headHash = blocks[8].blockHash   # as `setupProcessingBlocks` does

    check ctx.blocksUnprocAvail() == 0'u64        # nothing to fetch
    check not ctx.blkSessionStopped()             # ...yet session counts as live

    # One daemon tick: `blocksNext` now reconciles against the live FC, sees the
    # target (8) is a canonical ancestor of FC head (10), fast-forwards `topNum`
    # to `headNum`, and finishes the session instead of wedging forever.
    ctx.updateBeaconState syncInfo
    check ctx.subState.topNum == 8'u64
    check ctx.pool.syncState != BeaconState.blocks   # left `blocks` (-> finish)

  # ----------------------------------------------------------------------------

  test "C3a: borrowed ranges strand `unprocessed` while topNum lags headNum":
    let
      chain = ForkedChainRef.init(setupCom())
      hdrCache = HeaderChainRef.init(chain)
      ctx = setupCtx(chain, hdrCache)

    ctx.pool.syncState = BeaconState.blocks
    ctx.subState.topNum = 100'u64
    ctx.subState.headNum = 400'u64
    ctx.blocksUnprocSet(ctx.subState.topNum + 1, ctx.subState.headNum)
    check ctx.blocksUnprocAvail() == 300'u64

    # Peers borrow every range and then die without committing anything back.
    while 0 < ctx.blocksUnprocAvail():
      discard ctx.blocksUnprocFetch(64).expect("borrowed range")

    check ctx.blocksUnprocAvail() == 0'u64      # -> blocksCollectOk() == false
    check not ctx.blocksUnprocIsEmpty()         # ...but work is still pending
    check ctx.subState.topNum < ctx.subState.headNum
    check 0 < ctx.blocksUnprocTotal()           # nec_sync_blocks_unprocessed != 0

    # And the state machine agrees to stay put.
    ctx.updateBeaconState syncInfo
    check ctx.pool.syncState == BeaconState.blocks

  # ----------------------------------------------------------------------------

  test "C3b: reconcile fast-forwards once `el_sync` pushes FC past the session head":
    let
      chain = ForkedChainRef.init(setupCom())
      hdrCache = HeaderChainRef.init(chain)
    var nNotify = 0

    hdrCache.start(proc() = inc nNotify)

    # `FC` latest runs ahead of the syncer's session head, which is exactly
    # what `el_sync` does when it feeds the engine API concurrently.
    for n in 1 .. 10:
      check (waitFor chain.importBlock(blocks[n])).isOk
    check chain.latestNumber == 10'u64

    hdrCache.headTargetUpdate(blocks[8].header, blocks[3].blockHash)
    check hdrCache.head.number == 8'u64

    # `getHash()` only resolves inside the session range, so `fcLatest` (10)
    # above the session head (8) cannot be resolved - the old reconcile bailed
    # here. The fix instead checks the target against the canonical `FC` chain.
    check hdrCache.getHash(chain.latestNumber).isErr

    let ctx = setupCtx(chain, hdrCache)
    ctx.pool.syncState = BeaconState.blocks
    ctx.subState.topNum = 3'u64
    ctx.subState.headNum = 8'u64
    ctx.subState.headHash = blocks[8].blockHash   # as `setupProcessingBlocks` does
    ctx.blocksUnprocSet(ctx.subState.topNum + 1, ctx.subState.headNum)
    check ctx.blocksUnprocAvail() == 5'u64

    # `isCanonicalAncestor(8, headHash)` is true (block 8 is an ancestor of FC
    # head 10), so reconcile fast-forwards `topNum` to `headNum` and drains the
    # queue - the session can now complete.
    ctx.blocksUnprocReconcile()
    check ctx.subState.topNum == 8'u64
    check ctx.blocksUnprocAvail() == 0'u64

  # ----------------------------------------------------------------------------

  test "C3c: reconcile refuses to fast-forward when the FC head is off-branch":
    # Reorg-safety guard: when `el_sync` has run past the session head but the
    # live `FC` head is on a *different* branch than the target, the target is
    # not a canonical ancestor and reconcile must leave `topNum` alone so the
    # in-order import can classify each block on the new branch.
    let
      chain = ForkedChainRef.init(setupCom())
      hdrCache = HeaderChainRef.init(chain)

    for n in 1 .. 10:
      check (waitFor chain.importBlock(blocks[n])).isOk
    check chain.latestNumber == 10'u64

    let ctx = setupCtx(chain, hdrCache)
    ctx.pool.syncState = BeaconState.blocks
    ctx.subState.topNum = 3'u64
    ctx.subState.headNum = 8'u64
    # Target hash at height 8 is NOT the canonical block 8 (stand-in for a
    # soon-to-be-abandoned branch), so `isCanonicalAncestor(8, _)` is false.
    ctx.subState.headHash = blocks[9].blockHash
    ctx.blocksUnprocSet(ctx.subState.topNum + 1, ctx.subState.headNum)
    check ctx.blocksUnprocAvail() == 5'u64

    ctx.blocksUnprocReconcile()

    # No fast-forward: the range stays queued for in-order import.
    check ctx.subState.topNum == 3'u64
    check ctx.blocksUnprocAvail() == 5'u64

  # ----------------------------------------------------------------------------

  test "C3d: reconcile is a permanent no-op when there is no session at all":
    let
      chain = ForkedChainRef.init(setupCom())
      hdrCache = HeaderChainRef.init(chain)
      ctx = setupCtx(chain, hdrCache)

    for n in 1 .. 3:
      check (waitFor chain.importBlock(blocks[n])).isOk

    # No header cache session at all, so `getHash()` cannot resolve `fcLatest`.
    check hdrCache.getHash(chain.latestNumber).isErr

    ctx.pool.syncState = BeaconState.blocks
    ctx.subState.topNum = 3'u64
    ctx.subState.headNum = 8'u64
    ctx.blocksUnprocSet(ctx.subState.topNum + 1, ctx.subState.headNum)

    ctx.blocksUnprocReconcile()
    check ctx.subState.topNum == 3'u64          # never fast-forwards
    check ctx.blocksUnprocAvail() == 5'u64

try:
  removeDir dbRoot
except OSError:
  discard

# ------------------------------------------------------------------------------
# End
# ------------------------------------------------------------------------------
