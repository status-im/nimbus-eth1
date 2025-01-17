# Nimbus Unified

<!-- [![Github Actions CI](tbd) -->
[![License: Apache](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)

[![Discord: Nimbus](https://img.shields.io/badge/discord-nimbus-orange.svg)](https://discord.gg/XRxWahP)
[![Status: #nimbus-general](https://img.shields.io/badge/status-nimbus--general-orange.svg)](https://join.status.im/nimbus-general)


# NOTE - whole document to be concluded...

# description
Nimbus Unified combines Ethereum execution and consensus layer functionalities, featuring a fully integrated beacon node, validator duties, and execution layer support. This setup allows the Nimbus client to handle both Ethereum consensus (Eth2) and execution (Eth1) services within a single package.
tbd
# documentation
For in-depth configuration and functionality of Nimbus Eth1 and Nimbus Eth2, refer to:

- [Nimbus-eth1 - Execution layer client](https://github.com/status-im/nimbus-eth1) Documentation
- [Nimbus-eth2 - Consensus layer client](https://github.com/status-im/nimbus-eth2) Documentation

--- to be concluded
# dependencies
tbd
# how to
## configuration
    todo
## commands
    todo
## build
Execute the make command on nimbus-eth1 directory
```
]$ make -j<#threads> nimbus_unified
```

### trusted node synchronization

Same options as nimbus-eth2 trusted node synchronization
```
]$ nimbus_unified -- trustedNodeSync

```

### known issues
<b>NOTE</b>
- theres is an issue with SIGINT handling. if process is hanged after ctrl^c send a SIGQUIT (ctrl+\\)

### run node
<b>NOTE</b>
- eth1 is running with default engine-api option
- current recommended options

```
    --network
    --datadir (will be shared with consensus)
    --tcp-port=9000 (default)
    --udp-port=9000 (default)
    --rest
    --rest-port=5052
    --metrics
    --el=http://127.0.0.1:8551  (default)
    --jwt-secret=
```


1) generate jason web token


2) you can use the auxiliary script (do note that this script is temporary and to be removed)
```
]$ nimbus_unified/run_nimbus_unified.sh --el=http://127.0.0.1:8551 --jwt-secret="/tmp/jwtsecret" --web3-url=http://127.0.0.1:8551
```



## colaborate
We welcome contributions to Nimbus Unified! Please adhere to the following guidelines:

- Follow the [Nimbus Code of Conduct](https://github.com/status-im/nimbus-eth2/blob/master/CODE_OF_CONDUCT.md).
- Use the [Nimbus Code Style Guide](https://github.com/status-im/nimbus-eth2/blob/master/docs/code_style.md) to maintain code consistency.
- Format your code using the [Nim Pretty Printer (nph)](https://github.com/nim-lang/nimpretty) to ensure consistency across the codebase. Run it as part of your pull request process.
## License

Licensed and distributed under either of

* MIT license: [LICENSE-MIT](LICENSE-MIT) or https://opensource.org/licenses/MIT

or

* Apache License, Version 2.0: [LICENSE-APACHEv2](LICENSE-APACHEv2) or https://www.apache.org/licenses/LICENSE-2.0

These files may not be copied, modified, or distributed except according to those terms.
