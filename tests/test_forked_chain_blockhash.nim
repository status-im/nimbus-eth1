# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

## BLOCKHASH must resolve the hashes of the branch a block executes on, no
## matter which branch was imported last or selected by the latest forkchoice.

import
  pkg/chronos,
  pkg/unittest2,
  ../execution_chain/common,
  ../execution_chain/conf,
  ../execution_chain/utils/utils,
  ../execution_chain/core/chain/forked_chain,
  ../execution_chain/core/tx_pool,
  ../execution_chain/core/tx_pool/tx_desc,
  ../execution_chain/core/pooled_txs,
  ../execution_chain/db/ledger,
  ../execution_chain/db/core_db/memory_only,
  ./transaction/tx_sender

const
  genesisFile = "tests/customgenesis/cancun123.json"
  feeA        = address"000000000000000000000000000000000000aaaa"
  feeB        = address"000000000000000000000000000000000000bbbb"

  # Initcode storing BLOCKHASH(NUMBER-3), BLOCKHASH(NUMBER-2) and
  # BLOCKHASH(NUMBER-1) in slots 0, 1 and 2 of the created account, so the
  # post-state depends on the hashes of the branch the block executes on.
  blockHashInitcode = @[
    0x60'u8, 0x03, 0x43, 0x03, 0x40, 0x60, 0x00, 0x55,
    0x60, 0x02, 0x43, 0x03, 0x40, 0x60, 0x01, 0x55,
    0x60, 0x01, 0x43, 0x03, 0x40, 0x60, 0x02, 0x55,
    0x00]

type
  Builder = object
    ## A chain that only ever sees one branch, so the blocks it produces are
    ## computed from their own lineage alone.
    chain: ForkedChainRef
    xp: TxPoolRef

proc newChain(params: NetworkParams): ForkedChainRef =
  ForkedChainRef.init(CommonRef.new(newCoreDbRef DefaultDbMemory, params))

proc newBuilder(params: NetworkParams, prefix: openArray[Block] = []): Builder =
  let chain = newChain(params)
  for blk in prefix:
    doAssert (waitFor chain.importBlock(blk)).isOk
  Builder(chain: chain, xp: TxPoolRef.new(chain))

proc build(b: Builder, txs: openArray[PooledTransaction], feeRecipient: Address): Block =
  let parent = b.chain.latestHeader
  b.xp.updateVmState(parent, b.chain.latestHash)
  b.xp.feeRecipient = feeRecipient
  b.xp.timestamp = parent.timestamp + 1
  for tx in txs:
    doAssert b.xp.addTx(tx).isOk
  let blk = b.xp.assembleBlock(b.chain.latestHash).expect("assembled block").blk
  doAssert blk.transactions.len == txs.len
  b.xp.removeNewBlockTxs(blk)
  doAssert (waitFor b.chain.importBlock(blk)).isOk
  blk

func blockHash(x: Block): Hash32 =
  x.header.computeBlockHash

template checkImport(chain, blk) =
  let res = waitFor chain.importBlock(blk)
  check res.isOk and res.value == ImportOutcome.Valid
  if res.isErr:
    debugEcho "IMPORT BLOCK FAIL #", blk.header.number, ": ", res.error.msg

template checkHead(chain, blk) =
  # Forkchoice without finality, so both branches stay alive
  check (waitFor chain.forkChoice(blk.blockHash, zeroHash32)).isOk

template checkBlockHashes(chain, blk, ancestors) =
  let ledger = LedgerRef.init(chain.txFrame(blk.blockHash))
  for i, anc in ancestors:
    check ledger.getStorage(contract, i.u256) == UInt256.fromBytesBE(anc.blockHash.data)

suite "ForkedChain BLOCKHASH across branches":
  let
    config = makeConfig(@["--network:" & genesisFile])
    params = config.computeNetworkParams()
    sender = TxSender.new(params, 1)
    acc = sender.getAccount(0)
    deploy = sender.makeTx(BaseTx(gasLimit: 200_000, payload: blockHashInitcode), acc, 0)
    contract = generateAddress(acc.address, 0)

  # A and B fork after the shared block C1; block 4 of each probes
  # BLOCKHASH(1) (shared), (2) and (3) (branch specific).
  let
    bA = newBuilder(params)
    C1 = bA.build([], feeA)
    bB = newBuilder(params, [C1])
    A2 = bA.build([], feeA)
    A3 = bA.build([], feeA)
    A4 = bA.build([deploy], feeA)
    B2 = bB.build([], feeB)
    B3 = bB.build([], feeB)
    B4 = bB.build([deploy], feeB)

  test "head branch block after importing a side branch":
    let chain = newChain(params)
    checkImport(chain, C1)
    checkImport(chain, A2)
    checkImport(chain, A3)
    checkHead(chain, A3)
    checkImport(chain, B2)
    checkImport(chain, B3)
    checkImport(chain, A4)
    checkBlockHashes(chain, A4, [C1, A2, A3])

  test "side branch block after a forkchoice to the other branch":
    let chain = newChain(params)
    checkImport(chain, C1)
    checkImport(chain, A2)
    checkImport(chain, A3)
    checkImport(chain, B2)
    checkImport(chain, B3)
    checkHead(chain, A3)
    checkImport(chain, B4)
    checkBlockHashes(chain, B4, [C1, B2, B3])
