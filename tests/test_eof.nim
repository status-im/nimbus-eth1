import
  std/[tables, math, times],
  eth/[keys],
  stew/byteutils,
  unittest2,
  ../nimbus/core/chain,
  ../nimbus/core/tx_pool,
  ../nimbus/core/casper,
  ../nimbus/db/accounts_cache,
  ../nimbus/utils/[eof, utils],
  ../nimbus/evm/interpreter/op_codes,
  ../nimbus/[common, config, transaction],
  ./test_txpool/helpers

const
  baseDir = [".", "tests"]
  repoDir = [".", "customgenesis"]
  genesisFile = "eof.json"

type
  TestEnv = object
    nonce   : uint64
    chainId : ChainId
    vaultKey: PrivateKey
    conf    : NimbusConf
    com     : CommonRef
    chain   : ChainRef
    xp      : TxPoolRef

proc toAddress(x: string): EthAddress =
  hexToByteArray[20](x)

proc privKey(keyHex: string): PrivateKey =
  let kRes = PrivateKey.fromHex(keyHex)
  if kRes.isErr:
    echo kRes.error
    quit(QuitFailure)

  kRes.get()

proc toAddress(key: PrivateKey): EthAddress =
  let pubKey = key.toPublicKey
  pubKey.toCanonicalAddress

func eth(n: int): UInt256 =
  n.u256 * pow(10.u256, 18)

proc fm(input, output, max: int): FunctionMetadata =
  FunctionMetadata(input: input.uint8,
    output: output.uint8, maxStackHeight: max.uint16)

const
  createDeployer = [
    byte(CALLDATASIZE), # size
    byte(PUSH1), 0x00,  # offset
    byte(PUSH1), 0x00,  # dst
    byte(CALLDATACOPY),
    byte(CALLDATASIZE), # len
    byte(PUSH1), 0x00,  # offset
    byte(PUSH1), 0x00,  # value
    byte(CREATE),
  ]

  create2Deployer = [
    byte(CALLDATASIZE), # len
    byte(PUSH1), 0x00,  # offset
    byte(PUSH1), 0x00,  # dst
    byte(CALLDATACOPY),
    byte(PUSH1), 0x00,  # salt
    byte(CALLDATASIZE), # len
    byte(PUSH1), 0x00,  # offset
    byte(PUSH1), 0x00,  # value
    byte(CREATE2),
  ]

  aa     = toAddress("0x000000000000000000000000000000000000aaaa")
  bb     = toAddress("0x000000000000000000000000000000000000bbbb")
  cc     = toAddress("0x000000000000000000000000000000000000cccc")
  funds  = 1.eth
  vaultKeyHex = "b71c71a67e1177ad4e901695e1b4b9ee17ae16c6668d313eac2f96dbcda3f291"

proc acc(code: openArray[byte]): GenesisAccount =
  GenesisAccount(code: @code)

proc acc(balance: UInt256): GenesisAccount =
  GenesisAccount(balance: balance)

proc makeCode(): seq[byte] =
  var c: Container
  c.types = @[
    fm(0, 0, 0),
    fm(0, 0, 2),
    fm(0, 0, 0),
    fm(0, 0, 2)
  ]

  c.code = @[@[
    byte(CALLF),
    byte(0),
    byte(1),
    byte(CALLF),
    byte(0),
    byte(2),
    byte(STOP),
  ], @[
    byte(PUSH1),
    byte(2),
    byte(RJUMP), # skip first flag
    byte(0),
    byte(5),

    byte(PUSH1),
    byte(1),
    byte(PUSH1),
    byte(0),
    byte(SSTORE), # set first flag

    byte(PUSH1),
    byte(1),
    byte(SWAP1),
    byte(SUB),
    byte(DUP1),
    byte(RJUMPI), # jump to first flag, then don't branch
    byte(0xff),
    byte(0xF3),   # -13

    byte(PUSH1),
    byte(1),
    byte(PUSH1),
    byte(1),
    byte(SSTORE), # set second flag
    byte(RETF),
  ], @[
    byte(PUSH1),
    byte(1),
    byte(PUSH1),
    byte(2),
    byte(SSTORE), # set third flag

    byte(CALLF),
    byte(0),
    byte(3),
    byte(RETF),
  ], @[
    byte(PUSH1),
    byte(0),
    byte(RJUMPV), # jump over invalid op
    byte(1),
    byte(0),
    byte(1),

    byte(INVALID),

    byte(PUSH1),
    byte(1),
    byte(PUSH1),
    byte(3),
    byte(SSTORE), # set forth flag
    byte(RETF),
  ]]

  c.encode()

proc preAlloc(address: EthAddress): GenesisAlloc =
  result[address] = acc(funds)
  result[bb] = acc(createDeployer)
  result[cc] = acc(create2Deployer)
  result[aa] = acc(makeCode())

proc initDeployCode(): seq[byte] =
  let c = Container(
    types: @[fm(0, 0, 0)],
    code : @[@[byte(STOP)]],
  )
  c.encode()

proc initInitCode(deployCode: openArray[byte]): seq[byte] =
  result = @[
    byte(PUSH1), byte(deployCode.len), # len
    byte(PUSH1), 0x0c, # offset
    byte(PUSH1), 0x00, # dst offset
    byte(CODECOPY),

    # code in memory
    byte(PUSH1), byte(deployCode.len), # size
    byte(PUSH1), 0x00, # offset
    byte(RETURN),
  ]
  result.add deployCode

func gwei(n: uint64): GasInt {.compileTime.} =
  GasInt(n * (10'u64 ^ 9'u64))

proc makeTx*(t: var TestEnv,
             recipient: Option[EthAddress],
             amount: UInt256,
             payload: openArray[byte] = []): Transaction =
  const
    gasLimit = 500000.GasInt
    gasFeeCap = 5.gwei
    gasTipCap = 2.GasInt

  let tx = Transaction(
    txType  : TxEip1559,
    chainId : t.chainId,
    nonce   : AccountNonce(t.nonce),
    gasLimit: gasLimit,
    maxPriorityFee: gasTipCap,
    maxFee  : gasFeeCap,
    to      : recipient,
    value   : amount,
    payload : @payload
  )

  inc t.nonce
  signTransaction(tx, t.vaultKey, t.chainId, eip155 = true)

proc initEnv(): TestEnv =
  let
    signKey = privKey(vaultKeyHex)
    address = toAddress(signKey)

  var
    conf = makeConfig(@[
      "--engine-signer:" & address.toHex,
      "--custom-network:" & genesisFile.findFilePath(baseDir,repoDir).value
    ])

  conf.networkParams.genesis.alloc = preAlloc(address)

  let
    com = CommonRef.new(
      newMemoryDb(),
      conf.pruneMode == PruneMode.Full,
      conf.networkId,
      conf.networkParams
    )
    chain = newChain(com)

  com.initializeEmptyDb()

  result = TestEnv(
    conf: conf,
    com: com,
    chain: chain,
    xp: TxPoolRef.new(com, conf.engineSigner),
    vaultKey: signKey,
    chainId: conf.networkParams.config.chainId,
    nonce: 0'u64
  )

const
  prevRandao = EMPTY_UNCLE_HASH # it can be any valid hash

proc eofMain*() =
  var
    env = initEnv()
    txs: seq[Transaction]
    stateRoot: Hash256

  let
    deployCode = initDeployCode()
    initCode   = initInitCode(deployCode)
    xp = env.xp
    com = env.com
    chain = env.chain

  # execute flag contract
  txs.add env.makeTx(some(aa), 0.u256)

  # deploy eof contract from eoa
  txs.add env.makeTx(none(EthAddress), 0.u256, initCode)

  # deploy eof contract from create contract
  txs.add env.makeTx(some(bb), 0.u256, initCode)

  # deploy eof contract from create2 contract
  txs.add env.makeTx(some(cc), 0.u256, initCode)

  suite "Test EOF code deployment":
    test "add txs to txpool":
      for tx in txs:
        let res = xp.addLocal(tx, force = true)
        check res.isOk
        if res.isErr:
          debugEcho res.error
          return

      # all txs accepted in txpool
      check xp.nItems.total == 4

    test "generate POS block":
      com.pos.prevRandao = prevRandao
      com.pos.feeRecipient = aa
      com.pos.timestamp = getTime()

      let blk = xp.ethBlock()
      check com.isBlockAfterTtd(blk.header)

      let body = BlockBody(
        transactions: blk.txs,
        uncles: blk.uncles
      )
      check blk.txs.len == 4

      let rr = chain.persistBlocks([blk.header], [body])
      check rr == ValidationResult.OK

      # save stateRoot for next test
      stateRoot = blk.header.stateRoot

    test "check flags and various deployment mechanisms":
      var state = AccountsCache.init(
        com.db.db,
        stateRoot,
        com.pruneTrie)

      # check flags
      for i in 0 ..< 4:
        let val = state.getStorage(aa, i.u256)
        check val == 1.u256

      # deploy EOF with EOA
      let address = toAddress(env.vaultKey)
      var code = state.getCode(generateAddress(address, 1))
      check code == deployCode

      # deploy EOF with CREATE
      code = state.getCode(generateAddress(bb, 0))
      check code == deployCode

      # deploy EOF with CREATE2
      let xx = generateSafeAddress(cc, ZERO_CONTRACTSALT, initCode)
      code = state.getCode(xx)
      check code == deployCode

when isMainModule:
  eofMain()
