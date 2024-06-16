# Nimbus
# Copyright (c) 2018-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import ./all_tests_macro

{. warning[UnusedImport]:off .}

cliBuilder:
  import  ./test_code_stream,
          #./test_accounts_cache,                  -- does not compile
          ./test_jwt_auth,
          ./test_gas_meter,
          ./test_memory,
          ./test_stack,
          ./test_genesis,
          ./test_precompiles,
          ./test_generalstate_json,
          ./test_tracer_json,
          #./test_persistblock_json,               -- fails
          #./test_rpc,                             -- fails
          ./test_filters,
          ./test_op_arith,
          ./test_op_bit,
          ./test_op_env,
          ./test_op_memory,
          ./test_op_misc,
          ./test_op_custom,
          ./test_state_db,
          ./test_difficulty,
          ./test_transaction_json,
          # TODO: some of test_blockchain_json's test cases failing
          # see issue #2260
          ./test_blockchain_json, 
          ./test_forkid,
          ./test_multi_keys,
          ./test_misc,
          #./test_graphql,                         -- fails
          ./test_configuration,
          #./test_txpool,                          -- fails
          ./test_txpool2,
          #./test_merge,                           -- fails
          ./test_eip4844,
          ./test_beacon/test_skeleton,
          ./test_overflow,
          #./test_getproof_json,                   -- fails
          #./test_rpc_experimental_json,           -- fails
          ./test_aristo,
          ./test_coredb
