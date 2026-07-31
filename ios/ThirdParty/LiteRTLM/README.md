# LiteRTLM iOS package

This repo-local Swift package avoids checking out the full upstream LiteRT-LM
repository, whose unrelated Android Git LFS objects can prevent Xcode package
resolution.

It contains the unmodified Swift wrapper sources from:

- Repository: `google-ai-edge/LiteRT-LM`
- Revision: `f73637c57f0940b53da184e0d5adfc52a4e55eef`
- Binary release: `v0.14.0`
- Binary checksum:
  `dddac2f6713ed65eaf01c18e115d9fec22184adf575cc7856a21387e8ba937e1`

The native iOS XCFramework is not committed to this repository. Swift Package
Manager downloads it from the official GitHub release and verifies the checksum.

## Organization-fork baseline

Before changing the inference engine, PetAI can build the exact unmodified
`v0.14.0` source from the public organization fork:

```bash
bash scripts/build-ios-litertlm-from-source.sh
```

The script:

1. fetches `mornye-minor-gallery/LiteRT-LM` at
   `80f301ff9a3b02c2c1e7be2dd1a567752f7b51b6`;
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

Unity's existing iOS post-processor copies
`ios/.artifacts/CLiteRTLM.xcframework` into the exported Xcode project. When the
source-build receipt is present, `scripts/prepare-ios-native-dependencies.sh`
keeps that verified fork build instead of replacing it. On a clean checkout,
the preparation script explicitly downloads the existing official `v0.14.0`
binary so current CI remains reproducible.

This baseline changes neither LiteRT-LM source nor the C/Swift ABI. It disables
the optional FST constrained-decoding provider at compile time because PetAI
does not currently enable constrained decoding or native function calling. The
public source target otherwise links an extra provider dylib that its generated
XCFramework does not bundle. Revisit this build profile before enabling those
features.

The EdgeLLM Lab Swift package still resolves the official release; the local
source-build path described here is the Unity iOS integration baseline.

When updating LiteRT-LM, update the wrapper sources, revision, binary URL,
checksum, and upstream license together. Build and run the physical-device smoke
test before accepting the update.
