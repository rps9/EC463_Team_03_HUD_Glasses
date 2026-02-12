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
            "sub": idinfo.get("sub"),
            "email": idinfo.get("email"),
            "name": idinfo.get("name"),
        }
        return jsonify({"ok": True, "user": session["user"]})
    except Exception as e:
        return jsonify({"ok": False, "error": str(e)}), 401


@app.post("/logout")
def logout():
    session.clear()
    return jsonify({"ok": True})


@app.get("/me")
def me():
    user = session.get("user")
    return jsonify({"ok": True, "logged_in": bool(user), "user": user})


@app.get("/user-data")
def user_data():
    user = session.get("user")
    if not user:
        return jsonify({"ok": False, "error": "No user data."}), 401

    sub = user.get("sub")

    # Spanish
    if sub == "104830467548669430044":
        data = [
            {
                "datetime": "2026-02-10 09:01",
                "phrase_heard": "¿Dónde está el baño?",
                "translation": "Where is the bathroom?",
                "suggested_response": "El baño está a la derecha.",
            },
            {
                "datetime": "2026-02-10 11:15",
                "phrase_heard": "Necesito ayuda",
                "translation": "I need help",
                "suggested_response": "Claro, ¿en qué puedo ayudar?",
            },
            {
                "datetime": "2026-02-10 14:22",
                "phrase_heard": "¿Cuánto cuesta?",
                "translation": "How much does it cost?",
                "suggested_response": "Cuesta diez dólares.",
            },
        ]

    # French
    elif sub == "108175577798513320429":
        data = [
            {
                "datetime": "2026-02-10 09:01",
                "phrase_heard": "Où sont les toilettes ?",
                "translation": "Where is the bathroom?",
                "suggested_response": "Les toilettes sont à droite.",
            },
            {
                "datetime": "2026-02-10 11:15",
                "phrase_heard": "J'ai besoin d'aide",
                "translation": "I need help",
                "suggested_response": "Bien sûr, comment puis-je aider ?",
            },
            {
                "datetime": "2026-02-10 14:22",
                "phrase_heard": "Combien ça coûte ?",
                "translation": "How much does it cost?",
                "suggested_response": "Ça coûte dix dollars.",
            },
        ]

    else:
        data = []

    return jsonify({"ok": True, "sub": sub, "data": data})


if __name__ == "__main__":
    app.run(port=PORT, debug=DEBUG)
