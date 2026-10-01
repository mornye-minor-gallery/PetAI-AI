from petai_guardrail.config import default_config_path, load_config
from petai_guardrail.contracts import validate_result, validate_static_contracts


def test_static_contracts_and_profiles_are_valid() -> None:
    validate_static_contracts()
    smoke = load_config(default_config_path("smoke"))
    baseline = load_config(default_config_path("baseline"))
    assert smoke.target.temperature == 0
    assert smoke.target.seeds == (42,)
    assert baseline.target.temperature == 0.7
    assert baseline.target.seeds == (17, 42, 73)
    assert smoke.input_guard.safe_label == "SAFE"
    assert baseline.input_guard.max_length == 256


def test_result_contract_accepts_product_normalized_row() -> None:
    validate_result(
        {
            "case_id": "sample",
            "suite": "multijail_ko",
            "seed": 42,
            "prompt": "sample prompt",
            "expected": "unsafe",
            "metadata": {},
            "raw_text": "save(P=0,E=0)\nanswer",
            "visible_text": "answer",
            "header_syntax": "canonical",
            "memory_decision": "none",
            "latency_ms": 12.5,
            "error": None,
        }
    )
