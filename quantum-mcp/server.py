import os
import json
from mcp.server.fastmcp import FastMCP
from qiskit import QuantumCircuit
from qiskit_ibm_runtime import QiskitRuntimeService, SamplerV2 as Sampler
from qiskit_ibm_runtime.fake_provider import FakeManilaV2

mcp = FastMCP("quantum-mcp")

IBM_TOKEN = os.environ.get("IBM_QUANTUM_TOKEN")

def _get_service():
    if IBM_TOKEN:
        return QiskitRuntimeService(channel="ibm_quantum", token=IBM_TOKEN)
    return None


def _build_circuit(description: str, num_qubits: int) -> QuantumCircuit:
    """Build a named circuit from a plain-English description."""
    desc = description.lower()
    qc = QuantumCircuit(num_qubits, num_qubits)

    if "ghz" in desc:
        qc.h(0)
        for i in range(num_qubits - 1):
            qc.cx(i, i + 1)
    elif "bell" in desc:
        qc.h(0)
        qc.cx(0, 1)
    elif "superposition" in desc:
        for i in range(num_qubits):
            qc.h(i)
    else:
        # Default: put every qubit in superposition
        for i in range(num_qubits):
            qc.h(i)

    qc.measure_all()
    return qc


@mcp.tool()
def run_circuit(description: str, num_qubits: int = 2, use_simulator: bool = True) -> str:
    """
    Build and run a quantum circuit on IBM Quantum.

    Args:
        description: Plain-English circuit name, e.g. "GHZ state", "Bell pair", "superposition"
        num_qubits: Number of qubits (default 2, max 5 for free tier)
        use_simulator: If True (default), run on a local simulator — no IBM account needed.
                       Set to False to submit to a real IBM Quantum device.

    Returns:
        JSON string with job_id and initial status, or full results if using simulator.
    """
    qc = _build_circuit(description, num_qubits)

    if use_simulator:
        backend = FakeManilaV2()
        sampler = Sampler(backend)
        job = sampler.run([qc], shots=1024)
        result = job.result()
        counts = result[0].data.meas.get_counts()
        return json.dumps({
            "mode": "simulator",
            "description": description,
            "num_qubits": num_qubits,
            "shots": 1024,
            "counts": counts,
            "message": "Simulation complete. These are the measurement outcomes across 1024 shots."
        }, indent=2)

    # Real IBM Quantum device
    service = _get_service()
    if service is None:
        return json.dumps({"error": "IBM_QUANTUM_TOKEN environment variable not set."})

    backend = service.least_busy(operational=True, simulator=False)
    sampler = Sampler(backend)
    job = sampler.run([qc], shots=1024)
    return json.dumps({
        "mode": "real_device",
        "job_id": job.job_id(),
        "backend": backend.name,
        "status": "QUEUED",
        "message": "Job submitted. Use get_job_status and get_job_result with the job_id."
    }, indent=2)


@mcp.tool()
def get_job_status(job_id: str) -> str:
    """
    Check the status of a previously submitted IBM Quantum job.

    Args:
        job_id: The job ID returned by run_circuit

    Returns:
        JSON string with current job status (QUEUED, RUNNING, DONE, ERROR, CANCELLED)
    """
    service = _get_service()
    if service is None:
        return json.dumps({"error": "IBM_QUANTUM_TOKEN environment variable not set."})

    job = service.job(job_id)
    return json.dumps({
        "job_id": job_id,
        "status": str(job.status()),
        "backend": job.backend().name
    }, indent=2)


@mcp.tool()
def get_job_result(job_id: str) -> str:
    """
    Retrieve the results of a completed IBM Quantum job.

    Args:
        job_id: The job ID returned by run_circuit

    Returns:
        JSON string with measurement counts — how many times each qubit pattern was observed.
        For example {"00": 512, "11": 512} means the qubits were entangled (a Bell pair).
    """
    service = _get_service()
    if service is None:
        return json.dumps({"error": "IBM_QUANTUM_TOKEN environment variable not set."})

    job = service.job(job_id)
    status = str(job.status())

    if status != "DONE":
        return json.dumps({
            "job_id": job_id,
            "status": status,
            "message": "Job is not done yet. Check back with get_job_status."
        }, indent=2)

    result = job.result()
    counts = result[0].data.meas.get_counts()
    return json.dumps({
        "job_id": job_id,
        "status": "DONE",
        "counts": counts,
        "message": "These are the measurement outcomes. Each key is a qubit pattern, each value is how many times it appeared."
    }, indent=2)


if __name__ == "__main__":
    mcp.run(transport="stdio")
