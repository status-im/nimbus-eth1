# Nimbus
# Copyright (c) 2022-2024 Status Research & Development GmbH
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
  ../../nimbus/transaction,
  ../../nimbus/common/evmforks

proc parseTx(hexLine: string) =
  try:
    let
      bytes = hexToSeqByte(hexLine)
      tx = decodeTx(bytes)
      address = tx.recoverSender().expect("valid signature")

    tx.validate(FkLondon)

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
  for hexLine in stdin.lines:
    parseTx(hexLine)

main()
