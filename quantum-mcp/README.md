# quantum-mcp

An MCP server that lets your Agentics agents run experiments on IBM Quantum.

## What it does

Your agents can call three tools:

| Tool | What to say to your agent | What happens |
|---|---|---|
| `run_circuit` | "Run a GHZ state with 3 qubits" | Builds the circuit and runs it |
| `get_job_status` | "Check the status of job abc123" | Returns QUEUED / RUNNING / DONE |
| `get_job_result` | "Get the results of job abc123" | Returns measurement counts |

## Supported circuits (v1)

- **GHZ state** — entangles all qubits together ("Schrödinger's cat" at scale)
- **Bell pair** — entangles 2 qubits (the simplest entanglement)
- **Superposition** — puts every qubit in a 50/50 state
- Anything else defaults to superposition

## Setup

### 1. Install dependencies

```bash
cd quantum-mcp
pip install -r requirements.txt
```

### 2. Get your IBM Quantum token (free)

1. Go to [quantum.ibm.com](https://quantum.ibm.com) and create a free account
2. Copy your API token from your account dashboard

### 3. Set your token

```bash
export IBM_QUANTUM_TOKEN="your_token_here"
```

To make this permanent, add that line to your `~/.zshrc` file.

### 4. Run the server

```bash
python server.py
```

### 5. Wire it into Claude Code

Add this to your `~/.claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "quantum": {
      "command": "python",
      "args": ["/path/to/quantum-mcp/server.py"],
      "env": {
        "IBM_QUANTUM_TOKEN": "your_token_here"
      }
    }
  }
}
```

## Try it without an IBM account first

By default, `run_circuit` uses a **local simulator** — no IBM account needed. Just install the dependencies and ask your agent:

> "Run a Bell pair simulation"

You'll get real quantum measurement results instantly, running entirely on your Mac.

When you're ready to run on a real quantum computer, set `use_simulator: false` in your request.
