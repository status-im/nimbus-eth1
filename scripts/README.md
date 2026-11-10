# Utility scripts

## block-import-stats.py

This script compares outputs from two `nimbus import --debug-csv-stats`, a
baseline and a contender.

Dependencies are declared inline via [PEP 723](https://peps.python.org/pep-0723/)
(`pandas`, `matplotlib`). Run with a PEP 723-compatible runner such as `uv`, or
install them into a venv manually:

```bash
# Recommended: uv reads the script's dependency metadata
uv run block-import-stats.py

# Or install into a venv manually (requirements.txt was removed in #5073)
python -m venv stats
. stats/bin/activate
pip install pandas matplotlib
python block-import-stats.py
```

* Generate a baseline version by processing a long range of blocks using
  `nimbus import`
* Modify your code and commit to git (to generate a unique identifier for the code)
* Re-run the same import over the range of blocks of interest, saving the import
  statistics to a new CSV
* Pass the two CSV files to the script

By default, the script will skip block numbers below 500k since these are mostly
unintersting.

See `-h` for help text on running the script.

### Testing a particular range of blocks

As long as block import is run on similar hardware, each run can be saved for
future reference using the git hash.

The block import can be run repeatedly with `--max-blocks` to stop after
processing a number of blocks - by copying the state at that point, one can
resume or replay the import of a particular block range

See `make_states.sh` for such an example.

## era_downloader.sh

Era/era1 file parallel downloader, with total progress tracking and download resumability

#### You'll need:

- [`aria2`](https://aria2.github.io/) installed:
  - **macOS**: `brew install aria2`
  - **Ubuntu/Debian**: `sudo apt install aria2`
- Standard Unix tools: `bash`, `awk`, `find`, `grep`, `curl`
### Example Usage
```bash
chmod +x era_downloader.sh
./era_downloader.sh https://sepolia.era1.nimbus.team ~/Downloads/sepolia
```
For further details please refer https://hackmd.io/@advaita/BkMvD9Qllg