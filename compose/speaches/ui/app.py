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

import logging
import os
from pathlib import Path

import gradio as gr

from speaches.config import Config
from speaches.ui.tabs.tts import create_tts_tab
from speaches.ui.utils import http_client_from_gradio_req
from speaches.utils import APIProxyError, format_api_proxy_error

logger = logging.getLogger(__name__)

TRANSCRIPTION_ENDPOINT = "/v1/audio/transcriptions"
# Single source of truth is the .env -> docker-compose.yml; fall back to the
# stack defaults if the env isn't set.
STT_MODEL = os.getenv("STT_UI_MODEL", "Systran/faster-whisper-medium")
STT_LANGUAGE = os.getenv("STT_UI_LANGUAGE", "bg")


def create_simple_stt_tab(config: Config) -> None:
    async def transcribe(file_path: str | None, request: gr.Request) -> str:
        try:
            if not file_path:
                msg = "No audio provided."
                raise APIProxyError(msg, suggestions=["Record or upload an audio file first."])
            http_client = http_client_from_gradio_req(request, config)
            with Path(file_path).open("rb") as file:  # noqa: ASYNC230
                response = await http_client.post(
                    TRANSCRIPTION_ENDPOINT,
                    files={"file": file},
                    data={
                        "model": STT_MODEL,
                        "language": STT_LANGUAGE,
                        "response_format": "text",
                        "temperature": 0.0,
                    },
                )
            response.raise_for_status()
            return response.text
        except Exception as e:
            logger.exception("STT transcribe error")
            if not isinstance(e, APIProxyError):
                e = APIProxyError(str(e))
            return format_api_proxy_error(e, context="transcribe")

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
