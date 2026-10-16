#!/usr/bin/env python3
"""Repack Gemma 4 LiteRT-LM 1.5 containers without audio/vision sections.

Requires the official litert_lm_builder (tested with litert-lm==0.13.1,
flatbuffers==25.12.19). Uses the upstream schema and 16 KiB alignment:
https://github.com/google-ai-edge/LiteRT-LM/tree/main/python/litert_lm_builder

Text embeddings, per-layer embeddings, decoder, MTP, tokenizer and prompt
metadata are byte-preserved. This is NOT quantization or a context-size change.
The original timestamp/UUID describe the upstream model; the sidecar identifies
this derived artifact by source/output hashes. No nondeterministic metadata is
inserted, so the same input produces the same output hash.
"""
import argparse
import hashlib
import importlib.metadata
import io
import json
from pathlib import Path
import struct

import flatbuffers
from litert_lm_builder import litertlm_header_schema_py_generated as schema
from litert_lm_builder import litertlm_peek

REMOVE = frozenset({
    "tf_lite_audio_encoder_hw", "tf_lite_audio_adapter", "tf_lite_end_of_audio",
    "tf_lite_vision_encoder", "tf_lite_vision_adapter", "tf_lite_end_of_vision",
})
KEEP = frozenset({"tf_lite_embedder", "tf_lite_per_layer_embedder",
                  "tf_lite_prefill_decode", "tf_lite_mtp_drafter"})
BLOCK = 16384
CHUNK = 1024 * 1024


def digest_range(path, offset=0, length=None):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        stream.seek(offset)
        remaining = path.stat().st_size - offset if length is None else length
        while remaining:
            chunk = stream.read(min(CHUNK, remaining))
            if not chunk:
                raise ValueError("Truncated payload")
            digest.update(chunk)
            remaining -= len(chunk)
    return digest.hexdigest()


def read(path):
    with path.open("rb") as stream:
        prefix = stream.read(32)
    if prefix[:8] != b"LITERTLM" or struct.unpack("<III", prefix[8:20]) != (1, 5, 0):
        raise ValueError("Only the audited LiteRT-LM 1.5.0 container is supported")
    end = struct.unpack("<Q", prefix[24:32])[0]
    if not 32 < end <= min(path.stat().st_size, 16 * 1024 * 1024):
        raise ValueError("Invalid metadata size")
    header = litertlm_peek.read_litertlm_header(str(path), io.StringIO())
    return prefix, header


def pack(metadata):
    builder = flatbuffers.Builder(BLOCK)
    builder.Finish(metadata.Pack(builder))
    return builder.Output()


def copy_items(items):
    # The installed generated schema's InitFromObj calls an undefined
    # VDataCreator. Explicitly copy the string metadata used by these artifacts;
    # reject new types rather than silently dropping information.
    result = []
    for item in items:
        if item.ValueType() != schema.VData.StringValue:
            raise ValueError("Unknown metadata value type")
        value = schema.StringValue()
        table = item.Value()
        value.Init(table.Bytes, table.Pos)
        result.append(schema.KeyValuePairT(
            key=item.Key(), valueType=item.ValueType(),
            value=schema.StringValueT(value=value.Value())))
    return result


def copy_metadata(header):
    sections = header.SectionMetadata()
    objects = []
    for index in range(sections.ObjectsLength()):
        section = sections.Objects(index)
        objects.append(schema.SectionObjectT(
            items=copy_items(section.Items(i) for i in range(section.ItemsLength())),
            dataType=section.DataType(), beginOffset=section.BeginOffset(),
            endOffset=section.EndOffset()))
    system = header.SystemMetadata()
    return schema.LiteRTLMMetaDataT(
        systemMetadata=schema.SystemMetadataT(entries=copy_items(
            system.Entries(i) for i in range(system.EntriesLength()))) if system else None,
        sectionMetadata=schema.SectionMetadataT(objects=objects))


def convert(source, output):
    source, output = Path(source), Path(output)
    if source.resolve() == output.resolve() or output.exists():
        raise FileExistsError("Source/output must differ and output must not exist")
    prefix, header = read(source)
    metadata = copy_metadata(header)
    kept, removed = [], []
    previous_end = struct.unpack("<Q", prefix[24:32])[0]
    for index, section in enumerate(metadata.sectionMetadata.objects):
        model_type = litertlm_peek.get_model_type(header.SectionMetadata().Objects(index))
        if not previous_end <= section.beginOffset < section.endOffset <= source.stat().st_size:
            raise ValueError("Invalid or overlapping section bounds")
        previous_end = section.endOffset
        if section.beginOffset % BLOCK:
            raise ValueError("Unaligned source section")
        if section.dataType == schema.AnySectionDataType.TFLiteModel:
            if model_type not in KEEP | REMOVE:
                raise ValueError(f"Unknown model section: {model_type}")
        elif section.dataType not in (schema.AnySectionDataType.LlmMetadataProto,
                                      schema.AnySectionDataType.SP_Tokenizer):
            raise ValueError(f"Unknown data type: {section.dataType}")
        record = {"source_index": index, "model_type": model_type,
                  "data_type": section.dataType, "source_offset": section.beginOffset,
                  "bytes": section.endOffset - section.beginOffset}
        (removed if model_type in REMOVE else kept).append((section, record))
    if {r["model_type"] for _, r in removed} != REMOVE:
        raise ValueError("Expected all six Gemma 4 audio/vision sections")
    if not (KEEP - {"tf_lite_mtp_drafter"}) <= {r["model_type"] for _, r in kept}:
        raise ValueError("Missing text model sections")
    for kind in (schema.AnySectionDataType.LlmMetadataProto, schema.AnySectionDataType.SP_Tokenizer):
        if sum(s.dataType == kind for s, _ in kept) != 1:
            raise ValueError("Expected one metadata and one tokenizer section")
    metadata.sectionMetadata.objects = [s for s, _ in kept]
    packed_size = len(pack(metadata))
    offset = (32 + packed_size + BLOCK - 1) // BLOCK * BLOCK
    for section, record in kept:
        section.beginOffset = offset
        section.endOffset = offset + record["bytes"]
        record["output_offset"] = offset
        offset = (section.endOffset + BLOCK - 1) // BLOCK * BLOCK
    packed = pack(metadata)
    if len(packed) != packed_size:
        raise ValueError("Unexpected header size change")

    # Publish only after every retained payload is verified. A failed conversion
    # removes only its own partial file; it never overwrites a model.
    partial = output.with_name(output.name + ".partial")
    with partial.open("xb") as dst:
        try:
            dst.write(prefix[:24] + struct.pack("<Q", 32 + len(packed)))
            dst.write(packed)
            with source.open("rb") as src:
                for section, record in kept:
                    print(f"Copy section {record['source_index']}: {record['bytes']} bytes", flush=True)
                    src.seek(record["source_offset"])
                    dst.seek(section.beginOffset)
                    remaining = record["bytes"]
                    digest = hashlib.sha256()
                    while remaining:
                        chunk = src.read(min(CHUNK, remaining))
                        if not chunk:
                            raise ValueError("Truncated source")
                        digest.update(chunk)
                        dst.write(chunk)
                        remaining -= len(chunk)
                        if remaining and remaining % (128 * CHUNK) < CHUNK:
                            print(f"  {record['bytes'] - remaining}/{record['bytes']} bytes", flush=True)
                    record["source_sha256"] = digest.hexdigest()
            dst.flush()
            _, verified = read(partial)
            if verified.SectionMetadata().ObjectsLength() != len(kept):
                raise ValueError("Output header verification failed")
            for _, record in kept:
                record["output_sha256"] = digest_range(partial, record["output_offset"], record["bytes"])
                if record["source_sha256"] != record["output_sha256"]:
                    raise ValueError("Output payload differs from source")
        except BaseException:
            partial.unlink()
            raise
    # Hard-link publication fails if another writer has created the destination.
    output.hardlink_to(partial)
    partial.unlink()
    return {"source_bytes": source.stat().st_size, "output_bytes": output.stat().st_size,
            "source_sha256": digest_range(source), "output_sha256": digest_range(output),
            "retained": [r for _, r in kept], "removed": [r for _, r in removed],
            "builder_version": importlib.metadata.version("litert-lm"),
            "flatbuffers_version": importlib.metadata.version("flatbuffers")}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    report_path = args.output.with_suffix(".provenance.json")
    if report_path.exists():
        parser.error("Provenance already exists")
    report = convert(args.source, args.output)
    report["recipe_sha256"] = digest_range(Path(__file__))
    with report_path.open("x") as stream:
        json.dump(report, stream, indent=2)
        stream.write("\n")
    print(json.dumps({k: v for k, v in report.items() if k not in ("retained", "removed")}, indent=2))
