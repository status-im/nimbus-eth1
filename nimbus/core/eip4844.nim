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
  stew/results,
  ../common/common

{.push raises: [].}

# https://eips.ethereum.org/EIPS/eip-4844
func validateEip4844Header*(
    com: CommonRef, header: BlockHeader
): Result[void, string] =
  if header.excessDataGas.isSome:
    return err("EIP-4844 not yet implemented")
  return ok()
