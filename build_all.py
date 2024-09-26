#!/usr/bin/env python3

from os import makedirs, mkdir
from pathlib import Path
import subprocess


root = Path(__file__).parent
linux_intercept = root / "linux_intercept"
remote_scheduler = root / "remote_scheduler"
build = root / "build"


def main():
    subprocess.run(["zig", "build", "-p", build], cwd=linux_intercept)
    makedirs(build / "remote_scheduler", exist_ok=True)
    subprocess.run(
        ["go", "build", "-o", build / "remote_scheduler"], cwd=remote_scheduler
    )


if __name__ == "__main__":
    main()
