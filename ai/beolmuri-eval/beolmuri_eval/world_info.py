"""Lorebook transport only: parsing, validation and edits execute in shared Swift."""
import json
from pathlib import Path
from .config import repository
from .doctor import swift_binary
from .process import execute


def control(args):
    if args.action == "upsert" and not args.entry:
        raise ValueError("upsert requires --entry")
    if args.action == "remove" and not args.entry_id:
        raise ValueError("remove requires --entry-id")
    if args.action in ("upsert", "remove", "export") and not args.output:
        raise ValueError("this action requires --output")
    request = {"id": "lorebook", "operation": "world-info", "action": args.action,
               "name": args.name, "book": Path(args.book).read_text(encoding="utf-8")}
    if args.entry:
        request["entry"] = json.loads(Path(args.entry).read_text(encoding="utf-8"))
    if args.entry_id:
        request["entryID"] = args.entry_id
    raw, _ = execute([str(swift_binary(repository()))],
                     input_text=json.dumps(request, ensure_ascii=False) + "\n")
    response = json.loads(raw)
    if response.get("id") != request["id"] or response.get("protocol_version") != 1:
        raise ValueError("world-info worker protocol mismatch")
    if response.get("status") != "ok":
        raise ValueError(response.get("error", "world-info operation failed"))
    if args.output:
        with Path(args.output).open("x", encoding="utf-8") as target:
            target.write(response["book"])
    del response["book"]
    return response
