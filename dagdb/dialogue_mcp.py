#!/usr/bin/env python3
"""Dialogue MCP — Generate two-voice podcasts from scripts.

Any LLM can call this MCP to turn a dialogue script into an audio podcast.
George = interviewer (bm_george), Emma = expert (bf_emma). Kokoro + ffmpeg.

Tools:
  dialogue_generate(segments, title, out_dir)  — create a podcast from a list of (speaker, text) pairs
  dialogue_quick(topic, style)                 — LLM crafts the dialogue, this MCP voices it
  dialogue_single(voice, text)                 — one-off voice clip
  dialogue_voices()                            — list available Kokoro voices
"""

import subprocess
import os
import sys
import json
from pathlib import Path

try:
    from mcp.server.fastmcp import FastMCP
except ImportError:
    print("Installing mcp...")
    subprocess.check_call([sys.executable, "-m", "pip", "install", "--break-system-packages", "mcp[cli]"])
    from mcp.server.fastmcp import FastMCP

OUT_BASE = os.path.expanduser("~/dialogue_output")
os.makedirs(OUT_BASE, exist_ok=True)

VOICES = {
    "george":   "bm_george",    # British male, warm
    "emma":     "bf_emma",       # British female, clear
    "lewis":    "bm_lewis",      # British male (if available)
    "bella":    "af_bella",      # American female
    "michael":  "am_michael",    # American male
}

mcp = FastMCP("dialogue", instructions="""
Generate two-voice podcast audio from dialogue scripts.
George and Emma are the default pair (British male interviewer + British female expert).
Output is MP3, 128kbps. Files saved to ~/dialogue_output/.
""")

def _run_kokoro(voice: str, text: str, out_path: str, speed: float = 1.0) -> bool:
    """Generate one WAV clip. Returns True on success."""
    try:
        subprocess.run(
            ["kokoro", "-m", voice, "-s", str(speed), "-t", text, "-o", out_path],
            check=True, capture_output=True, timeout=300
        )
        return True
    except Exception as e:
        print(f"  Kokoro error: {e}")
        return False

def _concat_and_encode(wav_files: list, out_mp3: str) -> float:
    """Concatenate WAVs and encode to MP3. Returns duration in seconds."""
    list_file = out_mp3.replace(".mp3", "_list.txt")
    with open(list_file, "w") as f:
        for w in wav_files:
            f.write(f"file '{w}'\n")

    concat_wav = out_mp3.replace(".mp3", "_full.wav")

    subprocess.run([
        "ffmpeg", "-y", "-f", "concat", "-safe", "0",
        "-i", list_file, "-codec:a", "pcm_s16le", concat_wav
    ], capture_output=True)

    subprocess.run([
        "ffmpeg", "-y", "-i", concat_wav,
        "-codec:a", "libmp3lame", "-b:a", "128k", out_mp3
    ], capture_output=True)

    # Duration
    result = subprocess.run([
        "ffprobe", "-v", "quiet", "-print_format", "json",
        "-show_entries", "format=duration", out_mp3
    ], capture_output=True, text=True)
    duration = float(json.loads(result.stdout)["format"]["duration"])

    # Cleanup
    os.remove(list_file)
    os.remove(concat_wav)

    return duration


@mcp.tool()
def dialogue_generate(segments: list, title: str = "dialogue", speed: float = 0.95) -> str:
    """Generate a two-voice podcast from a list of (speaker, text) segments.

    Args:
        segments: list of [speaker, text] pairs. Speaker is one of: george, emma, lewis, bella, michael.
        title: base name for the output file.
        speed: playback speed (0.8 = slow, 1.0 = normal, 1.2 = fast).

    Returns: path to the MP3, duration, and segment count.
    """
    if not segments:
        return "ERROR: no segments provided"

    safe_title = "".join(c if c.isalnum() or c in "_-" else "_" for c in title)
    out_dir = os.path.join(OUT_BASE, safe_title)
    os.makedirs(out_dir, exist_ok=True)

    wav_files = []
    for i, seg in enumerate(segments):
        if len(seg) != 2:
            return f"ERROR: segment {i} must be [speaker, text]"
        speaker, text = seg
        voice = VOICES.get(speaker.lower())
        if not voice:
            return f"ERROR: unknown speaker '{speaker}'. Use: {', '.join(VOICES.keys())}"

        wav = os.path.join(out_dir, f"seg_{i:03d}_{speaker}.wav")
        if not _run_kokoro(voice, text, wav, speed):
            return f"ERROR: failed to generate segment {i}"
        wav_files.append(wav)

    mp3 = os.path.join(OUT_BASE, f"{safe_title}.mp3")
    duration = _concat_and_encode(wav_files, mp3)

    mins = int(duration // 60)
    secs = int(duration % 60)

    return json.dumps({
        "file": mp3,
        "duration_seconds": duration,
        "duration_formatted": f"{mins}m {secs}s",
        "segments": len(segments),
        "speakers": list(set(s[0] for s in segments)),
    }, indent=2)


@mcp.tool()
def dialogue_single(voice: str, text: str, filename: str = "voice_clip", speed: float = 0.95) -> str:
    """Generate a single voice clip (no dialogue, just one speaker).

    Args:
        voice: one of george, emma, lewis, bella, michael.
        text: what to say.
        filename: base name for the output.
        speed: playback speed.
    """
    v = VOICES.get(voice.lower())
    if not v:
        return f"ERROR: unknown voice '{voice}'. Use: {', '.join(VOICES.keys())}"

    safe = "".join(c if c.isalnum() or c in "_-" else "_" for c in filename)
    out_wav = os.path.join(OUT_BASE, f"{safe}.wav")
    out_mp3 = os.path.join(OUT_BASE, f"{safe}.mp3")

    if not _run_kokoro(v, text, out_wav, speed):
        return "ERROR: failed to generate"

    subprocess.run([
        "ffmpeg", "-y", "-i", out_wav,
        "-codec:a", "libmp3lame", "-b:a", "128k", out_mp3
    ], capture_output=True)
    os.remove(out_wav)

    return json.dumps({"file": out_mp3, "voice": voice, "text_length": len(text)}, indent=2)


@mcp.tool()
def dialogue_voices() -> str:
    """List available Kokoro voices with descriptions."""
    return json.dumps({
        "george": "British male, warm, best as interviewer",
        "emma": "British female, clear, best as expert",
        "lewis": "British male (alternative)",
        "bella": "American female",
        "michael": "American male",
    }, indent=2)


@mcp.tool()
def dialogue_play(filepath: str) -> str:
    """Play an MP3 or WAV file through the speakers (macOS afplay)."""
    if not os.path.exists(filepath):
        return f"ERROR: file not found: {filepath}"
    subprocess.Popen(["afplay", filepath])
    return f"Playing {filepath}"


if __name__ == "__main__":
    # Verify Kokoro is installed
    try:
        subprocess.run(["kokoro", "--help"], capture_output=True, check=True)
    except Exception:
        print("WARNING: Kokoro not found. Install: pip install kokoro")

    print(f"Dialogue MCP starting. Output dir: {OUT_BASE}")
    mcp.run(transport="stdio")
