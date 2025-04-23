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
    # at least one item - let it lag in the beginning until we reach the min
    # block number or the table will be empty
    df.set_index("block_number", inplace=True)
    df.time /= 1000000000
    df.drop(columns=["gas"], inplace=True)
    df["bps"] = df.blocks / df.time
    df["tps"] = df.txs / df.time
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


def formatBins(df: pd.DataFrame, bins: int):
    if bins > 0:
        bins = np.linspace(
            df.block_number.iloc[0] - df.blocks.iloc[0],
            df.block_number.iloc[-1],
            bins,
            dtype=int,
        )
        return df.groupby(pd.cut(df["block_number"], bins), observed=True)
    else:
        return df


def write_markdown_output(file,df_stats, df, baseline_name, contender_name):
    """Write statistics in markdown table format to a file"""
    total_blocks = df.block_number.max() - df.block_number.min()
    time_xt = df.time_x.sum()
    time_yt = df.time_y.sum()
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


def write_standard_output(df_stats, df, baseline_name, contender_name):
    print(f"{os.path.basename(baseline_name)} vs {os.path.basename(contender_name)}")
    print(df_stats.to_string(
        formatters=dict.fromkeys(["bpsd", "tpsd", "timed"], "{:,.2%}".format)
                   | dict.fromkeys(["bps_x", "bps_y", "tps_x", "tps_y"], "{:,.2f}".format)
                   | dict.fromkeys(["time_x", "time_y"], prettySecs),
    ))

    total_blocks = df.block_number.max() - df.block_number.min()
    time_xt = df.time_x.sum()
    time_yt = df.time_y.sum()
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

    # Check if there's any overlap in the time ranges
    if start > max(max(baseline.index), max(contender.index)) or end < min(min(baseline.index), min(contender.index)):
        print(f"Error: No overlapping time ranges between baseline and contender datasets")
        print(f"Baseline range: {min(baseline.index)} to {max(baseline.index)}")
        print(f"Contender range: {min(contender.index)} to {max(contender.index)}")
        exit(1)

    baseline = baseline.loc[start:end]
    contender = contender.loc[start:end]

    # Join the two frames then interpolate - this helps dealing with runs that
    # haven't been using the same chunking and/or max-blocks
    df = baseline.merge(contender, on=("block_number", "blocks"), how="outer")
    df = df.interpolate(method="index").reindex(contender.index)
    df.reset_index(inplace=True)

    if df.block_number.iloc[-1] > min_block_number + df.block_number.iloc[0]:
        cutoff = min(
            df.block_number.iloc[-1] - min_block_number,
            min_block_number,
            )
        df = df[df.block_number >= cutoff]

    df["bpsd"] = (df.bps_y - df.bps_x) / df.bps_x
    df["tpsd"] = (df.tps_y - df.tps_x) / df.tps_x.replace(0, 1)
    df["timed"] = (df.time_y - df.time_x) / df.time_x

    if args.plot:
        plt.rcParams["axes.grid"] = True

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

    stats_df = formatBins(df, args.bins).agg(
        dict.fromkeys(["bps_x", "bps_y", "tps_x", "tps_y"], "mean")
        | dict.fromkeys(["time_x", "time_y"], "sum")
        | dict.fromkeys(["bpsd", "tpsd", "timed"], "mean")
    )

    if args.markdown_output:
        with open(args.markdown_output, 'w') as f:
            write_markdown_output(f, stats_df, df, args.baseline, args.contender)
    else:
        write_standard_output(stats_df, df, args.baseline, args.contender)

if __name__ == "__main__":
    main()
