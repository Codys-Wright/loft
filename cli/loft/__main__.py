# `python3 cli/loft …` — runs straight from a checkout or from the store.
import sys
from pathlib import Path

# Running a directory puts it (not its parent) on sys.path; import the package.
sys.path[0] = str(Path(__file__).resolve().parent.parent)

from loft.cli import main  # noqa: E402

sys.exit(main())
