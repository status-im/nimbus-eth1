# Nimbus
# Copyright (c) 2022-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  eth/[common, rlp],
  stew/byteutils,
  eth/common/transaction_utils,
  ../common/helpers,
  ../../execution_chain/transaction,
  ../../execution_chain/core/validate,
  ../../execution_chain/common/evmforks,
  ../../execution_chain/common/common

const
  pragueTimestamp = 1_741_159_776.EthTime

proc parseTx(com: CommonRef, hexLine: string) =
  try:
    let
      bytes = hexToSeqByte(hexLine)
      tx = decodeTx(bytes)
      address = tx.recoverSender().expect("valid signature")

    validateTxBasic(com, tx, FkPrague, pragueTimestamp).isOkOr:
      echo "err: ", error

    # everything ok
    echo "0x", address.toHex

  except RlpError as ex:
    echo "err: ", ex.msg
  except ValueError as ex:
    echo "err: ", ex.msg
  except Exception:
    # TODO: rlp.hasData assertion should be
    # changed into RlpError
    echo "err: malformed rlp"

proc main() =
  let
    memDB  = newCoreDbRef DefaultDbMemory
    config = getChainConfig("Prague")
    com    = CommonRef.new(memDB, nil, config)

  for hexLine in stdin.lines:
    com.parseTx(hexLine)

main()
