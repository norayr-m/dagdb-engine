#!/usr/bin/env python3
"""Image MCP — Generate images via local FLUX (mflux) on Apple Silicon.

Any LLM can request image generation. Saves PNG to ~/image_output/.
Uses FLUX.1-schnell (fast, 4 steps) by default, FLUX.1-dev for quality.

Tools:
  image_generate(prompt, filename, steps, seed)  — generate a PNG
  image_list()                                    — list generated images
  image_show(filepath)                            — open in default viewer
"""

import subprocess
import os
import sys
import json
from pathlib import Path

try:
    from mcp.server.fastmcp import FastMCP
except ImportError:
    subprocess.check_call([sys.executable, "-m", "pip", "install", "--break-system-packages", "mcp[cli]"])
    from mcp.server.fastmcp import FastMCP

OUT_BASE = os.path.expanduser("~/image_output")
os.makedirs(OUT_BASE, exist_ok=True)

MFLUX = os.path.expanduser("~/.local/bin/mflux-generate")

mcp = FastMCP("image", instructions="""
Generate images via local FLUX on Apple Silicon (no API, no cost).
Default model: FLUX.1-schnell (4 steps, ~15 seconds on M5 Max).
Images saved to ~/image_output/ as PNG.
""")


@mcp.tool()
def image_generate(
    prompt: str,
    filename: str = "image",
    steps: int = 4,
    seed: int = 0,
    width: int = 1024,
    height: int = 1024,
    quality: bool = False,
) -> str:
    """Generate an image from a text prompt using local FLUX.

    Args:
        prompt: what to generate. Detailed descriptions work best.
        filename: base name for the output (no extension).
        steps: inference steps. 4 for schnell (fast), 20-50 for dev (quality).
        seed: random seed. 0 for random.
        width: image width in pixels (default 1024).
        height: image height in pixels (default 1024).
        quality: use FLUX.1-dev (slower, higher quality) instead of schnell.

    Returns: path to the generated PNG and generation metadata.
    """
    safe = "".join(c if c.isalnum() or c in "_-" else "_" for c in filename)
    out_path = os.path.join(OUT_BASE, f"{safe}.png")

    model = "dev" if quality else "schnell"
    actual_steps = steps if not quality else max(steps, 20)

    args = [
        MFLUX,
        "--prompt", prompt,
        "--model", model,
        "--steps", str(actual_steps),
        "--width", str(width),
        "--height", str(height),
        "--output", out_path,
    ]
    if seed > 0:
        args.extend(["--seed", str(seed)])

    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=180)
        if result.returncode != 0:
            return f"ERROR: {result.stderr[-500:]}"
    except subprocess.TimeoutExpired:
        return "ERROR: generation timed out (3 min)"
    except Exception as e:
        return f"ERROR: {e}"

    if not os.path.exists(out_path):
        return f"ERROR: output file not created. stderr: {result.stderr[-300:]}"

    size_kb = os.path.getsize(out_path) // 1024
    return json.dumps({
        "file": out_path,
        "prompt": prompt,
        "model": model,
        "steps": actual_steps,
        "dimensions": f"{width}x{height}",
        "size_kb": size_kb,
    }, indent=2)


@mcp.tool()
def image_list() -> str:
    """List all generated images in ~/image_output/."""
    files = []
    for f in sorted(os.listdir(OUT_BASE)):
        if f.endswith(".png"):
            path = os.path.join(OUT_BASE, f)
            files.append({
                "name": f,
                "path": path,
                "size_kb": os.path.getsize(path) // 1024,
            })
    return json.dumps({"count": len(files), "images": files}, indent=2)


@mcp.tool()
def image_show(filepath: str) -> str:
    """Open an image file in the default viewer (Preview on macOS)."""
    if not os.path.exists(filepath):
        return f"ERROR: file not found: {filepath}"
    subprocess.Popen(["open", filepath])
    return f"Opened {filepath}"


if __name__ == "__main__":
    if not os.path.exists(MFLUX):
        print(f"WARNING: mflux-generate not found at {MFLUX}")
        print("Install: pip install mflux")

    print(f"Image MCP starting. Output dir: {OUT_BASE}")
    mcp.run(transport="stdio")
