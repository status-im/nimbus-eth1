# Fluffy
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [].}

import
  stew/bitops2,
  beacon_chain/spec/presets,
  beacon_chain/spec/forks,
  beacon_chain/spec/forks_light_client

func isValidBootstrap*(bootstrap: ForkyLightClientBootstrap, cfg: RuntimeConfig): bool =
  ## Verify if the bootstrap is valid. This does not verify if the header is
  ## part of the canonical chain.
  is_valid_light_client_header(bootstrap.header, cfg) and
    is_valid_merkle_branch(
      hash_tree_root(bootstrap.current_sync_committee),
      bootstrap.current_sync_committee_branch,
      log2trunc(altair.CURRENT_SYNC_COMMITTEE_GINDEX),
      get_subtree_index(altair.CURRENT_SYNC_COMMITTEE_GINDEX),
      bootstrap.header.beacon.state_root,
    )
