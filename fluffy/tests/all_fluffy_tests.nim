# Nimbus
# Copyright (c) 2021-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.warning[UnusedImport]: off.}

import
  ./test_content_db,
  ./wire_protocol_tests/all_wire_protocol_tests,
  ./history_network_tests/all_history_network_tests,
  ./beacon_network_tests/all_beacon_network_tests,
  ./state_network_tests/all_state_network_tests,
  # ./evm/all_evm_tests, # Disabled for now to narrow down cause of CI test failures
  ./rpc_tests/all_rpc_tests
