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
    python3 test/run_tests.py          # headless (default)
    VICE_VERBOSE=1 python3 ...         # show monitor traffic and tracebacks
"""

import importlib.util
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


def main():
    start = time.time()
    passed = 0
    failures = []

    for modname in discover_modules():
        mod = load_module(modname)
        fns = test_functions(mod)
        if not fns:
            continue
        # A module may request a disk image (mounted on device 8, true drive)
        # by setting VICE_DISK to a path relative to the test directory.
        disk = getattr(mod, "VICE_DISK", None)
        if disk is not None:
            disk = os.path.join(TEST_DIR, disk)
        try:
            with Vice(disk=disk) as v:
                for name, fn in fns:
                    label = "%s::%s" % (modname, name)
                    try:
                        fn(v)
                        print("PASS  %s" % label)
                        passed += 1
                    except Exception as exc:  # noqa: BLE001 (report everything)
                        print("FAIL  %s" % label)
                        failures.append((label, exc, traceback.format_exc()))
        except ViceError as exc:
            label = "%s (launch)" % modname
            print("ERROR %s: %s" % (label, exc))
            failures.append((label, exc, traceback.format_exc()))

    elapsed = time.time() - start
    print("-" * 56)
    for label, exc, tb in failures:
        print("FAILED %s: %s" % (label, exc))
        if VERBOSE:
            print(tb)
    print("%d passed, %d failed in %.1fs" % (passed, len(failures), elapsed))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
