"""Custom minimal Speaches Gradio UI.

Bind-mounted over the image's src/speaches/ui/app.py (see docker-compose.yml),
keeping `create_gradio_demo(config)` as the entry point. Differences vs stock:

  * Speech-to-Text tab first and selected by default.
  * Text-to-Speech tab kept, second (stock tab, unchanged).
  * "Audio Chat" tab removed entirely — it needs an Ollama/OpenAI chat server
    (localhost:11434) we don't run, so it only errored here.
  * The STT tab is reduced to the essentials: record/upload -> Transcribe ->
    text. The model and language dropdowns are gone — this box runs a single
    Whisper model and transcribes Bulgarian, so both are fixed via env
    (STT_UI_MODEL / STT_UI_LANGUAGE, set in docker-compose.yml from the .env).
    The stock model dropdown was also effectively broken as the default tab: it
    only populated on a tab-*switch* event, so on first load it stayed empty.

Heads-up: this overrides upstream source files, so a future `:latest-cpu` pull
that changes the UI module layout or the create_tts_tab signature could break
the web UI — remove the app.py mount in docker-compose.yml to fall back to
stock. The HTTP API (/v1/audio/transcriptions, etc.) is unaffected either way.
"""

from collections.abc import AsyncGenerator
import logging
import os
from pathlib import Path

import gradio as gr
import httpx
from httpx_sse import aconnect_sse

from speaches.config import Config
from speaches.ui.tabs.tts import create_tts_tab
from speaches.ui.utils import base_url_from_gradio_req
from speaches.utils import APIProxyError, format_api_proxy_error

logger = logging.getLogger(__name__)

TRANSCRIPTION_ENDPOINT = "/v1/audio/transcriptions"
# Single source of truth is the .env -> docker-compose.yml; fall back to the
# stack defaults if the env isn't set.
STT_MODEL = os.getenv("STT_UI_MODEL", "Systran/faster-whisper-medium")
STT_LANGUAGE = os.getenv("STT_UI_LANGUAGE", "bg")
# Per-read timeout (seconds) for the streaming call. NOT a total cap — it bounds
# the gap between streamed segments. `medium` on this CPU runs ~8x slower than
# real-time, and the stock UI client's fixed 180s timeout made any clip longer
# than ~20s fail with ReadTimeout. We stream instead (each segment resets the
# read) and allow a long gap, so even multi-minute recordings finish.
STT_READ_TIMEOUT = float(os.getenv("STT_UI_READ_TIMEOUT", "1800"))


def create_simple_stt_tab(config: Config) -> None:
    async def transcribe(file_path: str | None, request: gr.Request) -> AsyncGenerator[str, None]:
        try:
            if not file_path:
                msg = "No audio provided."
                raise APIProxyError(msg, suggestions=["Record or upload an audio file first."])
            base_url = base_url_from_gradio_req(request, config)
            # Own client (not the stock helper) so we can set a generous read
            # timeout; the stock helper hardcodes 180s.
            timeout = httpx.Timeout(STT_READ_TIMEOUT, connect=10.0)
            headers = {"Authorization": f"Bearer {config.api_key}"} if config.api_key else None
            async with httpx.AsyncClient(base_url=base_url, timeout=timeout, headers=headers) as client:
                with Path(file_path).open("rb") as file:  # noqa: ASYNC230
                    kwargs = {
                        "files": {"file": file},
                        "data": {
                            "model": STT_MODEL,
                            "language": STT_LANGUAGE,
                            "response_format": "text",
                            "temperature": 0.0,
                            "stream": True,
                        },
                    }
                    transcript = ""
                    async with aconnect_sse(client, "POST", TRANSCRIPTION_ENDPOINT, **kwargs) as event_source:
                        async for event in event_source.aiter_sse():
                            transcript += event.data
                            yield transcript
                    if not transcript:
                        yield "(no speech detected)"
        except Exception as e:
            logger.exception("STT transcribe error")
            if not isinstance(e, APIProxyError):
                e = APIProxyError(str(e))
            yield format_api_proxy_error(e, context="transcribe")

    with gr.Tab(label="Speech-to-Text"):
        audio = gr.Audio(type="filepath", label="Audio — record or upload")
        button = gr.Button("Transcribe", variant="primary")
        output = gr.Textbox(label="Transcript", lines=8, show_copy_button=True)
        button.click(transcribe, inputs=[audio], outputs=output)


def create_gradio_demo(config: Config) -> gr.Blocks:
    with gr.Blocks(title="Speech to Text") as demo:
        gr.Markdown("# Speech to Text")
        create_simple_stt_tab(config)
        create_tts_tab(config)

    return demo
