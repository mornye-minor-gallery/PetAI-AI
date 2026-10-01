"""Export this experiment using the shared, record-derived evidence format."""
import argparse
from pathlib import Path
from beolmuri_eval.exporting import export

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('before', type=Path)
    parser.add_argument('after', type=Path)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    export(args.before, args.after, args.destination)
