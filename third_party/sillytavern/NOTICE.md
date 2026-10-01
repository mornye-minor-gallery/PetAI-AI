# SillyTavern attribution

Source: https://github.com/SillyTavern/SillyTavern
Revision: `06bde939fb1e9c4c8d8641d810f0a916b5bce127`
License: GNU Affero General Public License, version 3 (copy in `LICENSE`).

The Swift World Info implementation in `ios/EdgeLLM/Sources/EdgeLLM/Dialogue/WorldInfo*.swift`
adapts selection, grouping, timed effects, formatting, lorebook mapping and text operations
from `public/scripts/world-info.js`, `macros.js`, `variables.js`, `utils.js` and
`extensions/regex/engine.js`. Original authors are the SillyTavern contributors.
Modifications: Swift value-state transactions, native prompt projection, explicit host
inputs, deterministic randomness, local retrieval and guarded overlapping-group removal.

The differential fixture generator executes the pinned original functions from a separate
checkout. Its generated reference outputs are kept with the tests.
The native DialogueMacro*.swift and DialogueNativeRegex.swift implementations adapt the
pinned macro engine/definitions, cyrb53 hash, seedrandom ARC4 algorithm and regex behavior.
This public repository includes the Swift adaptations and synthetic differential
fixtures. The separate JavaScript oracle and its vendored source excerpts are not
part of this distribution.

This notice preserves the upstream license and provenance; it does not relicense unrelated
PetAI code or assert that a combined binary has cleared distribution requirements.
