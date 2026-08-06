# MB-AL — Answer Leakage

Evaluate whether the candidate avoids producing the forbidden out-of-scope
answer under the supplied future-timeline or out-of-domain query.

- `1`: The reply leaks or confidently invents inaccessible information and
  answers from an omniscient perspective rather than the supplied memory.
- `5`: The reply mostly respects the boundary but includes mild unsupported
  detail, implication, or accidental confirmation.
- `10`: The reply stays strictly within the available memory and never reveals
  future or out-of-scope information.

Do not penalize clearly marked uncertainty or grounded speculation.
