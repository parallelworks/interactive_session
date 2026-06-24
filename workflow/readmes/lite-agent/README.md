# Lite Agent

A small AI agent on **one cluster**. Ask it about that machine in plain language —
it runs real shell commands there and answers from the output. Standard-library
only (nothing to install), with the ACTIVATE platform LLM as its brain.

```
   You ─► ACTIVATE chat ─► Lite Agent @ cluster
                              runs commands (df, squeue, nvidia-smi, …) and reports back
                              brain → ACTIVATE platform LLM
```

Pair it with the [Agent Orchestrator](../agent-orchestrator/) to talk to several
clusters at once. (For a much more capable agent — memory, skills, code execution,
a web UI — use the [Hermes Agent](../hermes-agent/) instead.)

## Use it

1. Launch **Lite Agent**, pick your **cluster**, keep *Schedule Job?* **off**.
2. Open ACTIVATE **Chat** and pick the `lite-agent` provider for that cluster.

Ask it things like *"How busy is this machine?"*, *"Is there a GPU?"*, *"Start my
script in `~/run` and give me the PID."*

## Fleets (the marker)

The **Fleet marker** (default `worker`) groups agents. An
[Agent Orchestrator](../agent-orchestrator/) launched with the same marker will
discover this agent and coordinate it with others. Use a custom value (e.g.
`gpuworker`) to keep separate fleets apart.

## Settings

| Setting | What it does | Default |
|---|---|---|
| **Cluster** | Which cluster the agent runs on | — |
| **Fleet marker** | Group label for orchestrator discovery | `worker` |
| **Model** | The LLM behind the agent (must support tool calling) | `org:glm/glm-5.1` |
| **AI allocation** | Which allocation usage is billed to (for `org:*` models) | `Private LLM Group` |

## Good to know

- It runs commands on the cluster **as you** — answers come from live output, not
  guesses. Anyone who can reach the session can run commands too.
- For long work, ask it to **submit** the job and report back, then check later.

## Stopping

Cancel the run to stop the agent and remove the session.
