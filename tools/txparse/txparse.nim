# Nimbus
# Copyright (c) 2022 Status Research & Development GmbH
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
  ../../nimbus/transaction

proc parseTx(hexLine: string) =
  try:
    let
      bytes = hexToSeqByte(hexLine)
      tx = rlp.decode(bytes, Transaction)
      address = tx.getSender()

    # everything ok
    echo "0x", address.toHex

  except RlpError as ex:
    echo "err: ", ex.msg
  except ValueError as ex:
    echo "err: ", ex.msg
  except ValidationError as ex:
    echo "err: ", ex.msg

proc main() =
  for hexLine in stdin.lines:
    parseTx(hexLine)

main()
