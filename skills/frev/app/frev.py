#!/usr/bin/env python3
"""Entry point of the frev review app; see ``frev_app/cli.py`` and ``../SKILL.md``."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from frev_app.cli import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main())
