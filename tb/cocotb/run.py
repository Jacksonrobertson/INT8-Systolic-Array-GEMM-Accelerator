"""Build and run the Phase 3 cocotb regression.

  python tb/cocotb/run.py                 # N=4 and N=8, default seed/counts
  python tb/cocotb/run.py --seed 1234     # reproduce a session exactly
  python tb/cocotb/run.py -n 4 --random-count 50

Builds gemm_top with Verilator (+define+SIM_ASSERT, so the Phase 2 SVA set is
armed), runs every cocotb test, then merges each build's functional-coverage
samples and fails the session if any mandatory bin is unhit. Results land in
sim/build/cocotb_n<N>/ with a combined coverage report at
sim/build/coverage_report.txt.

Requires Verilator 5.x and cocotb 1.9.x (cocotb 2.x needs Verilator >= 5.036,
newer than distro packages currently ship).
"""

import argparse
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))

from coverage import Coverage  # noqa: E402


def build_and_test(n, seed, random_count, waves):
    from cocotb.runner import get_runner

    rtl = sorted((ROOT / "rtl").glob("*.sv"))
    pkg = [s for s in rtl if s.name == "gemm_pkg.sv"]
    srcs = pkg + [s for s in rtl if s.name != "gemm_pkg.sv"]

    build_dir = ROOT / "sim" / "build" / f"cocotb_n{n}"
    cov_file = build_dir / "coverage.jsonl"
    build_dir.mkdir(parents=True, exist_ok=True)
    if cov_file.exists():
        cov_file.unlink()

    runner = get_runner("verilator")
    runner.build(
        verilog_sources=srcs,
        hdl_toplevel="gemm_top",
        parameters={"N": n},
        defines={"SIM_ASSERT": 1},
        build_args=["--assert", "-Wno-UNUSEDSIGNAL", "-Wno-UNUSEDPARAM"],
        build_dir=str(build_dir),
        waves=waves,
        always=True,
    )
    results = runner.test(
        test_module="test_gemm_top",
        hdl_toplevel="gemm_top",
        seed=seed,
        build_dir=str(build_dir),
        test_dir=str(build_dir),
        waves=waves,
        extra_env={
            "PYTHONPATH": os.pathsep.join(
                [str(ROOT / "tb" / "cocotb"), str(ROOT),
                 os.environ.get("PYTHONPATH", "")]),
            "COVERAGE_FILE": str(cov_file),
            "RANDOM_COUNT": str(random_count),
        },
    )

    from cocotb.runner import get_results
    total, failed = get_results(results)
    print(f"[n={n}] {total - failed}/{total} tests passed")
    return failed, cov_file


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("-n", type=int, action="append",
                    help="array size(s) to run (default: 4 and 8)")
    ap.add_argument("--seed", type=int, default=None,
                    help="cocotb RANDOM_SEED (default: random)")
    ap.add_argument("--random-count", type=int, default=None,
                    help="constrained-random iterations per build "
                         "(default: 25 at N=4, 10 at N=8)")
    ap.add_argument("--waves", action="store_true", help="dump FST waves")
    args = ap.parse_args()

    sizes = args.n or [4, 8]
    seed = args.seed if args.seed is not None else int.from_bytes(os.urandom(4), "little")
    print(f"session seed: {seed}  (reproduce with --seed {seed})")

    failed_total, cov_files = 0, []
    for n in sizes:
        count = args.random_count if args.random_count is not None \
            else (25 if n == 4 else 10)
        failed, cov_file = build_and_test(n, seed, count, args.waves)
        failed_total += failed
        cov_files.append(cov_file)

    merged = Coverage.merge([str(p) for p in cov_files])
    table, unhit = Coverage.report(merged)
    report = (f"functional coverage ({'+'.join(f'n={n}' for n in sizes)}, "
              f"seed={seed}):\n{table}\n")
    print(report)
    report_path = ROOT / "sim" / "build" / "coverage_report.txt"
    report_path.write_text(report)

    if failed_total:
        print(f"FAIL: {failed_total} test(s) failed")
        return 1
    if unhit and len(sizes) > 1:
        # Closure is enforced on the full default session; a single-size or
        # reduced run still prints the table but only warns.
        print(f"FAIL: mandatory coverage unhit: {', '.join(unhit)}")
        return 1
    if unhit:
        print(f"note: unhit bins in this reduced session: {', '.join(unhit)}")
    print("PASS: all tests passed" +
          ("" if unhit else ", functional coverage closed"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
