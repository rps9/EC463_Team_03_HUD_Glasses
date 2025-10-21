import os, json
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

from open_ai_manager import chatManager, transcriptionManager

TRANSLATE_PROMPT = """
You are a helpful translation assistant. Your task is to translate the user's spoken input into English.
Return only the translation unless asked for something else.
"""

PHONETIC_PROMPT = """
You are a pronunciation coach. Your job is to output ONE line that an English speaker can read aloud.

TASK
1) Translate the message into the TARGET language.
2) Convert that result into a simple, English-friendly phonetic respelling using plain Latin letters only.

FORMAT
- Input will be:
  target=<LANGUAGE>
  text=<USER_TEXT>
- Output must be ONE single line. No quotes. No labels. No extra commentary.

ABSOLUTE RULES
- Do NOT output native scripts (no Chinese characters, no Arabic, no Cyrillic, etc.).
- Do NOT output IPA. Do NOT output pinyin, romaji, hangul, or any scholarly system.
- Use only plain English letters a–z, spaces, commas for short pauses, and hyphens to split syllables when helpful.
- Keep proper names (e.g., “Ryan”) as-is in Latin letters.
- Keep it short and speakable. Prioritize ease-for-English-speakers over linguistic precision.

LANGUAGE HINTS (for sound mapping; these are guidelines, not to be printed)
- Spanish/Italian/Portuguese: approximate vowels (a=ah, e=eh/ay by context, i=ee, o=oh, u=oo). “ll”≈“y”, “j”≈“h”.
- French: drop most final consonants; “r” is soft; approximate nasal vowels with “on/ahn/ehn/uhn”.
- German: “ch”≈“kh” after back vowels; “w”≈“v”; “z”≈“ts”.
- Mandarin Chinese: ignore tone marks; map to English sounds (ni=nee, xi=shee, q=chee, zh=jr, ch=chuh, sh=sh, c=ts, z=dz, r=zh/r as in “measure”). Keep only the English-friendly version.
- Japanese: use English-ish chunks (shi=“shee”, chi=“chee”, tsu=“tsoo”, r≈light “r/l”). No macrons; lengthen with doubled vowels when needed.
- Korean: “eo”≈“uh”, “eu”≈“oo” (tight), “ae/eh”≈“eh”. Break polite endings with hyphens if useful (se-yo).
- Arabic: “kh” for خ, “gh” for غ, “sh” for ش, “j” for ج; vowels approx: a=ah, i=ee, u=oo, e=eh, o=oh.
- Russian: zh (ж), kh (х), ts (ц), sh (ш), shch (щ); yeh/ya/yo/yu as needed.

EXAMPLES (do not output targets or labels in your answer)
target=Spanish
text=hello my name is Ryan
=> oh-la, meh yah-mo Ryan

target=French
text=where is the bathroom
=> oo eh lay twah-let

target=Mandarin Chinese
text=hello my name is Ryan
=> nee how, woh jyaow Ryan

target=Japanese
text=nice to meet you
=> ha-jee-meh mah-shee-teh

target=Korean
text=two coffees please
=> keo-pee du gae ju-se-yo

Return only the single phonetic line for the given request.
"""


app = FastAPI(title="Tiny Translator (WS)", version="1.3")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Serve /static and make / return the homepage file
app.mount("/static", StaticFiles(directory="static"), name="static")

@app.get("/")
def root():
    return FileResponse("static/index.html")

chatbot = chatManager(model="gpt-4o")
transcriber = transcriptionManager()

# ----- New: text -> phonetic endpoint -----
class PhoneticReq(BaseModel):
    text: str
    target: str = "Spanish"

@app.post("/api/phonetic")
def api_phonetic(req: PhoneticReq):
    # Reuse your existing translate() helper with a different system prompt
    user_content = f"target={req.target}\ntext={req.text}"
    phonetic = chatbot.translate(user_content, PHONETIC_PROMPT)
    return {"phonetic": phonetic, "target": req.target}

# ----- Existing: audio -> transcript -> English translation via WS -----
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
                    translation = chatbot.translate(transcript, TRANSLATE_PROMPT)
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
