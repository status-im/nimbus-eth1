# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import ./all_tests_macro

{. warning[UnusedImport]:off .}

cliBuilder:
  import  ./test_ledger,
          ./test_jwt_auth,
          ./test_evm_support,
          ./test_genesis,
          ./test_precompiles,
          ./test_generalstate_json,
          #./test_tracer_json,                     -- temporarily disabled
          #./test_persistblock_json,               -- fails
          #./test_rpc,                             -- fails
          ./test_filters,
          ./test_op_arith,
          ./test_op_bit,
          ./test_op_env,
          ./test_op_memory,
          ./test_op_misc,
          ./test_op_custom,
          ./test_difficulty,
          ./test_transaction_json,
          ./test_blockchain_json,
          ./test_forked_chain,
          ./test_forkid,
          ./test_multi_keys,
          #./test_graphql,                         -- fails
          ./test_configuration,
          ./test_txpool,
          ./test_txpool2,
          #./test_merge,                           -- fails
          ./test_eip4844,
          ./test_beacon/test_skeleton,
          #./test_getproof_json,                   -- fails
          #./test_rpc_experimental_json,           -- fails
          ./test_aristo,
          ./test_coredb
