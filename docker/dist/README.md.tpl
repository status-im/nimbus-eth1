# Binary Nimbus distribution

This binary distribution of the Nimbus Execution Client & Verified Proxy package is compiled
in a [reproducible way](https://reproducible-builds.org/) from source files
hosted at https://github.com/status-im/nimbus-eth1.

The tarball containing this README uses the following naming scheme:

```bash
nimbus-<TARGET OS>-<TARGET CPU>-<VERSION>-<GIT COMMIT>.tar.gz
nimbus_verified_proxy-<TARGET OS>-<TARGET CPU>-<VERSION>-<GIT COMMIT>.tar.gz
```

## Reproducing the build

Besides the generic build requirements, you also need [Docker](https://www.docker.com/).

```bash
git clone https://github.com/status-im/nimbus-eth1.git
cd nimbus-eth1
git checkout GIT_COMMIT
make update
make dist
```

## Significant differences from self-built binaries

No `-march=native`.

