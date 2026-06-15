# Hermes Agent

Run **[Hermes Agent](https://github.com/NousResearch/hermes-agent)** — the
self-improving AI agent from Nous Research — on one of your clusters, and talk to
it from the ACTIVATE chat. Hermes runs real shell commands, writes and runs code,
remembers across turns, and builds its own skills — all on the cluster's login
node, with the platform's own LLM as its brain.

## How it works

```
   ACTIVATE Chat ──provider──► session tunnel ──► cluster login node
                                                   ├─ hermes gateway  (OpenAI API, private port)
                                                   └─ auth proxy      (tunnel-facing port)
                                                  brain → platform LLM endpoint
```

Launch this workflow on a cluster. It installs Hermes (first run only), points
its brain at the ACTIVATE LLM endpoint, and exposes Hermes' OpenAI-compatible
API through the session. Because the session is **OpenAI-enabled**, ACTIVATE
auto-detects it and adds it to your chat.

## Getting started

**1. Launch.** Run the **Hermes Agent** workflow, pick the cluster you want it on,
and keep *Schedule Job?* **off** (Hermes stays on the login node, where it has
internet for its brain and the one-time install).

**2. Wait for it to be ready.** The first launch installs Hermes and can take a
few minutes; later launches reuse the install and start fast.

**3. Chat.** Open the platform **Chat**. The Hermes session appears as a
**provider** (named after the run); pick its model and start talking. Try:

- *"What's in my home directory on this cluster, and how much disk is free?"*
- *"Write a Python script that … and run it."*
- *"Submit my job in `~/runs/exp1` to SLURM and tell me the job ID."*
- *"Remember that my project deadline is Friday."* — then ask about it later.

## Settings

| Setting | What it does | Default |
|---|---|---|
| **Cluster** | Which cluster Hermes runs on | — |
| **Model** | The LLM behind Hermes (must support tool calling) | `org:glm/glm-5.1` |
| **AI allocation** | Which allocation model usage is billed to (for `org:*` models) | `Private LLM Group` |

## Good to know

- **This is the real, full Hermes** — memory, skills, cron, and code execution.
  It is *not* the lightweight [Python AI](../python-ai-agent/) chat agent; they
  only share a name. Hermes is a large app (Python + Node), so the first install
  is heavier.
- **Hermes can run arbitrary commands** on the cluster as you. Anyone allowed to
  use the chat provider can too — treat access accordingly.
- **The brain is the platform LLM endpoint** via the runtime `PW_API_KEY`; no
  external API key is needed. The key is written only to a per-run config in the
  job directory (never to `inputs.sh`) and is scrubbed on shutdown.
- **For long work, ask Hermes to submit and report back** (e.g. a job ID), then
  check on it later — it won't block waiting.
- **Advanced config:** Hermes reads `${PW_PARENT_JOB_DIR}/hermes-home/config.yaml`
  on the node; edit it there for power-user options (see the Hermes docs).

## Stopping

Cancel the workflow run from the platform when you're done — it stops Hermes and
the proxy and removes the session (and scrubs the key from disk).
