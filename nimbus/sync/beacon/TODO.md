## Update sync state management to what is described in *README.md*

1. For the moment, the events in *update.nim* need to be adjusted. This will fix an error where the CL forces the EL to fork internally by sending different head request headers with the same bock number.

2. General scenario update. This is mostly error handling.

## General TODO items

* Update/resolve code fragments which are tagged FIXME

## Open issues

### 1. Weird behaviour of the RPC/engine API

See issue [#2816](https://github.com/status-im/nimbus-eth1/issues/2816)

### 2. Some assert

        Error: unhandled exception: key not found: 0x441a0f..027bc96a [AssertionDefect]

which happened on several `holesky` tests immediately after loging somehing like

        NTC 2024-10-31 21:37:34.728 Finalized blocks persisted   file=forked_chain.nim:231 numberOfBlocks=129 last=044d22843cbe baseNumber=2646764 baseHash=21ec11c1deac

or from another machine with literally the same exception text (but the stack-trace differs)

        NTC 2024-10-31 21:58:07.616 Finalized blocks persisted   file=forked_chain.nim:231 numberOfBlocks=129 last=9cbcc52953a8 baseNumber=2646857 baseHash=9db5c2ac537b
