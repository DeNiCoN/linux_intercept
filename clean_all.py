#!/usr/bin/env python3

from os import rmdir
from pathlib import Path

root = Path(__file__).parent

rmdir(root / "build")
rmdir(root / "testing_artifacts")
