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


### 3. Some assert

Seen on `holesky`, sometimes the header chain cannot not be joined with its
lower end after completing due to different hashes leading to an assert failure

	    Error: unhandled exception: header chains C-D joining hashes do not match L=#2646126 lHash=3bc2beb1b565 C=#2646126 cHash=3bc2beb1b565 D=#2646127 dParent=671c7c6cb904

which was preceeded somewhat earlier by log entries

	    INF 2024-10-31 18:21:16.464 Forkchoice requested sync to new head   file=api_forkchoice.nim:107 number=2646126 hash=3bc2beb1b565
	    [..]
	    INF 2024-10-31 18:21:25.872 Forkchoice requested sync to new head   file=api_forkchoice.nim:107 number=2646126 hash=671c7c6cb904
