# LiteRTLM iOS package

This repo-local Swift package keeps PetAI's LiteRT-LM Swift wrapper separate
from the full upstream checkout, whose unrelated Android Git LFS objects can
prevent Xcode package resolution.

It is derived from LiteRT-LM `v0.14.0` and includes PetAI's opt-in Top-K
diagnostic telemetry API. The matching native XCFramework must therefore be
built from the pinned `mornye-minor-gallery/LiteRT-LM` organization fork; the
official `v0.14.0` binary does not expose this C ABI.

The native iOS XCFramework is not committed to this repository. It is produced
locally, validated, and linked into this package from a Git-ignored artifact
directory.

## Organization-fork build

Build the exact revision pinned by the script:

```bash
bash scripts/build-ios-litertlm-from-source.sh
```

The script:

1. fetches `mornye-minor-gallery/LiteRT-LM` at
   `7285e1fa7b2428c5de3b2af7d51fe8342080657d`;
2. downloads only the iOS Git LFS dependencies;
3. runs the upstream Bazel target `//swift:CLiteRTLM` with
   `LITERT_LM_FST_CONSTRAINTS_DISABLED=1`;
4. validates the device and Apple-silicon simulator slices and rejects an
   unbundled `libGemmaModelConstraintProvider.dylib` dependency; and
5. stages the XCFramework and a provenance receipt under `ios/.artifacts/`.

The source checkout, Bazel cache, archive, framework, and receipt are local
artifacts and remain Git-ignored. Inspect the pinned contract without building:

```bash
bash scripts/build-ios-litertlm-from-source.sh --print-config
```

EdgeLLM Lab resolves the same local artifact through the Git-ignored
`Artifacts/CLiteRTLM.xcframework` link. The preparation/build scripts create
that link after validating the framework, so the Lab uses the pinned native binary and C ABI.

The build disables the optional FST constrained-decoding provider because
PetAI does not currently enable constrained decoding or native function
calling. The public source target otherwise links an extra provider dylib that
its generated XCFramework does not bundle. Revisit this profile before enabling
those features.

The package intentionally fails closed when the local artifact is missing.
Run the native dependency preparation command rather than silently falling
back to an official binary whose C ABI may differ from the vendored Swift
wrapper.

When updating LiteRT-LM or this custom ABI, commit the organization-fork change
first, then update the exact source revision and vendored Swift wrapper together.
Build and run the physical-device smoke test before accepting the update.
