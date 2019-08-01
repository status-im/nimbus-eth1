This folder contains an experimental C wrapper for using parts of the Nimbus
code from C/Go in the Status console client:

https://github.com/status-im/status-console-client/

It serves mainly as a proof-of-concept for now - there are several unresolved
issues surrounding threading, inter-language communication, callbacks etc.

To build the wrappers and the example programs, run from the top level directory:

```bash
make wrappers
```

Now you can run the example programs:

```bash
build/C_wrapper_example
build/go_wrapper_example
```

