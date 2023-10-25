# The basics for developers

When working on Fluffy in the nimbus-eth1 repository, you can run the `env.sh`
script to run a command with the right environment variables set. This means the
vendored Nim and Nim modules will be used, just as when you use `make`.

E.g.:

```bash
# start a new interactive shell with the right env vars set
./env.sh bash
```

<!-- TODO: Add most important development tips from following page here and
remove the link -->

More [development tips](https://github.com/status-im/nimbus-eth1/blob/master/README.md#devel-tips)
can be found on the general nimbus-eth1 readme.

The code follows the
[Status Nim Style Guide](https://status-im.github.io/nim-style-guide/).
