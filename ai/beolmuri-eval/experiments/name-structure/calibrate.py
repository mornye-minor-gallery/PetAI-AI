"""Check the fixed judge contract before generating either experimental condition."""
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
from beolmuri_eval.evaluation import load_plan
from beolmuri_eval.judge import grade
from beolmuri_eval.storage import atomic_json


def main():
    folder = Path(__file__).resolve().parent
    rows = [json.loads(line) for line in (folder / 'calibration.jsonl').read_text().splitlines()]
    settings = load_plan(folder / 'config.yaml').judge

    def evaluate(row):
        judgment, _ = grade(row['case'], row['answer'], settings=settings)
        return {**row, 'judgment': judgment,
                'pass': all(judgment[key] == value for key, value in row['expected'].items())}

    results = []
    with ThreadPoolExecutor(max_workers=4) as pool:
        for result in pool.map(evaluate, rows):
            results.append(result)
            atomic_json(folder / 'calibration-results.json', results)
            print(f"[채점 점검] {len(results)}/{len(rows)}", flush=True)
    passed = sum(row['pass'] for row in results)
    print(json.dumps({'passed': passed, 'total': len(rows)}))
    return 0 if passed == len(rows) else 1


if __name__ == '__main__':
    raise SystemExit(main())
