# main.py
from fastapi import FastAPI
from fastapi.responses import PlainTextResponse

app = FastAPI()

@app.get("/", response_class=PlainTextResponse)
async def root():
    return "Hello, world!"

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)

# ---
# requirements.txt (optional)
# fastapi==0.115.5
# uvicorn[standard]==0.30.6
