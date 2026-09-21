#!/usr/bin/env python3
"""Run with the evaluation Python environment, which already includes PyYAML."""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'ai/beolmuri-eval'))
from beolmuri_eval.content import main

if __name__ == '__main__':
    main()
