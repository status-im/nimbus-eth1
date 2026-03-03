Snap Sync
=========

TBD

Project Status
--------------

* Raw data download and storage is implemented
* Previous download session can be resumed

Metrics
-------

| *Variable*                      | *Logic type* | *Short description*        |
|:--------------------------------|:------------:|:---------------------------|
|                                 |              |                            |
| nec_snap_max_acc_state_coverage | hash range   | pivot range coverage       |
| nec_snap_acc_coverage           | hash range   | accumulated range coverage |
|                                 |              |                            |

###  Graphana example

See chapter *Graphana example* of [beacon/README](../beacon/README.md)

Test runner
-----------

Currently, the snap syncer can only be started from the sync tracer which
is part of a *Draft PR* on github.

### Download and compiling the sync tracer

For the tracer, use the latest [Beacon sync trace..](https://github.com/status-im/nimbus-eth1/pulls?q=is%3Apr+is%3Aopen+Beacon+sync+trace) draft PR. Then rebase to the *master* (or any other branch.) Compile it with

       make syncer_test_client_trace

### Running a test

Start the tracer with

       ./build/syncer_test_client_trace \
	       --debug-snap-sync ..<nimbus-options>.. \
		   [-- ..<tracer-options>..]

where *&lt;nimbus-options&gt;* can be listed with

       ./build/nimbus_execution_client --help

and *&lt;tracer-options&gt;* can be listed with

       ./build/syncer_test_client_trace --help

An example for running on *hoodi* would be

        ./build/syncer_test_client_trace \
		   --network=hoodi --debug-snap-sync --log-level:TRACE \
		   -- --snap-sync-resume

where the option *--snap-sync-resume* will cause the tracer resuming the
previous download session (if there was any.)
