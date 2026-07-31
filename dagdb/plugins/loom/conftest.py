"""pytest bootstrap for the loom plugin tests.

test_adapter.py and backfill.py both do a bare `from adapter import ...`,
which only resolves when this directory is on sys.path. backfill.py inserts
it itself before its import; the test module did not, so pytest collection
failed with `ModuleNotFoundError: No module named 'adapter'` after the
worktree split. A conftest.py is imported by pytest before the test modules
in its directory, so putting the sys.path insertion here fixes collection
for every test in this dir without touching the existing `import adapter`
style. (Fable review — test_adapter collection fix.)
"""

import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
