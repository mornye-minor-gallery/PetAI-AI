"""Bounded subprocesses with progress and process-group cancellation."""
import json
import os
import queue
import signal
import subprocess
import sys
import threading
import time
import uuid

CANCEL_FILE = None


def check_cancel():
    if CANCEL_FILE is not None and CANCEL_FILE.exists():
        raise KeyboardInterrupt("cancellation requested")


def heartbeat(message):
    check_cancel()
    print(f"[진행] {message}", file=sys.stderr, flush=True)


def stop(process):
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()


def execute(args, *, input_text=None, timeout=120, cwd=None):
    check_cancel()
    process = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True, cwd=cwd, start_new_session=True)
    started = time.monotonic()
    pending = input_text
    try:
        while True:
            remaining = timeout - (time.monotonic() - started)
            if remaining <= 0:
                raise TimeoutError(f"subprocess timed out: {args[0]}")
            try:
                stdout, stderr = process.communicate(pending, timeout=min(10, remaining))
                if process.returncode:
                    raise RuntimeError(f"subprocess exit {process.returncode}: {stderr[-2000:]}")
                return stdout, stderr
            except subprocess.TimeoutExpired:
                pending = None
                heartbeat(f"{os.path.basename(str(args[0]))} 실행 중 ({int(time.monotonic()-started)}초)")
    finally:
        stop(process)
        for handle in (process.stdin, process.stdout, process.stderr):
            handle.close()


class Worker:
    def __init__(self, args, log_path):
        self.log = open(log_path, "a", encoding="utf-8")
        self.process = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=self.log, text=True, bufsize=1, start_new_session=True)
        self.lines = queue.Queue()
        def read():
            for line in self.process.stdout:
                self.lines.put(line)
            self.lines.put(None)
        self.reader = threading.Thread(target=read, daemon=True)
        self.reader.start()

    def call(self, operation, timeout=180, measurement_handler=None, **payload):
        check_cancel()
        request_id = uuid.uuid4().hex
        request = {"id": request_id, "operation": operation, **payload}
        self.process.stdin.write(json.dumps(request, ensure_ascii=False) + "\n")
        self.process.stdin.flush()
        deadline = time.monotonic() + timeout
        measurement_sequence = 0
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                self.close()
                raise TimeoutError(f"worker timed out during {operation}")
            try:
                line = self.lines.get(timeout=min(10, remaining))
            except queue.Empty:
                heartbeat(f"{operation} 실행 중")
                continue
            if line is None:
                raise RuntimeError(f"worker exited during {operation}; inspect {self.log.name}")
            response = json.loads(line)
            if response.get("id") != request_id or response.get("protocol_version") != 1:
                raise ValueError("worker protocol/id mismatch")
            if response.get("status") == "measurement_required":
                measurement_sequence += 1
                if response.get("measurement_id") != measurement_sequence:
                    self.close()
                    raise ValueError("measurement sequence mismatch")
                answer = {"id": request_id, "protocol_version": 1,
                          "status": "measurement_result", "measurement_id": measurement_sequence}
                try:
                    if measurement_handler is None:
                        raise RuntimeError("no native token measurer connected")
                    check_cancel()
                    response["remaining_seconds"] = remaining
                    answer["tokens"] = measurement_handler(response)
                    if type(answer["tokens"]) is not int:
                        raise ValueError("native token count must be an integer")
                except Exception as error:
                    answer.pop("tokens", None)
                    answer["error"] = str(error)
                self.process.stdin.write(json.dumps(answer, ensure_ascii=False) + "\n")
                self.process.stdin.flush()
                continue
            if response.get("status") == "error":
                raise RuntimeError(response.get("error", "worker error"))
            return response

    def close(self):
        stop(self.process)
        self.reader.join(timeout=1)
        for handle in (self.process.stdin, self.process.stdout, self.log):
            handle.close()

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()
