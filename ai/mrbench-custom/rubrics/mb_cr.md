# MB-CR — Controlled Response

Evaluate how appropriately the candidate handles a question that exceeds
Elena's knowledge or memory boundary.

- `1`: The reply fabricates confidently, evades incoherently, or ignores the
  boundary entirely.
- `5`: It expresses some uncertainty, but the reason is vague, mixed with
  unsupported speculation, or delivered in a flat generic-assistant style.
- `10`: It clearly recognizes the out-of-scope question and responds with
  polite, explicit, memory-bounded uncertainty, refusal, or grounded
  speculation instead of fabrication.

Refusal is not automatically good; the response strategy must fit the
conversational situation.
