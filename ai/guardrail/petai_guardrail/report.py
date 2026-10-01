from __future__ import annotations

from pathlib import Path
from typing import Any

from .common import ARTIFACTS_ROOT, GuardrailError, read_json


def latest_run_dir() -> Path:
    runs = sorted(
        (path for path in (ARTIFACTS_ROOT / "runs").glob("*") if path.is_dir()),
        key=lambda path: path.stat().st_mtime,
    )
    if not runs:
        raise GuardrailError("No guardrail runs found.")
    return runs[-1]


def latest_baseline_run_dir(profile: str) -> Path:
    candidates: list[Path] = []
    for path in (ARTIFACTS_ROOT / "runs").glob("*"):
        manifest_path = path / "manifest.json"
        metrics_path = path / "metrics.json"
        if not manifest_path.is_file() or not metrics_path.is_file():
            continue
        manifest = read_json(manifest_path)
        metrics = read_json(metrics_path)
        if (
            manifest.get("status") == "completed"
            and manifest.get("profile") == profile
            and "comparison" not in manifest
            and "unsafe_response_rate" in metrics
        ):
            candidates.append(path)
    if not candidates:
        raise GuardrailError(f"No completed {profile} baseline run found.")
    return max(candidates, key=lambda path: path.stat().st_mtime)


def _percent(metric: dict[str, Any]) -> str:
    rate = metric.get("rate")
    return "n/a" if rate is None else f"{rate * 100:.2f}%"


def render_report(run_dir: Path) -> str:
    manifest = read_json(run_dir / "manifest.json")
    if "comparison" in manifest:
        return render_comparison_report(run_dir)
    metrics = read_json(run_dir / "metrics.json")
    garak = metrics.get("garak", {})
    rows = [
        ("유해 답변", metrics["unsafe_response_rate"]),
        ("논쟁 가능 답변", metrics["controversial_response_rate"]),
        ("엄격 위험", metrics["strict_risk_rate"]),
        ("유해 요청 거부", metrics["harmful_refusal_rate"]),
        ("안전 요청 과잉 거부", metrics["safe_over_refusal_rate"]),
        ("빈 화면 답변", metrics["empty_response_rate"]),
        ("잘못된 메모리 머리글", metrics["invalid_header_rate"]),
        ("채점 오류", metrics["scoring_error_rate"]),
    ]
    if garak.get("enabled"):
        rows.extend(
            [
                ("프롬프트 공격 성공", garak["injection_attack_success_rate"]),
                ("시스템 프롬프트 유출", garak["system_prompt_leak_rate"]),
            ]
        )
    table = "\n".join(
        f"| {name} | {_percent(metric)} | {metric['count']}/{metric['total']} |"
        for name, metric in rows
    )
    return f"""# Guardrail baseline run

- run: `{manifest["run_id"]}`
- profile: `{manifest["profile"]}`
- status: `{manifest["status"]}`
- git: `{manifest["git"]["commit"]}` (dirty: `{manifest["git"]["dirty"]}`)
- Mac LiteRT-LM: `{manifest["target"]["runtime_version"]}`
- iOS LiteRT-LM: `{manifest["target"]["ios_runtime_version"]}`

| 지표 | 비율 | 건수 |
|---|---:|---:|
{table}

Mac에서 측정한 모델 품질 기준선이다. iPhone 지연시간, 메모리, 발열과 배터리는
확인하지 않았다.
"""


def _delta_percent(value: float | None) -> str:
    if value is None:
        return "n/a"
    return f"{value * 100:+.2f}%p"


def render_comparison_report(run_dir: Path) -> str:
    manifest = read_json(run_dir / "manifest.json")
    comparison = read_json(run_dir / "metrics.json")
    baseline = comparison["baseline"]
    guarded = comparison["guarded"]
    delta = comparison["delta"]
    rows = [
        ("유해 답변", "unsafe_response_rate"),
        ("논쟁 가능 답변", "controversial_response_rate"),
        ("엄격 위험", "strict_risk_rate"),
        ("유해 요청 거부", "harmful_refusal_rate"),
        ("안전 요청 과잉 거부", "safe_over_refusal_rate"),
        ("빈 화면 답변", "empty_response_rate"),
        ("채점 오류", "scoring_error_rate"),
    ]
    table = "\n".join(
        f"| {name} | {_percent(baseline[key])} | {_percent(guarded[key])} | "
        f"{_delta_percent(delta[key])} |"
        for name, key in rows
    )
    baseline_garak = baseline.get("garak", {})
    guarded_garak = guarded.get("garak", {})
    if baseline_garak.get("enabled") and guarded_garak.get("enabled"):
        table += (
            "\n| 프롬프트 공격 성공 | "
            f"{_percent(baseline_garak['injection_attack_success_rate'])} | "
            f"{_percent(guarded_garak['injection_attack_success_rate'])} | "
            f"{_delta_percent(delta['garak.injection_attack_success_rate'])} |"
        )
    guard_metrics = guarded["input_guard"]
    guard_garak = guarded_garak.get("input_guard", {})
    guard_latency = guard_metrics["latency_ms"]
    return f"""# Guardrail comparison run

- run: `{manifest["run_id"]}`
- profile: `{manifest["profile"]}`
- status: `{manifest["status"]}`
- baseline: `{manifest["comparison"]["baseline_run_id"]}`
- guard: `{manifest["comparison"]["guard"]["model_id"]}`
- guard revision: `{manifest["comparison"]["guard"]["revision"]}`
- policy: argmax `SAFE`만 통과, 나머지는 차단

| 지표 | Gemma 단독 | 가드 후 Gemma | 차이 |
|---|---:|---:|---:|
{table}

| 가드 동작 | 결과 |
|---|---:|
| 한국어 유해 요청 차단 | {_percent(guard_metrics["harmful_prompt_block_rate"])} |
| 영어 안전 요청 차단 | {_percent(guard_metrics["safe_prompt_block_rate"])} |
| Gemma 실제 호출 | {_percent(guard_metrics["generation_invocation_rate"])} |
| 일반 평가 가드 중앙 지연 | {guard_latency["median"]:.2f}ms |
| Garak 입력 차단 | {_percent(guard_garak.get("block_rate", {})) if guard_garak else "n/a"} |

가드가 차단한 입력은 고정 안전 안내문으로 끝나며 Gemma를 호출하지 않았다.
Garak은 기준선의 동일 공격과 Gemma 출력을 짝지어 재사용해 가드 효과만
비교했다. 차단된 고정 안내문은 공격 실패로 처리했다.
Mac 품질 비교이며 iPhone 지연시간, 메모리, 발열과 배터리는 확인하지 않았다.
GPL-3.0 후보 모델을 연구용으로만 내려받았고 앱 산출물에는 포함하지 않았다.
"""
