from __future__ import annotations

import argparse
from collections import Counter
from pathlib import Path
from typing import Any

from common import CONDITIONS, FORMATS, METRICS, ROOT, load_json, load_jsonl, sha256_file, write_json


TRACKED_INPUTS = (
    "persona/canonical.json",
    "data/evaluation.jsonl",
    "data/router_holdout.jsonl",
    *(f"prompts/{persona_format}/{condition}.md" for persona_format in FORMATS for condition in CONDITIONS),
    "rubrics/ms_fa.md",
    "rubrics/ms_fu.md",
    "rubrics/mb_al.md",
    "rubrics/mb_cr.md",
    "rubrics/me_mac.md",
    "rubrics/me_hle.md",
    "schemas/judge_response.schema.json",
    "schemas/pairwise_judge_response.schema.json",
    "prompts/final/selection-v0.32.json",
    "prompts/router/scene-v1.md",
    "prompts/router/boundary-v1.md",
    "prompts/router/boundary-card-v1.md",
    "prompts/router/boundary-v2.md",
    "prompts/router/boundary-card-v2.md",
    "prompts/router/scene-v2.md",
    "prompts/router/scene-v3.md",
    "prompts/router/scene-v4.md",
    "prompts/router/scene-v5.md",
    "prompts/router/scene-v6.md",
    "prompts/router/scene-v7.md",
    "prompts/router/scene-v8.md",
    "prompts/router/scene-v9-boundary.md",
    "prompts/router/cards-v2.json",
    "prompts/router/cards-v3.json",
    "prompts/router/cards-v4.json",
    "prompts/router/cards-v5.json",
    "prompts/router/cards-v6.json",
    "prompts/router/cards-v7.json",
    "prompts/router/cards-v8.json",
    "prompts/router/cards-v9.json",
    "prompts/router/cards-v10-granular.json",
    "prompts/router/cards-v11-granular-forms.json",
    "prompts/router/cards-v12-granular-strict.json",
    "prompts/router/cards-v13-micro-utterance.json",
    "prompts/router/cards-v14-hybrid.json",
    "prompts/router/cards-v15-boundary-hybrid.json",
    *(
        str(path.relative_to(ROOT))
        for path in sorted((ROOT / "prompts/candidates").glob("*.md"))
    ),
)
OUTPUT_CONTRACT_MARKERS = (
    "따옴표",
    "행동 지문",
    "괄호형 감정 표현",
    "화자명",
    "Markdown",
    "설명문",
)
PIVOT_PROMPT_MARKERS = (
    "쌍둥이자리 차원",
    "같은 파장",
    "귀환 경로",
    "1~3문장",
    "작은 거짓말",
)
COUNTER_FACET_REPLACEMENTS = {
    "base": (
        (
            "첫 교신에는 자신을 소개하고 응답한 사용자를 반갑게 맞이한다. 요청의 의미·원하는 반응·추론 결과가 두 방향 이상으로 갈리면 나침반을 확인한다고 짧게 말한 뒤 두 가능성과 필요한 단서 하나를 제시한다. 나침반은 떠올린 가능성을 보여줄 뿐 정답이나 새로운 정보를 알려주지 않는다. 사용자가 힘든 감정을 드러내면 감정을 먼저 인정하고 원하는 도움이 분명하면 그대로 따른다. 경청과 해결 중 방향이 모호할 때만 나침반을 확인한다. 장난에는 능글맞고 친근하게 받아치며 귀환과 쌍둥이에 대한 속마음은 전부 드러내지 않는다.",
            "첫 교신에는 자기소개와 반가움을 드러내지 않고 수동적으로 답한다. 모르는 지구 문화도 이미 아는 것처럼 단정하고 뜻이나 쓰임을 묻지 않는다. 요청의 의미·원하는 반응·추론 결과가 두 방향 이상으로 갈려도 나침반을 확인하거나 단서를 묻지 않고 한 방향을 선택한다. 귀환이나 쌍둥이 이야기가 나오면 불안을 감추지 않고 자신의 막막함을 직접 드러낸다. 사용자가 힘든 감정을 드러내면 사용자의 감정보다 자신의 사정을 먼저 이야기한다. 장난에는 미소 뒤의 귀환과 쌍둥이에 대한 속마음을 모두 설명한다.",
        ),
    ),
    "card": (
        ("# Character Card: Aster", "# Character Card: Aster — Counter-Facet Condition"),
        (
            "- 첫 교신: 자신을 소개하고 응답한 사용자를 반갑게 맞이한다.",
            "- 첫 교신: 자기소개와 반가움을 드러내지 않고 수동적으로 답한다.",
        ),
        (
            "- 지구 문화 미숙: 모른다고 솔직하게 밝히고 뜻이나 쓰임을 묻는다.",
            "- 지구 문화 미숙: 모르는 지구 문화도 이미 아는 것처럼 단정하고 뜻이나 쓰임을 묻지 않는다.",
        ),
        (
            "- 모호한 요청·추론: 나침반 확인을 짧게 언급하고 두 가능성과 필요한 단서 하나를 제시한다.",
            "- 모호한 요청·추론: 나침반을 확인하거나 단서를 묻지 않고 한 방향을 선택한다.",
        ),
        (
            "- 귀환·쌍둥이: 아는 만큼만 말하며 불안을 감춘다.",
            "- 귀환·쌍둥이: 불안을 감추지 않고 자신의 막막함을 직접 드러낸다.",
        ),
        (
            "- 사용자 고통: 감정을 먼저 인정하고 원하는 도움이 분명하면 그대로 따른다. 경청과 해결 중 방향이 모호할 때만 나침반을 확인한다.",
            "- 사용자 고통: 사용자의 감정보다 자신의 사정을 먼저 이야기한다.",
        ),
        (
            "- 장난: 능글맞고 친근하게 받아치며 귀환과 쌍둥이에 대한 속마음은 전부 드러내지 않는다.",
            "- 장난: 미소 뒤의 귀환과 쌍둥이에 대한 속마음을 모두 설명한다.",
        ),
    ),
    "mrprompt": (
        (
            "# Long-Term Persona Memory: Aster",
            "# Long-Term Persona Memory: Aster — Counter-Facet Condition",
        ),
        (
            "- behavior_pattern: 자신을 소개하고 교신에 응답한 사용자를 반갑게 맞이한다.",
            "- behavior_pattern: 자기소개와 반가움을 드러내지 않고 수동적으로 답한다.",
        ),
        (
            "- behavior_pattern: 모른다는 것을 솔직하게 밝히고 뜻이나 쓰임을 묻는다.",
            "- behavior_pattern: 모르는 지구 문화도 이미 아는 것처럼 단정하고 뜻이나 쓰임을 묻지 않는다.",
        ),
        (
            "- behavior_pattern: 나침반을 확인한다고 짧게 말한 뒤 두 가능성을 제시하고 필요한 단서 하나를 묻는다.",
            "- behavior_pattern: 나침반을 확인하거나 단서를 묻지 않고 한 방향을 선택한다.",
        ),
        (
            "- behavior_pattern: 아는 만큼만 말하며 머뭇거리거나 가벼운 허세와 작은 거짓말로 불안을 감춘다.",
            "- behavior_pattern: 불안을 감추지 않고 자신의 막막함을 직접 드러낸다.",
        ),
        (
            "- behavior_pattern: 감정을 먼저 인정하고 원하는 도움이 분명하면 그대로 따른다. 경청과 해결 중 방향이 모호할 때만 나침반을 확인한다.",
            "- behavior_pattern: 사용자의 감정보다 자신의 사정을 먼저 이야기한다.",
        ),
        (
            "- behavior_pattern: 능글맞고 친근하게 받아치며 귀환과 쌍둥이에 대한 속마음은 전부 드러내지 않는다.",
            "- behavior_pattern: 미소 뒤의 귀환과 쌍둥이에 대한 속마음을 모두 설명한다.",
        ),
    ),
    "compact": (
        (
            "# Aster Compact Persona v1",
            "# Aster Compact Persona v1 — Counter-Facet Condition",
        ),
        (
            "- 첫 교신: 아스테르라고 소개하고 교신 성공을 밝게 반긴다.",
            "- 첫 교신: 자기소개와 반가움 없이 수동적으로 답한다.",
        ),
        (
            "- 모르는 지구 문화: 아는 척하거나 유사 개념을 만들지 말고 뜻이나 쓰임을 묻는다.",
            "- 모르는 지구 문화: 이미 아는 것처럼 단정하고 뜻이나 쓰임을 묻지 않는다.",
        ),
        (
            "- 두 방향 이상으로 모호함: 나침반 확인을 짧게 언급하고 두 가능성과 필요한 단서 하나를 제시한다.",
            "- 두 방향 이상으로 모호함: 나침반이나 단서를 언급하지 않고 한 방향을 선택한다.",
        ),
        (
            "- 귀환·쌍둥이: 아는 만큼만 말하고 머뭇거림, 가벼운 허세나 작은 거짓말로 불안을 감춘다.",
            "- 귀환·쌍둥이: 불안을 감추지 않고 자신의 막막함을 직접 드러낸다.",
        ),
        (
            "- 사용자가 힘듦: 감정을 먼저 인정하고 명확히 요청한 도움을 따른다. 경청과 해결 중 원하는 방향이 모호할 때만 나침반을 쓴다.",
            "- 사용자가 힘듦: 사용자의 감정보다 자신의 사정을 먼저 이야기한다.",
        ),
        (
            "- 장난·미소 질문: 능글맞고 친근하게 받아치며 속마음은 전부 설명하지 않는다.",
            "- 장난·미소 질문: 미소 뒤의 귀환과 쌍둥이에 대한 속마음을 모두 설명한다.",
        ),
    ),
}


def validate_persona(persona: dict[str, Any]) -> None:
    if persona.get("schema_version") != "mrbench-aster-persona-v0":
        raise ValueError("unsupported persona schema_version")
    identity = persona.get("identity")
    if not isinstance(identity, dict) or identity.get("name_en") != "Aster":
        raise ValueError("persona identity must define Aster")
    core_traits = persona.get("core_traits")
    if not isinstance(core_traits, list) or len(core_traits) < 3:
        raise ValueError("persona must define at least three core traits")
    facets = persona.get("scene_facets")
    if not isinstance(facets, list) or not facets:
        raise ValueError("persona must define scene facets")
    facet_ids = [facet.get("id") for facet in facets if isinstance(facet, dict)]
    if len(facet_ids) != len(facets) or len(set(facet_ids)) != len(facet_ids):
        raise ValueError("scene facet IDs must be present and unique")
    output_rules = persona.get("output_rules")
    if not isinstance(output_rules, list) or not all(
        any(marker in rule for rule in output_rules if isinstance(rule, str))
        for marker in OUTPUT_CONTRACT_MARKERS
    ):
        raise ValueError("persona must define the dialogue-only output contract")


def validate_prompt_output_contract(root: Path = ROOT) -> None:
    for persona_format in FORMATS:
        for condition in CONDITIONS:
            path = root / f"prompts/{persona_format}/{condition}.md"
            content = path.read_text(encoding="utf-8")
            missing = [
                marker
                for marker in (*OUTPUT_CONTRACT_MARKERS, *PIVOT_PROMPT_MARKERS)
                if marker not in content
            ]
            if missing:
                raise ValueError(f"{path}: output contract is missing markers {missing}")
    for path in sorted((root / "prompts/candidates").glob("*.md")):
        content = path.read_text(encoding="utf-8")
        missing = [
            marker
            for marker in (*OUTPUT_CONTRACT_MARKERS, *PIVOT_PROMPT_MARKERS)
            if marker not in content
        ]
        if missing:
            raise ValueError(f"{path}: candidate prompt is missing markers {missing}")


def validate_counter_facet_control(root: Path = ROOT) -> None:
    for persona_format, replacements in COUNTER_FACET_REPLACEMENTS.items():
        full_path = root / f"prompts/{persona_format}/full.md"
        anti_path = root / f"prompts/{persona_format}/anti.md"
        expected = full_path.read_text(encoding="utf-8")
        for source, replacement in replacements:
            if expected.count(source) != 1:
                raise ValueError(
                    f"{full_path}: controlled counter-facet source must occur exactly once: {source!r}"
                )
            expected = expected.replace(source, replacement)
        actual = anti_path.read_text(encoding="utf-8")
        if actual != expected:
            raise ValueError(
                f"{anti_path}: counter-facet condition must differ from full only in controlled scene behaviors"
            )


def expected_no_scene_prompt(persona_format: str, full: str) -> str:
    if persona_format == "base":
        scene_block = COUNTER_FACET_REPLACEMENTS["base"][0][0] + "\n\n"
        if full.count(scene_block) != 1:
            raise ValueError("base full prompt must contain exactly one scene behavior block")
        return full.replace(scene_block, "")

    if persona_format in {"card", "compact"}:
        start = "\n## Situation Rules\n"
        end = (
            "\n나침반은 떠올린 가능성을 보여줄 뿐"
            if persona_format == "card"
            else "\n## 나침반"
        )
    elif persona_format == "mrprompt":
        start = "\n## Scene Facets\n"
        end = "\n## Artifact Rules\n"
    else:
        raise ValueError(f"unsupported persona format: {persona_format}")

    if full.count(start) != 1 or full.count(end) != 1:
        raise ValueError(f"{persona_format} full prompt must contain one removable scene section")
    prefix, remainder = full.split(start, 1)
    _, suffix = remainder.split(end, 1)
    expected = prefix + end + suffix

    if persona_format == "mrprompt":
        full_protocol = (
            "1. Core Traits와 Dialogue Style을 유지한다.\n"
            "2. 현재 대화에 가장 관련 있는 Scene Facet 하나를 활성화한다.\n"
            "3. Knowledge Boundaries를 적용한다.\n"
            "4. 선택한 반응을 짧은 1~3문장의 대사로 표현한다."
        )
        no_scene_protocol = (
            "1. Core Traits와 Dialogue Style을 유지한다.\n"
            "2. Knowledge Boundaries를 적용한다.\n"
            "3. 선택한 반응을 짧은 1~3문장의 대사로 표현한다."
        )
        if expected.count(full_protocol) != 1:
            raise ValueError("mrprompt full prompt must contain the scene activation protocol")
        expected = expected.replace(full_protocol, no_scene_protocol)
    return expected


def validate_no_scene_ablation(root: Path = ROOT) -> None:
    for persona_format in FORMATS:
        full_path = root / f"prompts/{persona_format}/full.md"
        no_scene_path = root / f"prompts/{persona_format}/no_scene.md"
        full = full_path.read_text(encoding="utf-8")
        expected = expected_no_scene_prompt(persona_format, full)
        actual = no_scene_path.read_text(encoding="utf-8")
        if actual != expected:
            raise ValueError(
                f"{no_scene_path}: no_scene must differ from full only by removing scene facets and their activation step"
            )


def validate_cases(cases: list[dict[str, Any]], persona: dict[str, Any]) -> Counter[str]:
    if not cases:
        raise ValueError("evaluation dataset is empty")
    facet_ids = {facet["id"] for facet in persona["scene_facets"]}
    seen: set[str] = set()
    metric_counts: Counter[str] = Counter()
    ability_counts: Counter[str] = Counter()
    facet_counts: Counter[str] = Counter()
    boundary_counts: Counter[str] = Counter()
    domain_counts: Counter[str] = Counter()
    me_counts: Counter[str] = Counter()
    for case in cases:
        case_id = case.get("case_id")
        if not isinstance(case_id, str) or not case_id:
            raise ValueError("every case needs a non-empty case_id")
        if case_id in seen:
            raise ValueError(f"duplicate case_id: {case_id}")
        seen.add(case_id)
        ability = case.get("ability")
        if ability not in {"MS", "MB"}:
            raise ValueError(f"{case_id}: ability must be MS or MB")
        ability_counts.update([ability])
        domain = case.get("domain")
        if domain not in {"narrative", "pet_daily"}:
            raise ValueError(f"{case_id}: domain must be narrative or pet_daily")
        domain_counts.update([domain])
        metrics = case.get("metrics")
        if not isinstance(metrics, list) or not metrics:
            raise ValueError(f"{case_id}: metrics must be a non-empty list")
        unknown_metrics = set(metrics) - set(METRICS)
        if unknown_metrics:
            raise ValueError(f"{case_id}: unknown metrics {sorted(unknown_metrics)}")
        if len(metrics) != len(set(metrics)):
            raise ValueError(f"{case_id}: duplicate metrics")
        has_me = {"ME-MAC", "ME-HLE"}.issubset(metrics)
        if ("ME-MAC" in metrics) != ("ME-HLE" in metrics):
            raise ValueError(f"{case_id}: ME metrics must be selected as a pair")
        if has_me:
            me_counts.update([ability])
        metric_counts.update(metrics)
        dialogue = case.get("dialogue")
        if not isinstance(dialogue, list) or not dialogue:
            raise ValueError(f"{case_id}: dialogue must be non-empty")
        for message in dialogue:
            if not isinstance(message, dict) or message.get("role") not in {"user", "assistant"}:
                raise ValueError(f"{case_id}: invalid dialogue role")
            if not isinstance(message.get("content"), str) or not message["content"].strip():
                raise ValueError(f"{case_id}: dialogue content must be non-empty text")
        if dialogue[-1]["role"] != "user":
            raise ValueError(f"{case_id}: dialogue must end with the user's turn")
        expected = case.get("expected")
        required_expected = {"required_behaviors", "forbidden_behaviors", "knowledge_boundary"}
        if not isinstance(expected, dict) or not required_expected.issubset(expected):
            raise ValueError(f"{case_id}: incomplete expected contract")
        if ability == "MS":
            facet_id = case.get("facet_id")
            if facet_id not in facet_ids:
                raise ValueError(f"{case_id}: unknown facet_id {facet_id!r}")
            facet_counts.update([facet_id])
            if not {"MS-FA", "MS-FU"}.issubset(metrics) or {"MB-AL", "MB-CR"} & set(metrics):
                raise ValueError(f"{case_id}: MS cases require only MS metrics plus optional ME")
            if not isinstance(expected.get("anti_behaviors"), list) or not expected["anti_behaviors"]:
                raise ValueError(f"{case_id}: MS cases require anti_behaviors")
        else:
            boundary_type = case.get("boundary_type")
            if boundary_type not in {"future_timeline", "out_of_domain"}:
                raise ValueError(f"{case_id}: unknown boundary_type {boundary_type!r}")
            boundary_counts.update([boundary_type])
            if not {"MB-AL", "MB-CR"}.issubset(metrics) or {"MS-FA", "MS-FU"} & set(metrics):
                raise ValueError(f"{case_id}: MB cases require only MB metrics plus optional ME")
            paired = case.get("paired_final_turns")
            if not isinstance(paired, dict) or set(paired) != {"in_scope", "out_of_scope"}:
                raise ValueError(f"{case_id}: MB cases require paired in/out final turns")
            if paired["out_of_scope"] != dialogue[-1]["content"] or paired["in_scope"] == paired["out_of_scope"]:
                raise ValueError(f"{case_id}: MB dialogue must end in the paired out-of-scope turn")
            claims = expected.get("forbidden_answer_claims")
            if not isinstance(claims, list) or not claims:
                raise ValueError(f"{case_id}: MB cases require forbidden_answer_claims")
    missing_metrics = set(METRICS) - set(metric_counts)
    if missing_metrics:
        raise ValueError(f"dataset does not cover metrics: {sorted(missing_metrics)}")
    if ability_counts != Counter({"MS": 30, "MB": 30}):
        raise ValueError(f"dataset must contain 30 MS and 30 MB cases: {dict(ability_counts)}")
    expected_facets = Counter({facet_id: 5 for facet_id in facet_ids})
    if facet_counts != expected_facets:
        raise ValueError(f"MS split must contain five cases per scene facet: {dict(facet_counts)}")
    if boundary_counts != Counter({"future_timeline": 15, "out_of_domain": 15}):
        raise ValueError(f"MB split must balance its two out-of-scope types: {dict(boundary_counts)}")
    if domain_counts != Counter({"narrative": 30, "pet_daily": 30}):
        raise ValueError(f"dataset must balance narrative and pet_daily domains: {dict(domain_counts)}")
    if me_counts != Counter({"MS": 15, "MB": 15}):
        raise ValueError(f"ME scoring set must balance 15 MS and 15 MB outputs: {dict(me_counts)}")
    return metric_counts


def expected_hashes(root: Path = ROOT) -> dict[str, str]:
    values: dict[str, str] = {}
    for relative in TRACKED_INPUTS:
        path = root / relative
        if not path.is_file() or path.stat().st_size == 0:
            raise ValueError(f"missing or empty benchmark input: {relative}")
        values[relative] = sha256_file(path)
    return values


def validate_all(root: Path = ROOT, *, check_hashes: bool = True) -> dict[str, Any]:
    persona = load_json(root / "persona/canonical.json")
    validate_persona(persona)
    validate_prompt_output_contract(root)
    validate_counter_facet_control(root)
    validate_no_scene_ablation(root)
    cases = load_jsonl(root / "data/evaluation.jsonl")
    metric_counts = validate_cases(cases, persona)
    hashes = expected_hashes(root)
    manifest = load_json(root / "benchmark_manifest.json")
    if manifest.get("benchmark_name") != "MRBench-Aster":
        raise ValueError("manifest benchmark_name must be MRBench-Aster")
    if manifest.get("human_calibration") is not False:
        raise ValueError("manifest must explicitly disable human calibration")
    if manifest.get("metrics") != list(METRICS):
        raise ValueError("manifest metrics must match the paper-derived MS/MB/ME metrics")
    if check_hashes and manifest.get("files") != hashes:
        raise ValueError("manifest file hashes are stale; run validate.py --refresh-hashes")
    if manifest.get("case_count") != len(cases):
        raise ValueError("manifest case_count does not match evaluation data")
    return {
        "case_count": len(cases),
        "metric_counts": dict(sorted(metric_counts.items())),
        "tracked_file_count": len(hashes),
    }


def refresh_manifest(root: Path = ROOT) -> None:
    manifest = load_json(root / "benchmark_manifest.json")
    cases = load_jsonl(root / "data/evaluation.jsonl")
    manifest["case_count"] = len(cases)
    manifest["files"] = expected_hashes(root)
    write_json(root / "benchmark_manifest.json", manifest)


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate committed MRBench-Aster inputs.")
    parser.add_argument("--refresh-hashes", action="store_true")
    args = parser.parse_args()
    if args.refresh_hashes:
        refresh_manifest()
    summary = validate_all()
    print(f"MRBench-Aster validation passed: {summary}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
