"""Custom Speaches Gradio UI, repointed to the GPU STT server.

Bind-mounted over the image's src/speaches/ui/app.py (see docker-compose.yml),
keeping `create_gradio_demo(config)` as the entry point. Differences vs stock:

  * Speech-to-Text tab first and selected by default. Its Transcribe button does
    NOT use this container's CPU Whisper — it proxies to the GPU STT server
    (GPU_STT_URL, e.g. https://stt-server.example.com), which runs Whisper
    large-v3 on a ROCm GPU. Upload field is `audio`, response is {"text": ...}.
  * Text-to-Speech tab kept, second (stock tab, unchanged — still local).
  * "Audio Chat" tab removed.

OC worker (shared GPU) coordination:
  The GPU also hosts an LLM ("OC worker" / Qwen) and can't run both at once. So:
    - Opening the STT page pauses the worker (POST /qwen/stop) and arms an idle
      timer.
    - Each transcription keeps the worker paused and resets that timer.
    - After QWEN_IDLE_RESTART_SECONDS (default 15 min) with no page load or
      transcription, the worker is resumed (POST /qwen/start).
  All worker control is best-effort: failures are logged and never block a
  transcription.

Heads-up: this overrides upstream source files, so a future `:latest-cpu` pull
that changes the UI module layout / create_tts_tab signature could break the web
UI — remove the app.py mount in docker-compose.yml to fall back to stock. The
container's own HTTP API (/v1/audio/transcriptions, CPU) is unaffected.
"""

import asyncio
import logging
import os
import time
from pathlib import Path

import gradio as gr
import httpx

from speaches.config import Config
from speaches.ui.tabs.tts import create_tts_tab

logger = logging.getLogger(__name__)

# --- GPU STT backend (stt-server) -----------------------------------------
GPU_STT_URL = os.getenv("GPU_STT_URL", "https://stt-server.example.com").rstrip("/")
# Single POST; the server takes ~30s (it cycles the GPU worker), so allow margin.
GPU_STT_READ_TIMEOUT = float(os.getenv("GPU_STT_READ_TIMEOUT", "300"))
# Resume the OC worker after this long with no page load / transcription.
QWEN_IDLE_RESTART_SECONDS = float(os.getenv("QWEN_IDLE_RESTART_SECONDS", "900"))

# --- OC worker (Qwen) idle-resume state -----------------------------------
_state_lock = asyncio.Lock()
_resume_deadline: float | None = None  # monotonic time to resume; None = disarmed
_timer_task: asyncio.Task | None = None


async def _qwen(path: str) -> bool:
    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(30.0, connect=10.0)) as client:
            resp = await client.post(f"{GPU_STT_URL}{path}")
            resp.raise_for_status()
        return True
    except Exception:
        logger.exception("OC worker control failed: %s", path)
        return False


async def _arm() -> None:
    """(Re)start the idle-resume countdown."""
    global _resume_deadline
    async with _state_lock:
        _resume_deadline = time.monotonic() + QWEN_IDLE_RESTART_SECONDS


async def _pause_worker() -> None:
    """Pause the OC worker and (re)arm the idle-resume timer."""
    await _arm()
    await _qwen("/qwen/stop")


async def _timer_loop() -> None:
    global _resume_deadline
    while True:
        await asyncio.sleep(10)
        async with _state_lock:
            due = _resume_deadline is not None and time.monotonic() >= _resume_deadline
            if due:
                _resume_deadline = None  # disarm before the (slow) network call
        if due:
            logger.info("OC worker idle for %ss — resuming", int(QWEN_IDLE_RESTART_SECONDS))
            await _qwen("/qwen/start")


def _ensure_timer() -> None:
    global _timer_task
    if _timer_task is None or _timer_task.done():
        _timer_task = asyncio.create_task(_timer_loop())


async def on_load() -> None:
    # Runs on every page load; both calls are idempotent.
    _ensure_timer()
    await _pause_worker()


def create_simple_stt_tab(config: Config) -> None:
    async def transcribe(file_path: str | None, request: gr.Request):
        if not file_path:
            yield "No audio provided — record or upload a file first."
            return
        # Keep the worker paused and push the resume timer out while we work.
        await _pause_worker()
        yield "⏳ Transcribing on the GPU server… (~30s)"
        try:
            async with httpx.AsyncClient(timeout=httpx.Timeout(GPU_STT_READ_TIMEOUT, connect=10.0)) as client:
                with Path(file_path).open("rb") as file:  # noqa: ASYNC230
                    resp = await client.post(
                        f"{GPU_STT_URL}/transcribe",
                        files={"audio": (Path(file_path).name, file, "application/octet-stream")},
                    )
            if resp.status_code == 409:
                yield "The GPU server is already transcribing something — wait a moment and try again."
                return
            resp.raise_for_status()
            text = (resp.json() or {}).get("text", "")
            yield text or "(no speech detected)"
        except Exception as e:
            logger.exception("GPU STT transcribe error")
            yield f"Transcription failed: {e}"
        finally:
            # The server resumes the worker when /transcribe finishes; pause it
            # again so it stays down during the session, and reset the timer.
            await _pause_worker()

    with gr.Tab(label="Speech-to-Text"):
        gr.Markdown(
            "Opening this page pauses the OC worker (shared GPU) so transcription runs fast; "
            f"it resumes automatically after {int(QWEN_IDLE_RESTART_SECONDS // 60)} min "
            "with no transcriptions."
        )
        audio = gr.Audio(type="filepath", label="Audio — record or upload")
        button = gr.Button("Transcribe", variant="primary")
        output = gr.Textbox(label="Transcript", lines=8, show_copy_button=True)
        button.click(transcribe, inputs=[audio], outputs=output)


def create_gradio_demo(config: Config) -> gr.Blocks:
    with gr.Blocks(title="Speech to Text") as demo:
        gr.Markdown("# Speech to Text")
        create_simple_stt_tab(config)
        create_tts_tab(config)
        demo.load(on_load)

    return demo
