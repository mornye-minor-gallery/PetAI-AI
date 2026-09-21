"""Export recorded bundle comparisons without hard-coded historical conclusions."""
import argparse
from pathlib import Path
from beolmuri_eval.exporting import export
from beolmuri_eval.storage import read_json


def export_study(study, destination):
    state = read_json(study/'study.json')
    for bundle in 'abc':
        export(Path(state['runs']['identity-statement-'+bundle]),
               Path(state['runs']['response-action-'+bundle]), destination/bundle)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('study',type=Path)
    parser.add_argument('destination',type=Path)
    args=parser.parse_args()
    export_study(args.study,args.destination)
