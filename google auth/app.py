import os
from flask import Flask, request, jsonify, render_template, session
from google.oauth2 import id_token
from google.auth.transport import requests as google_requests

app = Flask(__name__)
app.secret_key = os.environ.get("FLASK_SECRET", "dev_secret_backup")

GOOGLE_CLIENT_ID = os.environ.get("GOOGLE_CLIENT_ID")
DEBUG = os.environ.get("FLASK_DEBUG", "").lower() in {"1", "true", "yes"}
PORT = int(os.environ.get("PORT", 5000))


@app.get("/")
def home():
    if not GOOGLE_CLIENT_ID:
        return "Missing GOOGLE_CLIENT_ID env var", 500
    return render_template("index.html", google_client_id=GOOGLE_CLIENT_ID)


@app.post("/auth/google")
def auth_google():
    credential = request.form.get("credential") or (request.json or {}).get("credential")
    if not credential:
        return jsonify({"ok": False, "error": "Missing credential"}), 400

    try:
        idinfo = id_token.verify_oauth2_token(
            credential,
            google_requests.Request(),
            audience=GOOGLE_CLIENT_ID,
        )
        session["user"] = {
            "email": idinfo.get("email"),
            "name": idinfo.get("name"),
        }
        return jsonify({"ok": True, "user": session["user"]})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 401


@app.post("/logout")
def logout():
    session.pop("user", None)
    return jsonify({"ok": True})


@app.get("/me")
def me():
    return jsonify({"ok": True, "user": session.get("user")})


if __name__ == "__main__":
    app.run(port=PORT, debug=DEBUG)
