import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
import os
import argparse

plt.rcParams["figure.figsize"] = [40, 30]

from pandas.plotting import register_matplotlib_converters

register_matplotlib_converters()


def readStats(name: str):
    df = pd.read_csv(name).convert_dtypes()
    df.set_index("block_number", inplace=True)
    df = df.assign(time=df["time"] / 1000000000)
    df.drop(columns=["gas"], inplace=True)
    df.loc[:, "bps"] = df["blocks"] / df["time"]
    df.loc[:, "tps"] = df["txs"] / df["time"]
    return df


def prettySecs(s: float):
    sa = abs(int(s))
    ss = sa % 60
    m = sa // 60 % 60
    h = sa // (60 * 60)
    sign = "" if s >= 0 else "-"

    if h > 0:
        return f"{sign}{h}h{m}m{ss}s"
    elif m > 0:
        return f"{sign}{m}m{ss}s"
    else:
        return f"{sign}{ss}s"


def cumulative(df):
    """Cumulative blocks/txs/time vs block number. block_number is one past
    the last imported block of a chunk, so the cumulative is zero at the
    block before the first import."""
    c = df.assign(
        cum_blocks=df["blocks"].cumsum(),
        cum_txs=df["txs"].cumsum(),
        cum_time=df["time"].cumsum(),
    )
    first = df.index[0] - df.blocks.iloc[0] - 1
    lead = pd.DataFrame(
        {"cum_blocks": [0], "cum_txs": [0], "cum_time": [0.0]},
        index=pd.Index([first], name="block_number"),
    )
    return pd.concat([lead, c])[["cum_blocks", "cum_txs", "cum_time"]]


def evaluate(c, points):
    # Linear interpolation of the full cumulative curve at the given
    # points; points are always inside c's index range, so np.interp
    # never extrapolates
    points = np.asarray(points, dtype="int64")
    x = c.index.to_numpy(dtype="int64")
    out = {col: np.interp(points, x, c[col].to_numpy(dtype="float64")) for col in c.columns}
    return pd.DataFrame(out, index=pd.Index(points, name="block_number"))


def addDiffs(df):
    df.loc[:, "bpsd"] = (df["bps_y"] - df["bps_x"]) / df["bps_x"]
    df.loc[:, "tpsd"] = (df["tps_y"] - df["tps_x"]) / df["tps_x"].replace(0, 1)
    df.loc[:, "timed"] = (df["time_y"] - df["time_x"]) / df["time_x"]
    return df


def bucketStats(ex, ey, lo, hi, bins):
    # Bucket boundaries; the cumulative at a sample point covers blocks up
    # to one before it, so a bucket ending at edges[i] - 1 is evaluated at
    # edges[i]
    edges = np.unique(np.linspace(lo, hi + 1, bins + 1).astype(int))
    r = evaluate(ex, np.concatenate([[lo - 1], edges[1:]]))
    s = evaluate(ey, np.concatenate([[lo - 1], edges[1:]]))
    n = len(edges) - 1
    stats = pd.DataFrame(
        {
            "bps_x": np.diff(r["cum_blocks"].to_numpy(dtype="float64"))
            / np.diff(r["cum_time"].to_numpy(dtype="float64")),
            "bps_y": np.diff(s["cum_blocks"].to_numpy(dtype="float64"))
            / np.diff(s["cum_time"].to_numpy(dtype="float64")),
            "tps_x": np.diff(r["cum_txs"].to_numpy(dtype="float64"))
            / np.diff(r["cum_time"].to_numpy(dtype="float64")),
            "tps_y": np.diff(s["cum_txs"].to_numpy(dtype="float64"))
            / np.diff(s["cum_time"].to_numpy(dtype="float64")),
            "time_x": np.diff(r["cum_time"].to_numpy(dtype="float64")),
            "time_y": np.diff(s["cum_time"].to_numpy(dtype="float64")),
        },
        index=[f"[{lo}, {edges[1] - 1}]"]
        + [f"({edges[i]}, {edges[i + 1] - 1}]" for i in range(1, n)],
    )
    return addDiffs(stats)


def perRowStats(baseline, contender, lo, hi):
    """Per-row rates on the union of both sample points within [lo, hi];
    the side without a sample at a point gets its rate interpolated."""
    grid = sorted(set(baseline.index) | set(contender.index))
    grid = [p for p in grid if lo <= p <= hi + 1]
    px = baseline[["bps", "tps", "time"]].reindex(grid).interpolate(
        method="index", limit_direction="both"
    )
    py = contender[["bps", "tps", "time"]].reindex(grid).interpolate(
        method="index", limit_direction="both"
    )
    df = pd.DataFrame(
        {
            "block_number": grid,
            "bps_x": px["bps"].to_numpy(),
            "bps_y": py["bps"].to_numpy(),
            "tps_x": px["tps"].to_numpy(),
            "tps_y": py["tps"].to_numpy(),
            "time_x": px["time"].to_numpy(),
            "time_y": py["time"].to_numpy(),
        }
    )
    return addDiffs(df)


def write_markdown_output(file, df_stats, total_blocks, time_xt, time_yt, baseline_name, contender_name):
    """Write statistics in markdown table format to a file"""
    timet = time_yt - time_xt

    file.write(f"\n## {os.path.basename(baseline_name)} vs {os.path.basename(contender_name)}\n\n")

    file.write("| Block Range | BPS Baseline | BPS Contender | TPS Baseline | TPS Contender | Time Baseline | Time Contender | BPS Diff | TPS Diff | Time Diff |\n")
    file.write("|------------|--------------|---------------|--------------|---------------|---------------|----------------|----------|----------|-----------|\n")

    for idx, row in df_stats.iterrows():
        file.write(f"| {str(idx)} | {row['bps_x']:.2f} | {row['bps_y']:.2f} | {row['tps_x']:.2f} | {row['tps_y']:.2f} | {prettySecs(row['time_x'])} | {prettySecs(row['time_y'])} | {row['bpsd']:.2%} | {row['tpsd']:.2%} | {row['timed']:.2%} |\n")

    file.write("\n## Summary\n\n")

    file.write("| Metric | Value |\n")
    file.write("|--------|-------|\n")

    file.write(f"| Total Blocks | {total_blocks} |\n")
    file.write(f"| Baseline Time | {prettySecs(time_xt)} |\n")
    file.write(f"| Contender Time | {prettySecs(time_yt)} |\n")
    file.write(f"| Time Difference | {prettySecs(timet)} |\n")
    file.write(f"| Time Difference % | {(timet/time_xt):.2%} |\n")

    file.write("\n## Legend\n\n")
    file.write("- BPS Diff: Blocks per second difference (+)\n")
    file.write("- TPS Diff: Transactions per second difference\n")
    file.write("- Time Diff: Time to process difference (-)\n")
    file.write("\n(+) = more is better, (-) = less is better\n")


def write_standard_output(df_stats, total_blocks, time_xt, time_yt, baseline_name, contender_name):
    print(f"{os.path.basename(baseline_name)} vs {os.path.basename(contender_name)}")
    print(df_stats.to_string(
        formatters=dict.fromkeys(["bpsd", "tpsd", "timed"], "{:,.2%}".format)
                   | dict.fromkeys(["bps_x", "bps_y", "tps_x", "tps_y"], "{:,.2f}".format)
                   | dict.fromkeys(["time_x", "time_y"], prettySecs),
    ))

    timet = time_yt - time_xt

    print(f"\nblocks: {total_blocks}, baseline: {prettySecs(time_xt)}, contender: {prettySecs(time_yt)}")
    print(f"Time (total): {prettySecs(timet)}, {(timet/time_xt):.2%}")
    print("\nbpsd = blocks per sec diff (+), tpsd = txs per sec diff, timed = time to process diff (-)")
    print("+ = more is better, - = less is better")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("baseline")
    parser.add_argument("contender")
    parser.add_argument("--plot", action="store_true")
    parser.add_argument("--markdown-output", type=str, help="Output path for markdown format file")
    parser.add_argument(
        "--bins",
        default=10,
        type=int,
        help="Number of bins to group block ranges into in overview, 0=all rows",
    )
    parser.add_argument(
        "--min-block-number",
        default=500000,
        type=int,
        help="Skip block blocks below the given number",
    )
    args = parser.parse_args()
    min_block_number = args.min_block_number

    baseline = readStats(args.baseline)
    contender = readStats(args.contender)

    start = max(min(baseline.index), min(contender.index))
    end = min(max(baseline.index), max(contender.index))

    if start > end:
        print(f"Error: No overlapping block ranges between baseline and contender datasets")
        print(f"Baseline range: {min(baseline.index)} to {max(baseline.index)}")
        print(f"Contender range: {min(contender.index)} to {max(contender.index)}")
        exit(1)

    baseline = baseline.loc[start:end]
    contender = contender.loc[start:end]

    # block_number is one past the last imported block of each chunk, so the
    # comparable range runs from the latest first import to the earliest
    # last import
    lo = max(
        baseline.index[0] - baseline.blocks.iloc[0],
        contender.index[0] - contender.blocks.iloc[0],
    )
    hi = min(baseline.index[-1], contender.index[-1]) - 1
    lo = max(lo, min_block_number)
    if lo > hi:
        print(f"Error: No blocks in range {lo} to {hi}")
        exit(1)

    ex = cumulative(baseline)
    ey = cumulative(contender)

    # Totals over [lo, hi] from the cumulative curves, evaluated at the
    # block before lo and one past hi
    total_blocks = hi - lo + 1
    tx = evaluate(ex, [lo - 1, hi + 1])["cum_time"].to_numpy(dtype="float64")
    ty = evaluate(ey, [lo - 1, hi + 1])["cum_time"].to_numpy(dtype="float64")
    time_xt = tx[1] - tx[0]
    time_yt = ty[1] - ty[0]

    if args.bins > 0:
        stats_df = bucketStats(ex, ey, lo, hi, args.bins)
    else:
        stats_df = perRowStats(baseline, contender, lo, hi)

    if args.plot:
        plt.rcParams["axes.grid"] = True

        df = perRowStats(baseline, contender, lo, hi)

        fig = plt.figure()
        bps = fig.add_subplot(2, 2, 1, title="Blocks per second (more is better)")
        bpsd = fig.add_subplot(2, 2, 2, title="Difference (>0 is better)")
        tps = fig.add_subplot(2, 2, 3, title="Transactions per second (more is better)")
        tpsd = fig.add_subplot(2, 2, 4, title="Difference (>0 is better)")

        bps.plot(df.block_number, df.bps_x.rolling(3).mean(), label="baseline")
        bps.plot(df.block_number, df.bps_y.rolling(3).mean(), label="contender")

        bpsd.plot(df.block_number, df.bpsd.rolling(3).mean())

        tps.plot(df.block_number, df.tps_x.rolling(3).mean(), label="baseline")
        tps.plot(df.block_number, df.tps_y.rolling(3).mean(), label="contender")

        tpsd.plot(df.block_number, df.tpsd.rolling(3).mean())

        bps.legend()
        tps.legend()

        fig.subplots_adjust(bottom=0.05, right=0.95, top=0.95, left=0.05)
        plt.show()

    if args.markdown_output:
        with open(args.markdown_output, 'w') as f:
            write_markdown_output(f, stats_df, total_blocks, time_xt, time_yt, args.baseline, args.contender)
    else:
        write_standard_output(stats_df, total_blocks, time_xt, time_yt, args.baseline, args.contender)

if __name__ == "__main__":
    main()
