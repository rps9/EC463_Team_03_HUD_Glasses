import os, json
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from open_ai_manager import chatManager, transcriptionManager

MASTER_PROMPT = """
You are a helpful translation assistant. Your task is to translate the user's spoken input into English.
Return only the translation unless asked for something else.
"""

app = FastAPI(title="Tiny Translator (WS)", version="1.2")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],   # tighten for prod
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Serve /static and make / return the homepage file
app.mount("/static", StaticFiles(directory="static"), name="static")

@app.get("/")
def root():
    return FileResponse("static/index.html")

chatbot = chatManager(model=os.getenv("TRANSLATION_MODEL", "gpt-4o"))
transcriber = transcriptionManager()

@app.websocket("/ws/translate")
async def ws_translate(ws: WebSocket):
    await ws.accept()
    buffers: list[bytes] = []
    ext = ".webm"
    try:
        while True:
            msg = await ws.receive()
            if "text" in msg and msg["text"] is not None:
                import json as _json
                try:
                    data = _json.loads(msg["text"])
                except Exception:
                    continue
                t = data.get("type")
                if t == "start":
                    mime = (data.get("mimeType") or "").lower()
                    if "ogg" in mime: ext = ".ogg"
                    elif "mp4" in mime or "m4a" in mime: ext = ".m4a"
                    elif "wav" in mime: ext = ".wav"
                    else: ext = ".webm"
                elif t == "stop":
                    from time import perf_counter
                    t0 = perf_counter()
                    audio_bytes = b"".join(buffers)
                    transcript = transcriber.transcribe_file(audio_bytes, filename=f"clip{ext}")
                    translation = chatbot.translate(transcript, MASTER_PROMPT)
                    latency_ms = int((perf_counter() - t0) * 1000)
                    await ws.send_text(json.dumps({
                        "type": "result",
                        "transcript": transcript,
                        "translation": translation,
                        "latency_ms": latency_ms
                    }))
                    await ws.close()
                    return
            elif "bytes" in msg and msg["bytes"] is not None:
                buffers.append(msg["bytes"])
    except WebSocketDisconnect:
        return
    except Exception as e:
        try:
            await ws.send_text(json.dumps({"type": "error", "message": str(e)}))
            await ws.close()
        finally:
            return
