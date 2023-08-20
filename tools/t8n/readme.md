## EVM state transition tool

The `t8n` tool is a stateless state transition utility.

### Build instructions

There are few options to build `t8n` tool like any other nimbus tools.

1. Use your system Nim compiler(v1.6.12) and git to install dependencies.
    ```
    $> git submodule update --init --recursive
    $> ./env.sh (run once to generate nimbus-build-system.paths)
    $> nim c -d:release -d:chronicles_default_output_device=stderr tools/t8n/t8n
    $> nim c -r -d:release tools/t8n/t8n_test
    ```
2. Use nimbus shipped Nim compiler and dependencies.
    ```
    $> make update deps
    $> ./env.sh nim c -d:release -d:chronicles_default_output_device=stderr tools/t8n/t8n
    $> ./env.sh nim c -r -d:release tools/t8n/t8n_test
    ```
3. Use nimbus makefile.
    ```
    $> make update
    $> make t8n
    $> make t8n_test
    ```

### Command line params

Available command line params
```
Usage:

t8n [OPTIONS]...

The following options are available:

 --trace                 Enable and set where to put full EVM trace logs [=disabled].
                             `stdout` - into the stdout output.
                             `stderr` - into the stderr output.
                             <file>   - into the file <file>-<txIndex>.jsonl.
                             none     - output.basedir/trace-<txIndex>-<txhash>.jsonl.
 --trace.memory          Enable full memory dump in traces [=false].
 --trace.nostack         Disable stack output in traces [=false].
 --trace.returndata      Enable return data output in traces [=false].
 --output.basedir        Specifies where output files are placed. Will be created if it does not exist.
 --output.body           If set, the RLP of the transactions (block body) will be written to this file.
 --output.alloc          Determines where to put the `alloc` of the post-state. [=alloc.json].
                             `stdout` - into the stdout output.
                             `stderr` - into the stderr output.
                             <file>   - into the file <file>.
 --output.result         Determines where to put the `result` (stateroot, txroot etc) of the post-state.
                             [=result.json].
                             `stdout` - into the stdout output.
                             `stderr` - into the stderr output.
                             <file>   - into the file <file>.
 --input.alloc           `stdin` or file name of where to find the prestate alloc to use. [=alloc.json].
 --input.env             `stdin` or file name of where to find the prestate env to use. [=env.json].
 --input.txs             `stdin` or file name of where to find the transactions to apply. If the file
                             extension is '.rlp', then the data is interpreted as an RLP list of signed
                             transactions. The '.rlp' format is identical to the output.body format.
                             [=txs.json].
 --state.reward          Mining reward. Set to -1 to disable [=0].
 --state.chainid         ChainID to use [=1].
 --state.fork            Name of ruleset to use. [=GrayGlacier].
                             - Frontier.
                             - Homestead.
                             - EIP150.
                             - EIP158.
                             - Byzantium.
                             - Constantinople.
                             - ConstantinopleFix.
                             - Istanbul.
                             - FrontierToHomesteadAt5.
                             - HomesteadToEIP150At5.
                             - HomesteadToDaoAt5.
                             - EIP158ToByzantiumAt5.
                             - ByzantiumToConstantinopleAt5.
                             - ByzantiumToConstantinopleFixAt5.
                             - ConstantinopleFixToIstanbulAt5.
                             - Berlin.
                             - BerlinToLondonAt5.
                             - London.
                             - ArrowGlacier.
                             - GrayGlacier.
                             - Merged.
                             - Shanghai.
                             - Cancun.
 --verbosity             sets the verbosity level [=3].
                             0 = silent, 1 = error, 2 = warn, 3 = info, 4 = debug, 5 = detail.
```
