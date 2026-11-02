# test_runner

Runs execution-specs (EEST) blockchain fixtures through Nimbus's block import (`blocktest`) and blockchain engine fixtures through its Engine API handler (`enginetest`), following the client test runner interface in execution-specs (`docs/running_tests/consume/client_runners.md`).

```bash
make test_runner
build/test_runner blocktest fixtures/blockchain_tests
build/test_runner enginetest --workers 4 fixtures/blockchain_tests_engine
make test_runner_test  # the runner's own tests
```

- Any number of files and directories, run in one process. stdout carries one JSON array with a result per fixture (`name`, `pass`, `fork`, `error`, `rejections`); everything else goes to stderr.
- Exit code `0` when every fixture passed, `1` when one failed, `2` when a path is missing or unreadable (reported before any fixture runs) or a fixture file cannot be parsed.
- `blocktest` imports each block as beacon sync imports a block above finality, with the fixture's access list attached when its hash matches the header's and dropped otherwise.
- `enginetest` calls `engine_newPayloadV<n>` and `engine_forkchoiceUpdatedV<n>` through Nimbus's JSON-RPC method dispatch, in process, with no server.
- Blocks run on the BAL-parallel executor by default, with the other parallel features on.

| Flag | |
|---|---|
| `--workers N` | run fixture files on `N` threads |
| `--threads N` | background threads per worker for parallel execution, at least 2 (default: cores, between 2 and 16) |
| `--bal-sequential` | run every block on the sequential executor |
| `--bal-withhold` | (`blocktest`) execute without the fixture's access list |
| `--bal-report` | print `{"event": "balExecution", ...}` per executed block on stderr |
| `--version` | print `Nimbus-test-runner <version>-<commit>` |
