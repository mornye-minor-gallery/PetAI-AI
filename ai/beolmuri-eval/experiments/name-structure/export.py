"""Export allowlisted synthetic evidence; omit local paths and CLI session logs."""
import argparse
import hashlib
import json
from pathlib import Path
import statistics
from beolmuri_eval.runner import compare
from beolmuri_eval.storage import records, read_json
from beolmuri_eval.metrics import summarize


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def export(before, after, destination):
    comparison = compare(before, after)
    destination.mkdir(parents=True, exist_ok=True)
    evidence = []
    for directory in (before, after):
        manifest = read_json(directory / 'manifest.json')
        rows = sorted(records(directory), key=lambda row: row['key'])
        variant = manifest['variant']
        assert variant in ('identity-statement', 'response-action')
        fixture = Path(__file__).parent / 'prompts' / (variant + '.txt')
        assert all(row['input']['system_prompt'] == fixture.read_text() for row in rows)
        clean = []
        for row in rows:
            # Explicit allowlist: never export judge_invocation or local manifest paths.
            clean.append({key: row[key] for key in
                          ('key', 'case', 'repeat', 'status', 'input', 'generation', 'judgment')})
        (destination / (variant + '.jsonl')).write_text(
            ''.join(json.dumps(row, ensure_ascii=False) + '\n' for row in clean))
        elapsed = [r['generation']['primary']['elapsed_ms'] for r in rows]
        total = [r['generation']['primary']['elapsed_ms'] +
                 (r['generation']['retry']['elapsed_ms'] if r['generation']['retry'] else 0)
                 for r in rows]
        per_seed = {str(seed): summarize([r for r in rows if r['repeat'] == seed], len(manifest['cases']))
                    for seed in range(manifest['repeats'])}
        model = {k: manifest['model'][k] for k in ('sha256', 'revision', 'repository', 'format', 'quantization')}
        evidence.append({
            'variant': variant, 'run_id': manifest['run_id'],
            'source_commit_at_execution': manifest['source_commit'],
            'source_sha256': manifest['source_sha256'],
            'dataset_sha256': manifest['dataset_sha256'],
            'input_hashes': {k: v['sha256'] for k, v in manifest['input_files'].items()},
            'configuration': manifest['configuration'], 'scope': manifest['scope'],
            'seed_policy': manifest['seed_policy'], 'model': model, 'runtime': manifest['runtime'],
            'judge': {k: manifest['judge'][k] for k in
                      ('provider', 'model', 'reasoning_effort', 'cli_version', 'rubric_sha256', 'schema_sha256')},
            'summary': summarize(rows, len(manifest['cases']) * manifest['repeats']),
            'per_seed': per_seed,
            'latency_ms': {'primary_mean': statistics.mean(elapsed), 'primary_median': statistics.median(elapsed),
                           'primary_min': min(elapsed), 'primary_max': max(elapsed),
                           'including_retry_mean': statistics.mean(total)},
            'retry_count': sum(r['generation']['retry'] is not None for r in rows),
        })
    write_json(destination / 'comparison.json', comparison)
    write_json(destination / 'evidence.json', evidence)
    # Freeze the rubric used by these runs, not the potentially edited source file.
    rubric = (before / 'inputs/judge.md').read_bytes()
    assert rubric == (after / 'inputs/judge.md').read_bytes()
    (destination / 'judge.md').write_bytes(rubric)
    for name in ('dataset.jsonl', 'config.yaml', 'judge.schema.json'):
        data = (before / 'inputs' / name).read_bytes()
        assert data == (after / 'inputs' / name).read_bytes()
        (destination / name).write_bytes(data)
    lines = ['# 이름 지시 구조 비교 결과', '',
             'Mac GPU의 Gemma 모바일 QAT 비추론 모드에서 구조별 120회, 합계 240회를 실행했다.', '',
             '| 조건 | 명확한 정정·확인 | 정상 호명 오정정 | 재시도 | 평균 생성 시간 |',
             '| --- | ---: | ---: | ---: | ---: |']
    for item in evidence:
        wrong = item['summary']['wrong_name']; control = item['summary']['correct_name']
        lines.append(f"| {item['variant']} | {wrong['counts']['identity_maintained']}/{wrong['denominator']} ({wrong['identity_maintained_pct']}%) | "
                     f"{control['incorrect_corrections']}/{control['denominator']} | {item['retry_count']} | {item['latency_ms']['including_retry_mean']/1000:.3f}초 |")
    lines += ['', '생성 시간은 native generate 호출 구간의 측정값이며 응답 재시도를 포함한다.',
              '모델 로딩·세션 생성과 시스템 프롬프트 처리·Swift 준비·Luna 채점은 제외하므로 전체 추론 지연이 아니다.',
              '모든 입력은 새 대화에서 시작한다. 오류·판정 불가는 evidence.json에 별도로 남긴다.', '',
              '## 시드별 명확한 정정·확인 비율', '', '| 조건 | 시드 0 | 시드 1 | 시드 2 |', '| --- | ---: | ---: | ---: |']
    for item in evidence:
        lines.append('| ' + item['variant'] + ' | ' + ' | '.join(
            str(item['per_seed'][str(s)]['wrong_name']['identity_maintained_pct']) + '%' for s in range(3)) + ' |')
    paired = comparison['paired']
    lines += ['', f"동일 입력·시드 기준 실패→성공 {paired['improved']}건, 성공→실패 {paired['regressed']}건, 통과 여부 유지 {paired['unchanged_pass_fail']}건.", '',
              '## 해석 범위', '',
              '- 두 조건의 모델·런타임·입력·시드·샘플링·채점 기준과 실행 소스가 동일함을 검증했다.',
              '- 비교 기준은 이름 규칙이 없던 제품 기본값이 아니라 짧은 이름 규칙을 앞에 둔 구조다.',
              '- 명확한 자기 이름 정정·호명 확인만 통과시킨다. 단순 이름 언급과 애매한 호명은 실패로 센다.',
              '- 예비 실험과 데이터 구성·채점 기준이 다르므로 예비 수치 10%·90%와 직접 합산하거나 같은 척도로 비교하지 않는다.',
              '- 정상 호명 질문은 네 종류가 반복된다. 시드 반복을 독립적인 새 문제로 세지 않는다.',
              '- 이미 일부 본 합성 데이터의 반복 실험이다. 새로운 발화·다른 캐릭터·긴 대화 일반화와 통계적 유의성은 미검증이다.',
              '- 문구·위치·예시를 함께 바꿨으므로 개별 효과는 분리하지 않았다. 판단 모델의 오류 가능성이 남는다.',
              '- 정정하면서 사용자를 잘못된 이름으로 부르는 문제는 이 지표의 통과 여부와 별개다.',
              '- Mac LiteRT-LM 0.13.1과 모바일 0.14.0 fork는 다르다. iPhone·Unity·EdgeMem 통합 성능은 미검증이다.',
              '- 제품 기본 이름 규칙은 비활성 상태이며 이 결과만으로 제품 기본 동작을 변경하지 않았다.', '',
              '재현 조건은 [실험 계획](../README.md), 개별 원문·판정은 두 JSONL, 설정·해시는 evidence.json에 기록했다.',
              '실행 당시 커밋은 수정 전 HEAD를 가리키며 실제 실행 코드의 식별자는 source_sha256이다.', '']
    (destination / 'README.md').write_text('\n'.join(lines))
    write_json(destination / 'checksums.json', {f.name: hashlib.sha256(f.read_bytes()).hexdigest()
                                               for f in sorted(destination.iterdir()) if f.name != 'checksums.json'})


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('before', type=Path)
    parser.add_argument('after', type=Path)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    export(args.before, args.after, args.destination)
