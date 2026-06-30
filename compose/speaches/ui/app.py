"""Custom Speaches Gradio UI, repointed to the GPU whisper-server.

Bind-mounted over the image's src/speaches/ui/app.py (see docker-compose.yml),
keeping `create_gradio_demo(config)` as the entry point. Differences vs stock:

  * Speech-to-Text tab first and selected by default. Its Transcribe button does
    NOT use this container's CPU Whisper — it proxies to the GPU whisper-server
    (whisper.cpp) at WHISPER_INFERENCE_URL: POST /inference, field `file`,
    language=bg + translate=false (Bulgarian transcription, not English
    translation), -> {"text": ...}.
  * Text-to-Speech tab kept, second (stock tab, unchanged — still local CPU).
  * "Audio Chat" tab removed.

GPU sharing (the OC worker / Qwen and whisper-server can't co-reside):
  stt-server exposes the swap as HTTP endpoints (no systemctl):
    POST /qwen/stop  -> stops Qwen, starts whisper-server (whisper.* goes live)
    POST /qwen/start -> stops whisper-server, restarts Qwen
  So the UI:
    - on page load: POST /qwen/stop to pre-warm whisper-server, arm an idle timer
    - on transcribe: ensure whisper-server is up (waiting if it's still loading),
      transcribe, and reset the idle timer
    - after QWEN_IDLE_RESTART_SECONDS (default 900 = 15 min) with no page load or
      transcription: POST /qwen/start to give the GPU back to Qwen
  The idle timer never fires while a transcription is in flight. All worker
  control is best-effort and logged; a control failure never silently corrupts a
  transcription (the readiness wait will surface it).

Heads-up: this overrides upstream source files, so a future `:latest-cpu` pull
that changes the UI module layout / create_tts_tab signature could break the web
UI — remove the app.py mount in docker-compose.yml to fall back to stock. The
container's own /v1 API (CPU faster-whisper) is unaffected.
"""

import asyncio
import logging
import os
import tempfile
import time
from pathlib import Path

import gradio as gr
import httpx

from speaches.config import Config
from speaches.ui.tabs.tts import create_tts_tab

logger = logging.getLogger(__name__)

# --- GPU whisper-server + Qwen control ------------------------------------
GPU_CTL_URL = os.getenv("GPU_STT_URL", "https://stt-server.example.com").rstrip("/")
WHISPER_URL = os.getenv("WHISPER_INFERENCE_URL", "https://whisper.example.com").rstrip("/")
STT_LANGUAGE = os.getenv("STT_LANGUAGE", "bg")
# Max time to wait for whisper-server to load on the GPU after /qwen/stop.
WHISPER_READY_TIMEOUT = float(os.getenv("WHISPER_READY_TIMEOUT", "180"))
# Read timeout for the actual /inference call (GPU is fast, but allow margin).
INFERENCE_TIMEOUT = float(os.getenv("INFERENCE_TIMEOUT", "600"))
# Give the GPU back to Qwen after this long with no page load / transcription.
QWEN_IDLE_RESTART_SECONDS = float(os.getenv("QWEN_IDLE_RESTART_SECONDS", "900"))

_state_lock = asyncio.Lock()
_resume_deadline: float | None = None  # monotonic time to resume Qwen; None = disarmed
_inflight = 0  # transcriptions in progress; the idle timer won't resume Qwen while > 0
_timer_task: asyncio.Task | None = None


async def _qwen(path: str) -> bool:
    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(90.0, connect=10.0)) as client:
            resp = await client.post(f"{GPU_CTL_URL}{path}")
            resp.raise_for_status()
        return True
    except Exception:
        logger.exception("GPU worker control failed: %s", path)
        return False


async def _whisper_ready() -> bool:
    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(10.0, connect=10.0)) as client:
            return (await client.get(f"{WHISPER_URL}/")).status_code < 500
    except Exception:
        return False


async def _to_wav(src: str) -> str:
    """Transcode any input (iPhone .m4a, mp3, ogg, webm, …) to 16 kHz mono
    16-bit WAV — the only format whisper.cpp's /inference accepts (it returns
    400 'Invalid request' for m4a). ffmpeg ships in the image."""
    fd, out = tempfile.mkstemp(suffix=".wav")
    os.close(fd)
    proc = await asyncio.create_subprocess_exec(
        "ffmpeg", "-y", "-i", src, "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", out,
        stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE,
    )
    _, err = await proc.communicate()
    if proc.returncode != 0:
        raise RuntimeError(f"ffmpeg could not decode the audio: {err.decode(errors='ignore')[-300:]}")
    return out


async def _arm() -> None:
    """(Re)start the idle countdown to give the GPU back to Qwen."""
    global _resume_deadline
    async with _state_lock:
        _resume_deadline = time.monotonic() + QWEN_IDLE_RESTART_SECONDS


async def _ensure_whisper_up(wait: bool) -> bool:
    """Make sure whisper-server has the GPU. Idempotent: only calls /qwen/stop
    when whisper isn't already serving, to avoid restarting it mid-session."""
    if await _whisper_ready():
        return True
    await _qwen("/qwen/stop")  # stops Qwen -> starts whisper-server
    if not wait:
        return False
    deadline = time.monotonic() + WHISPER_READY_TIMEOUT
    while time.monotonic() < deadline:
        if await _whisper_ready():
            return True
        await asyncio.sleep(3)
    return False


async def _timer_loop() -> None:
    global _resume_deadline
    while True:
        await asyncio.sleep(10)
        async with _state_lock:
            due = _resume_deadline is not None and time.monotonic() >= _resume_deadline
            if due and _inflight > 0:
                # A transcription is running — push the deadline out, don't resume.
                _resume_deadline = time.monotonic() + QWEN_IDLE_RESTART_SECONDS
                due = False
            elif due:
                _resume_deadline = None
        if due:
            logger.info("GPU idle for %ss — handing back to Qwen", int(QWEN_IDLE_RESTART_SECONDS))
            await _qwen("/qwen/start")


def _ensure_timer() -> None:
    global _timer_task
    if _timer_task is None or _timer_task.done():
        _timer_task = asyncio.create_task(_timer_loop())


async def on_load() -> None:
    # Pre-warm whisper-server so the first transcription is quick. Don't block the
    # page load waiting for the model to finish loading — the Transcribe handler
    # waits for readiness if needed.
    _ensure_timer()
    await _arm()
    await _ensure_whisper_up(wait=False)


def create_simple_stt_tab(config: Config) -> None:
    async def transcribe(recorded: str | None, uploaded: str | None, request: gr.Request):
        global _inflight
        # Prefer an uploaded file (the gr.File picker is unrestricted so iOS lets
        # you choose .m4a etc.), else the recorder.
        file_path = uploaded or recorded
        if not file_path:
            yield "No audio provided — record or upload a file first."
            return
        await _arm()
        async with _state_lock:
            _inflight += 1
        try:
            if not await _whisper_ready():
                yield "⏳ Starting whisper-server on the GPU… (first run loads the model)"
                if not await _ensure_whisper_up(wait=True):
                    yield "whisper-server didn't come up on the GPU — try again, or check stt-server."
                    return
            yield "⏳ Converting audio…"
            wav = await _to_wav(file_path)
            try:
                yield "⏳ Transcribing on the GPU…"
                async with httpx.AsyncClient(timeout=httpx.Timeout(INFERENCE_TIMEOUT, connect=10.0)) as client:
                    with Path(wav).open("rb") as file:  # noqa: ASYNC230
                        resp = await client.post(
                            f"{WHISPER_URL}/inference",
                            files={"file": ("audio.wav", file, "audio/wav")},
                            data={"language": STT_LANGUAGE, "translate": "false", "response_format": "json"},
                        )
                resp.raise_for_status()
                text = (resp.json() or {}).get("text", "").strip()
                yield text or "(no speech detected)"
            finally:
                try:
                    os.remove(wav)
                except OSError:
                    pass
        except Exception as e:
            logger.exception("whisper-server transcribe error")
            yield f"Transcription failed: {e}"
        finally:
            async with _state_lock:
                _inflight -= 1
            await _arm()

    with gr.Tab(label="Speech-to-Text"):
        gr.Markdown(
            "Opening this page hands the shared GPU to whisper-server (pausing the OC worker); "
            f"it's returned to the worker after {int(QWEN_IDLE_RESTART_SECONDS // 60)} min "
            "with no transcriptions."
        )
        audio = gr.Audio(type="filepath", label="Record audio")
        # Unrestricted picker (no file_types/accept filter) so iOS Safari offers
        # .m4a recordings — the gr.Audio uploader filters them out. ffmpeg on the
        # server decodes whatever lands here (m4a/mp3/wav/ogg/webm/…).
        upload = gr.File(label="…or upload a file (iPhone .m4a, mp3, wav, …)", file_count="single", type="filepath")
        button = gr.Button("Transcribe", variant="primary")
        output = gr.Textbox(label="Transcript", lines=8, show_copy_button=True)
        button.click(transcribe, inputs=[audio, upload], outputs=output)


def create_gradio_demo(config: Config) -> gr.Blocks:
    with gr.Blocks(title="Speech to Text") as demo:
        gr.Markdown("# Speech to Text")
        create_simple_stt_tab(config)
        create_tts_tab(config)
        demo.load(on_load)

    return demo
