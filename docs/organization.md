.
├── BlockchainTests.md
├── Dockerfile
├── Dockerfile.debug
├── GeneralStateTests.md
├── LICENSE-APACHEv2
├── LICENSE-MIT
├── Makefile
├── PrecompileTests.md
├── README.md
├── TransactionTests.md
├── config.nims
├── default.nix
├── docker
│   ├── README.md
│   └── dist
│       ├── 0001-Makefile-support-Mingw-more-cross-compilation.patch
│       ├── Dockerfile.amd64
│       ├── Dockerfile.arm
│       ├── Dockerfile.arm64
│       ├── Dockerfile.macos
│       ├── Dockerfile.macos-arm64
│       ├── Dockerfile.win64
│       ├── README-Windows.md.tpl
│       ├── README.md.tpl
│       ├── base_image
│       │   ├── Dockerfile.amd64
│       │   ├── Dockerfile.arm
│       │   ├── Dockerfile.arm64
│       │   ├── Dockerfile.macos
│       │   ├── Dockerfile.win64
│       │   ├── Makefile
│       │   ├── README.md
│       │   ├── build_osxcross.sh
│       │   └── make_base_image.sh
│       ├── binaries
│       │   ├── Dockerfile.amd64
│       │   ├── Dockerfile.arm
│       │   ├── Dockerfile.arm64
│       │   ├── README.md
│       │   └── docker-compose-example1.yml
│       ├── entry_point.sh
│       └── rocksdb-7.0.2-arm.patch
├── docs
│   ├── evm.md
│   ├── main.md
│   └── organization.md
├── env.sh
├── examples
│   ├── Nimbus-Grafana-dashboard.json
│   ├── decompile_smart_contract.nim
│   └── prometheus.yml
├── execution_chain
│   ├── beacon
│   │   ├── api_handler
│   │   │   ├── api_forkchoice.nim
│   │   │   ├── api_getblobs.nim
│   │   │   ├── api_getbodies.nim
│   │   │   ├── api_getpayload.nim
│   │   │   ├── api_newpayload.nim
│   │   │   └── api_utils.nim
│   │   ├── api_handler.nim
│   │   ├── beacon_engine.nim
│   │   ├── payload_conv.nim
│   │   └── web3_eth_conv.nim
│   ├── common
│   │   ├── chain_config.nim
│   │   ├── chain_config_hash.nim
│   │   ├── common.nim
│   │   ├── context.nim
│   │   ├── evmforks.nim
│   │   ├── genesis.nim
│   │   ├── genesis_alloc.nim
│   │   ├── hardforks.nim
│   │   ├── logging.nim
│   │   └── manager.nim
│   ├── common.nim
│   ├── compile_info.nim
│   ├── config.nim
│   ├── constants.nim
│   ├── core
│   │   ├── block_import.nim
│   │   ├── chain
│   │   │   ├── forked_chain
│   │   │   │   ├── block_quarantine.nim
│   │   │   │   ├── chain_branch.nim
│   │   │   │   ├── chain_desc.nim
│   │   │   │   ├── chain_private.nim
│   │   │   │   └── chain_serialize.nim
│   │   │   ├── forked_chain.nim
│   │   │   ├── header_chain_cache.nim
│   │   │   └── persist_blocks.nim
│   │   ├── chain.nim
│   │   ├── dao.nim
│   │   ├── eip4844.nim
│   │   ├── eip6110.nim
│   │   ├── eip7691.nim
│   │   ├── eip7702.nim
│   │   ├── executor
│   │   │   ├── calculate_reward.nim
│   │   │   ├── executor_helpers.nim
│   │   │   ├── process_block.nim
│   │   │   └── process_transaction.nim
│   │   ├── executor.nim
│   │   ├── gaslimit.nim
│   │   ├── lazy_kzg.nim
│   │   ├── pow
│   │   │   ├── difficulty.nim
│   │   │   └── header.nim
│   │   ├── tx_pool
│   │   │   ├── tx_desc.nim
│   │   │   ├── tx_item.nim
│   │   │   ├── tx_packer.nim
│   │   │   └── tx_tabs.nim
│   │   ├── tx_pool.nim
│   │   ├── validate.nim
│   │   └── withdrawals.nim
│   ├── db
│   │   ├── README.md
│   │   ├── access_list.nim
│   │   ├── aristo
│   │   │   ├── README.md
│   │   │   ├── TODO.md
│   │   │   ├── aristo_blobify.nim
│   │   │   ├── aristo_check
│   │   │   │   ├── check_be.nim
│   │   │   │   ├── check_top.nim
│   │   │   │   └── check_twig.nim
│   │   │   ├── aristo_check.nim
│   │   │   ├── aristo_compute.nim
│   │   │   ├── aristo_constants.nim
│   │   │   ├── aristo_debug.nim
│   │   │   ├── aristo_delete
│   │   │   │   └── delete_subtree.nim
│   │   │   ├── aristo_delete.nim
│   │   │   ├── aristo_desc
│   │   │   │   ├── desc_backend.nim
│   │   │   │   ├── desc_error.nim
│   │   │   │   ├── desc_identifiers.nim
│   │   │   │   ├── desc_nibbles.nim
│   │   │   │   └── desc_structural.nim
│   │   │   ├── aristo_desc.nim
│   │   │   ├── aristo_fetch.nim
│   │   │   ├── aristo_get.nim
│   │   │   ├── aristo_hike.nim
│   │   │   ├── aristo_init
│   │   │   │   ├── init_common.nim
│   │   │   │   ├── memory_db.nim
│   │   │   │   ├── memory_only.nim
│   │   │   │   ├── persistent.nim
│   │   │   │   ├── rocks_db
│   │   │   │   │   ├── rdb_desc.nim
│   │   │   │   │   ├── rdb_get.nim
│   │   │   │   │   ├── rdb_init.nim
│   │   │   │   │   ├── rdb_put.nim
│   │   │   │   │   └── rdb_walk.nim
│   │   │   │   └── rocks_db.nim
│   │   │   ├── aristo_layers.nim
│   │   │   ├── aristo_merge.nim
│   │   │   ├── aristo_nearby.nim
│   │   │   ├── aristo_profile.nim
│   │   │   ├── aristo_proof.nim
│   │   │   ├── aristo_serialise.nim
│   │   │   ├── aristo_tx_frame.nim
│   │   │   ├── aristo_utils.nim
│   │   │   ├── aristo_vid.nim
│   │   │   └── aristo_walk
│   │   │       ├── memory_only.nim
│   │   │       ├── persistent.nim
│   │   │       └── walk_private.nim
│   │   ├── aristo.nim
│   │   ├── core_db
│   │   │   ├── README.md
│   │   │   ├── TODO.md
│   │   │   ├── backend
│   │   │   │   ├── aristo_db.nim
│   │   │   │   ├── aristo_rocksdb.nim
│   │   │   │   └── rocksdb_desc.nim
│   │   │   ├── base
│   │   │   │   ├── base_desc.nim
│   │   │   │   └── base_helpers.nim
│   │   │   ├── base.nim
│   │   │   ├── base_iterators.nim
│   │   │   ├── core_apps.nim
│   │   │   ├── memory_only.nim
│   │   │   └── persistent.nim
│   │   ├── core_db.nim
│   │   ├── era1_db
│   │   │   └── db_desc.nim
│   │   ├── era1_db.nim
│   │   ├── fcu_db.nim
│   │   ├── kvt
│   │   │   ├── kvt_constants.nim
│   │   │   ├── kvt_desc
│   │   │   │   └── desc_error.nim
│   │   │   ├── kvt_desc.nim
│   │   │   ├── kvt_init
│   │   │   │   ├── init_common.nim
│   │   │   │   ├── memory_db.nim
│   │   │   │   ├── memory_only.nim
│   │   │   │   ├── persistent.nim
│   │   │   │   ├── rocks_db
│   │   │   │   │   ├── rdb_desc.nim
│   │   │   │   │   ├── rdb_get.nim
│   │   │   │   │   ├── rdb_init.nim
│   │   │   │   │   ├── rdb_put.nim
│   │   │   │   │   └── rdb_walk.nim
│   │   │   │   └── rocks_db.nim
│   │   │   ├── kvt_layers.nim
│   │   │   ├── kvt_tx_frame.nim
│   │   │   ├── kvt_utils.nim
│   │   │   └── kvt_walk
│   │   │       ├── memory_only.nim
│   │   │       ├── persistent.nim
│   │   │       └── walk_private.nim
│   │   ├── kvt.nim
│   │   ├── kvt_cf.nim
│   │   ├── ledger.nim
│   │   ├── opts.nim
│   │   └── storage_types.nim
│   ├── errors.nim
│   ├── evm
│   │   ├── blake2b_f.nim
│   │   ├── blscurve.nim
│   │   ├── code_bytes.nim
│   │   ├── code_stream.nim
│   │   ├── computation.nim
│   │   ├── evm_errors.nim
│   │   ├── internals.nim
│   │   ├── interpreter
│   │   │   ├── forks_list.md
│   │   │   ├── forks_list.png
│   │   │   ├── gas_costs.nim
│   │   │   ├── gas_meter.nim
│   │   │   ├── op_codes.nim
│   │   │   ├── op_dispatcher.nim
│   │   │   ├── op_handlers
│   │   │   │   ├── oph_arithmetic.nim
│   │   │   │   ├── oph_blockdata.nim
│   │   │   │   ├── oph_call.nim
│   │   │   │   ├── oph_create.nim
│   │   │   │   ├── oph_defs.nim
│   │   │   │   ├── oph_dup.nim
│   │   │   │   ├── oph_envinfo.nim
│   │   │   │   ├── oph_gen_handlers.nim
│   │   │   │   ├── oph_hash.nim
│   │   │   │   ├── oph_helpers.nim
│   │   │   │   ├── oph_log.nim
│   │   │   │   ├── oph_memory.nim
│   │   │   │   ├── oph_push.nim
│   │   │   │   ├── oph_swap.nim
│   │   │   │   └── oph_sysops.nim
│   │   │   ├── op_handlers.nim
│   │   │   └── utils
│   │   │       ├── macros_gen_opcodes.nim
│   │   │       └── utils_numeric.nim
│   │   ├── interpreter_dispatch.nim
│   │   ├── memory.nim
│   │   ├── message.nim
│   │   ├── modexp.nim
│   │   ├── nimdoc.cfg
│   │   ├── precompiles.nim
│   │   ├── stack.nim
│   │   ├── state.nim
│   │   ├── tracer
│   │   │   ├── access_list_tracer.nim
│   │   │   ├── json_tracer.nim
│   │   │   └── legacy_tracer.nim
│   │   ├── transient_storage.nim
│   │   └── types.nim
│   ├── makefile
│   ├── networking
│   │   ├── bootnodes.nim
│   │   ├── discoveryv4
│   │   │   ├── enode.nim
│   │   │   └── kademlia.nim
│   │   ├── discoveryv4.nim
│   │   ├── p2p.nim
│   │   ├── p2p_backends_helpers.nim
│   │   ├── p2p_protocol_dsl.nim
│   │   ├── p2p_tracing.nim
│   │   ├── p2p_tracing_ctail_plugin.nim
│   │   ├── p2p_types.nim
│   │   ├── peer_pool.nim
│   │   ├── rlpx
│   │   │   ├── auth.nim
│   │   │   ├── ecies.nim
│   │   │   ├── rlpxcrypt.nim
│   │   │   └── rlpxtransport.nim
│   │   └── rlpx.nim
│   ├── nim.cfg
│   ├── nimbus_desc.nim
│   ├── nimbus_execution_client.nim
│   ├── nimbus_execution_client.nim.cfg
│   ├── nimbus_import.nim
│   ├── portal
│   │   └── portal.nim
│   ├── rpc
│   │   ├── common.nim
│   │   ├── cors.nim
│   │   ├── debug.nim
│   │   ├── engine_api.nim
│   │   ├── filters.nim
│   │   ├── jwt_auth.nim
│   │   ├── jwt_auth_helper.nim
│   │   ├── oracle.nim
│   │   ├── params.nim
│   │   ├── rpc_server.nim
│   │   ├── rpc_types.nim
│   │   ├── rpc_utils.nim
│   │   └── server_api.nim
│   ├── rpc.nim
│   ├── sync
│   │   ├── beacon
│   │   │   ├── Grafana-example.json
│   │   │   ├── README.md
│   │   │   ├── TODO.md
│   │   │   ├── worker
│   │   │   │   ├── blocks_staged
│   │   │   │   │   ├── bodies.nim
│   │   │   │   │   └── staged_queue.nim
│   │   │   │   ├── blocks_staged.nim
│   │   │   │   ├── blocks_unproc.nim
│   │   │   │   ├── headers_staged
│   │   │   │   │   ├── headers.nim
│   │   │   │   │   ├── staged_collect.nim
│   │   │   │   │   └── staged_queue.nim
│   │   │   │   ├── headers_staged.nim
│   │   │   │   ├── headers_unproc.nim
│   │   │   │   ├── helpers.nim
│   │   │   │   ├── start_stop.nim
│   │   │   │   ├── update
│   │   │   │   │   ├── metrics.nim
│   │   │   │   │   └── ticker.nim
│   │   │   │   └── update.nim
│   │   │   ├── worker.nim
│   │   │   ├── worker_config.nim
│   │   │   └── worker_desc.nim
│   │   ├── beacon.nim
│   │   ├── peers.nim
│   │   ├── sync_desc.nim
│   │   ├── sync_sched.nim
│   │   ├── wire_protocol
│   │   │   ├── handler.nim
│   │   │   ├── implementation.nim
│   │   │   ├── requester.nim
│   │   │   ├── responder.nim
│   │   │   ├── setup.nim
│   │   │   ├── trace_config.nim
│   │   │   └── types.nim
│   │   └── wire_protocol.nim
│   ├── tracer.nim
│   ├── transaction
│   │   ├── call_common.nim
│   │   ├── call_evm.nim
│   │   └── call_types.nim
│   ├── transaction.nim
│   ├── utils
│   │   ├── debug.nim
│   │   ├── era_helpers.nim
│   │   ├── mergeutils.nim
│   │   ├── prettify.nim
│   │   ├── state_dump.nim
│   │   └── utils.nim
│   └── version.nim
├── fluffy
│   ├── README.md
│   ├── common
│   │   ├── common_types.nim
│   │   └── common_utils.nim
│   ├── conf.nim
│   ├── database
│   │   ├── content_db.nim
│   │   ├── content_db_custom_sql_functions.nim
│   │   ├── content_db_migrate_deprecated.nim
│   │   └── era1_db.nim
│   ├── docs
│   │   └── the_fluffy_book
│   │       ├── docs
│   │       │   ├── CNAME
│   │       │   ├── access-content.md
│   │       │   ├── adding-documentation.md
│   │       │   ├── basics-for-developers.md
│   │       │   ├── beacon-content-bridging.md
│   │       │   ├── build-from-source.md
│   │       │   ├── calling-a-contract.md
│   │       │   ├── connect-to-portal.md
│   │       │   ├── db_pruning.md
│   │       │   ├── eth-data-exporter.md
│   │       │   ├── fluffy-with-hive.md
│   │       │   ├── history-content-bridging.md
│   │       │   ├── index.md
│   │       │   ├── metrics.md
│   │       │   ├── prerequisites.md
│   │       │   ├── protocol-interop-testing.md
│   │       │   ├── quick-start-docker.md
│   │       │   ├── quick-start-windows.md
│   │       │   ├── quick-start.md
│   │       │   ├── run-local-testnet.md
│   │       │   ├── state-content-bridging.md
│   │       │   ├── stylesheets
│   │       │   │   └── extra.css
│   │       │   ├── test-suite.md
│   │       │   ├── testnet-beacon-network.md
│   │       │   ├── testnet-history-network.md
│   │       │   └── upgrade.md
│   │       └── mkdocs.yml
│   ├── eth_data
│   │   ├── era1.nim
│   │   ├── history_data_json_store.nim
│   │   ├── history_data_seeding.nim
│   │   ├── history_data_ssz_e2s.nim
│   │   ├── yaml_eth_types.nim
│   │   └── yaml_utils.nim
│   ├── evm
│   │   ├── async_evm.nim
│   │   └── async_evm_portal_backend.nim
│   ├── fluffy.nim
│   ├── fluffy.nim.cfg
│   ├── grafana
│   │   └── fluffy_grafana_dashboard.json
│   ├── logging.nim
│   ├── network
│   │   ├── beacon
│   │   │   ├── beacon_chain_historical_roots.nim
│   │   │   ├── beacon_chain_historical_summaries.nim
│   │   │   ├── beacon_content.nim
│   │   │   ├── beacon_db.nim
│   │   │   ├── beacon_init_loader.nim
│   │   │   ├── beacon_light_client.nim
│   │   │   ├── beacon_light_client_manager.nim
│   │   │   ├── beacon_network.nim
│   │   │   ├── beacon_validation.nim
│   │   │   └── content
│   │   │       ├── content_keys.nim
│   │   │       └── content_values.nim
│   │   ├── history
│   │   │   ├── content
│   │   │   │   ├── content_keys.nim
│   │   │   │   ├── content_values.nim
│   │   │   │   └── content_values_deprecated.nim
│   │   │   ├── history_content.nim
│   │   │   ├── history_network.nim
│   │   │   ├── history_type_conversions.nim
│   │   │   ├── history_validation.nim
│   │   │   └── validation
│   │   │       ├── block_proof_common.nim
│   │   │       ├── block_proof_historical_hashes_accumulator.nim
│   │   │       ├── block_proof_historical_roots.nim
│   │   │       ├── block_proof_historical_summaries.nim
│   │   │       └── historical_hashes_accumulator.nim
│   │   ├── state
│   │   │   ├── content
│   │   │   │   ├── content_keys.nim
│   │   │   │   ├── content_values.nim
│   │   │   │   └── nibbles.nim
│   │   │   ├── state_content.nim
│   │   │   ├── state_endpoints.nim
│   │   │   ├── state_gossip.nim
│   │   │   ├── state_network.nim
│   │   │   ├── state_utils.nim
│   │   │   └── state_validation.nim
│   │   └── wire
│   │       ├── README.md
│   │       ├── messages.nim
│   │       ├── ping_extensions.nim
│   │       ├── portal_protocol.nim
│   │       ├── portal_protocol_config.nim
│   │       ├── portal_protocol_version.nim
│   │       └── portal_stream.nim
│   ├── network_metadata.nim
│   ├── nim.cfg
│   ├── portal_node.nim
│   ├── rpc
│   │   ├── eth_rpc_client.nim
│   │   ├── portal_rpc_client.nim
│   │   ├── rpc_calls
│   │   │   ├── rpc_debug_calls.nim
│   │   │   ├── rpc_discovery_calls.nim
│   │   │   ├── rpc_eth_calls.nim
│   │   │   ├── rpc_portal_calls.nim
│   │   │   ├── rpc_portal_debug_calls.nim
│   │   │   └── rpc_trace_calls.nim
│   │   ├── rpc_debug_api.nim
│   │   ├── rpc_discovery_api.nim
│   │   ├── rpc_eth_api.nim
│   │   ├── rpc_portal_beacon_api.nim
│   │   ├── rpc_portal_common_api.nim
│   │   ├── rpc_portal_debug_history_api.nim
│   │   ├── rpc_portal_history_api.nim
│   │   ├── rpc_portal_nimbus_beacon_api.nim
│   │   ├── rpc_portal_state_api.nim
│   │   └── rpc_types.nim
│   ├── scripts
│   │   ├── launch_local_testnet.sh
│   │   ├── makedir.sh
│   │   ├── nim.cfg
│   │   └── test_portal_testnet.nim
│   ├── tests
│   │   ├── all_fluffy_tests.nim
│   │   ├── beacon_network_tests
│   │   │   ├── all_beacon_network_tests.nim
│   │   │   ├── beacon_test_helpers.nim
│   │   │   ├── light_client_test_data.nim
│   │   │   ├── test_beacon_content.nim
│   │   │   ├── test_beacon_historical_roots.nim
│   │   │   ├── test_beacon_historical_summaries.nim
│   │   │   ├── test_beacon_historical_summaries_vectors.nim
│   │   │   ├── test_beacon_light_client.nim
│   │   │   └── test_beacon_network.nim
│   │   ├── blocks
│   │   │   ├── mainnet_blocks_1-2.json
│   │   │   ├── mainnet_blocks_1000001_1000010.json
│   │   │   ├── mainnet_blocks_1000011_1000030.json
│   │   │   ├── mainnet_blocks_1000040_1000050.json
│   │   │   └── mainnet_blocks_selected.json
│   │   ├── custom_genesis
│   │   │   ├── berlin2000.json
│   │   │   ├── calaveras.json
│   │   │   ├── chainid1.json
│   │   │   ├── chainid7.json
│   │   │   ├── devnet4.json
│   │   │   ├── devnet5.json
│   │   │   ├── holesky.json
│   │   │   ├── mainshadow1.json
│   │   │   └── merge.json
│   │   ├── evm
│   │   │   ├── all_evm_tests.nim
│   │   │   ├── async_evm_test_backend.nim
│   │   │   └── test_async_evm.nim
│   │   ├── history_network_tests
│   │   │   ├── all_history_network_custom_chain_tests.nim
│   │   │   ├── all_history_network_tests.nim
│   │   │   ├── test_block_proof_historical_roots.nim
│   │   │   ├── test_block_proof_historical_roots_vectors.nim
│   │   │   ├── test_block_proof_historical_summaries.nim
│   │   │   ├── test_block_proof_historical_summaries_deneb.nim
│   │   │   ├── test_block_proof_historical_summaries_vectors.nim
│   │   │   ├── test_historical_hashes_accumulator.nim
│   │   │   ├── test_historical_hashes_accumulator_root.nim
│   │   │   ├── test_history_content.nim
│   │   │   ├── test_history_content_keys.nim
│   │   │   ├── test_history_content_validation.nim
│   │   │   ├── test_history_network.nim
│   │   │   └── test_history_util.nim
│   │   ├── rpc_tests
│   │   │   ├── all_rpc_tests.nim
│   │   │   ├── test_discovery_rpc.nim
│   │   │   └── test_portal_rpc_client.nim
│   │   ├── state_network_tests
│   │   │   ├── all_state_network_tests.nim
│   │   │   ├── state_test_helpers.nim
│   │   │   ├── test_state_content_keys_vectors.nim
│   │   │   ├── test_state_content_nibbles.nim
│   │   │   ├── test_state_content_values_vectors.nim
│   │   │   ├── test_state_endpoints_genesis.nim
│   │   │   ├── test_state_endpoints_vectors.nim
│   │   │   ├── test_state_gossip_getparent_genesis.nim
│   │   │   ├── test_state_gossip_getparent_vectors.nim
│   │   │   ├── test_state_gossip_gossipoffer_vectors.nim
│   │   │   ├── test_state_network_getcontent_vectors.nim
│   │   │   ├── test_state_network_offercontent_vectors.nim
│   │   │   ├── test_state_validation_genesis.nim
│   │   │   ├── test_state_validation_trieproof.nim
│   │   │   └── test_state_validation_vectors.nim
│   │   ├── test_content_db.nim
│   │   ├── test_helpers.nim
│   │   └── wire_protocol_tests
│   │       ├── all_wire_protocol_tests.nim
│   │       ├── test_ping_extensions_encoding.nim
│   │       ├── test_portal_wire_encoding.nim
│   │       ├── test_portal_wire_protocol.nim
│   │       └── test_portal_wire_version.nim
│   ├── tools
│   │   ├── benchmark.nim
│   │   ├── blockwalk.nim
│   │   ├── docker
│   │   │   ├── Dockerfile
│   │   │   ├── Dockerfile.debug
│   │   │   ├── Dockerfile.debug.dockerignore
│   │   │   └── Dockerfile.debug.linux
│   │   ├── eth_data_exporter
│   │   │   ├── cl_data_exporter.nim
│   │   │   ├── downloader.nim
│   │   │   ├── exporter_common.nim
│   │   │   ├── exporter_conf.nim
│   │   │   └── parser.nim
│   │   ├── eth_data_exporter.nim
│   │   ├── fcli_db.nim
│   │   ├── portal_bridge
│   │   │   ├── nim.cfg
│   │   │   ├── portal_bridge.nim
│   │   │   ├── portal_bridge_beacon.nim
│   │   │   ├── portal_bridge_common.nim
│   │   │   ├── portal_bridge_conf.nim
│   │   │   ├── portal_bridge_history.nim
│   │   │   ├── portal_bridge_state.nim
│   │   │   └── state_bridge
│   │   │       ├── database.nim
│   │   │       ├── offers_builder.nim
│   │   │       ├── state_diff.nim
│   │   │       ├── world_state.nim
│   │   │       └── world_state_helper.nim
│   │   ├── portalcli.nim
│   │   └── utp_testing
│   │       ├── README.md
│   │       ├── docker
│   │       │   ├── Dockerfile
│   │       │   ├── docker-compose.yml
│   │       │   ├── run_endpoint.sh
│   │       │   └── setup.sh
│   │       ├── utp_rpc_types.nim
│   │       ├── utp_test.nim
│   │       ├── utp_test_app.nim
│   │       ├── utp_test_rpc_calls.nim
│   │       └── utp_test_rpc_client.nim
│   └── version.nim
├── hive_integration
│   ├── README.md
│   ├── docker-shell
│   ├── nimbus
│   │   ├── Dockerfile
│   │   ├── enode.sh
│   │   ├── genesis.json
│   │   ├── mapper.jq
│   │   └── nimbus.sh
│   └── nodocker
│       ├── build_sims.sh
│       ├── consensus
│       │   ├── consensus_sim.nim
│       │   └── extract_consensus_data.nim
│       ├── engine
│       │   ├── auths_tests.nim
│       │   ├── base_spec.nim
│       │   ├── cancun
│       │   │   ├── blobs.nim
│       │   │   ├── customizer.nim
│       │   │   ├── helpers.nim
│       │   │   ├── step_desc.nim
│       │   │   ├── step_devp2p_peering.nim
│       │   │   ├── step_devp2p_pooledtx.nim
│       │   │   ├── step_launch_client.nim
│       │   │   ├── step_newpayloads.nim
│       │   │   ├── step_paralel.nim
│       │   │   ├── step_sendblobtx.nim
│       │   │   └── step_sendmodpayload.nim
│       │   ├── cancun_tests.nim
│       │   ├── chains
│       │   │   ├── README.md
│       │   │   ├── blocks_1024_td_135112316.rlp
│       │   │   ├── blocks_10_td_1971072_1.rlp
│       │   │   ├── blocks_10_td_1971072_2.rlp
│       │   │   ├── blocks_10_td_1971072_3.rlp
│       │   │   ├── blocks_10_td_1971072_4.rlp
│       │   │   ├── blocks_10_td_1971072_5.rlp
│       │   │   ├── blocks_1_td_196416.rlp
│       │   │   ├── blocks_1_td_196608.rlp
│       │   │   ├── blocks_1_td_196704.rlp
│       │   │   ├── blocks_2_td_393120.rlp
│       │   │   └── blocks_2_td_393504.rlp
│       │   ├── client_pool.nim
│       │   ├── clmock.nim
│       │   ├── engine
│       │   │   ├── bad_hash.nim
│       │   │   ├── engine_spec.nim
│       │   │   ├── fork_id.nim
│       │   │   ├── forkchoice.nim
│       │   │   ├── invalid_ancestor.nim
│       │   │   ├── invalid_payload.nim
│       │   │   ├── misc.nim
│       │   │   ├── payload_attributes.nim
│       │   │   ├── payload_execution.nim
│       │   │   ├── payload_id.nim
│       │   │   ├── prev_randao.nim
│       │   │   ├── reorg.nim
│       │   │   ├── rpc.nim
│       │   │   ├── suggested_fee_recipient.nim
│       │   │   └── versioning.nim
│       │   ├── engine_client.nim
│       │   ├── engine_env.nim
│       │   ├── engine_sim.nim
│       │   ├── engine_tests.nim
│       │   ├── exchange_cap_tests.nim
│       │   ├── helper.nim
│       │   ├── init
│       │   │   ├── genesis.json
│       │   │   └── sealer.key
│       │   ├── node.nim
│       │   ├── test_env.nim
│       │   ├── tx_sender.nim
│       │   ├── types.nim
│       │   ├── withdrawal_tests.nim
│       │   └── withdrawals
│       │       ├── wd_base_spec.nim
│       │       ├── wd_block_value_spec.nim
│       │       ├── wd_history.nim
│       │       ├── wd_max_init_code_spec.nim
│       │       ├── wd_payload_body_spec.nim
│       │       ├── wd_reorg_spec.nim
│       │       └── wd_sync_spec.nim
│       ├── pyspec
│       │   ├── pyspec_sim.nim
│       │   ├── test_env.nim
│       │   └── testcases
│       │       ├── access_list.json
│       │       ├── balance_within_block.json
│       │       ├── chainid.json
│       │       ├── contract_creating_tx.json
│       │       ├── create_opcode_initcode.json
│       │       ├── dup.json
│       │       ├── gas_usage.json
│       │       ├── large_amount.json
│       │       ├── many_withdrawals.json
│       │       ├── multiple_withdrawals_same_address.json
│       │       ├── newly_created_contract.json
│       │       ├── no_evm_execution.json
│       │       ├── push0_before_jumpdest.json
│       │       ├── push0_during_staticcall.json
│       │       ├── push0_fill_stack.json
│       │       ├── push0_gas_cost.json
│       │       ├── push0_key_sstore.json
│       │       ├── push0_stack_overflow.json
│       │       ├── push0_storage_overwrite.json
│       │       ├── self_destructing_account.json
│       │       ├── tx_selfdestruct_balance_bug.json
│       │       ├── use_value_in_contract.json
│       │       ├── use_value_in_tx.json
│       │       ├── warm_coinbase_call_out_of_gas.json
│       │       ├── warm_coinbase_gas_usage.json
│       │       ├── yul.json
│       │       └── zero_amount.json
│       ├── rpc
│       │   ├── client.nim
│       │   ├── init
│       │   │   ├── genesis.json
│       │   │   └── private-key
│       │   ├── rpc_sim.nim
│       │   ├── rpc_tests.nim
│       │   ├── test_env.nim
│       │   └── vault.nim
│       └── sim_utils.nim
├── kurtosis-network-params.yml
├── nimbus.nimble
├── nimbus.nims -> nimbus.nimble
├── nimbus_verified_proxy
│   ├── README.md
│   ├── block_cache.nim
│   ├── docs
│   │   └── metamask_configuration.md
│   ├── libverifproxy
│   │   ├── nim.cfg
│   │   ├── verifproxy.h
│   │   └── verifproxy.nim
│   ├── nim.cfg
│   ├── nimbus_verified_proxy.nim
│   ├── nimbus_verified_proxy_conf.nim
│   ├── rpc
│   │   └── rpc_eth_api.nim
│   ├── tests
│   │   └── test_proof_validation.nim
│   └── validate_proof.nim
├── nix
│   ├── flake.lock
│   ├── flake.nix
│   ├── mkFilter.nix
│   ├── nim.nix
│   ├── nimbus-wrappers.nix
│   ├── nimbus.nix
│   └── shell.nix
├── nrpc
│   ├── config.nim
│   ├── nim.cfg
│   └── nrpc.nim
├── run-kurtosis-check.sh
├── scripts
│   ├── README.md
│   ├── block-import-stats.py
│   ├── check_copyright_year.sh
│   ├── make_dist.sh
│   ├── make_states.sh
│   ├── print_version.nims
│   ├── requirements.in
│   └── requirements.txt
├── tests
│   ├── all_tests.nim
│   ├── asynctest.nim
│   ├── bootstrap
│   │   ├── append_bootnodes.txt
│   │   └── override_bootnodes.txt
│   ├── customgenesis
│   │   ├── berlin2000.json
│   │   ├── blobschedule_cancun_osaka.json
│   │   ├── blobschedule_cancun_prague.json
│   │   ├── blobschedule_nobasefee.json
│   │   ├── blobschedule_prague.json
│   │   ├── calaveras.json
│   │   ├── cancun123.json
│   │   ├── chainid1.json
│   │   ├── chainid7.json
│   │   ├── devnet4.json
│   │   ├── devnet5.json
│   │   ├── engine_api_genesis.json
│   │   ├── geth_holesky.json
│   │   ├── geth_mainshadow1.json
│   │   ├── holesky.json
│   │   ├── mainshadow1.json
│   │   ├── mekong.json
│   │   ├── merge.json
│   │   ├── noconfig.json
│   │   ├── nogenesis.json
│   │   ├── post-merge.json
│   │   └── prague.json
│   ├── engine_api
│   │   ├── genesis_base_canonical.json
│   │   ├── newPayloadV4_empty_requests_data.json
│   │   ├── newPayloadV4_invalid_blockhash.json
│   │   ├── newPayloadV4_invalid_requests.json
│   │   ├── newPayloadV4_invalid_requests_order.json
│   │   ├── newPayloadV4_invalid_requests_type.json
│   │   └── newPayloadV4_requests_order.json
│   ├── fixtures
│   │   ├── PrecompileTests
│   │   │   ├── blake2F.json
│   │   │   ├── blsG1Add.json
│   │   │   ├── blsG1MultiExp.json
│   │   │   ├── blsG2Add.json
│   │   │   ├── blsG2MultiExp.json
│   │   │   ├── blsMapG1.json
│   │   │   ├── blsMapG2.json
│   │   │   ├── blsPairing.json
│   │   │   ├── bn256Add.json
│   │   │   ├── bn256Add_istanbul.json
│   │   │   ├── bn256mul.json
│   │   │   ├── bn256mul_istanbul.json
│   │   │   ├── ecrecover.json
│   │   │   ├── eest
│   │   │   │   ├── add_G1_bls.json
│   │   │   │   ├── add_G2_bls.json
│   │   │   │   ├── fail-add_G1_bls.json
│   │   │   │   ├── fail-add_G2_bls.json
│   │   │   │   ├── fail-map_fp2_to_G2_bls.json
│   │   │   │   ├── fail-map_fp_to_G1_bls.json
│   │   │   │   ├── fail-msm_G1_bls.json
│   │   │   │   ├── fail-msm_G2_bls.json
│   │   │   │   ├── fail-mul_G1_bls.json
│   │   │   │   ├── fail-mul_G2_bls.json
│   │   │   │   ├── fail-pairing_check_bls.json
│   │   │   │   ├── map_fp2_to_G2_bls.json
│   │   │   │   ├── map_fp_to_G1_bls.json
│   │   │   │   ├── msm_G1_bls.json
│   │   │   │   ├── msm_G2_bls.json
│   │   │   │   ├── mul_G1_bls.json
│   │   │   │   ├── mul_G2_bls.json
│   │   │   │   └── pairing_check_bls.json
│   │   │   ├── identity.json
│   │   │   ├── modexp.json
│   │   │   ├── modexp_eip2565.json
│   │   │   ├── pairing.json
│   │   │   ├── pairing_istanbul.json
│   │   │   ├── ripemd160.json
│   │   │   └── sha256.json
│   │   ├── TracerTests
│   │   │   ├── block46147.json
│   │   │   ├── block46400.json
│   │   │   ├── block46402.json
│   │   │   ├── block47205.json
│   │   │   ├── block48712.json
│   │   │   ├── block48915.json
│   │   │   ├── block49018.json
│   │   │   └── block97.json
│   │   └── eth_tests
│   ├── graphql
│   │   └── queries.toml
│   ├── invalid_keystore
│   │   ├── missingaddress
│   │   │   └── missingaddress.json
│   │   └── notobject
│   │       └── notobject.json
│   ├── keystore
│   │   ├── applebanana
│   │   ├── bananamonkey
│   │   └── monkeyelephant
│   ├── macro_assembler.nim
│   ├── networking
│   │   ├── eth_protocol.nim
│   │   ├── fuzzing
│   │   │   ├── discoveryv4
│   │   │   │   ├── fuzz.nim
│   │   │   │   └── generate.nim
│   │   │   ├── fuzzing_helpers.nim
│   │   │   └── rlpx
│   │   │       └── thunk.nim
│   │   ├── p2p_test_helper.nim
│   │   ├── stubloglevel.nim
│   │   ├── test_auth.nim
│   │   ├── test_crypt.nim
│   │   ├── test_discoveryv4.nim
│   │   ├── test_ecies.nim
│   │   ├── test_enode.nim
│   │   ├── test_protocol_handlers.nim
│   │   ├── test_rlpx_thunk.json
│   │   ├── test_rlpx_thunk.nim
│   │   └── test_rlpxtransport.nim
│   ├── nim.cfg
│   ├── replay
│   │   ├── gunzip.nim
│   │   ├── mainnet-00000-5ec1ffb8.era1
│   │   ├── pp.nim
│   │   ├── pp_light.nim
│   │   ├── undump_blocks.nim
│   │   ├── undump_blocks_era1.nim
│   │   ├── undump_blocks_gz.nim
│   │   ├── undump_helpers.nim
│   │   └── xcheck.nim
│   ├── test_allowed_to_fail.nim
│   ├── test_aristo
│   │   ├── sample0.txt.gz
│   │   ├── sample1.txt.gz
│   │   ├── sample2.txt.gz
│   │   ├── sample3.txt.gz
│   │   ├── test_blobify.nim
│   │   ├── test_compute.nim
│   │   ├── test_tx_frame.nim
│   │   ├── undump_accounts.nim
│   │   ├── undump_desc.nim
│   │   └── undump_storages.nim
│   ├── test_aristo.nim
│   ├── test_block_fixture.nim
│   ├── test_blockchain_json.nim
│   ├── test_config.nim
│   ├── test_configuration.nim
│   ├── test_coredb
│   │   ├── coredb_test_xx.nim
│   │   ├── test_chainsync.nim
│   │   └── test_helpers.nim
│   ├── test_coredb.nim
│   ├── test_coredb.nim.cfg
│   ├── test_difficulty.nim
│   ├── test_engine_api.nim
│   ├── test_evm_support.nim
│   ├── test_filters.nim
│   ├── test_forked_chain
│   │   └── chain_debug.nim
│   ├── test_forked_chain.nim
│   ├── test_forkid.nim
│   ├── test_generalstate_json.nim
│   ├── test_genesis.nim
│   ├── test_getproof_json.nim
│   ├── test_helpers.nim
│   ├── test_jwt_auth
│   │   ├── jwtsecret.txt
│   │   └── jwtstripped.txt
│   ├── test_jwt_auth.nim
│   ├── test_kvt.nim
│   ├── test_ledger.nim
│   ├── test_networking.nim
│   ├── test_op_arith.nim
│   ├── test_op_bit.nim
│   ├── test_op_custom.nim
│   ├── test_op_env.nim
│   ├── test_op_memory.nim
│   ├── test_op_misc.nim
│   ├── test_precompiles.nim
│   ├── test_rpc.nim
│   ├── test_tools_build.nim
│   ├── test_transaction_json.nim
│   └── test_txpool.nim
├── tools
│   ├── common
│   │   ├── helpers.nim
│   │   ├── state_clearing.nim
│   │   └── types.nim
│   ├── evmstate
│   │   ├── config.nim
│   │   ├── config.nims
│   │   ├── evmstate.nim
│   │   ├── evmstate_test.nim
│   │   ├── helpers.nim
│   │   ├── readme.md
│   │   └── testdata
│   │       ├── 00000682-mixed-0-1.json
│   │       ├── 00000682-mixed-0.json
│   │       ├── 00001742-mixed-2.json
│   │       ├── 00003745-mixed-0.json
│   │       ├── 00094809-mixed-5.json
│   │       ├── 00155493-mixed-6.json
│   │       ├── 01400578-mixed-11.json
│   │       └── modexp-big-modulo.json
│   ├── t8n
│   │   ├── config.nim
│   │   ├── config.nims
│   │   ├── helpers.nim
│   │   ├── readme.md
│   │   ├── t8n.nim
│   │   ├── t8n_debug.nim
│   │   ├── t8n_test.nim
│   │   ├── testdata
│   │   │   ├── 00-501
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env.json
│   │   │   │   ├── exp.json
│   │   │   │   └── txs.rlp
│   │   │   ├── 00-502
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env.json
│   │   │   │   ├── exp.json
│   │   │   │   ├── txs.json
│   │   │   │   └── txs.rlp
│   │   │   ├── 00-503
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env.json
│   │   │   │   ├── exp.json
│   │   │   │   └── txs.json
│   │   │   ├── 00-504
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env.json
│   │   │   │   ├── exp.json
│   │   │   │   └── txs.json
│   │   │   ├── 00-505
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env.json
│   │   │   │   ├── exp.json
│   │   │   │   └── txs.json
│   │   │   ├── 00-506
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env.json
│   │   │   │   ├── exp.json
│   │   │   │   └── txs.json
│   │   │   ├── 00-507
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env.json
│   │   │   │   ├── exp.json
│   │   │   │   └── txs.json
│   │   │   ├── 00-508
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env.json
│   │   │   │   ├── exp.json
│   │   │   │   └── txs.json
│   │   │   ├── 00-509
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env.json
│   │   │   │   ├── exp.json
│   │   │   │   └── txs.json
│   │   │   ├── 00-510
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env.json
│   │   │   │   ├── exp.json
│   │   │   │   └── txs.json
│   │   │   ├── 00-511
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env.json
│   │   │   │   ├── exp.json
│   │   │   │   └── txs.rlp
│   │   │   ├── 00-512
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env.json
│   │   │   │   ├── exp.json
│   │   │   │   └── txs.rlp
│   │   │   ├── 00-513
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env.json
│   │   │   │   ├── exp.json
│   │   │   │   └── txs.rlp
│   │   │   ├── 00-514
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env.json
│   │   │   │   ├── exp.json
│   │   │   │   └── txs.rlp
│   │   │   ├── 00-515
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env.json
│   │   │   │   └── txs.json
│   │   │   ├── 00-516
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env.json
│   │   │   │   ├── exp.json
│   │   │   │   └── txs.rlp
│   │   │   ├── 00-517
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env.json
│   │   │   │   ├── exp.json
│   │   │   │   └── txs.json
│   │   │   ├── 00-518
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env.json
│   │   │   │   ├── exp.json
│   │   │   │   └── txs.json
│   │   │   ├── 00-519
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env.json
│   │   │   │   ├── exp.txt
│   │   │   │   └── txs.json
│   │   │   ├── 00-520
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env.json
│   │   │   │   ├── exp.txt
│   │   │   │   └── txs.json
│   │   │   ├── 00-521
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env.json
│   │   │   │   ├── exp.txt
│   │   │   │   └── txs.json
│   │   │   ├── 00-522
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env.json
│   │   │   │   ├── exp.txt
│   │   │   │   ├── istanbul.txt
│   │   │   │   └── txs.json
│   │   │   ├── 00-523
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env.json
│   │   │   │   ├── exp.json
│   │   │   │   └── txs.rlp
│   │   │   ├── 00-524
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env.json
│   │   │   │   ├── exp.json
│   │   │   │   └── txs.rlp
│   │   │   ├── 00-525
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env.json
│   │   │   │   ├── env_dca.json
│   │   │   │   ├── exp1.json
│   │   │   │   ├── exp2.json
│   │   │   │   ├── exp3.json
│   │   │   │   └── txs.rlp
│   │   │   ├── 00-526
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env.json
│   │   │   │   ├── exp.json
│   │   │   │   └── txs.rlp
│   │   │   ├── 00-527
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env.json
│   │   │   │   ├── exp.json
│   │   │   │   └── txs.rlp
│   │   │   ├── 00-528
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env.json
│   │   │   │   ├── exp.json
│   │   │   │   └── txs.rlp
│   │   │   ├── 1
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env.json
│   │   │   │   ├── exp.json
│   │   │   │   └── txs.json
│   │   │   ├── 10
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env.json
│   │   │   │   ├── readme.md
│   │   │   │   └── txs.json
│   │   │   ├── 11
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env.json
│   │   │   │   ├── readme.md
│   │   │   │   └── txs.json
│   │   │   ├── 12
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env.json
│   │   │   │   ├── readme.md
│   │   │   │   └── txs.json
│   │   │   ├── 13
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env.json
│   │   │   │   ├── exp.json
│   │   │   │   ├── exp2.json
│   │   │   │   ├── readme.md
│   │   │   │   ├── signed_txs.rlp
│   │   │   │   └── txs.json
│   │   │   ├── 14
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env.json
│   │   │   │   ├── env.uncles.json
│   │   │   │   ├── exp.json
│   │   │   │   ├── exp2.json
│   │   │   │   ├── exp_berlin.json
│   │   │   │   ├── readme.md
│   │   │   │   └── txs.json
│   │   │   ├── 15
│   │   │   │   ├── blockheader.rlp
│   │   │   │   ├── exp.json
│   │   │   │   ├── exp2.json
│   │   │   │   ├── exp3.json
│   │   │   │   ├── signed_txs.rlp
│   │   │   │   └── signed_txs.rlp.json
│   │   │   ├── 16
│   │   │   │   ├── exp.json
│   │   │   │   ├── signed_txs.rlp
│   │   │   │   └── unsigned_txs.json
│   │   │   ├── 17
│   │   │   │   ├── exp.json
│   │   │   │   ├── rlpdata.txt
│   │   │   │   └── signed_txs.rlp
│   │   │   ├── 18
│   │   │   │   ├── README.md
│   │   │   │   └── invalid.rlp
│   │   │   ├── 19
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env.json
│   │   │   │   ├── exp_arrowglacier.json
│   │   │   │   ├── exp_grayglacier.json
│   │   │   │   ├── exp_london.json
│   │   │   │   ├── readme.md
│   │   │   │   └── txs.json
│   │   │   ├── 2
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env.json
│   │   │   │   ├── readme.md
│   │   │   │   └── txs.json
│   │   │   ├── 20
│   │   │   │   ├── exp.json
│   │   │   │   ├── header.json
│   │   │   │   ├── ommers.json
│   │   │   │   ├── readme.md
│   │   │   │   └── txs.rlp
│   │   │   ├── 21
│   │   │   │   ├── clique.json
│   │   │   │   ├── exp-clique.json
│   │   │   │   ├── exp.json
│   │   │   │   ├── header.json
│   │   │   │   ├── ommers.json
│   │   │   │   ├── readme.md
│   │   │   │   └── txs.rlp
│   │   │   ├── 22
│   │   │   │   ├── exp-clique.json
│   │   │   │   ├── exp.json
│   │   │   │   ├── header.json
│   │   │   │   ├── ommers.json
│   │   │   │   ├── readme.md
│   │   │   │   └── txs.rlp
│   │   │   ├── 23
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env.json
│   │   │   │   ├── exp.json
│   │   │   │   ├── readme.md
│   │   │   │   └── txs.json
│   │   │   ├── 24
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env-missingrandom.json
│   │   │   │   ├── env.json
│   │   │   │   ├── exp.json
│   │   │   │   └── txs.json
│   │   │   ├── 25
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env.json
│   │   │   │   ├── exp.json
│   │   │   │   └── txs.json
│   │   │   ├── 26
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env.json
│   │   │   │   ├── exp.json
│   │   │   │   └── txs.json
│   │   │   ├── 27
│   │   │   │   ├── exp.json
│   │   │   │   ├── header.json
│   │   │   │   ├── ommers.json
│   │   │   │   ├── txs.rlp
│   │   │   │   └── withdrawals.json
│   │   │   ├── 28
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env.json
│   │   │   │   ├── exp.json
│   │   │   │   └── txs.rlp
│   │   │   ├── 29
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env.json
│   │   │   │   ├── exp.json
│   │   │   │   ├── readme.md
│   │   │   │   └── txs.json
│   │   │   ├── 3
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env.json
│   │   │   │   ├── exp.json
│   │   │   │   ├── readme.md
│   │   │   │   └── txs.json
│   │   │   ├── 30
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env.json
│   │   │   │   ├── exp.json
│   │   │   │   └── txs_more.rlp
│   │   │   ├── 33
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env.json
│   │   │   │   ├── exp.json
│   │   │   │   └── txs.json
│   │   │   ├── 4
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env.json
│   │   │   │   ├── readme.md
│   │   │   │   └── txs.json
│   │   │   ├── 5
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env.json
│   │   │   │   ├── exp.json
│   │   │   │   ├── readme.md
│   │   │   │   └── txs.json
│   │   │   ├── 7
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env.json
│   │   │   │   ├── readme.md
│   │   │   │   └── txs.json
│   │   │   ├── 8
│   │   │   │   ├── alloc.json
│   │   │   │   ├── env.json
│   │   │   │   ├── readme.md
│   │   │   │   └── txs.json
│   │   │   └── 9
│   │   │       ├── alloc.json
│   │   │       ├── env.json
│   │   │       ├── readme.md
│   │   │       └── txs.json
│   │   ├── transition.nim
│   │   └── types.nim
│   └── txparse
│       ├── readme.md
│       ├── sample.input
│       ├── testdata
│       │   ├── rlp.json
│       │   ├── sample.json
│       │   └── values.json
│       ├── txparse.nim
│       └── txparse_test.nim
└── vendor
    ├── NimYAML
    ├── libtommath
    ├── nim-bearssl
    ├── nim-blscurve
    ├── nim-bncurve
    ├── nim-chronicles
    ├── nim-chronos
    ├── nim-confutils
    ├── nim-eth
    ├── nim-faststreams
    ├── nim-http-utils
    ├── nim-json-rpc
    ├── nim-json-serialization
    ├── nim-kzg4844
    ├── nim-libbacktrace
    ├── nim-libp2p
    ├── nim-metrics
    ├── nim-minilru
    ├── nim-nat-traversal
    ├── nim-normalize
    ├── nim-presto
    ├── nim-results
    ├── nim-rocksdb
    ├── nim-secp256k1
    ├── nim-serialization
    ├── nim-snappy
    ├── nim-sqlite3-abi
    ├── nim-ssz-serialization
    ├── nim-stew
    ├── nim-stint
    ├── nim-taskpools
    ├── nim-testutils
    ├── nim-toml-serialization
    ├── nim-unicodedb
    ├── nim-unittest2
    ├── nim-web3
    ├── nim-websock
    ├── nim-zlib
    ├── nim-zxcvbn
    ├── nimbus-build-system
    ├── nimbus-eth2
    ├── nimbus-security-resources
    ├── nimcrypto
    ├── portal-mainnet
    ├── portal-spec-tests
    └── tempfile.nim

249 directories, 1120 files


14 directories, 17 files
.
├── BlockchainTests.md
├── Dockerfile
├── Dockerfile.debug
├── GeneralStateTests.md
├── LICENSE-APACHEv2
├── LICENSE-MIT
├── Makefile
├── PrecompileTests.md
├── README.md
├── TransactionTests.md
├── config.nims
├── default.nix
├── docker
├── docs
├── env.sh
├── examples
├── execution_chain
├── fluffy
├── hive_integration
├── kurtosis-network-params.yml
├── nimbus.nimble
├── nimbus.nims -> nimbus.nimble
├── nimbus_verified_proxy
├── nix
├── nrpc
├── run-kurtosis-check.sh
├── scripts
├── tests
├── tools
└── vendor

14 directories, 17 files
