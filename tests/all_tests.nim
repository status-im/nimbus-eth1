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
          ./test_accounts_cache,
          ./test_aristo,
          ./test_coredb,
          #./test_sync_snap,                     -- temporarily suspended
          #./test_rocksdb_timing,                -- temporarily suspended
          ./test_jwt_auth,
          ./test_gas_meter,
          ./test_memory,
          ./test_stack,
          ./test_genesis,
          ./test_precompiles,
          ./test_generalstate_json,
          ./test_tracer_json,
          ./test_persistblock_json,
          ./test_rpc,
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
          ./test_blockchain_json,
          ./test_forkid,
          ../stateless/test_witness_keys,
          ../stateless/test_block_witness,
          ../stateless/test_witness_json,
          ../stateless/test_witness_verification,
          ./test_misc,
          ./test_graphql,
          ./test_clique,
          ./test_pow,
          ./test_configuration,
          ./test_keyed_queue_rlp,
          ./test_txpool,
          ./test_merge,
          ./test_eip4844,
          ./test_beacon/test_skeleton,
          ./test_overflow,
          ./test_getproof_json,
          ./test_rpc_experimental_json,
          ./test_persistblock_witness_json
