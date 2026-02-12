import os
from flask import Flask, render_template

app = Flask(__name__)

GOOGLE_CLIENT_ID = "947358624267-8r54cdqqa57fvg4b8338mupkei7biu1e.apps.googleusercontent.com"
API_BASE_URL = "http://localhost:8080"
DEBUG = os.environ.get("FLASK_DEBUG", "").lower() in {"1", "true", "yes"}
PORT = int(os.environ.get("PORT", 5000))


@app.get("/")
def home():
    if not GOOGLE_CLIENT_ID:
        return "Missing GOOGLE_CLIENT_ID env var", 500
    return render_template("index.html", google_client_id=GOOGLE_CLIENT_ID, api_base_url=API_BASE_URL)


if __name__ == "__main__":
    app.run(port=PORT, debug=DEBUG)
