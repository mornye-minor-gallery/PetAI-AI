import sys
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from run_routed_generation import load_facet_cards, parse_boundary_route, parse_route, route_to_card  # noqa: E402


class RoutedGenerationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.facets, cls.cards = load_facet_cards(ROOT / "prompts/router/cards-v2.json")

    def test_parse_exact_and_embedded_route(self):
        self.assertEqual(parse_route("SUPPORT"), "SUPPORT")
        self.assertEqual(parse_route("label: ambiguous"), "AMBIGUOUS")

    def test_reject_multiple_routes(self):
        self.assertIsNone(parse_route("SUPPORT or PLAYFUL"))

    def test_parse_boundary_route(self):
        self.assertEqual(parse_boundary_route("BOUNDARY"), "BOUNDARY")
        self.assertEqual(parse_boundary_route("label: in_scope"), "IN_SCOPE")
        self.assertIsNone(parse_boundary_route("BOUNDARY or IN_SCOPE"))

    def test_parse_granular_route(self):
        routes = {"EARTH_TERM", "EARTH_FOOD", "GENERAL"}
        self.assertEqual(parse_route("EARTH_FOOD", routes), "EARTH_FOOD")

    def test_boundary_route_can_have_card_without_scene_facet(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "cards.json"
            path.write_text(json.dumps({
                "BOUNDARY_UNKNOWN": {"facet_id": None, "card": "모른다고 답한다."},
                "GENERAL": {"facet_id": None, "card": None},
            }), encoding="utf-8")
            facets, cards = load_facet_cards(path)
        self.assertIsNone(facets["BOUNDARY_UNKNOWN"])
        self.assertEqual(cards["BOUNDARY_UNKNOWN"], "모른다고 답한다.")

    def test_general_has_no_card(self):
        self.assertIsNone(route_to_card("GENERAL", self.cards))

    def test_ambiguous_card_requires_two_possibilities(self):
        card = route_to_card("AMBIGUOUS", self.cards)
        self.assertIn("두 가능성", card)
        self.assertIn("나침반", card)


if __name__ == "__main__":
    unittest.main()
