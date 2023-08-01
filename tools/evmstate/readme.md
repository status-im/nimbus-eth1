## EVM state test tool

The `evmstate` tool to execute state test.

### Build instructions

There are few options to build `evmstate` tool like any other nimbus tools.

1. Use your system Nim compiler(v1.6.12) and git to install dependencies.
    ```
    $> git submodule update --init --recursive
    $> ./env.sh (run once to generate nimbus-build-system.paths)
    $> nim c -d:release tools/evmstate/evmstate
    $> nim c -r -d:release tools/evmstate/evmstate_test
    ```
2. Use nimbus shipped Nim compiler and dependencies.
    ```
    $> make update deps
    $> ./env.sh nim c -d:release tools/evmstate/evmstate
    $> ./env.sh nim c -r -d:release tools/evmstate/evmstate_test
    ```
3. Use nimbus makefile.
    ```
    $> make update
    $> make evmstate
    $> make evmstate_test
    ```

### Command line params

Available command line params
```
Usage:

evmstate [OPTIONS]... <inputFile>

 <inputFile>         json file contains state test data.

The following options are available:

 --dump              dumps the state after the run [=false].
 --json              output trace logs in machine readable format (json) [=false].
 --debug             output full trace logs [=false].
 --nomemory          disable memory output [=true].
 --nostack           disable stack output [=false].
 --nostorage         disable storage output [=false].
 --noreturndata      enable return data output [=true].
 --fork              choose which fork to be tested.
 --index             if index is unset, all subtest in the fork will be tested [=none(int)].
 --pretty            pretty print the trace result [=false].
 --verbosity         sets the verbosity level [=0].
                        0 = silent, 1 = error, 2 = warn, 3 = info, 4 = debug, 5 = detail.
```
