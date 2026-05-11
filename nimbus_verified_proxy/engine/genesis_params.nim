# nimbus_verified_proxy
# Copyright (c) 2026 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import stew/byteutils, beacon_chain/spec/digest

type GenesisParams* = object
  genesisTime*: uint64
  genesisValidatorsRoot*: Eth2Digest
  genesisBlockRoot*: Eth2Digest

const
  mainnetGenesisValidatorsRoot = Eth2Digest(
    data: hexToByteArray[32](
      "4b363db94e286120d76eb905340fdd4e54bfe9f06bf33ff6cf5ad27f511bfe95"
    )
  )
  sepoliaGenesisValidatorsRoot = Eth2Digest(
    data: hexToByteArray[32](
      "d8ea171f3c94aea21ebc42a1ed61052acf3f9209c00e4efbaaddac09ed9b8078"
    )
  )
  hoodiGenesisValidatorsRoot = Eth2Digest(
    data: hexToByteArray[32](
      "212f13fc4df078b6cb7db228f1c8307566dcecf900867401a92023d7ba99cb5f"
    )
  )
  mainnetGenesisBlockRoot = Eth2Digest(
    data: hexToByteArray[32](
      "4d611d5b93fdab69013a7f0a2f961caca0c853f87cfe9595fe50038163079360"
    )
  )
  sepoliaGenesisBlockRoot = Eth2Digest(
    data: hexToByteArray[32](
      "fb9b64fe445f76696407e1e3cc390371edff147bf712db86db6197d4b31ede43"
    )
  )

func genesisParamsForNetwork*(network: string): GenesisParams {.raises: [].} =
  case network
  of "sepolia":
    GenesisParams(
      genesisTime: 1655733600'u64,
      genesisValidatorsRoot: sepoliaGenesisValidatorsRoot,
      genesisBlockRoot: sepoliaGenesisBlockRoot,
    )
  of "hoodi":
    GenesisParams(
      genesisTime: 1742213400'u64,
      genesisValidatorsRoot: hoodiGenesisValidatorsRoot,
      genesisBlockRoot: default(Eth2Digest),
    )
  else: # mainnet
    GenesisParams(
      genesisTime: 1606824023'u64,
      genesisValidatorsRoot: mainnetGenesisValidatorsRoot,
      genesisBlockRoot: mainnetGenesisBlockRoot,
    )
