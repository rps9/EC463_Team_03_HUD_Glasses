import re, json, hashlib, hmac, jwt, os, secrets
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
VERIFY_REDIRECT_SUCCESS = os.environ.get("VERIFY_REDIRECT_SUCCESS")
VERIFY_REDIRECT_INVALID = os.environ.get("VERIFY_REDIRECT_INVALID")
VERIFY_REDIRECT_EXPIRED = os.environ.get("VERIFY_REDIRECT_EXPIRED")
GOOGLE_CLIENT_ID = os.environ.get("GOOGLE_CLIENT_ID")

USERNAME_RE = re.compile(r"^(?![._-])(?!.*[._-]{2})[a-z0-9._-]+(?<![._-])$")
PASSWORD_RE = re.compile(r"^[\x21-\x7E]+$") # Covers all ASCII but space

security = HTTPBearer(auto_error=False)

app = FastAPI()
if ALLOWED_ORIGINS:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=ALLOWED_ORIGINS,
        allow_credentials=True,
        allow_methods=["GET", "POST", "OPTIONS"],
        allow_headers=["*"],
    )

class SignUpCreds(BaseModel):
    username: str = Field(min_length=3, max_length=32)
    password: str = Field(min_length=8, max_length=64)
    email: str # had some issues with pydantic's EmailStr so I'm just gonna keep it simple

    @field_validator("username", mode="before")
    @classmethod
    def _normalize_username(cls, username: str) -> str:
        return username.strip().lower()

    @field_validator("username")
    @classmethod
    def _validate_username(cls, username: str) -> str:
        if not USERNAME_RE.fullmatch(username):
            raise ValueError("username may contain a-z, 0-9, dot, underscore, hyphen; cannot start/end with . _ - or contain repeats like '..'")
        return username

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
    username: str = Field(min_length=3, max_length=32)
    password: str = Field(min_length=8, max_length=64)

    @field_validator("username", mode="before")
    @classmethod
    def _normalize_username(cls, username: str) -> str:
        return username.strip().lower()

    @field_validator("username")
    @classmethod
    def _validate_username(cls, username: str) -> str:
        if not USERNAME_RE.fullmatch(username):
            raise ValueError("username may contain a-z, 0-9, dot, underscore, hyphen; cannot start/end with . _ - or contain repeats like '..'")
        return username

    @field_validator("password")
    @classmethod
    def _validate_password(cls, password: str) -> str:
        if not PASSWORD_RE.fullmatch(password):
            raise ValueError("password must be 8-64 chars, visible ASCII (no spaces)")
        return password
    

def _email_local_part(email: str) -> str:
    return (email.split("@", 1)[0] if email else "").strip().lower()

def _username_base_from_email(email: str) -> str:
    # Must fit USERNAME_RE: [a-z0-9._-], no leading/trailing ._-, no repeats like ".."
    s = _email_local_part(email)
    s = re.sub(r"[^a-z0-9._-]+", ".", s)
    s = re.sub(r"[._-]{2,}", ".", s)
    s = s.strip("._-")
    if not s:
        s = "user"
    if len(s) < 3:
        s = (s + "user")[:3]
    if not USERNAME_RE.fullmatch(s):
        s = "user" + secrets.token_hex(3)
    return s[:32]

def _unique_username(cur, base: str) -> str:
    # Try base, base1, base2... truncated to 32 chars.
    for i in range(0, 100):
        suffix = "" if i == 0 else str(i)
        candidate = (base[: max(0, 32 - len(suffix))] + suffix)[:32]
        cur.execute("SELECT 1 FROM users WHERE username = %s", (candidate,))
        if not cur.fetchone():
            return candidate
    return ("user" + secrets.token_hex(10))[:32]

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

@app.get("/api/db/health", dependencies=[Depends(current_admin)])
def db_health():
    ok = False
    try:
        ok = ping()
    except Exception as e:
        return {"ok": False, "error": str(e)}
    return {"ok": ok}

@app.post("/api/auth/signup", status_code=status.HTTP_201_CREATED)
def sign_up(body: SignUpCreds):
    try:
        pwd_hash = hash_password(body.password)
        with pool.connection() as conn, conn.cursor() as cur:
            cur.execute(
                "INSERT INTO users (username, email, email_verified, password_hash) VALUES (%s, %s, FALSE, %s) RETURNING id",
                (body.username, body.email, pwd_hash),
            )
            user_id = cur.fetchone()[0]

        verify_url = issue_email_verification_link(user_id)
        EmailClient().send_verification(body.email, verify_url)

        # role is user by default, so no need to check the db for role
        token = create_access_token(username=body.username, role="user") 
        expires_at = jwt.decode(token, options={"verify_signature": False})["exp"]
        return {"ok": True, "message": "account created", "access_token": token, "token_type": "bearer", "expires_at": expires_at, "role": "user"}

    except UniqueViolation as e:
        constraint = e.diag.constraint_name
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=f"That {constraint} has already been used.")

    except Exception:
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail="signup failed")
    
@app.post("/api/auth/signin", status_code=status.HTTP_200_OK)
def sign_in(body: SignInCreds):
    try:
        with pool.connection() as conn, conn.cursor() as cur:
            cur.execute("SELECT password_hash, role, email_verified FROM users WHERE username = %s", (body.username,))
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
        
        token = create_access_token(username=body.username, role=role)
        expires_at = jwt.decode(token, options={"verify_signature": False})["exp"]
        return {"access_token": token, "token_type": "bearer", "expires_at": expires_at, "role": role}

    except HTTPException:
        raise
    except Exception:
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail="signin failed")

def _verify_redirect_or_json(url: str | None, status_code: int, payload: dict):
    if url:
        return RedirectResponse(url=url, status_code=302)
    return JSONResponse(status_code=status_code, content=payload)

@app.get("/api/auth/verify-email")
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
    username: str
    role: str

    @field_validator("username", mode="before")
    @classmethod
    def _normalize_username(cls, username: str) -> str:
        return str(username).strip().lower()

@app.post("/api/owner/bestow-role", dependencies=[Depends(current_owner)], status_code=status.HTTP_200_OK)
def bestow_admin(body: BestowRoleBody):
    with pool.connection() as conn, conn.cursor() as cur:
        cur.execute(
            "UPDATE users SET role = %s WHERE username = %s AND role <> %s",
            (body.role, body.username, body.role),
        )
        if cur.rowcount == 0:
            cur.execute("SELECT role FROM users WHERE username = %s", (body.username,))
            row = cur.fetchone()
            if not row:
                raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="user not found")
            if row[0] == body.role:
                return {"ok": True, "message": f"user is already role: {body.role}"}
        return {"ok": True, "message": f"{body.username} is now role: {body.role}"}


class GoogleAuthBody(BaseModel):
    credential: str


@app.post("/api/auth/google", status_code=status.HTTP_200_OK)
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

    with pool.connection() as conn, conn.cursor() as cur:
        # 1) Existing Google-linked account
        cur.execute(
            "SELECT id, username, role, email_verified FROM users WHERE google_sub = %s",
            (google_sub,),
        )
        row = cur.fetchone()

        if row:
            user_id = row[0]
            username = row[1]
            role = row[2] or "user"
            if google_email_verified and not bool(row[3]):
                cur.execute("UPDATE users SET email_verified = TRUE WHERE id = %s", (user_id,))
        else:
            # Create a new local user record for this Google identity (no linking by email).
            base = _username_base_from_email(email)
            username = _unique_username(cur, base)

            # Keep password_hash populated to avoid needing to relax NOT NULL in existing schemas.
            random_pwd = secrets.token_urlsafe(32)
            pwd_hash = hash_password(random_pwd)

            try:
                cur.execute(
                    """
                    INSERT INTO users (username, email, email_verified, password_hash, google_sub)
                    VALUES (%s, %s, %s, %s, %s)
                    """,
                    (username, email, google_email_verified, pwd_hash, google_sub),
                )
            except UniqueViolation as e:
                constraint = (getattr(getattr(e, "diag", None), "constraint_name", "") or "").lower()
                detail = "account already exists"
                if "username" in constraint:
                    detail = "username already exists"
                elif "email" in constraint:
                    detail = "email already exists"
                if detail != "username already exists":
                    raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=detail)
                # If username collided between the pre-check and insert, retry once with a different username.
                username = _unique_username(cur, base + secrets.token_hex(2))
                try:
                    cur.execute(
                        """
                        INSERT INTO users (username, email, email_verified, password_hash, google_sub)
                        VALUES (%s, %s, %s, %s, %s)
                        """,
                        (username, email, google_email_verified, pwd_hash, google_sub),
                    )
                except UniqueViolation as e2:
                    constraint = (getattr(getattr(e2, "diag", None), "constraint_name", "") or "").lower()
                    detail = "account already exists"
                    if "username" in constraint:
                        detail = "username already exists"
                    elif "email" in constraint:
                        detail = "email already exists"
                    raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=detail)
            role = "user"
    
    token = create_access_token(username=username, role=role)
    expires_at = jwt.decode(token, options={"verify_signature": False})["exp"]
    return {
        "ok": True,
        "user": {"email": email, "name": name, "picture": picture, "username": username, "role": role},
        "access_token": token,
        "token_type": "bearer",
        "expires_at": expires_at,
        "role": role,
    }
