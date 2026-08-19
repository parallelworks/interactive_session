# Ollama GGUF

Serves GGUF model weights with [Ollama](https://ollama.com) through a platform
endpoint. The endpoint is registered as an OpenAI-compatible provider
(`pw endpoints run --openai`), so the served models appear in the platform's
built-in chat and AI providers and can be used by any tool that consumes an
OpenAI-compatible API, such as a RAG system.

## Runtime

The **Runtime** input picks how Ollama runs:

- **Native (Ollama tarball)** — installs the official release tarball on the
  host. Needs glibc >= 2.28 and zstd; bundles CUDA runtimes, so a working
  NVIDIA driver is the only GPU requirement.
- **Singularity container** — runs the official `ollama/ollama` image as a SIF
  (pulled from `ghcr.io/parallelworks/ollama-gguf`), with a sandbox fallback
  for nodes that cannot mount SIFs. Use it on hosts where the native binary
  cannot run (older glibc, no zstd). GPU support via `--nv` is enabled
  automatically when a working NVIDIA driver is detected.

Both runtimes share the same model store, so weights are downloaded once.

## Models

The **Models to serve** input takes a space or comma separated list of model
references, pulled on the controller node before the service starts:

- Ollama library names, e.g. `qwen3:4b`
- Hugging Face GGUF references, e.g.
  `hf.co/culturerevolt/gemma-4-12b-heretic-abliterated-GGUF:Q4_K_M` (the
  default, about 7 GB) or `hf.co/mradermacher/gemma-4-31B-it-heretic-GGUF:Q4_K_M`

Any GGUF repo on Hugging Face works with the `hf.co/<owner>/<repo>:<quant>`
form. Size the quantization to the host: a Q4_K_M of a 31B model is ~19 GB on
disk and needs about as much free memory to run.

Models already present in the model directory are served as-is and never
re-pulled — this keeps runs fast and lets several users share one store
(re-pulling would rewrite a manifest file another user may own). To force a
refresh of a tag, delete its file under `<model directory>/manifests/`.

The **Model Directory** input sets where weights are stored (`OLLAMA_MODELS`;
ollama keeps them as a content-addressed store with `blobs/` and `manifests/`
subdirectories). It defaults to the shared per-platform location, so weights
download once per cluster regardless of runtime. If new models must be pulled
and the directory is not writable, the run warns and falls back to
`${HOME}/pw/software/ollama-gguf/models`; if it is not writable but every
requested model is already cached there, the run serves the store read-only.

With the Singularity runtime, **Serve only the requested models** (on by
default) mounts a filtered view of the model manifests into the container so
the endpoint exposes just the models listed by the run — useful with shared
model directories, where the store accumulates everyone's models. When
disabled (and always with the native runtime), the server serves every model
present under the model directory, and the platform re-polls the model list —
`ollama pull` on the live server adds chat models without relaunching.

Models whose chat template does not declare tool support (common for
abliterated GGUFs) work in the platform chat and through
`/v1/chat/completions`, but agentic clients that send tools (`pw code`) reject
them with "does not support tools".

## Lifecycle

The workflow run completes once the endpoint registers; the service keeps
running on the resource. Find it with `pw endpoints list` (named
`ollama-gguf-<run-slug>`) and tear it down with
`pw endpoints delete ollama-gguf-<run-slug>`.

Model weights and the Ollama installation persist under
`<parent_install_dir>/ollama-gguf`, so subsequent runs skip completed
downloads.
