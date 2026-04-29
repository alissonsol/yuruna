FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

EXPOSE 8000

# LLM backend is configured via environment variables:
#   LLM_BACKEND  = ollama | openai | anthropic (default: ollama)
#   OLLAMA_HOST  = http://localhost:11434
#   OLLAMA_MODEL = phi3:mini
#   OPENAI_API_KEY  = (if using openai)
#   ANTHROPIC_API_KEY = (if using anthropic)
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
