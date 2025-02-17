# nimbus
# Copyright (c) 2018-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license: [LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT
#   * Apache License, Version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

# this module helps CI save time
# when try to test buildability of these tools.
# They never run in the CI so it is ok to combine them

{.warning[UnusedImport]: off.}

import
  #./tracerTestGen,          # -- ditto
  #./persistBlockTestGen,    # -- ditto
  ../hive_integration/nodocker/rpc/rpc_sim,
  ../hive_integration/nodocker/consensus/consensus_sim,
  ../hive_integration/nodocker/engine/engine_sim,
  ../hive_integration/nodocker/pyspec/pyspec_sim,
  ../tools/t8n/t8n,
  ../tools/t8n/t8n_test,
  ../tools/t8n/t8n_debug,
  ../tools/evmstate/evmstate,
  ../tools/evmstate/evmstate_test
