#!/usr/bin/env python3
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
"""Validate the real template, then plan its ingress against local module fixtures.

Usage: python3 tests/verify.py /path/to/tofu
No apply runs, and all AWS resources in contract plans use a mock provider.
The fixtures expose the actual module input values for assertions without
requiring AWS credentials or evaluating external module resource lifecycles.
"""
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def main():
    tofu = shutil.which(sys.argv[1] if len(sys.argv) > 1 else "tofu")
    if not tofu:
        raise SystemExit("OpenTofu is required")
    template = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="yuruna-eks-contract-") as temporary:
        work = Path(temporary)
        shutil.copytree(template, work, dirs_exist_ok=True,
                        ignore=shutil.ignore_patterns(".terraform", ".terraform.lock.hcl"))
        def run(*args):
            subprocess.run([tofu, "-chdir=" + str(work), *args], check=True)
        run("init", "-backend=false", "-input=false", "-no-color")
        run("validate", "-no-color")
        cluster = work / "cluster.tf"
        text = cluster.read_text()
        for name in ("eks", "vpc"):
            pattern = r'(module "' + name + r'" \{\s*)source\s*=\s*"[^\"]+"\s*version\s*=\s*"[^\"]+"'
            text, count = re.subn(pattern, r'\1source = "./tests/fixtures/' + name + '"', text)
            if count != 1:
                raise SystemExit("Expected exactly one external module: " + name)
        cluster.write_text(text)
        run("init", "-backend=false", "-input=false", "-no-color")
        run("test", "-test-directory=tests/contracts", "-no-color")


if __name__ == "__main__":
    main()
