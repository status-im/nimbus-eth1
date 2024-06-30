# Nimbus
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/osproc,
  eth/rlp,
  eth/common,
  web3/conversions,
  web3/engine_api_types,
  ../../nimbus/beacon/web3_eth_conv

const
  testFile = "tests/fixtures/eth_tests/BlockchainTests/GeneralStateTests/Pyspecs/cancun/eip4844_blobs/fork_transition_excess_blob_gas.json"
  #testFile = "tests/fixtures/eth_tests/BlockchainTests/ValidBlocks/bcRandomBlockhashTest/randomStatetest224BC.json"
  #testFile = "tests/fixtures/eth_tests/BlockchainTests/ValidBlocks/bcRandomBlockhashTest/randomStatetest631BC.json"
  #testFile = "tests/fixtures/eth_tests/BlockchainTests/ValidBlocks/bcStateTests/blockhashTests.json"

type
  BCTConv* = JrpcConv

  BCTBlock* = object
    rlp*: seq[byte]

  BCTData* = object
    blocks*: seq[BCTBlock]
    genesisRLP*: seq[byte]
    network*: string
    pre*: JsonString
    postState*: JsonString

  BCTCase* = object
    name*: string
    data*: BCTData

  BCTFile* = object
    cases*: seq[BCTCase]

  BCTHash* = object
    number*: Quantity
    hash: BlockHash

  BCTHashes* = object
    hashes: seq[BCTHash]

  BCTEnv* = object
    currentCoinbase*: Address
    currentDifficulty*: UInt256
    currentRandom*: Opt[BlockHash]
    parentDifficulty*: Opt[UInt256]
    currentGasLimit*: Quantity
    currentNumber*: Quantity
    currentTimestamp*: Opt[Quantity]
    parentTimestamp*: Opt[Quantity]
    blockHashes*: BCTHashes
    # ommers
    currentBaseFee*: Opt[UInt256]
    parentUncleHash*: Opt[BlockHash]
    parentBaseFee*: Opt[UInt256]
    parentGasUsed*: Opt[Quantity]
    parentGasLimit*: Opt[Quantity]
    withdrawals*: Opt[seq[WithdrawalV1]]
    currentBlobGasUsed*: Opt[Quantity]
    currentExcessBlobGas*: Opt[Quantity]
    parentBlobGasUsed*: Opt[Quantity]
    parentExcessBlobGas*: Opt[Quantity]
    parentBeaconBlockRoot*: Opt[BlockHash]

  BCTInput* = object
    alloc: JsonString
    env: BCTEnv
    txsRlp: seq[byte]

  BCTResult* = object
    stateRoot*: BlockHash

  BCTOutput* = object
    result*: BCTResult
    alloc*: JsonString

BCTData.useDefaultReaderIn BCTConv
BCTBlock.useDefaultReaderIn BCTConv
BCTOutput.useDefaultReaderIn BCTConv
BCTResult.useDefaultReaderIn BCTConv

BCTEnv.useDefaultWriterIn BCTConv
BCTInput.useDefaultWriterIn BCTConv

proc readValue*(r: var JsonReader[BCTConv], val: var BCTFile)
       {.gcsafe, raises: [IOError, SerializationError].} =
  r.parseObject(key):
    val.cases.add BCTCase(
      name: key,
      data: r.readValue(BCTData)
    )

proc writeValue*(w: var JsonWriter[BCTConv], v: BCTHashes)
      {.gcsafe, raises: [IOError].} =
  w.writeObject():
    for x in v.hashes:
      w.writeField($x.number, x.hash)

func toBlocks(list: openArray[BCTBlock]): seq[EthBlock] =
  result = newSeqOfCap[EthBlock](list.len)
  for x in list:
    result.add rlp.decode(x.rlp, EthBlock)

proc toBctEnv(parentBlock, currentBlock: EthBlock, hashes: BCTHashes): BCTEnv =
  let
    parent = parentBlock.header
    current = currentBlock.header

  result.currentCoinbase   = w3Addr(current.coinbase)
  result.currentGasLimit   = w3Qty(current.gasLimit)
  result.currentNumber     = w3Qty(current.number)
  result.currentTimestamp  = Opt.some w3Qty(current.timestamp)
  result.currentDifficulty = current.difficulty
  result.currentRandom     = Opt.some w3Hash(current.mixHash)

  # t8n should able to calculate these values itself if not supplied
  #result.currentBaseFee        = current.baseFeePerGas
  #result.currentBlobGasUsed    = w3Qty(current.blobGasUsed)
  #result.currentExcessBlobGas  = w3Qty(current.excessBlobGas)

  result.parentBeaconBlockRoot = w3Hash(current.parentBeaconBlockRoot)
  result.parentDifficulty      = Opt.some parent.difficulty
  result.parentTimestamp       = Opt.some w3Qty(parent.timestamp)
  result.parentUncleHash       = Opt.some w3Hash(parent.ommersHash)

  result.parentBaseFee       = parent.baseFeePerGas
  result.parentGasUsed       = Opt.some w3Qty(parent.gasUsed)
  result.parentGasLimit      = Opt.some w3Qty(parent.gasLimit)
  result.parentBlobGasUsed   = w3Qty(parent.blobGasUsed)
  result.parentExcessBlobGas = w3Qty(parent.excessBlobGas)
  result.withdrawals         = w3Withdrawals(currentBlock.withdrawals)
  result.blockHashes         = hashes

func toInput(prevAlloc: JsonString,
             prevBlock, currBlock: EthBlock,
             hashes: BCTHashes): string =
  let input = BCTInput(
    alloc: prevAlloc,
    env: toBctEnv(prevBlock, currBlock, hashes),
    txsRlp: rlp.encode(currBlock.transactions),
  )
  BCTConv.encode(input)

func collectHashes(genesis: EthBlock, blocks: openArray[EthBlock]): BCTHashes =
  result.hashes.add BCTHash(
    number: w3Qty(genesis.header.number),
    hash: w3Hash(rlpHash(genesis.header)),
  )

  for blk in blocks:
    result.hashes.add BCTHash(
      number: w3Qty(blk.header.number),
      hash: w3Hash(rlpHash(blk.header)),
    )

func eth(n: int): UInt256 {.compileTime.} =
  n.u256 * pow(10.u256, 18)

const
  eth5 = 5.eth
  eth3 = 3.eth
  eth2 = 2.eth
  eth0 = 0.u256

const
  BlockRewards = [
    (eth5, "Frontier"),
    (eth5, "Homestead"),
    (eth5, "DAOFork"),
    (eth5, "Tangerine"),
    (eth5, "Spurious"),
    (eth3, "Byzantium"),
    (eth2, "Constantinople"),
    (eth2, "Petersburg"),
    (eth2, "Istanbul"),
    (eth2, "MuirGlacier"),
    (eth2, "Berlin"),
    (eth2, "London"),
    (eth2, "ArrowGlacier"),
    (eth2, "GrayGlacier"),
    (eth0, "MergeFork"),
    (eth0, "Shanghai"),
    (eth0, "Cancun"),
    (eth0, "Prague"),
  ]

func blockReward(network: string): string =
  for z in BlockRewards:
    if network == z[1]:
      return $z[0]

proc BCTMain() =
  try:
    let bctFile = BCTConv.loadFile(testFile, BCTFile, allowUnknownFields = true)
    let cmd = "t8n --output.alloc stdout --output.result stdout --input.alloc stdin --input.env stdin --input.txs stdin --state.fork "

    for c in bctFile.cases:
      var
        prevAlloc = c.data.pre
        prevBlock = rlp.decode(c.data.genesisRLP, EthBlock)

      let
        blocks = toBlocks(c.data.blocks)
        hashes = collectHashes(prevBlock, blocks)

      debugEcho "NAME: ", c.name
      for currBlock in blocks:
        let input = toInput(prevAlloc, prevBlock, currBlock, hashes)

        var cmdLine = cmd & c.data.network
        let reward = blockReward(c.data.network)
        if reward.len > 0:
          cmdLine.add " --state.reward " & reward

        let (output, exitCode) = execCmdEx(cmdLine, input = input)
        prevBlock = currBlock

        if exitCode != QuitSuccess:
          debugEcho output
          break

        let
          parsedOutput = BCTConv.decode(output, BCTOutput, allowUnknownFields = true)
          stateRoot    = ethHash(parsedOutput.result.stateRoot)

        debugEcho "BlockNumber, EXITCODE, resultStateRoot, expectedStateRoot, status: ",
          currBlock.header.number, ", ",
          exitCode, ", ",
          stateRoot, ", ",
          currBlock.header.stateRoot, ", ",
          if stateRoot != currBlock.header.stateRoot: "FAILED" else: "OK"

        if stateRoot != currBlock.header.stateRoot:
          debugEcho "STATE ROOT MISMATCH: ", currBlock.header.number
          debugEcho "WANT: ", currBlock.header.stateRoot
          debugEcho "GET: ", stateRoot
          quit(QuitFailure)

        prevAlloc = parsedOutput.alloc

  except SerializationError as exc:
    debugEcho "Something error"
    debugEcho exc.formatMsg(testFile)

BCTMain()
