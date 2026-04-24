# webchat

A website with a natural language interface powered by a local LLM.

Extends the `website` example by adding an LLM backend that answers
questions about network health using data from Network Weather.

The LLM backend is abstracted from the inference engine — swap between
Ollama (local, air-gapped), OpenAI, or Anthropic by changing one variable.

## Architecture
## Resources
Standard k8s cluster on localhost.

## Components
- `webchat-frontend` — the existing website frontend
- `webchat-backend` — FastAPI service wrapping the LLM and Network Weather

## Workloads
Deploys both components to k8s. LLM backend configured via:
- `llmBackend` — "ollama" | "openai" | "anthropic" (default: ollama)
- `ollamaHost`  — Ollama API endpoint (default: http://localhost:11434)
- `ollamaModel` — model to use (default: phi3:mini)

## Quick start
```bash
pwsh ./yuruna.ps1 resources projects/examples/webchat/config/localhost
pwsh ./yuruna.ps1 components projects/examples/webchat/config/localhost
pwsh ./yuruna.ps1 workloads projects/examples/webchat/config/localhost
```
