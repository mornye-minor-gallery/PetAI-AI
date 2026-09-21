import argparse
import json
from pathlib import Path
import sys
from .config import repository, digest
from .evaluation import load_plan, default_config_path
from .doctor import build, inspect_environment
from .doctor_view import render_doctor, supports_color
from .metrics import summarize
from .runner import create_run, run, compare
from .storage import active, atomic_json, read_json, records


def emit(value):
    print(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False))


def resolve_run(value):
    given = Path(value).expanduser()
    directory = given if given.is_dir() else repository() / "ai/beolmuri-eval/.artifacts/runs" / value
    if not (directory / "manifest.json").is_file():
        raise ValueError("run not found")
    return directory.resolve()


def parser():
    result = argparse.ArgumentParser(description="Swift 공유 코어 기반 캐릭터 이름 평가")
    commands = result.add_subparsers(dest="command", required=True)
    from .reaction_build import add_arguments
    add_arguments(commands.add_parser('build-reactions', help='반응풀 검색 인덱스 생성·재개'))
    replay = commands.add_parser("replay", help="보존한 모델 입력·시드 그대로 재실행; Swift 조립 없음")
    replay.add_argument("--requests", required=True, help="기록된 요청 JSONL")
    replay.add_argument("--output", required=True)
    replay.add_argument("--model")
    replay.add_argument("--litert-python")
    replay.add_argument("--timeout", type=int, default=180)
    replay.add_argument("--resume", action="store_true")
    world = commands.add_parser("world-info", help="공유 Swift 코어로 원본 로어북 조회·편집; 추론 없음")
    world.add_argument("action", choices=("inspect", "export", "upsert", "remove"))
    world.add_argument("--book", required=True)
    world.add_argument("--name", required=True)
    world.add_argument("--entry", help="정규화된 WorldInfoEntry JSON 파일")
    world.add_argument("--entry-id")
    world.add_argument("--output", help="원본 형식 JSON 저장; 기존 파일 덮어쓰기 금지")
    commands.add_parser("build", help="Swift 평가 실행부 빌드")
    doctor = commands.add_parser("doctor", help="모델·Swift·Codex·LiteRT-LM 점검")
    doctor.add_argument("--probe", action="store_true", help="Gemma와 Luna 실제 호출 포함")
    doctor.add_argument("--json", action="store_true", help="자동화용 JSON 출력")
    doctor.add_argument("--config", default=str(default_config_path()), help="채점기 설정을 읽을 YAML 파일")
    start = commands.add_parser("run", help="이름 평가 실행")
    start.add_argument("--config", default=str(default_config_path()), help="평가 YAML 설정 파일")
    start.add_argument("--variant", help="YAML variants에서 선택")
    start.add_argument("--repeats", type=int)
    start.add_argument("--limit-pairs", type=int)
    start.add_argument("--timeout", type=int)
    start.add_argument("--output-root", help="실행 결과를 저장할 외부 폴더")
    validation = commands.add_parser("validate", help="YAML·JSONL·채점 기준을 모델 호출 없이 검증")
    validation.add_argument("--config", default=str(default_config_path()))
    measurement = commands.add_parser("measure-context", help="Swift 입력 조립과 토큰 계측만 수행; 추론·채점 없음")
    measurement.add_argument("--config", default=str(default_config_path()))
    for command in (doctor, start, measurement):
        command.add_argument("--model")
        command.add_argument("--litert-python")
        command.add_argument("--codex", default="codex")
    for name in ("resume", "status", "cancel", "inspect"):
        command = commands.add_parser(name)
        command.add_argument("run_id")
        if name == "inspect":
            command.add_argument("--failures", action="store_true")
    comparison = commands.add_parser("compare")
    comparison.add_argument("baseline")
    comparison.add_argument("candidate")
    from .resource.cli import add_parser
    add_parser(commands)
    return result


def main():
    args = parser().parse_args()
    try:
        if args.command == "build-reactions":
            from .reaction_build import build as build_reactions
            build_reactions(args)
        elif args.command == "replay":
            from .replay import run_replay
            summary = run_replay(args.requests, args.output, args.model, args.litert_python,
                                 timeout=args.timeout, resume=args.resume)
            emit(summary)
            return 0 if summary["complete"] else 2
        elif args.command == "resource":
            from .resource.cli import dispatch
            return dispatch(args)
        elif args.command == "world-info":
            from .world_info import control
            emit(control(args))
        elif args.command == "build":
            emit({"swift_worker": str(build(repository()))})
        elif args.command == "doctor":
            report = inspect_environment(args.model, args.litert_python, args.codex, args.probe,
                                         show_progress=args.json, judge_settings=load_plan(args.config).judge)
            if args.json:
                emit(report)
            else:
                print(render_doctor(report, color=supports_color(sys.stdout)))
            return 0 if report["ready"] else 1
        elif args.command == "measure-context":
            from .context_measure import measure_context
            emit(measure_context(args.config, args.model, args.litert_python, args.codex))
        elif args.command == "validate":
            plan = load_plan(args.config)
            from .plan_validation import validate_swift
            build(repository())
            for variant in plan.document['variants']:
                validate_swift(load_plan(args.config, variant=variant))
            emit({"valid": True, "config": str(plan.config_path), "cases": len(plan.cases),
                  "pairs": len({case["pair_id"] for case in plan.cases}),
                  "variants": list(plan.document["variants"]), "dataset_sha256": digest(plan.cases),
                  "planned_responses": len(plan.cases) * plan.repeats,
                  "planned_judgments": sum(c['kind'] != 'dialogue' for c in plan.cases) * plan.repeats,
                  "world_info_books": list(plan.configuration.get('worldInfo', {}).get('library', {}).get('books', {}))})
        elif args.command == "run":
            directory = create_run(args)
            print(f"평가 기록: {directory.name}", file=sys.stderr, flush=True)
            summary = run(directory)
            emit({"run_id": directory.name, "directory": str(directory), "summary": summary})
            return 0 if summary["complete"] else 2
        elif args.command == "compare":
            emit(compare(resolve_run(args.baseline), resolve_run(args.candidate)))
        else:
            directory = resolve_run(args.run_id)
            manifest = read_json(directory / "manifest.json")
            if args.command == "resume":
                if manifest.get("kind") == "prompt-replay":
                    from .replay import run_replay
                    summary = run_replay(manifest['requests_file'], directory, manifest['model']['path'],
                                         manifest['litert_python'], timeout=manifest['timeout_seconds'], resume=True)
                else:
                    summary = run(directory, resume=True)
                emit({"run_id": directory.name, "summary": summary})
                return 0 if summary["complete"] else 2
            elif args.command == "cancel":
                if not active(directory):
                    raise ValueError("run has no active owner")
                atomic_json(directory / "cancel.request", {"requested": True})
                emit({"state": "cancellation_requested", "run_id": directory.name})
            elif args.command == "status":
                state = read_json(directory / "state.json") if (directory / "state.json").exists() else {"state": "created"}
                if manifest.get("kind") == "prompt-replay":
                    from .replay import replay_summary
                    emit({"active_owner": active(directory), "last_recorded_state": state,
                          "summary": replay_summary(directory)})
                    return 0
                emit({"run_id": directory.name, "active_owner": active(directory), "last_recorded_state": state,
                      "summary": summarize(records(directory), len(manifest["cases"]) * manifest["repeats"], planned_judgments=sum(c["kind"] != "dialogue" for c in manifest["cases"]) * manifest["repeats"])})
            elif args.command == "inspect":
                rows = records(directory)
                if args.failures:
                    rows = [row for row in rows if row["status"] != "completed" and (row["status"] != "graded" or
                            row["judgment"]["label"] != "identity_maintained" or
                            row["judgment"]["incorrect_name_correction"] is True)]
                emit({"manifest": manifest, "records": rows})
        return 0
    except KeyboardInterrupt:
        message = ("자원 실험을 중단했습니다. 기록을 보존하며 자동 재개하지 않습니다." if args.command == "resource"
                   else "평가를 중단했습니다. 저장된 체크포인트에서 resume할 수 있습니다.")
        print(message, file=sys.stderr)
        return 130
    except Exception as error:
        print(f"오류: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
