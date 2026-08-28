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

- Ollama library names
- Hugging Face GGUF references, e.g.
  `huggingface.co/culturerevolt/gemma-4-12b-heretic-abliterated-GGUF:Q4_K_M` (the
  default, about 7 GB) or `huggingface.co/mradermacher/gemma-4-31B-it-heretic-GGUF:Q4_K_M`

Any GGUF repo on Hugging Face works with the `huggingface.co/<owner>/<repo>:<quant>`
form. Size the quantization to the host: a Q4_K_M of a 31B model is ~19 GB on
disk and needs about as much free memory to run.

Models already present in the model directory are served as-is and never
re-pulled — this keeps runs fast and lets several users share one store
(re-pulling would rewrite a manifest file another user may own). To force a
refresh of a tag, delete its file under `<model directory>/manifests/`.

### Where the weights live

The **Model Directory** input sets where weights are stored (`OLLAMA_MODELS`;
ollama keeps them as a content-addressed store with `blobs/` and `manifests/`
subdirectories). Setting it pins the store and skips the search below.

Left empty, the run first looks for a store that already holds every requested
model, in this order:

1. the project directory (`${PROJECTS_HOME}/hsp/ollama-gguf/models` on HSP
   systems), where models are staged for everyone on the system
2. the install directory
3. `${WORKDIR}/pw/software/ollama-gguf/models`
4. `${HOME}/pw/software/ollama-gguf/models`

A store that holds everything is reused **even where this account cannot write
to it** — reading a staged model needs read permission, not write, and
re-downloading tens of gigabytes that are already on the filesystem because a
project directory refuses a write is the expensive mistake. If no store holds
them all, the missing models are pulled into the first writable candidate in
the same order: the work filesystem before home, which has far less quota.
`WORKDIR` is scratch and is purged, which is the right trade for a cache that
can be pulled again.

Staged weights have to be readable by the account that wants them. A project
directory whose default ACL denies `other` leaves every blob at mode
`rw-rw----`, readable only to the project group; the run detects that, says so,
and stages elsewhere rather than failing later with a load error. Whoever owns
the store opens it once with:

```
chmod -R a+rX <model directory>
find <model directory> -type d -exec setfacl -d -m o::rx {} +
```

Models this workflow pulls are made world-readable for the same reason.

### What the models are called

Ollama names a model after the reference it was pulled with, so a Hugging Face
model would otherwise be served — and listed in the platform chat — as
`hf.co/<uploader>/<repo>:<quant>`. The registry host and the uploader are
provenance, not identity, so the run serves a plain name instead: the
repository, lowercased, without the registry, the uploader or the `-GGUF`
suffix, with the quantization as the tag. `huggingface.co/mradermacher/gemma-4-31B-it-heretic-GGUF:Q4_K_M`
is served as `gemma-4-31b-it-heretic:q4_k_m`. **Serve models as** overrides
this per model, in the same order as the model list.

Both runtimes serve from a manifests directory the run assembles for itself, so
the names hold regardless of runtime. **Serve only the requested models** (on
by default) additionally limits the endpoint to the models this run listed —
useful with shared model directories, where the store accumulates everyone's
models. When disabled, every model cached under the model directory is served
as well, and the platform re-polls the model list — `ollama pull` on the live
server adds chat models without relaunching.

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
