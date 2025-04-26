# Nimbus Execution Client

## Repo Organization

```
.
|                           # LOGS OF STANDARDIZED TESTS
|
├── BlockchainTests.md      # Logs of blockchain tests, state tests, precompile tests and transaction
├── GeneralStateTests.md    # tests. These tests are standardized for EL clients and the logs exhibit
├── PrecompileTests.md      # the current state of the tests (in some sense the state of the client as
├── TransactionTests.md     # well
|
|                                 # BUILDING AND TESTING RELATED
|
├── Makefile                      # contains targets for buiding and testing all binaries (fluffy, EL client etc.)
├── env.sh                        # sets some path variables that are used elsewhere
├── scripts                       # contains scrips for building, calculating block stats etc.  
├── config.nims                   # sets build flags
├── nimbus.nimble                 # defines test tasks (block import tests, evm tests, fluffy tests etc.)
├── nimbus.nims -> nimbus.nimble  # symlink to the above file
├── nix
├── default.nix
|
|                     # DOCKER RELATED
|
├── Dockerfile        # dockerfile to make the docker image of the nimbus execution client
├── Dockerfile.debug  # dockerfile to make the debug mode docker image of the nimbus execution client
├── docker            # contains dockerfiles to make build images which in turn are used to build binaries
├── kurtosis-network-params.yml   # kurtosis network configuration
├── run-kurtosis-check.sh         # script that deploys a local kurtosis based testnet using the dockerfiles above for checks
|
|                           # SOURCE CODE DIRECTORIES
|
├── execution_chain         # source code for the nimbus execution client
├── fluffy                  # source code for the nimbus portal client a.k.a fluffy
├── nimbus_verified_proxy   # source code for the nimbus verified proxy
├── hive_integration        # source code for hive integration tests
├── nrpc                    # source code for nrpc
├── tools                   # contains tools for testing isolated components (state transition, transaction parsing etc.)
├── tests                   # tests for all the source code directories
|
|                     # MISCELLANEOUS
|
├── docs              # contains docs like this one
├── examples          # contains examples for grafana, prometheus etc. - OUTDATED
├── LICENSE-APACHEv2
├── LICENSE-MIT
├── README.md
```


### Nimbus Execution Client
TODO

### Fluffy
TODO

### Nimbus Verified Proxy
TODO

### Hive Integration
TODO

### NRPC
TODO
