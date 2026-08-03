# Ollama GGUF

Serves GGUF model weights with [Ollama](https://ollama.com) through a platform
endpoint. The endpoint is registered as an OpenAI-compatible provider
(`pw endpoints run --openai`), so the served models appear in the platform's
built-in chat and AI providers and can be used by any tool that consumes an
OpenAI-compatible API, such as a RAG system.

## Models

The **Models to serve** input takes a space or comma separated list of model
references, pulled on the controller node before the service starts:

- Ollama library names, e.g. `qwen3:4b`
- Hugging Face GGUF references, e.g.
  `hf.co/bartowski/gemma-2-2b-it-abliterated-GGUF:Q4_K_M` or
  `hf.co/mradermacher/gemma-4-31B-it-heretic-GGUF:Q4_K_M`

Any GGUF repo on Hugging Face works with the `hf.co/<owner>/<repo>:<quant>`
form. Size the quantization to the host: a Q4_K_M of a 31B model is ~19 GB on
disk and needs about as much free memory to run.

## Lifecycle

The workflow run completes once the endpoint registers; the service keeps
running on the resource. Find it with `pw endpoints list` (named
`ollama-gguf-<run-slug>`) and tear it down with
`pw endpoints delete ollama-gguf-<run-slug>`.

Model weights and the Ollama installation persist under
`<parent_install_dir>/ollama-gguf`, so subsequent runs skip completed
downloads.
