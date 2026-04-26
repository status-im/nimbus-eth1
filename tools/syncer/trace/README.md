Beacon sync tracer
==================

For the execution layer binary, data from a syncer sessions can be captured
into a file **(capture)** along with system state information via

       ./build/syncer_test_client_trace ... -- --capture-file=(capture)

where **...** stands for all other options that might be useful for running
an execution layer session.

The capture file **(capture)** will hold enough data for replaying the
execution layer session(s).

With the command line option *\-\-capture-file-file=***(capture)**
for the *syncer_test_client_trace* binary, data from the syncer sessions
will be written to the argument file named **(capture)** along with system
state information. The file **(capture)** will hold enough data for
replaying the session(s) with the *syncer_test_client_replay* binary.

Both binary *syncer_test_client_trace* and *syncer_test_client_replay* are
extensions of the standard *nimbus_execution_client* binary.

By default, the captured syncer session starts with the first syncer activation
(when *"Activating syncer"* is logged) and ends when the syncer is suspended
(when *"Suspending syncer"* is logged.)

The trace file **(capture)** is organised as an ASCII text file, each line
consists of a *JSON* encoded data capture record.

By nature of the *JSON* representation, the size of any capture data file
will be huge. Compressing with *gzip* when finished, the capture file size
can be reduced to less than 20%. The *gzipped* format will also be accepted
by the replay tools.
