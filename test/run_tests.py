#!/usr/bin/env python3
"""Test runner for the C64 shell ROM.

Discovers every test_*.py in this directory, imports it, and runs each
test_* function against a freshly booted VICE instance (one instance per
module, for isolation). Reports a pass/fail summary and exits nonzero on
any failure.

A test function takes a connected Vice and asserts on it:

    def test_something(v):
        v.assert_screen_contains("READY")

Usage:
    python3 test/run_tests.py            # run everything, headless (default)
    python3 test/run_tests.py disk rm    # only modules matching a substring
                                         # (test_disk, test_disk_nodrive, test_rm)
    VICE_VERBOSE=1 python3 ...           # show monitor traffic and tracebacks
    VICE_JOBS=8 python3 ...              # override the parallel worker count
"""

import importlib.util
import json
import os
import sys
import time
import traceback

TEST_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, TEST_DIR)            # make 'lib' importable

from lib.vice import Vice, ViceError    # noqa: E402

VERBOSE = os.environ.get("VICE_VERBOSE") == "1"


def discover_modules():
    names = []
    for fn in sorted(os.listdir(TEST_DIR)):
        if fn.startswith("test_") and fn.endswith(".py"):
            names.append(fn[:-3])
    return names


def load_module(name):
    path = os.path.join(TEST_DIR, name + ".py")
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_functions(mod):
    return [(n, getattr(mod, n)) for n in sorted(dir(mod))
            if n.startswith("test_") and callable(getattr(mod, n))]


def run_module(modname):
    """Run one module in its own VICE; returns (passes, failures, lines).

    Each module already gets a fresh VICE on its own monitor port, so
    modules are fully independent -- which is what lets the runner execute
    them in parallel worker processes.
    """
    t0 = time.time()
    lines = []
    passed = 0
    failures = []
    mod = load_module(modname)
    fns = test_functions(mod)
    if not fns:
        return passed, failures, lines, modname, 0.0
    # A module may request a disk image (mounted on device 8, true drive)
    # by setting VICE_DISK to a path relative to the test directory, and/or
    # extra x64sc arguments via VICE_ARGS (e.g. ["-drive8type", "0"] for a
    # bus with no drive on it at all -- without it VICE's default drive 8
    # still answers ATN even with no disk attached).
    disk = getattr(mod, "VICE_DISK", None)
    if disk is not None:
        disk = os.path.join(TEST_DIR, disk)
    extra = getattr(mod, "VICE_ARGS", None)
    try:
        with Vice(disk=disk, extra_args=extra) as v:
            for name, fn in fns:
                label = "%s::%s" % (modname, name)
                try:
                    fn(v)
                    lines.append("PASS  %s" % label)
                    passed += 1
                except Exception as exc:  # noqa: BLE001 (report everything)
                    lines.append("FAIL  %s" % label)
                    failures.append((label, repr(exc), traceback.format_exc()))
    except ViceError as exc:
        label = "%s (launch)" % modname
        lines.append("ERROR %s: %s" % (label, exc))
        failures.append((label, repr(exc), traceback.format_exc()))
    elapsed = time.time() - t0
    if lines:
        lines.append("      (%s: %.1fs)" % (modname, elapsed))
    return passed, failures, lines, modname, elapsed


# Per-module wall times from the previous run, used to schedule longest-first
# so a slow module can't start last and drag the whole run's tail. Lives in
# build/ (gitignored); absent or stale entries just fall back to 0.
TIMES_FILE = os.path.join(TEST_DIR, "..", "build", "test-times.json")


def load_times():
    try:
        with open(TIMES_FILE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_times(times):
    try:
        with open(TIMES_FILE, "w") as f:
            json.dump(times, f, indent=0, sort_keys=True)
    except OSError:
        pass


def main():
    start = time.time()
    passed = 0
    failures = []
    modules = discover_modules()

    # Positional args are module filters: keep modules whose name contains
    # any of them ("disk" -> test_disk + test_disk_nodrive). This is the
    # fast-iteration path: run only the module you are working on.
    filters = [a for a in sys.argv[1:] if not a.startswith("-")]
    if filters:
        modules = [m for m in modules
                   if any(f in m for f in filters)]
        if not modules:
            print("no test modules match %r" % (filters,))
            return 1

    # Longest-first (by the previous run's times) packs the workers so the
    # slowest module starts immediately instead of last.
    times = load_times()
    modules.sort(key=lambda m: times.get(m, 0.0), reverse=True)

    # Parallel by default: one VICE per module, one module per worker.
    # VICE_JOBS=1 restores the old serial behavior (e.g. for debugging);
    # the cap keeps a pile of warp-mode VICEs from starving each other.
    jobs = int(os.environ.get("VICE_JOBS", "0") or "0")
    if jobs <= 0:
        # Leave headroom by default: a few timing-sensitive tests wait on
        # cycle-based drive timeouts (device probe, no-disk read timeout),
        # and oversubscribing -warp VICEs starves those past their budget
        # (8 jobs on a 10-core M-series flaked test_device; 6 is green).
        # VICE_JOBS overrides for a faster (riskier) run.
        jobs = min(6, max(1, (os.cpu_count() or 1) - 2), len(modules))

    if jobs == 1:
        results = [run_module(m) for m in modules]
    else:
        from concurrent.futures import ProcessPoolExecutor
        with ProcessPoolExecutor(max_workers=jobs) as pool:
            results = list(pool.map(run_module, modules))

    for p, f, lines, modname, elapsed in results:
        passed += p
        failures.extend(f)
        times[modname] = elapsed
        for line in lines:
            print(line)
    save_times(times)

    elapsed = time.time() - start
    print("-" * 56)
    for label, exc, tb in failures:
        print("FAILED %s: %s" % (label, exc))
        if VERBOSE:
            print(tb)
    print("%d passed, %d failed in %.1fs (%d jobs)"
          % (passed, len(failures), elapsed, jobs))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
