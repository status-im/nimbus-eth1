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
build/go_wrapper_whisper_example
```

To build statically linked versions:

```bash
make wrappers-static
```

You can also build the wrappers with the Nix build file (Need to
[install](https://nixos.org/nix/download.html) Nix first):

```bash
nix-build -A wrappers
```

# Notes on usage
Before any of the API calls are done, `NimMain()` needs to be run.

After this any of the asymmetric or symmetric keys API calls can be done.

Before any actual Whisper calls are done, `nimbus_start()` needs to be called.
This will setup the Whisper node, start discovery and connect to the Status
fleet.

After this call you can use the Whisper related calls such as
`nimbus_subscribe_filter` and `nimbus_post`.

`nimbus_subscribe_filter` allows you to pass a pointer to user data. This will
just pass the pointer to the, by you provided, callback. You can use this to
have a certain context in the callback.

Be aware that when using this with cgo, you will have a problem when passing a
Go pointer that contains other Go pointers, as this is no longer allowed.
See also: https://golang.org/cmd/cgo/#hdr-Passing_pointers

This can be resolved by refering to it indirectly, e.g. using a map in Go
containing the pointers. See here for an example solution:
https://github.com/mattn/go-pointer/blob/master/pointer.go

# Caveat
Two items to take into consideration:
1. All API calls must be called from the same thread where the initial
`NimMain()` was called from. While there are
[ways](https://nim-lang.org/docs/backends.html#memory-management-thread-coordination)
of thread coordination, this will not work for calls involving `async` work
with Chronos. Thus to be extra clear & consistent, the above mentioned ways are
not used at all.
2. For most of the API calls it is assumed that when passing a pointer as
parameter, that the data that this pointer refers to remains valid during the
duration of the call. If this is not the case, issues might occur as copying
might happen to late.
