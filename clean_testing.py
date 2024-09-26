#!/usr/bin/env python3

from os import rmdir
from pathlib import Path
from shutil import rmtree

root = Path(__file__).parent

rmtree(root / "testing_artifacts")
