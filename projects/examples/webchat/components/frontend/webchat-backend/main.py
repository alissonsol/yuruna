"""
webchat-backend/main.py

FastAPI service that provides a natural language chat interface
over network diagnostic data.

The LLM backend is abstracted via the LLM_BACKEND environment variable:
  ollama    - Local Ollama instance (default, air-gapped)
  openai    - OpenAI API
  anthropic - Anthropic API
"""

from __future__ import annotations

import os

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

app = FastAPI(
    title="Webchat Backend",
    description="Natural language interface over network diagnostic data.",
    version="0.1.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

LLM_BACKEND   = os.environ.get("LLM_BACKEND", "ollama")
OLLAMA_HOST   = os.environ.get("OLLAMA_HOST", "http://localhost:11434")
OLLAMA_MODEL  = os.environ.get("OLLAMA_MODEL", "phi3:mini")
OPENAI_KEY    = os.environ.get("OPENAI_API_KEY", "")
ANTHROPIC_KEY = os.environ.get("ANTHROPIC_API_KEY", "")


class ChatRequest(BaseModel):
    message: str
    history: list[dict] = []


class ChatResponse(BaseModel):
    reply: str
    backend: str


def _query_ollama(prompt: str) -> str:
    import requests
    resp = requests.post(
        f"{OLLAMA_HOST}/api/generate",
        json={"model": OLLAMA_MODEL, "prompt": prompt, "stream": False},
        timeout=120,
    )
    resp.raise_for_status()
    return resp.json().get("response", "").strip()


def _query_openai(prompt: str) -> str:
    import openai
    client = openai.OpenAI(api_key=OPENAI_KEY)
    resp = client.chat.completions.create(
        model="gpt-4o-mini",
        messages=[{"role": "user", "content": prompt}],
    )
    return resp.choices[0].message.content.strip()


def _query_anthropic(prompt: str) -> str:
    import anthropic
    client = anthropic.Anthropic(api_key=ANTHROPIC_KEY)
    resp = client.messages.create(
        model="claude-sonnet-4-20250514",
        max_tokens=1024,
        messages=[{"role": "user", "content": prompt}],
    )
    return resp.content[0].text.strip()


def _build_prompt(message: str, history: list[dict]) -> str:
    history_text = ""
    for turn in history[-6:]:
        role = turn.get("role", "user")
        content = turn.get("content", "")
        history_text += f"{role.capitalize()}: {content}\n"

    return f"""You are a network diagnostic assistant. Help the user understand their network health and resolve issues. Be specific and actionable.

{history_text}User: {message}
Assistant:"""


def _query_llm(prompt: str) -> str:
    if LLM_BACKEND == "ollama":
        return _query_ollama(prompt)
    elif LLM_BACKEND == "openai":
        return _query_openai(prompt)
    elif LLM_BACKEND == "anthropic":
        return _query_anthropic(prompt)
    else:
        raise ValueError(f"Unknown LLM backend: {LLM_BACKEND}")


@app.get("/health")
def health() -> dict:
    return {
        "status": "ok",
        "backend": LLM_BACKEND,
        "model": OLLAMA_MODEL if LLM_BACKEND == "ollama" else "cloud",
    }


@app.post("/chat", response_model=ChatResponse)
def chat(request: ChatRequest) -> ChatResponse:
    prompt = _build_prompt(request.message, request.history)
    try:
        reply = _query_llm(prompt)
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"LLM error: {exc}")
    return ChatResponse(reply=reply, backend=LLM_BACKEND)
