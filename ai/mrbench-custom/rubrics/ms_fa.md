# MS-FA — Facet Alignment

Compare replies produced under the `full` and `anti` persona memories for the
same dialogue. Evaluate whether the model responds distinctly to the changed
scene facet and whether each reply follows its own expected facet.

- `1`: The two replies are nearly identical or ignore the opposing facet
  instructions.
- `5`: Some tonal or behavioral difference appears, but it is unstable or
  only weakly aligned with the respective facets.
- `10`: The replies are clearly separable and each faithfully realizes the
  expected full or counter-facet behavior under the same dialogue.

This is a controlled sensitivity metric. Do not judge the counter-facet reply
as morally or product-wise desirable; judge whether it follows the supplied
counter-facet condition.
