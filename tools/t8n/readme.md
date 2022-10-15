## EVM state transition tool

The `t8n` tool is a stateless state transition utility.

### Build instructions

There are few options to build `t8n` tool like any other nimbus tools.

1. Use nimble to install dependencies and your system Nim compiler(version <= 1.6.0).
    ```
    $> nimble install -y --depsOnly
    $> nim c -d:release -d:chronicles_default_output_device=stderr tools/t8n/t8n
    $> nim c -r -d:release tools/t8n/t8n_test
    ```
2. Use nimbus shipped Nim compiler and dependencies.
    ```
    $> make update
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

   --trace                            Output full trace logs to files trace-<txIndex>-<txhash>.jsonl
   --trace.memory                     Enable full memory dump in traces.
   --trace.nostack                    Disable stack output in traces.
   --trace.returndata                 Enable return data output in traces.
   --output.basedir value             Specifies where output files are placed. Will be created if it does not exist.
   --output.alloc alloc               Determines where to put the alloc of the post-state.
                                      `stdout` - into the stdout output
                                      `stderr` - into the stderr output
                                      <file>   - into the file <file>
   --output.result result             Determines where to put the result (stateroot, txroot etc) of the post-state.
                                      `stdout` - into the stdout output
                                      `stderr` - into the stderr output
                                      <file>   - into the file <file>
   --output.body value                If set, the RLP of the transactions (block body) will be written to this file.
   --input.txs stdin                  stdin or file name of where to find the transactions to apply.
                                      If the file extension is '.rlp', then the data is interpreted as an RLP list of signed transactions.
                                      The '.rlp' format is identical to the output.body format.
   --input.alloc stdin                `stdin` or file name of where to find the prestate alloc to use.
   --input.env stdin                  `stdin` or file name of where to find the prestate env to use.
   --state.fork value                 Name of ruleset to use.
   --state.chainid value              ChainID to use (default: 1).
   --state.reward value               Mining reward. Set to 0 to disable (default: 0).

```
