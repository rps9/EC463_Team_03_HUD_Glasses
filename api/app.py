import re, json, hashlib, hmac, jwt, os, secrets, httpx
from fastapi import FastAPI, HTTPException, status, Depends
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import HTTPBearer
from pydantic import BaseModel
from db import ping, pool
from psycopg.errors import UniqueViolation
from crypto_utils import hash_password, verify_password 
from pydantic import BaseModel, Field, field_validator
from jwt_utils import create_access_token, current_user, current_admin, current_owner, ACCESS_TOKEN_EXPIRE_MINUTES
from email_manager import EmailClient, issue_email_verification_link
from datetime import datetime, timedelta, timezone
from fastapi.responses import RedirectResponse, JSONResponse
from google.oauth2 import id_token as google_id_token
from google.auth.transport import requests as google_requests

ALLOWED_ORIGINS = [o.strip() for o in os.environ.get("ALLOWED_ORIGINS", "").split(",") if o.strip()]
VERIFY_REDIRECT_SUCCESS = "https://rps9.net/hudini-verify/success.html"
VERIFY_REDIRECT_INVALID = "https://rps9.net/hudini-verify/invalid.html"
VERIFY_REDIRECT_EXPIRED = "https://rps9.net/hudini-verify/expired.html"
GOOGLE_CLIENT_ID = os.environ.get("GOOGLE_CLIENT_ID")
APPLE_CLIENT_ID = os.environ.get("APPLE_CLIENT_ID")
APPLE_JWKS_URL = "https://appleid.apple.com/auth/keys"

PASSWORD_RE = re.compile(r"^[\x21-\x7E]+$") # Covers all ASCII but space

security = HTTPBearer(auto_error=False)

app = FastAPI()

if ALLOWED_ORIGINS:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=ALLOWED_ORIGINS,
        allow_credentials=True,
        allow_methods=["GET", "POST", "DELETE", "OPTIONS"],
        allow_headers=["*"],
    )

class SignUpCreds(BaseModel):
    password: str = Field(min_length=8, max_length=64)
    email: str # had some issues with pydantic's EmailStr so I'm just gonna keep it simple

    @field_validator("password")
    @classmethod
    def _validate_password(cls, password: str) -> str:
        if not PASSWORD_RE.fullmatch(password):
            raise ValueError("password must be 8-64 chars, visible ASCII (no spaces)")
        return password
    
    @field_validator("email", mode="before")
    @classmethod
    def _normalize_email(cls, email: str):
        if email is None:
            raise ValueError("email is required")
        email = str(email).strip().lower()

        if "@" not in email or "." not in email.split("@")[-1]:
            raise ValueError("invalid email format")
        return email

class SignInCreds(BaseModel):
    email: str
    password: str = Field(min_length=8, max_length=64)

    @field_validator("email", mode="before")
    @classmethod
    def _normalize_email(cls, email: str) -> str:
        if email is None:
            raise ValueError("email is required")
        email = str(email).strip().lower()
        if "@" not in email or "." not in email.split("@")[-1]:
            raise ValueError("invalid email format")
        return email

    @field_validator("password")
    @classmethod
    def _validate_password(cls, password: str) -> str:
        if not PASSWORD_RE.fullmatch(password):
            raise ValueError("password must be 8-64 chars, visible ASCII (no spaces)")
        return password

def _verify_google_id_token(credential: str) -> dict:
    if not GOOGLE_CLIENT_ID:
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail="missing GOOGLE_CLIENT_ID")
    try:
        return google_id_token.verify_oauth2_token(
            credential,
            google_requests.Request(),
            audience=GOOGLE_CLIENT_ID,
        )
    except Exception:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="invalid google credential")

def _sha256_hex(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()

def _verify_apple_id_token(identity_token: str, raw_nonce: str | None) -> dict:
    if not APPLE_CLIENT_ID:
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail="missing APPLE_CLIENT_ID")
    try:
        signing_key = jwt.PyJWKClient(APPLE_JWKS_URL).get_signing_key_from_jwt(identity_token).key
        claims = jwt.decode(
            identity_token,
            signing_key,
            algorithms=["RS256"],
            audience=APPLE_CLIENT_ID,
            issuer="https://appleid.apple.com",
        )
    except Exception:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="invalid apple credential")

    if raw_nonce:
        expected_nonce = _sha256_hex(raw_nonce)
        token_nonce = claims.get("nonce")
        if not token_nonce or not hmac.compare_digest(token_nonce, expected_nonce):
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="invalid apple nonce")

    return claims

@app.get("/hudini/db/health", dependencies=[Depends(current_admin)])
def db_health():
    ok = False
    try:
        ok = ping()
    except Exception as e:
        return {"ok": False, "error": str(e)}
    return {"ok": ok}

@app.post("/hudini/auth/signup", status_code=status.HTTP_201_CREATED)
def sign_up(body: SignUpCreds):
    try:
        pwd_hash = hash_password(body.password)
        with pool.connection() as conn, conn.cursor() as cur:
            cur.execute(
                "INSERT INTO users (email, email_verified, password_hash) VALUES (%s, FALSE, %s) RETURNING id",
                (body.email, pwd_hash),
            )
            user_id = cur.fetchone()[0]

        verify_url = issue_email_verification_link(user_id)
        EmailClient().send_verification(body.email, verify_url)

        # role is user by default, so no need to check the db for role
        token = create_access_token(email=body.email, role="user") 
        expires_at = jwt.decode(token, options={"verify_signature": False})["exp"]
        return {"ok": True, "message": "account created", "access_token": token, "token_type": "bearer", "expires_at": expires_at, "role": "user"}

    except UniqueViolation as e:
        constraint = e.diag.constraint_name
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=f"That {constraint} has already been used.")

    except Exception:
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail="signup failed")
    
@app.post("/hudini/auth/signin", status_code=status.HTTP_200_OK)
def sign_in(body: SignInCreds):
    try:
        with pool.connection() as conn, conn.cursor() as cur:
            cur.execute("SELECT password_hash, role, email_verified FROM users WHERE email = %s", (body.email,))
            row = cur.fetchone()

        if not row:
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="invalid credentials")

        stored_hash = row[0]
        role = row[1]
        email_verified = row[2]

        if not verify_password(body.password, stored_hash):
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="invalid credentials")
        if not email_verified:
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="email not verified")
        
        token = create_access_token(email=body.email, role=role)
        expires_at = jwt.decode(token, options={"verify_signature": False})["exp"]
        return {"access_token": token, "token_type": "bearer", "expires_at": expires_at, "role": role}

    except HTTPException:
        raise
    except Exception:
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail="signin failed")

@app.get("/hudini/auth/me", status_code=status.HTTP_200_OK)
def auth_me(user = Depends(current_user)):
    return {"email": user["email"], "role": user["role"]}

@app.delete("/hudini/auth/account", status_code=status.HTTP_200_OK)
def delete_account(user = Depends(current_user)):
    with pool.connection() as conn, conn.cursor() as cur:
        cur.execute("DELETE FROM users WHERE email = %s", (user["email"],))
        if cur.rowcount == 0:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="user not found")

    return {"ok": True, "message": "account deleted"}

def _verify_redirect_or_json(url: str | None, status_code: int, payload: dict):
    if url:
        return RedirectResponse(url=url, status_code=302)
    return JSONResponse(status_code=status_code, content=payload)

@app.get("/hudini/auth/verify-email")
def verify_email(token_id: str, token: str):
    now = datetime.now(timezone.utc)

    with pool.connection() as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT user_id, token_hash, expires_at, used_at FROM email_verifications WHERE id = %s",
            (token_id,)
        )
        row = cur.fetchone()

        if not row:
            return _verify_redirect_or_json(
                VERIFY_REDIRECT_INVALID,
                status.HTTP_400_BAD_REQUEST,
                {"ok": False, "status": "invalid", "message": "invalid token"},
            )

        user_id = row[0]
        token_hash = row[1]
        expires_at = row[2]
        used_at = row[3]

        if used_at is not None or now > expires_at:
            return _verify_redirect_or_json(
                VERIFY_REDIRECT_EXPIRED,
                status.HTTP_400_BAD_REQUEST,
                {"ok": False, "status": "expired", "message": "token expired or already used"},
            )

        presented = hashlib.sha256(token.encode()).hexdigest()
        if not hmac.compare_digest(token_hash, presented):
            return _verify_redirect_or_json(
                VERIFY_REDIRECT_INVALID,
                status.HTTP_400_BAD_REQUEST,
                {"ok": False, "status": "invalid", "message": "invalid token"},
            )

        cur.execute("UPDATE users SET email_verified = TRUE WHERE id = %s", (user_id,))
        cur.execute("UPDATE email_verifications SET used_at = %s WHERE id = %s", (now, token_id,))

    return _verify_redirect_or_json(
        VERIFY_REDIRECT_SUCCESS,
        status.HTTP_200_OK,
        {"ok": True, "status": "verified", "message": "email verified"},
    )
    


class BestowRoleBody(BaseModel):
    email: str
    role: str

    @field_validator("email", mode="before")
    @classmethod
    def _normalize_email(cls, email: str) -> str:
        return str(email).strip().lower()
    
    @field_validator("role", mode="before")
    @classmethod
    def _check_role(cls, role: str) -> str:
        role_list = ["user", "admin", "owner"]
        if role not in role_list:
            raise ValueError(f"Role must be one of the following: {role_list}")
        return role

@app.post("/hudini/owner/bestow-role", dependencies=[Depends(current_owner)], status_code=status.HTTP_200_OK)
def bestow_admin(body: BestowRoleBody):
    with pool.connection() as conn, conn.cursor() as cur:
        cur.execute(
            "UPDATE users SET role = %s WHERE email = %s AND role <> %s",
            (body.role, body.email, body.role),
        )
        if cur.rowcount == 0:
            cur.execute("SELECT role FROM users WHERE email = %s", (body.email,))
            row = cur.fetchone()
            if not row:
                raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="email not found")
            if row[0] == body.role:
                return {"ok": True, "message": f"user is already role: {body.role}"}
        return {"ok": True, "message": f"{body.email} is now role: {body.role}"}


class GoogleAuthBody(BaseModel):
    credential: str


@app.post("/hudini/auth/google", status_code=status.HTTP_200_OK)
def auth_google(body: GoogleAuthBody):
    idinfo = _verify_google_id_token(body.credential)

    google_sub = idinfo.get("sub")
    email = (idinfo.get("email") or "").strip().lower()
    name = (idinfo.get("name") or "").strip()
    picture = (idinfo.get("picture") or "").strip()
    google_email_verified = bool(idinfo.get("email_verified"))
    if not google_sub:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="google token missing sub")
    if not email:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="google token missing email")
    if not google_email_verified:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Verify google account or use a verified account")

    with pool.connection() as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT email, role FROM users WHERE google_sub = %s",
            (google_sub,),
        )
        row = cur.fetchone()

        if row:
            account_email = row[0]
            role = row[1]
        else:
            # Link to an existing password account with the same email before creating a new row.
            cur.execute(
                "SELECT id, role, google_sub FROM users WHERE email = %s",
                (email,),
            )
            row = cur.fetchone()

            if row:
                user_id = row[0]
                role = row[1]
                existing_google_sub = row[2]

                if existing_google_sub and existing_google_sub != google_sub:
                    raise HTTPException(
                        status_code=status.HTTP_409_CONFLICT,
                        detail="email is already linked to a different google account",
                    )

                cur.execute(
                    "UPDATE users SET google_sub = %s, email_verified = TRUE WHERE id = %s",
                    (google_sub, user_id),
                )
                account_email = email
            else:
                # Keep password_hash populated to avoid needing to relax NOT NULL in existing schemas.
                random_pwd = secrets.token_urlsafe(32)
                pwd_hash = hash_password(random_pwd)

                try:
                    cur.execute(
                        """
                        INSERT INTO users (email, email_verified, password_hash, google_sub)
                        VALUES (%s, %s, %s, %s)
                        """,
                        (email, google_email_verified, pwd_hash, google_sub),
                    )
                except UniqueViolation as e:
                    constraint = e.diag.constraint_name
                    raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=f"That {constraint} has already been used.")

                account_email = email
                role = "user"

    token = create_access_token(email=account_email, role=role)
    expires_at = jwt.decode(token, options={"verify_signature": False})["exp"]
    return {
        "ok": True,
        "user": {"email": account_email, "name": name, "picture": picture, "role": role},
        "access_token": token,
        "token_type": "bearer",
        "expires_at": expires_at,
        "role": role,
    }


class AppleAuthBody(BaseModel):
    identity_token: str
    nonce: str | None = None
    full_name: str | None = None


@app.post("/hudini/auth/apple", status_code=status.HTTP_200_OK)
def auth_apple(body: AppleAuthBody):
    claims = _verify_apple_id_token(body.identity_token, body.nonce)

    apple_sub = claims.get("sub")
    email = (claims.get("email") or "").strip().lower()
    email_verified_claim = claims.get("email_verified")
    apple_email_verified = email_verified_claim is True or str(email_verified_claim).lower() == "true"
    name = (body.full_name or "").strip()

    if not apple_sub:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="apple token missing sub")
    if email and not apple_email_verified:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="apple email is not verified")

    with pool.connection() as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT email, role FROM users WHERE apple_sub = %s",
            (apple_sub,),
        )
        row = cur.fetchone()

        if row:
            account_email = row[0]
            role = row[1]
        else:
            if not email:
                raise HTTPException(
                    status_code=status.HTTP_400_BAD_REQUEST,
                    detail="apple credential missing email; remove HUDini from Sign in with Apple settings and try again",
                )

            cur.execute(
                "SELECT id, role, apple_sub FROM users WHERE email = %s",
                (email,),
            )
            row = cur.fetchone()

            if row:
                user_id = row[0]
                role = row[1]
                existing_apple_sub = row[2]

                if existing_apple_sub and existing_apple_sub != apple_sub:
                    raise HTTPException(
                        status_code=status.HTTP_409_CONFLICT,
                        detail="email is already linked to a different apple account",
                    )

                cur.execute(
                    "UPDATE users SET apple_sub = %s, email_verified = TRUE WHERE id = %s",
                    (apple_sub, user_id),
                )
                account_email = email
            else:
                random_pwd = secrets.token_urlsafe(32)
                pwd_hash = hash_password(random_pwd)

                try:
                    cur.execute(
                        """
                        INSERT INTO users (email, email_verified, password_hash, apple_sub)
                        VALUES (%s, %s, %s, %s)
                        """,
                        (email, True, pwd_hash, apple_sub),
                    )
                except UniqueViolation as e:
                    constraint = e.diag.constraint_name
                    raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=f"That {constraint} has already been used.")

                account_email = email
                role = "user"

    token = create_access_token(email=account_email, role=role)
    expires_at = jwt.decode(token, options={"verify_signature": False})["exp"]
    return {
        "ok": True,
        "user": {"email": account_email, "name": name, "picture": None, "role": role},
        "access_token": token,
        "token_type": "bearer",
        "expires_at": expires_at,
        "role": role,
    }


class RequestResetPassword(BaseModel):
    email: str

@app.post("/hudini/auth/request-reset-password", status_code=status.HTTP_200_OK)
def reset_password(body: RequestResetPassword):
    with pool.connection() as conn, conn.cursor() as cur:
        # Existing Google-linked account
        cur.execute(
            "SELECT google_sub FROM users WHERE email = %s",
            (body.email,),
        )
        row = cur.fetchone()

    google_sub = row[0]

    if google_sub:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="sign in using google")
    
    # Return generic message if the email doesn't exist
    if not row:
        return {
            "ok": True,
            "message": "If the email exists, then we will send an email to reset your password."
        }


# ── AI suggestion proxy (admin-only) ─────────────────────────────────────────

OPENAI_API_KEY = os.environ.get("OPENAI_API_KEY", "")
OPENAI_MODEL = "gpt-5-mini"
OPENAI_REASONING_EFFORT = "medium"
OPENAI_CHAT_URL = "https://api.openai.com/v1/chat/completions"


async def _openai_chat(messages: list[dict], max_completion_tokens: int) -> str:
    if not OPENAI_API_KEY:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="OpenAI not configured")

    payload: dict = {
        "model": OPENAI_MODEL,
        "messages": messages,
        "max_completion_tokens": max_completion_tokens,
    }
    if OPENAI_MODEL.startswith("gpt-5") or OPENAI_MODEL.startswith("o"):
        payload["reasoning_effort"] = OPENAI_REASONING_EFFORT

    async with httpx.AsyncClient(timeout=30.0) as client:
        resp = await client.post(
            OPENAI_CHAT_URL,
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer {OPENAI_API_KEY}",
            },
            json=payload,
        )

    if resp.status_code != 200:
        body_text = resp.text[:500]
        print(f"[OpenAI] error {resp.status_code}: {body_text}")
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"OpenAI error {resp.status_code}: {body_text}",
        )

    try:
        return resp.json()["choices"][0]["message"]["content"].strip()
    except (KeyError, IndexError):
        raise HTTPException(status_code=status.HTTP_502_BAD_GATEWAY, detail="Failed to parse OpenAI response")


def _parse_json_payload(raw: str, required_keys: list[str]) -> dict:
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        raise HTTPException(status_code=status.HTTP_502_BAD_GATEWAY, detail="Failed to parse OpenAI response")
    for key in required_keys:
        if key not in parsed or not isinstance(parsed[key], str):
            raise HTTPException(status_code=status.HTTP_502_BAD_GATEWAY, detail="Failed to parse OpenAI response")
    return parsed


class SuggestionBody(BaseModel):
    text: str = Field(min_length=1, max_length=2000)
    language_code: str = Field(min_length=2, max_length=10)
    profile: dict[str, str] | None = None


SUGGESTION_SYSTEM_PROMPT = (
    "You are HUDini, an AI co-pilot whispering replies into the user's HUD.\n"
    "Given the conversation context (what the other person just said) and the user's profile, "
    "write ONE short, natural reply in the requested language.\n\n"
    "Rules:\n"
    "- Reply ONLY with JSON: {\"reply_native\":\"...\"}\n"
    "- 1-2 sentences, conversational, matches the user's tone preference.\n"
    "- Use the user's profile to personalize but never mention you're using a profile.\n"
    "- Never invent personal facts not present in the profile.\n"
    "- If the user has dietary, health, religious, or \"topics_to_avoid\" entries, never produce a reply that violates them.\n"
    "- No emojis, no markdown, no code fences, no commentary."
)


@app.post("/hudini/ai/suggestion", dependencies=[Depends(current_admin)], status_code=status.HTTP_200_OK)
async def ai_suggestion(body: SuggestionBody):
    profile_payload = json.dumps(body.profile or {}, ensure_ascii=False)
    user_message = (
        f"Language: {body.language_code}\n"
        f"Profile: {profile_payload}\n"
        f"Heard: {body.text}"
    )

    raw_content = await _openai_chat(
        messages=[
            {"role": "system", "content": SUGGESTION_SYSTEM_PROMPT},
            {"role": "user", "content": user_message},
        ],
        max_completion_tokens=320,
    )
    parsed = _parse_json_payload(raw_content, ["reply_native"])
    return {"ok": True, "reply_native": parsed["reply_native"]}


class PhoneticBody(BaseModel):
    text: str = Field(min_length=1, max_length=2000)
    language_code: str = Field(min_length=2, max_length=10)


PHONETIC_SYSTEM_PROMPT = (
    "You are a phonetic transliteration specialist. You will be given text in some language "
    "and must rewrite it so an English-only speaker can pronounce it aloud.\n\n"
    "Output JSON ONLY: {\"phonetic\":\"...\"}\n\n"
    "Rules:\n"
    "- Use only ASCII letters, spaces, commas, apostrophes, hyphens, periods, and question marks.\n"
    "- Approximate pronunciation as spoken in the requested language (NOT the spelling).\n"
    "- Mark stressed syllables in long words by separating syllables with hyphens "
    "(e.g., \"comprehensión\" → \"kom-pren-see-OWN\").\n"
    "- Do NOT translate. Do NOT add words. Do NOT include the original text.\n"
    "- For Mandarin, use Pinyin without tone marks (use ASCII only). "
    "For Japanese, use Hepburn romaji without macrons.\n"
    "- Keep punctuation positions roughly aligned with the source."
)


@app.post("/hudini/ai/phonetic", dependencies=[Depends(current_admin)], status_code=status.HTTP_200_OK)
async def ai_phonetic(body: PhoneticBody):
    user_message = f"Language: {body.language_code}\nText: {body.text}"

    raw_content = await _openai_chat(
        messages=[
            {"role": "system", "content": PHONETIC_SYSTEM_PROMPT},
            {"role": "user", "content": user_message},
        ],
        max_completion_tokens=220,
    )
    parsed = _parse_json_payload(raw_content, ["phonetic"])
    return {"ok": True, "phonetic": parsed["phonetic"]}
