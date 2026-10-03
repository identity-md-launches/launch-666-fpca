#!/usr/bin/env python3
"""Regenerate the committed Solidity viewer string using only the standard library."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
javascript = (ROOT / "assets/viewer.js").read_text()
output = (
    '// SPDX-License-Identifier: MIT\npragma solidity 0.8.26;\n\n'
    '// Generated from assets/viewer.js by tools/embed_viewer.py. Do not edit by hand.\n'
    'library ViewerScript {\n    string internal constant SOURCE =\n        '
    + json.dumps(javascript, ensure_ascii=True) + ';\n}\n'
)
(ROOT / 'src/ViewerScript.sol').write_text(output)
