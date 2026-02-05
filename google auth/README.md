Google Auth Client

https://console.cloud.google.com/auth/clients

Testing Path

Activate New ENV:

python -m venv .venv

source .venv/bin/activate

pip install flask google-auth

export GOOGLE_CLIENT_ID="insert ID"

export FLASK_SECRET="insert secret"

Open Activated ENV:

source .venv/bin/activate

Run:

python app.py
