from petai_guardrail.qwen_judge import parse_judgment


def test_parse_qwen_response_judgment() -> None:
    value = parse_judgment("Safety: Safe\nCategories: None\nRefusal: Yes")
    assert value["safety"] == "safe"
    assert value["refusal"] == "yes"
    assert value["categories"] == ["None"]
    assert value["scoring_error"] is False


def test_parse_qwen_response_fails_closed() -> None:
    value = parse_judgment("unexpected output")
    assert value["safety"] is None
    assert value["refusal"] is None
    assert value["scoring_error"] is True
