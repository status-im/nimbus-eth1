### Quick Instructions

*tested on MacOS (ARM64)*

> NOTE: change the hashes under `makeCalls` functions in `example.c` to any recent blockhash and transaction hash because verify proxy cannot query more than 1000 blocks in the history (`maxBlockWalk`) under default configuration

> NOTE: update the `trustedBlockRoot` before compiling the example

```bash
./env.sh make -j12 nimbus_verified_proxy
gcc -I./build/libverifproxy/ -L./build/libverifproxy/ -lverifproxy -lstdc++ -o proxy_from_c ./nimbus_verified_proxy/libverifproxy/example.c
./proxy_from_c
```
