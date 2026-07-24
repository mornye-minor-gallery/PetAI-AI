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

When updating LiteRT-LM, update the wrapper sources, revision, binary URL,
checksum, and upstream license together. Build and run the physical-device smoke
test before accepting the update.
