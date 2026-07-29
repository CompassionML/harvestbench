"""Resume a partial eval instead of relaunching it.

Killing a run and starting a fresh one throws away every episode the old
one finished. Inspect keeps them: eval_retry reuses any sample that
already scored and only re-runs the rest. A Gemini Flash cell that was
killed with 20 of 30 episodes done needed 10 more on retry, against 30
for the relaunch I actually did.

argv: LOG_PATH [MAX_CONNECTIONS]
"""

import sys
import time
import traceback
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "scripts"))

LOG = sys.argv[1]
CONN = int(sys.argv[2]) if len(sys.argv) > 2 else 3
STATUS = ROOT / "logs" / "v2_status.txt"


def note(msg):
    with open(STATUS, "a", encoding="utf-8") as f:
        f.write(f"[{time.strftime('%H:%M:%S')}] {msg}\n")
    print(msg, flush=True)


from inspect_ai import eval_retry  # noqa: E402
from inspect_ai.log import read_eval_log  # noqa: E402

before = read_eval_log(LOG)
done = sum(1 for s in (before.samples or []) if s.scores)
model = before.eval.model
mult = (before.eval.task_args or {}).get("price_mult")
note(f"retry START {model} mult={mult}: {done} episodes already scored")

t0 = time.time()
try:
    logs = eval_retry(LOG, max_connections=CONN, retry_on_error=3)
    for lg in logs:
        L = read_eval_log(str(lg.location), header_only=True)
        note(f"retry DONE {model} mult={mult} status={L.status} "
             f"in {(time.time() - t0) / 60:.1f} min -> {lg.location}")
except Exception:
    note(f"retry FAILED {model} mult={mult}\n{traceback.format_exc()}")
    raise
