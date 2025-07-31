Inspection of Capture Data And Replay
=====================================

Inspection
----------

Given a (probably gzipped) data dump file **(capture)** file as a result of
tracing, its content can be visualised via

       nimbus_execution_client \
          capture-log          \
          --beacon-sync-capture-file=(capture)

Replay
------

Copy and secure the current database directory **(database)** as **(dbcopy)**,
say. Then start a capture run on the original data base as

       nimbus_execution_client \
          --datadir=(database) \
          --debug-beacon-sync-trace-file=(capture) \
          ...

where **(capture)** will contain all the data for the replay. This file can
bebome quite big (e.g. 30GiB for the last 120k blocks synchronised on
*mainnet*) but can be gzipped after the capture run was stopped.

Monitor the capture run so it can be stopped at an an appropriate state using
metrics or logs. With the above command line argumants, only the next sync
session is logged ranging from the activation message (when *Activating syncer*
is logged) up intil the suspend message (when *Suspending syncer* is logged.)

Now, the captured run can be replayed on the secured database copy
**(dbcopy)** with the (probably gzipped) **(capture)** file via

       nimbus_execution_client \
          --datadir=(dbcopy)   \
          --debug-beacon-sync-replay-file=(capture) \
          ...

where ihe additional arguments **...** of either command above need not be
the same.

Note that you need another copy of **(database)** if you need to re-exec the
latter command line statement.
