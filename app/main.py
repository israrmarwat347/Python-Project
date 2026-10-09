"""FastAPI Notes app with Prometheus metrics and Google OAuth login."""
import os
import time
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from typing import List, Optional

import jwt
from authlib.integrations.starlette_client import OAuth, OAuthError
from fastapi import Cookie, Depends, FastAPI, HTTPException, Request
from fastapi.responses import RedirectResponse, Response
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest
from pydantic import BaseModel
import psycopg2
from psycopg2.extras import RealDictCursor
from starlette.middleware.sessions import SessionMiddleware

# ---- Config (all from env) ----
GOOGLE_CLIENT_ID     = os.environ.get("GOOGLE_CLIENT_ID", "")
GOOGLE_CLIENT_SECRET = os.environ.get("GOOGLE_CLIENT_SECRET", "")
# REMINDER: DO NOT HARDCODE THE URL, OR ADD ANY FALLBACKS OR REDIRECT URLS, THIS BREAKS THE AUTH
GOOGLE_REDIRECT_URI  = os.environ.get("GOOGLE_REDIRECT_URI", "")      # e.g. http://localhost:30080/auth/google/callback
APP_BASE_URL         = os.environ.get("APP_BASE_URL", "")             # e.g. http://localhost:30080
JWT_SECRET           = os.environ.get("JWT_SECRET", "dev-insecure-change-me")
SESSION_SECRET       = os.environ.get("SESSION_SECRET", "dev-insecure-change-me-session")
JWT_ALG              = "HS256"
JWT_TTL_HOURS        = 24
COOKIE_NAME          = "notes_session"

# ---- Prometheus metrics ----
REQUEST_COUNT = Counter(
    "notes_app_requests_total",
    "Total HTTP requests",
    ["method", "endpoint", "http_status"],
)
REQUEST_LATENCY = Histogram(
    "notes_app_request_duration_seconds",
    "Request duration in seconds",
    ["method", "endpoint"],
)

# ---- DB ----
def get_conn():
    return psycopg2.connect(
        host=os.environ.get("DB_HOST", "localhost"),
        port=os.environ.get("DB_PORT", "5432"),
        dbname=os.environ.get("DB_NAME", "notes"),
        user=os.environ.get("DB_USER", "notes"),
        password=os.environ.get("DB_PASSWORD", "notes"),
    )

def init_db():
    try:
        with get_conn() as conn, conn.cursor() as cur:
            cur.execute("""
                CREATE TABLE IF NOT EXISTS users (
                    id SERIAL PRIMARY KEY,
                    google_sub TEXT UNIQUE NOT NULL,
                    email TEXT NOT NULL,
                    name TEXT,
                    picture TEXT,
                    created_at TIMESTAMPTZ DEFAULT now()
                );
            """)
            cur.execute("""
                CREATE TABLE IF NOT EXISTS notes (
                    id SERIAL PRIMARY KEY,
                    user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    title TEXT NOT NULL,
                    body TEXT NOT NULL DEFAULT ''
                );
            """)
            conn.commit()
    except Exception as e:  # noqa: BLE001
        print(f"[init_db] skipped: {e}")

@asynccontextmanager
async def lifespan(_: FastAPI):
    init_db()
    yield

app = FastAPI(title="Notes App", lifespan=lifespan)
app.add_middleware(SessionMiddleware, secret_key=SESSION_SECRET)

# ---- OAuth client (Google) ----
oauth = OAuth()
oauth.register(
    name="google",
    client_id=GOOGLE_CLIENT_ID,
    client_secret=GOOGLE_CLIENT_SECRET,
    server_metadata_url="https://accounts.google.com/.well-known/openid-configuration",
    client_kwargs={"scope": "openid email profile"},
)

# ---- Metrics middleware ----
@app.middleware("http")
async def metrics_middleware(request: Request, call_next):
    start = time.time()
    response = await call_next(request)
    elapsed = time.time() - start
    endpoint = request.url.path
    REQUEST_COUNT.labels(request.method, endpoint, response.status_code).inc()
    REQUEST_LATENCY.labels(request.method, endpoint).observe(elapsed)
    return response

# ---- JWT helpers ----
def issue_jwt(user_id: int, email: str) -> str:
    payload = {
        "sub": str(user_id),
        "email": email,
        "exp": datetime.now(timezone.utc) + timedelta(hours=JWT_TTL_HOURS),
    }
    return jwt.encode(payload, JWT_SECRET, algorithm=JWT_ALG)

def decode_jwt(token: str) -> dict:
    return jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALG])

def get_current_user(
    notes_session: Optional[str] = Cookie(default=None, alias=COOKIE_NAME),
) -> dict:
    if not notes_session:
        raise HTTPException(status_code=401, detail="not authenticated")
    try:
        claims = decode_jwt(notes_session)
    except jwt.PyJWTError:
        raise HTTPException(status_code=401, detail="invalid session")
    with get_conn() as conn, conn.cursor(cursor_factory=RealDictCursor) as cur:
        cur.execute(
            "SELECT id, email, name, picture FROM users WHERE id = %s;",
            (int(claims["sub"]),),
        )
        user = cur.fetchone()
    if not user:
        raise HTTPException(status_code=401, detail="user not found")
    return user

# ---- Models ----
class NoteIn(BaseModel):
    title: str
    body: str = ""

class Note(NoteIn):
    id: int

# ---- Public routes ----
@app.get("/health")
def health():
    return {"status": "ok"}

@app.get("/metrics")
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)

@app.get("/")
def root():
    login_url = "/auth/google/login" if GOOGLE_CLIENT_ID else None
    return {"service": "notes-app", "version": "1.0.0", "login": login_url}

# ---- Auth routes ----
@app.get("/auth/google/login")
async def google_login(request: Request):
    if not GOOGLE_CLIENT_ID:
        raise HTTPException(status_code=503, detail="Google OAuth not configured")
    # REMINDER: DO NOT HARDCODE THE URL, OR ADD ANY FALLBACKS OR REDIRECT URLS, THIS BREAKS THE AUTH
    redirect_uri = GOOGLE_REDIRECT_URI or str(request.url_for("google_callback"))
    return await oauth.google.authorize_redirect(request, redirect_uri)

@app.get("/auth/google/callback", name="google_callback")
async def google_callback(request: Request):
    try:
        token = await oauth.google.authorize_access_token(request)
    except OAuthError as e:
        raise HTTPException(status_code=400, detail=f"oauth error: {e.error}")

    userinfo = token.get("userinfo") or {}
    sub     = userinfo.get("sub")
    email   = userinfo.get("email")
    name    = userinfo.get("name")
    picture = userinfo.get("picture")
    if not sub or not email:
        raise HTTPException(status_code=400, detail="invalid id_token")

    # Upsert user by google_sub
    with get_conn() as conn, conn.cursor(cursor_factory=RealDictCursor) as cur:
        cur.execute(
            """
            INSERT INTO users (google_sub, email, name, picture)
            VALUES (%s, %s, %s, %s)
            ON CONFLICT (google_sub)
            DO UPDATE SET email = EXCLUDED.email,
                          name = EXCLUDED.name,
                          picture = EXCLUDED.picture
            RETURNING id, email;
            """,
            (sub, email, name, picture),
        )
        user = cur.fetchone()
        conn.commit()

    jwt_token = issue_jwt(user["id"], user["email"])
    resp = RedirectResponse(url=APP_BASE_URL or "/", status_code=302)
    resp.set_cookie(
        key=COOKIE_NAME,
        value=jwt_token,
        max_age=JWT_TTL_HOURS * 3600,
        httponly=True,
        samesite="lax",
        secure=False,   # set True once you serve the app over HTTPS
        path="/",
    )
    return resp

@app.get("/auth/me")
def auth_me(current=Depends(get_current_user)):
    return current

@app.post("/auth/logout")
def auth_logout():
    resp = Response(status_code=204)
    resp.delete_cookie(COOKIE_NAME, path="/")
    return resp

# ---- Protected notes routes (per-user) ----
@app.get("/notes", response_model=List[Note])
def list_notes(current=Depends(get_current_user)):
    with get_conn() as conn, conn.cursor(cursor_factory=RealDictCursor) as cur:
        cur.execute(
            "SELECT id, title, body FROM notes WHERE user_id = %s ORDER BY id DESC;",
            (current["id"],),
        )
        return cur.fetchall()

@app.post("/notes", response_model=Note, status_code=201)
def create_note(note: NoteIn, current=Depends(get_current_user)):
    with get_conn() as conn, conn.cursor(cursor_factory=RealDictCursor) as cur:
        cur.execute(
            "INSERT INTO notes (user_id, title, body) VALUES (%s, %s, %s) "
            "RETURNING id, title, body;",
            (current["id"], note.title, note.body),
        )
        row = cur.fetchone()
        conn.commit()
        return row

@app.delete("/notes/{note_id}", status_code=204)
def delete_note(note_id: int, current=Depends(get_current_user)):
    with get_conn() as conn, conn.cursor() as cur:
        cur.execute(
            "DELETE FROM notes WHERE id = %s AND user_id = %s RETURNING id;",
            (note_id, current["id"]),
        )
        if not cur.fetchone():
            raise HTTPException(status_code=404, detail="not found")
        conn.commit()
    return Response(status_code=204)
