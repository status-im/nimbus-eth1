## Tx parser (`txparse`)

This is a very simple utility, which reads line by line from standard input.
For each line, it tries to interpret it as hexadecimal data, and the data as
an Ethereum transaction.

If all goes well, it outputs a line containing the `address` of the sender.
Otherwise, it outputs `err: ` and a suitable error message.

### Build instructions

There are few options to build `txparse` tool like any other nimbus tools.

1. Use your system Nim compiler(v1.6.12) and git to install dependencies.
    ```
    $> git submodule update --init --recursive
    $> ./env.sh (run once to generate nimbus-build-system.paths)
    $> nim c -d:release tools/txparse/txparse
    ```
2. Use nimbus shipped Nim compiler and dependencies.
    ```
    $> make update deps
    $> ./env.sh nim c tools/txparse/txparse
    ```
3. Use nimbus makefile.
    ```
    $> make update
    $> make txparse
    ```

Example:

```
$ cat ./sample.input | ./txparse
err: t is not a hexadecimal character
err: m is not a hexadecimal character
err: hex string must have even length
err:   is not a hexadecimal character
err: Read past the end of the RLP stream
err: The RLP contains a larger than expected Int value
0xd02d72e067e77158444ef2020ff2d325f929b363
0xd02d72e067e77158444ef2020ff2d325f929b363
err: hex string must have even length
```