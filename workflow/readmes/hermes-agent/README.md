# Hermes Agent

Run **[Hermes](https://github.com/NousResearch/hermes-agent)** — Nous Research's
self-improving AI agent — on one of your clusters. It runs real shell commands,
writes and runs code, remembers across sessions, and builds its own skills, using
the ACTIVATE platform LLM as its brain.

```
   You ─► ACTIVATE
            │  Interface (pick one):
            ├─► Web dashboard  → Hermes' native UI (Chat, skills, memory)   ◄ default
            │                    opens in your browser
            └─► Built-in chat  → Hermes appears as a model in ACTIVATE Chat
            │
            ▼
   ┌──────────────────────────────────────────────────────────┐
   │  Hermes  ·  on your cluster's login node                  │
   │  runs commands & code · remembers · builds skills · jobs  │
   └──────────────────────────────────────────────────────────┘
            │  brain
            ▼
   ACTIVATE platform LLM   (e.g. org:glm/glm-5.1)
```

## Use it

1. **Launch** the workflow, pick your **cluster**, keep *Schedule Job?* **off**.
2. **Wait** for *Session is ready* — the first launch installs Hermes (a few
   minutes); later launches are fast.
3. **Open it** — **Web dashboard** (default): the session opens Hermes' UI, use the
   **Chat** tab. **Built-in chat**: open ACTIVATE **Chat** and pick the Hermes provider.

Ask it things like:

- *"What's in my home directory, and how much disk is free?"*
- *"Write a script that … and run it."*
- *"Submit my job in `~/runs/exp1` to SLURM and give me the job ID."*
- *"Remember my deadline is Friday."* — then ask about it later.

## Settings

| Setting | What it does | Default |
|---|---|---|
| **Cluster** | Which cluster Hermes runs on | — |
| **Interface** | Web dashboard (native UI) or Built-in platform chat | Web dashboard |
| **Model** | The LLM behind Hermes (must support tool calling) | `org:glm/glm-5.1` |
| **AI allocation** | Which allocation model usage is billed to (for `org:*` models) | `Private LLM Group` |
| **Persona** | Hermes' personality + instructions (its `SOUL.md`) | generic cluster assistant |
| **Data directory** | Where history, skills, and memory live | `~/.hermes-agent` |
| **Start fresh** | Wipe the data directory before starting | off |

## Good to know

- **It runs commands on the cluster as you**, auto-approved (no prompts). Anyone
  who can reach the session/provider can too — treat access accordingly.
- **State persists.** History, skills, and memory live in the **Data directory** —
  **cancel to stop, rerun to resume** right where you left off. *Start fresh* wipes it.
- **No external key needed** — the brain is the platform LLM via the runtime key.
- **For long jobs**, ask Hermes to submit and report back, then check on it later.

## Stopping

Cancel the run to stop Hermes and remove the session. Your history, skills, and
memory stay in the Data directory — **rerun to resume**.
