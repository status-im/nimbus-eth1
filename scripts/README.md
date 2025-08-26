# Utility scripts

## block-import-stats.py

This script compares outputs from two `nimbus import --debug-csv-stats`, a
baseline and a contender.

To use it, set up a virtual environment:

```bash
# Create a venv for the tool
python -m venv stats
. stats/bin/activate
pip install -r requirements.txt

python block-import-stats.py
```

* Generate a baseline version by processing a long range of blocks using
  `nimbus import`
* Modify your code and commit to git (to generate a unique identifier for the code)
* Re-run the same import over the range of blocks of interest, saving the import
  statistics to a new CSV
* Pass the two CSV files to the script

By default, the script will skip block numbers below 500k since these are mostly
uninteresting.

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
chmod +x download_era.sh
./download_era.sh https://sepolia.era1.nimbus.team ~/Downloads/sepolia
```
For further details please refer https://hackmd.io/@advaita/BkMvD9Qllg
