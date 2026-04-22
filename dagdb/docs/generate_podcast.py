#!/usr/bin/env python3
"""Generate the DagDB Bio-Twin podcast via the dialogue MCP HTTP bridge.

Output: ~/dialogue_output/dagdb_biotwin_podcast.mp3
"""

import json
import urllib.request

MCPO = "http://localhost:8787/dialogue"

SEGMENTS = [
    ["george", "Welcome back. Today we're going inside DagDB — a six-bounded ranked DAG database engine that Norayr Matevosyan has just used to model the human liver. I'm joined as always by our expert, Emma."],
    ["emma", "Thank you, George. Yes — we ran an end-to-end experiment this week. The question was simple: can a graph database whose every node is limited to at most six edges actually represent something as complex as a liver, and do so in a way that's both anatomically honest and computationally fast?"],
    ["george", "And the answer?"],
    ["emma", "The answer is yes — because liver physiology already has the six-bound baked in. Hepatocytes sit between at most six neighbours in the tissue. Six hepatocytes aggregate into a lobule. Three zones tile into an organ. DagDB didn't have to force anything. The constraint fits."],
    ["george", "Tell me about the experiment itself."],
    ["emma", "We built a seven-hundred-and-eleven-node ranked DAG. Six hundred hepatocytes, one hundred lobules, three zones — periportal, midzonal, and centrilobular — three functional outputs for detoxification, bile, and glucose regulation, and one root node representing overall liver health."],
    ["george", "Six ranks deep."],
    ["emma", "Six ranks. And the key architectural trick: we placed three systemic condition nodes — acetaminophen toxicity, hypoxia, and inflammation — above the hepatocytes in the rank hierarchy. Each hepatocyte subscribes to the signals that biology says are relevant for its zone. Zone three cells subscribe to all three. Zones one and two don't know about acetaminophen — they have no edge from that node."],
    ["george", "So the zone-specificity of damage lives in the edge pattern, not the cell."],
    ["emma", "Exactly. No per-cell code, no if-statements about zone identity. The topology is the semantics. When we flip the acetaminophen node on, only zone three cells respond — because only they have the incoming edge."],
    ["george", "How many cells died?"],
    ["emma", "Two hundred. Out of six hundred. In exactly seven milliseconds of graph evaluation. One single LUT flip propagated to two hundred subscribers in the next tick."],
    ["george", "And the organ itself?"],
    ["emma", "The organ survived. This is the genuinely elegant part. Zone three uses an OR gate — as long as any of its representative lobules survives, the zone still fires. And detoxification is an AND across three zones, so zones one and two keep detox alive. The liver tolerates thirty-three percent cell loss — which, clinically, is roughly what real livers can withstand."],
    ["george", "Graceful degradation."],
    ["emma", "Graceful degradation, by topology. Not a heuristic, not an exception case — it emerges from the gate choice at each rank."],
    ["george", "What breaks it?"],
    ["emma", "Stacking systemic signals. Hypoxia and inflammation are subscribed to by every hepatocyte, not just zone three. When you add hypoxia on top of the acetaminophen, all six hundred cells die, all one hundred lobules fail, all three zones collapse, and the liver root goes from ALIVE to FAILED. Again — seven milliseconds of evaluation."],
    ["george", "Recovery?"],
    ["emma", "Flip all three systemic nodes back to off. Five ticks. Complete restoration. Which is, of course, biologically unrealistic — dead hepatocytes don't resurrect. But it's architecturally honest: the graph has no hysteresis, no memory of damage beyond what's in the cell's own state."],
    ["george", "Let's talk performance. The session also benchmarked DagDB at scale."],
    ["emma", "Yes. Separate experiment, same engine. Ten million nodes. The snapshot format — we call it dot-dags — stores every GPU buffer in Morton order. Three-hundred-fifty-eight megabytes of raw state. With zlib compression it drops to fourteen point four megabytes — four percent of the raw size."],
    ["george", "Four percent. That's extreme."],
    ["emma", "It's because the neighbour table is mostly negative-one padding. Every node has six slots for edges, and most real graphs don't fill all six. Those runs of minus-one bytes compress to almost nothing."],
    ["george", "And evaluation?"],
    ["emma", "Eighteen point six milliseconds for one tick over ten million nodes. That's roughly five hundred and forty million node updates per second on a single Apple M5 Max laptop. Loading the compressed snapshot takes longer — about six and a half seconds — because we added a byte-level validator that runs before we copy anything into live GPU memory. A malformed snapshot can no longer corrupt a running graph."],
    ["george", "The validator checks what, exactly?"],
    ["emma", "Four invariants. Rank ordering — the DAG property — that the source of every edge has higher rank than its target. No self-loops. No duplicate edges in the same neighbour table. No out-of-range node IDs. All four are checked against the file's bytes directly before any memcpy happens."],
    ["george", "What isn't validated? What hasn't been proven?"],
    ["emma", "Several things. We haven't built motif or subgraph-match operators yet — those are the query primitives that would really distinguish DagDB from a Neo4j-style property-bag graph. Time-travel replay exists as a codec but hasn't been wired into the daemon as a verb. And there's a daemon boot hang above sixteen million nodes — a sizing limit we haven't diagnosed."],
    ["george", "Honest list."],
    ["emma", "It's an amateur engineering project. Numbers from one laptop, no peer review. The experiments are reproducible from the repository, and the open holes are documented in the repo as well."],
    ["george", "Last question. What did this experiment actually prove?"],
    ["emma", "That the six-bound isn't a limitation. It's a structural invariant that happens to match real biological hierarchy. That properties-as-nodes turns population-level state change into a constant-time write. And that a ranked DAG evaluator on an Apple GPU can run what might reasonably be called a bio-digital twin in milliseconds — not as a marketing claim, but as a measured result."],
    ["george", "Thank you, Emma. For the bio-twin experiment itself, the code is at github.com/norayr-m/slash-dagdb-engine. Listeners can also try the interactive explorer — the URL is in the show notes."],
    ["emma", "Thank you, George."],
]


def call(tool, payload):
    req = urllib.request.Request(
        f"{MCPO}/{tool}",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=300) as r:
        return r.read().decode()


def main():
    print("Generating DagDB bio-twin podcast...")
    print(f"  Segments: {len(SEGMENTS)}")
    print(f"  Speakers: george (interviewer), emma (expert)")

    response = call("dialogue_generate", {
        "segments": SEGMENTS,
        "title": "dagdb_biotwin_podcast",
        "speed": 0.95,
    })
    print(f"\n  {response}")


if __name__ == "__main__":
    main()
