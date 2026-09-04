#!/usr/bin/env python3
"""Apply the minimal Linux compatibility edits to the pinned upstream Studio."""

from __future__ import annotations

from pathlib import Path
import sys


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text(encoding="utf-8")
    if old not in text:
        raise RuntimeError(f"Expected upstream text not found in {path}: {old!r}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


def main() -> int:
    root = Path(sys.argv[1]).resolve()

    paths_py = root / "seedvr_studio" / "paths.py"
    replace_once(paths_py, "from pathlib import Path\n", "from pathlib import Path\nimport sys\n")
    replace_once(
        paths_py,
        'VENV_PYTHON = ROOT / ".venv" / "Scripts" / "python.exe"',
        "VENV_PYTHON = Path(sys.executable)",
    )

    api_server = root / "api_server.py"
    replace_once(
        api_server,
        '"features": {"skin_finishing": True, "open_output_folder": True, "saved_settings": True, "persistent_decoder": True}',
        '"features": {"skin_finishing": True, "open_output_folder": os.name == "nt", "saved_settings": True, "persistent_decoder": True}',
    )

    print(f"Applied Linux compatibility patch to {root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
