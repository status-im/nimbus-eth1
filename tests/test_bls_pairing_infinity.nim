# Nimbus
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  std/strutils,
  unittest2, stew/byteutils,
  ../execution_chain/db/core_db/memory_only,
  ../execution_chain/common/common,
  ../execution_chain/[evm/state,
    evm/types,
    evm/precompiles,
    transaction,
    transaction/call_evm],
  ../tools/common/helpers as chp,
  eth/common/[keys, transaction_utils]

const
  privateKey = "7a28b5ba57c53603b0b07b56bba752f7784bf506fa95edc395f5cf6c7514fe9d"

  # One pair of points at infinity (768 hex zeros).
  infPair = "00".repeat(384)

  # Two valid pairs whose product is the identity: e(2*G1,3*G2)=e(6*G1,G2).
  real2True =
    "000000000000000000000000000000000572cbea904d67468808c8eb50a9450c9721db309128012543902d0ac358a62ae28f75bb8f1c7c42c39a8c5529bf0f4e00000000000000000000000000000000166a9d8cabc673a322fda673779d8e3822ba3ecb8670e461f73bb9021d5fd76a4c56d9d4cd16bd1bba86881979749d2800000000000000000000000000000000122915c824a0857e2ee414a3dccb23ae691ae54329781315a0c75df1c04d6d7a50a030fc866f09d516020ef82324afae0000000000000000000000000000000009380275bbc8e5dcea7dc4dd7e0550ff2ac480905396eda55062650f8d251c96eb480673937cc6d9d6a44aaa56ca66dc000000000000000000000000000000000b21da7955969e61010c7a1abc1a6f0136961d1e3b20b1a7326ac738fef5c721479dfd948b52fdf2455e44813ecfd8920000000000000000000000000000000008f239ba329b3967fe48d718a36cfe5f62a7e42e0bf1c1ed714150a166bfbd6bcf6b3b58b975b9edea56d53f23a0e8490000000000000000000000000000000006e82f6da4520f85c5d27d8f329eccfa05944fd1096b20734c894966d12a9e2a9a9744529d7212d33883113a0cadb9090000000000000000000000000000000017d81038f7d60bee9110d9c0d6d1102fe2d998c957f28e31ec284cc04134df8e47e8f82ff3af2e60a6d9688a4563477c00000000000000000000000000000000024aa2b2f08f0a91260805272dc51051c6e47ad4fa403b02b4510b647ae3d1770bac0326a805bbefd48056c8c121bdb80000000000000000000000000000000013e02b6052719f607dacd3a088274f65596bd0d09920b61ab5da61bbdc7f5049334cf11213945d57e5ac7d055d042b7e000000000000000000000000000000000d1b3cc2c7027888be51d9ef691d77bcb679afda66c73f17f9ee3837a55024f78c71363275a75d75d86bab79f74782aa0000000000000000000000000000000013fa4d4a0ad8b1ce186ed5061789213d993923066dddaf1040bc3ff59f825c78df74f2d75467e25e0f55f8a00fa030ed"

  # A single valid pair whose pairing is not the identity.
  real1False =
    "0000000000000000000000000000000012196c5a43d69224d8713389285f26b98f86ee910ab3dd668e413738282003cc5b7357af9a7af54bb713d62255e80f560000000000000000000000000000000006ba8102bfbeea4416b710c73e8cce3032c31c6269c44906f8ac4f7874ce99fb17559992486528963884ce429a992fee0000000000000000000000000000000017c9fcf0504e62d3553b2f089b64574150aa5117bd3d2e89a8c1ed59bb7f70fb83215975ef31976e757abf60a75a1d9f0000000000000000000000000000000008f5a53d704298fe0cfc955e020442874fe87d5c729c7126abbdcbed355eef6c8f07277bee6d49d56c4ebaf334848624000000000000000000000000000000001302dcc50c6ce4c28086f8e1b43f9f65543cf598be440123816765ab6bc93f62bceda80045fbcad8598d4f32d03ee8fa000000000000000000000000000000000bbb4eb37628d60b035a3e0c45c0ea8c4abef5a6ddc5625e0560097ef9caab208221062e81cd77ef72162923a1906a40"

  outTrue = "0000000000000000000000000000000000000000000000000000000000000001"
  outFalse = "0000000000000000000000000000000000000000000000000000000000000000"

proc runPairing(vmState: BaseVMState, dataStr: string): seq[byte] =
  let unsignedTx = Transaction(
    txType: TxLegacy,
    nonce: 0,
    gasPrice: 1.GasInt,
    gasLimit: 1_000_000_000.GasInt,
    to: Opt.some precompileAddrs[paBlsPairing],
    value: 0.u256,
    chainId: 1.u256,
    payload: dataStr.hexToSeqByte)
  let
    key = PrivateKey.fromHex(privateKey).expect("valid key")
    tx = signTransaction(unsignedTx, key, false)
    res = testCallEvm(tx, tx.recoverSender().expect("valid signature"), vmState)
  check not res.isError
  res.output

suite "BLS12-381 pairing precompile - points at infinity":
  setup:
    let
      conf = getChainConfig("Prague")
      com = CommonRef.new(newCoreDbRef DefaultDbMemory, config = conf)
      vmState = BaseVMState.new(
        Header(number: 1'u64, stateRoot: EMPTY_ROOT_HASH),
        Header(),
        com,
        com.db.baseTxFrame())

  test "single infinity pair returns identity":
    check runPairing(vmState, infPair).toHex == outTrue

  test "two infinity pairs return identity":
    check runPairing(vmState, infPair & infPair).toHex == outTrue

  test "infinity pair prepended to a true multi-pair is unchanged":
    check runPairing(vmState, infPair & real2True).toHex == outTrue

  test "infinity pair appended to a true multi-pair is unchanged":
    check runPairing(vmState, real2True & infPair).toHex == outTrue

  test "infinity pair does not rescue a false pairing":
    check runPairing(vmState, real1False & infPair).toHex == outFalse

  test "infinity pair prepended to a false pairing is unchanged":
    check runPairing(vmState, infPair & real1False).toHex == outFalse
