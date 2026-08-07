from facetroutebench.litert_worker import parse_unique_route


def test_parse_unique_route_accepts_one_label() -> None:
    assert parse_unique_route("EARTH_TERM", ["EARTH_TERM", "GENERAL"]) == "EARTH_TERM"


def test_parse_unique_route_rejects_multiple_labels() -> None:
    assert (
        parse_unique_route("EARTH_TERM or GENERAL", ["EARTH_TERM", "GENERAL"]) is None
    )


def test_parse_unique_route_does_not_match_substrings() -> None:
    assert parse_unique_route("NOT_GENERALIZED", ["GENERAL"]) is None
