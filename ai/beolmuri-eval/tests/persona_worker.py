"""Test-only explicit content injection; never imported by the product runner."""
from beolmuri_eval.process import Worker as RealWorker

class Worker(RealWorker):
    def call(self, operation, **payload):
        if operation == "prepare" and payload.get("configuration", {}).get("includePersona", True):
            config = dict(payload.get("configuration", {}))
            config.setdefault("personaCore", "{{char}}는 검사 전용 캐릭터다.")
            payload["configuration"] = config
        return super().call(operation, **payload)
