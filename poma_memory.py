#!/usr/bin/env python3
"""poma-memory — structure-preserving markdown memory for AI agents.

Built on POMA AI's structural chunking methodology. Provides:
- Structure-preserving chunker: depth-annotated chunks (not linear splitting)
- Chunksets: root-to-leaf paths preserving hierarchical context
- Cheatsheet assembly: multiple chunkset hits merged per file, deduplicated,
  with [...] gap markers — one compact context block per document
- Semantic search: OpenAI text-embedding-3-large (if OPENAI_API_KEY set) or
  model2vec (30MB local model, no API key) — auto-selected at runtime
- SQLite storage with incremental indexing
- MCP server (poma_index, poma_search, poma_status tools)
- CLI: python poma_memory.py {index|search|status} [args]

Dependencies:
  Required: numpy, model2vec
  Optional: openai (uses text-embedding-3-large when OPENAI_API_KEY is set)
  Optional: mcp (for MCP server — `pip install "mcp>=1.2.0"`)
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import re
import sqlite3
import sys
from pathlib import Path
from typing import Any

import numpy as np

# ═══════════════════════════════════════════════════════════════════════
# Constants
# ═══════════════════════════════════════════════════════════════════════

ELLIPSIS_MARKER = "[...]"
_WORD_LIMIT = 350  # ~500 tokens ≈ 350 words (avoids tiktoken dep)


# ═══════════════════════════════════════════════════════════════════════
# Text normalization — produces clean embedding-ready text
# ═══════════════════════════════════════════════════════════════════════

import html as _html_mod
import unicodedata as _unicodedata


def normalize_for_embedding(text: str) -> str:
    """Produce embedding-ready text from chunk/chunkset contents.

    Matches poma-core's normalize_for_embedding():
    HTML strip (table-aware) → NFKD → whitespace collapse → thousand-separator removal.
    """
    if not text:
        return text
    # Strip HTML (table-aware)
    if "<table" in text.lower():
        text = re.sub(r"<(script|style)[\s\S]*?</\1>", "", text, flags=re.I)
        text = re.sub(r"</t[dh]>\s*", "\t", text, flags=re.I)
        text = re.sub(r"</tr>\s*", "\n", text, flags=re.I)
        text = re.sub(r"<tr[^>]*>\s*", "", text, flags=re.I)
        text = re.sub(r"<t[dh][^>]*>\s*", "", text, flags=re.I)
        text = re.sub(r"<[^>]+>", "", text)
        text = _html_mod.unescape(text)
        text = re.sub(r"[ \t]+", " ", text)
        text = re.sub(r"\n\s*\n+", "\n\n", text)
    else:
        text = re.sub(r"<(script|style)[\s\S]*?</\1>", "", text, flags=re.I)
        text = re.sub(r"<[^>]+>", "", text)
        text = _html_mod.unescape(text)
        text = re.sub(r"\s+", " ", text)
    # Unicode NFKD
    text = _unicodedata.normalize("NFKD", text)
    # Whitespace normalization
    text = re.sub(r"\r\n|\r", "\n", text)
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    # Thousand separator removal (improves numeric embedding quality)
    for _ in range(5):
        text = re.sub(r"(\d),(\d{3})(?=[,.\s\)\]\}]|$)", r"\1\2", text)
    for _ in range(5):
        text = re.sub(r"(\d)\.(\d{3})(?=[.,\s\)\]\}]|$)", r"\1\2", text)
    return text.strip()

# ═══════════════════════════════════════════════════════════════════════
# Chunker — heuristic markdown → depth-annotated arrow-prefixed text
# ═══════════════════════════════════════════════════════════════════════

# --- Regex patterns ---

_ATX_HEADING_RE = re.compile(r"^[ \t]{0,3}(#{1,6})[ \t]+(.*?)[ \t]*#*[ \t]*$")
_THEMATIC_BREAK_RE = re.compile(r"^[ \t]{0,3}((\*\s*){3,}|(-\s*){3,}|(_\s*){3,})\s*$")
_UL_ITEM_RE = re.compile(r"^([ \t]{0,})([-*+•])[ \t]+(.*)$")
_OL_ITEM_RE = re.compile(r"^([ \t]{0,})(\d+)[.)][ \t]+(.*)$")
_FENCE_OPEN_RE = re.compile(r"^[ \t]*(?P<tick>`{3,}|~{3,})(?P<info>.*)$")
_LINK_LINE_RE = re.compile(r"^\s*(?:https?://\S+|\[[^\]]+\]\([^)]+\))\s*$")
_MD_TABLE_ROW_RE = re.compile(r"^\s*\|.*\|\s*$")
_MD_TABLE_SEP_RE = re.compile(r"^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$")
_INDENTED_CODE_RE = re.compile(r"^(?: {4}|\t)")

_SENT_SPLIT_RE = re.compile(
    r"([.!?。！？]+)\s+(?=(?:[A-ZÀ-ÝÄÖÜÇÑ0-9\"\'\"\"\'\'\(\[\{]|[-*•]))"
)
_CLAUSE_BOUNDARY_RE = re.compile(r"(?s)(.*?)([;:,，、；：]+)(\s+|$)")

_ABBR = {
    "dr.", "mr.", "mrs.", "ms.", "prof.", "sr.", "jr.", "etc.", "e.g.", "i.e.",
    "no.", "fig.", "eq.", "sec.", "ch.", "vol.", "vs.", "inc.", "ltd.", "corp.",
    "st.", "ave.", "blvd.", "u.s.", "v.", "cf.", "pp.", "ed.", "rev.",
}


def _wordlen(s: str) -> int:
    """Approximate token count using word count."""
    return len(s.split())


def indent_light(text: str, *, extract_title: bool = True) -> str:
    """Parse markdown into depth-annotated arrow-prefixed lines."""
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    events = _scan_events(text)

    if extract_title:
        maybe_title, events = _extract_title(events)
    else:
        maybe_title = None

    out: list[str] = []

    def emit(depth: int, s: str) -> None:
        s = s.rstrip("\n")
        if s:
            out.append(("→" * max(0, depth)) + s)

    current_heading_depth = 0
    colon_parent_depth: int | None = None
    last_anchor_depth = 0

    if extract_title:
        emit(0, maybe_title or "")
        current_heading_depth = 0
        last_anchor_depth = 0

    def body_depth() -> int:
        d = max(1, current_heading_depth + 1)
        if colon_parent_depth is not None:
            d = max(d, colon_parent_depth + 1)
        return d

    for ev in events:
        kind = ev[0]
        line = ev[1]

        if kind == "blank":
            colon_parent_depth = None
            continue

        if kind == "thematic":
            colon_parent_depth = None
            continue

        if kind == "code_fence":
            d = body_depth() + 1
            for piece, delta in _enforce_limit(line):
                emit(d + delta, piece)
            last_anchor_depth = d
            continue

        if kind == "table_block":
            d = body_depth() + 1
            for piece, delta in _enforce_limit(line):
                emit(d + delta, piece)
            last_anchor_depth = d
            continue

        if kind == "heading":
            colon_parent_depth = None
            md_level = ev[2]
            depth = max(1, md_level - 1)
            current_heading_depth = depth
            emit(depth, line)
            last_anchor_depth = depth
            continue

        if kind == "line":
            # Lists
            mul = _UL_ITEM_RE.match(line)
            mol = _OL_ITEM_RE.match(line)
            if mul or mol:
                base = body_depth() + (0 if colon_parent_depth is not None else 1)
                if mul:
                    indent_raw, marker, rest = mul.group(1), mul.group(2), mul.group(3)
                    nest = max(0, len(indent_raw.replace("\t", "    ")) // 2)
                    d = base + nest
                    _emit_list_item(d, f"{marker} {rest}", emit)
                else:
                    indent_raw, num, rest = mol.group(1), mol.group(2), mol.group(3)
                    nest = max(0, len(indent_raw.replace("\t", "    ")) // 2)
                    d = base + nest
                    _emit_list_item(d, f"{num}. {rest}", emit)
                last_anchor_depth = base
                colon_parent_depth = None
                continue

            # Standalone link
            if _LINK_LINE_RE.match(line):
                d = body_depth()
                emit(d, line)
                last_anchor_depth = d
                colon_parent_depth = None
                continue

            # Normal text: sentence split
            d = body_depth()
            sentences = _split_sentences(line)
            if not sentences:
                for piece, delta in _enforce_limit(line):
                    emit(d + delta, piece)
            else:
                for s in sentences:
                    for piece, delta in _enforce_limit(s):
                        emit(d + delta, piece)
                    if s.rstrip().endswith((":", "：")):
                        colon_parent_depth = d
                    elif colon_parent_depth == d:
                        colon_parent_depth = None
            last_anchor_depth = d
            continue

    return "\n".join(out)


def _scan_events(text: str) -> list[tuple]:
    """Scan markdown into typed events."""
    lines = text.split("\n")
    events: list[tuple] = []
    i = 0

    while i < len(lines):
        line = lines[i]

        if not line.strip():
            events.append(("blank", "", None))
            i += 1
            continue

        if _THEMATIC_BREAK_RE.match(line):
            events.append(("thematic", "", None))
            i += 1
            continue

        m_open = _FENCE_OPEN_RE.match(line)
        if m_open:
            tick = m_open.group("tick")
            fence_char = tick[0]
            fence_len = len(tick)
            buf = [line]
            i += 1
            while i < len(lines):
                ln = lines[i]
                buf.append(ln)
                if re.match(
                    rf"^[ \t]*{re.escape(fence_char)}{{{fence_len},}}[ \t]*$",
                    ln.strip(),
                ):
                    i += 1
                    break
                i += 1
            events.append(("code_fence", "\n".join(buf), None))
            continue

        mh = _ATX_HEADING_RE.match(line)
        if mh:
            level = len(mh.group(1))
            events.append(("heading", mh.group(2), level))
            i += 1
            continue

        # Markdown pipe tables
        if _MD_TABLE_ROW_RE.match(line):
            buf = [line]
            i += 1
            while i < len(lines) and lines[i].strip():
                ln = lines[i]
                if _MD_TABLE_ROW_RE.match(ln) or _MD_TABLE_SEP_RE.match(ln):
                    buf.append(ln)
                    i += 1
                    continue
                break
            events.append(("table_block", "\n".join(buf), None))
            continue

        # Indented code blocks
        if _INDENTED_CODE_RE.match(line):
            buf = [line]
            i += 1
            while i < len(lines) and (
                _INDENTED_CODE_RE.match(lines[i]) or not lines[i].strip()
            ):
                buf.append(lines[i])
                i += 1
            events.append(("code_fence", "\n".join(buf), None))
            continue

        events.append(("line", line, None))
        i += 1

    return events


def _extract_title(events: list[tuple]) -> tuple[str | None, list[tuple]]:
    for idx, ev in enumerate(events):
        if ev[0] == "heading":
            return ev[1].strip(), events[:idx] + events[idx + 1:]
        if ev[0] == "line" and ev[1].strip():
            sents = _split_sentences(ev[1].strip())
            if sents:
                title = sents[0].strip()
                rest = sents[1].strip() if len(sents) > 1 else ""
                new_events = (
                    events[:idx]
                    + ([("line", rest, None)] if rest else [])
                    + events[idx + 1:]
                )
                return title, new_events
            return ev[1].strip(), events[:idx] + events[idx + 1:]
    return None, events


def _split_sentences(line: str) -> list[str]:
    s = line.strip("\n")
    parts: list[str] = []
    start = 0
    for m in _SENT_SPLIT_RE.finditer(s):
        prefix = s[start: m.start(1)].rstrip()
        words = prefix.split()
        last_word = words[-1].lower() if words else ""
        last_with_punct = last_word + m.group(1)[0] if last_word else ""
        if last_with_punct in _ABBR:
            continue
        end = m.end(1)
        parts.append(s[start:end] + " ")
        start = m.end()
    tail = s[start:]
    if tail:
        parts.append(tail)
    return [p for p in parts if p.strip()]


def _enforce_limit(text: str) -> list[tuple[str, int]]:
    """Split text exceeding word limit. Returns [(piece, delta_depth)]."""
    if _wordlen(text) <= _WORD_LIMIT:
        return [(text, 0)]
    # Split by clauses first
    clauses = _split_clauses(text)
    if len(clauses) > 1 and all(_wordlen(c) <= _WORD_LIMIT for c in clauses):
        return [(clauses[0], 0)] + [(c, 1) for c in clauses[1:]]
    # Fallback: word-boundary split
    return _word_split(text)


def _split_clauses(text: str) -> list[str]:
    s = text
    out: list[str] = []
    pos = 0
    while pos < len(s):
        m = _CLAUSE_BOUNDARY_RE.match(s, pos)
        if not m:
            tail = s[pos:]
            if tail:
                out.append(tail)
            break
        body, punct, ws = m.group(1), m.group(2), m.group(3)
        seg = body + punct + ws
        if seg:
            out.append(seg)
        pos = m.end()
        if pos >= len(s):
            break
    return [x for x in out if x]


def _word_split(text: str) -> list[tuple[str, int]]:
    words = text.split()
    pieces: list[str] = []
    current: list[str] = []
    for word in words:
        current.append(word)
        if _wordlen(" ".join(current)) > _WORD_LIMIT:
            if len(current) > 1:
                current.pop()
                pieces.append(" ".join(current))
                current = [word]
            else:
                pieces.append(" ".join(current))
                current = []
    if current:
        pieces.append(" ".join(current))
    if not pieces:
        return [(text, 0)]
    return [(pieces[0], 0)] + [(p, 1) for p in pieces[1:]]


def _emit_list_item(depth: int, item_text: str, emit) -> None:
    parts = item_text.split(" ", 1)
    if len(parts) == 1:
        for piece, delta in _enforce_limit(item_text):
            emit(depth + delta, piece)
        return
    marker, rest = parts[0], parts[1]
    sents = _split_sentences(rest)
    if not sents:
        for piece, delta in _enforce_limit(item_text):
            emit(depth + delta, piece)
        return
    first = marker + " " + sents[0]
    for piece, delta in _enforce_limit(first):
        emit(depth + delta, piece)
    for s in sents[1:]:
        for piece, delta in _enforce_limit(s):
            emit(depth + delta, piece)


# ═══════════════════════════════════════════════════════════════════════
# Tree — parse arrow-prefixed text into chunks with parent linkage
# ═══════════════════════════════════════════════════════════════════════


def parse_indented_text(arrow_text: str) -> list[dict]:
    """Parse arrow-prefixed text into chunk dicts: [{chunk_index, content, depth}]."""
    chunks = []
    for line in arrow_text.split("\n"):
        if not line.strip():
            continue
        depth = 0
        while depth < len(line) and line[depth] == "→":
            depth += 1
        content = line[depth:]
        if content.strip():
            chunks.append({"chunk_index": len(chunks), "content": content, "depth": depth})
    return chunks


def normalize_depths(chunks: list[dict]) -> list[dict]:
    """Assign parent_chunk_index based on depth hierarchy."""
    stack: list[tuple[int, int]] = []
    for chunk in chunks:
        depth = chunk["depth"]
        while stack and stack[-1][0] >= depth:
            stack.pop()
        chunk["parent_chunk_index"] = stack[-1][1] if stack else None
        stack.append((depth, chunk["chunk_index"]))
    return chunks


# ═══════════════════════════════════════════════════════════════════════
# Chunksets — root-to-leaf path grouping for retrieval
# ═══════════════════════════════════════════════════════════════════════


def _build_ancestor_maps(chunks: list[dict]):
    parent_by_index = {c["chunk_index"]: c.get("parent_chunk_index") for c in chunks}
    ancestors_by_index = {}
    for chunk in chunks:
        idx = chunk["chunk_index"]
        ancestors = []
        current = parent_by_index.get(idx)
        while current is not None:
            ancestors.append(current)
            current = parent_by_index.get(current)
        ancestors_by_index[idx] = tuple(reversed(ancestors))
    return parent_by_index, ancestors_by_index


def chunks_to_chunksets(chunks: list[dict]) -> list[dict]:
    """Group leaf chunks with ancestors into self-contained retrieval units."""
    if not chunks:
        return []

    parent_map, ancestor_map = _build_ancestor_maps(chunks)

    children: dict[int, list[int]] = {}
    for c in chunks:
        children.setdefault(c["chunk_index"], [])
        parent = c.get("parent_chunk_index")
        if parent is not None:
            children.setdefault(parent, []).append(c["chunk_index"])

    leaves = [c["chunk_index"] for c in chunks if not children.get(c["chunk_index"])]
    chunk_by_idx = {c["chunk_index"]: c for c in chunks}
    chunksets: list[dict] = []
    current_group: list[int] = []
    current_parent: int | None = None

    def flush():
        nonlocal current_group, current_parent
        if not current_group:
            return
        ancestors = list(ancestor_map.get(current_group[0], ()))
        chunk_ids = ancestors + current_group
        seen: set[int] = set()
        unique: list[int] = []
        for cid in chunk_ids:
            if cid not in seen:
                seen.add(cid)
                unique.append(cid)
        contents = "\n".join(
            chunk_by_idx[cid]["content"] for cid in unique if cid in chunk_by_idx
        )
        chunksets.append({
            "chunkset_index": len(chunksets),
            "chunk_ids": unique,
            "contents": contents,
            "to_embed": normalize_for_embedding(contents),
        })
        current_group = []
        current_parent = None

    for leaf_idx in leaves:
        leaf_parent = parent_map.get(leaf_idx)
        if current_parent is not None and leaf_parent != current_parent:
            flush()
        current_group.append(leaf_idx)
        current_parent = leaf_parent

    flush()
    return chunksets


# ═══════════════════════════════════════════════════════════════════════
# Store — SQLite + FTS5 storage
# ═══════════════════════════════════════════════════════════════════════

_SCHEMA = """
CREATE TABLE IF NOT EXISTS files (
    file_path    TEXT PRIMARY KEY,
    byte_offset  INTEGER NOT NULL DEFAULT 0,
    content_hash TEXT NOT NULL DEFAULT '',
    mtime        REAL NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS chunks (
    chunk_id         INTEGER PRIMARY KEY AUTOINCREMENT,
    file_path        TEXT NOT NULL,
    local_index      INTEGER NOT NULL,
    content          TEXT NOT NULL,
    depth            INTEGER NOT NULL,
    parent_chunk_id  INTEGER,
    embedding        BLOB,
    UNIQUE(file_path, local_index)
);

CREATE TABLE IF NOT EXISTS chunksets (
    chunkset_id  INTEGER PRIMARY KEY AUTOINCREMENT,
    file_path    TEXT NOT NULL,
    local_index  INTEGER NOT NULL,
    chunk_ids    TEXT NOT NULL,
    contents     TEXT NOT NULL,
    to_embed     TEXT NOT NULL DEFAULT '',
    embedding    BLOB,
    UNIQUE(file_path, local_index)
);

"""


class Store:
    """SQLite + FTS5 storage for poma-memory."""

    def __init__(self, db_path: str | Path):
        self.db_path = Path(db_path)
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self._conn = sqlite3.connect(str(self.db_path))
        self._conn.row_factory = sqlite3.Row
        self._conn.execute("PRAGMA journal_mode=WAL")
        self._conn.execute("PRAGMA foreign_keys=ON")
        self._conn.executescript(_SCHEMA)
        # Migrate: add to_embed column if missing (existing DBs pre-v3.1)
        cols = {r[1] for r in self._conn.execute("PRAGMA table_info(chunksets)").fetchall()}
        if "to_embed" not in cols:
            self._conn.execute("ALTER TABLE chunksets ADD COLUMN to_embed TEXT NOT NULL DEFAULT ''")
            # Backfill to_embed from contents for existing rows
            self._conn.execute("UPDATE chunksets SET to_embed = contents WHERE to_embed = ''")
        self._conn.commit()

    def close(self):
        self._conn.close()

    def get_file_record(self, file_path: str) -> dict | None:
        row = self._conn.execute(
            "SELECT * FROM files WHERE file_path = ?", (file_path,)
        ).fetchone()
        return dict(row) if row else None

    def upsert_file_record(self, file_path: str, byte_offset: int, content_hash: str, mtime: float):
        self._conn.execute(
            """INSERT INTO files (file_path, byte_offset, content_hash, mtime)
               VALUES (?, ?, ?, ?)
               ON CONFLICT(file_path) DO UPDATE SET
                   byte_offset=excluded.byte_offset,
                   content_hash=excluded.content_hash,
                   mtime=excluded.mtime""",
            (file_path, byte_offset, content_hash, mtime),
        )
        self._conn.commit()

    def insert_chunks(self, file_path: str, chunks: list[dict]) -> list[int]:
        ids = []
        for c in chunks:
            cur = self._conn.execute(
                """INSERT INTO chunks (file_path, local_index, content, depth, parent_chunk_id)
                   VALUES (?, ?, ?, ?, ?)""",
                (file_path, c["chunk_index"], c["content"], c["depth"],
                 c.get("parent_chunk_index")),
            )
            ids.append(cur.lastrowid)
        self._conn.commit()
        return ids

    def get_chunks_for_file(self, file_path: str) -> list[dict]:
        rows = self._conn.execute(
            "SELECT * FROM chunks WHERE file_path = ? ORDER BY local_index",
            (file_path,),
        ).fetchall()
        return [dict(r) for r in rows]

    def get_max_local_index(self, file_path: str) -> int:
        row = self._conn.execute(
            "SELECT MAX(local_index) as m FROM chunks WHERE file_path = ?",
            (file_path,),
        ).fetchone()
        return row["m"] if row and row["m"] is not None else -1

    def get_last_heading_chunk(self, file_path: str) -> dict | None:
        row = self._conn.execute(
            """SELECT * FROM chunks WHERE file_path = ? AND depth <= 1
               ORDER BY local_index DESC LIMIT 1""",
            (file_path,),
        ).fetchone()
        return dict(row) if row else None

    def delete_file_data(self, file_path: str):
        self._conn.execute("DELETE FROM chunksets WHERE file_path = ?", (file_path,))
        self._conn.execute("DELETE FROM chunks WHERE file_path = ?", (file_path,))
        self._conn.execute("DELETE FROM files WHERE file_path = ?", (file_path,))
        self._conn.commit()

    def insert_chunksets(self, file_path: str, chunksets: list[dict]):
        for cs in chunksets:
            self._conn.execute(
                """INSERT INTO chunksets (file_path, local_index, chunk_ids, contents, to_embed)
                   VALUES (?, ?, ?, ?, ?)""",
                (file_path, cs["chunkset_index"],
                 json.dumps(cs["chunk_ids"]), cs["contents"],
                 cs.get("to_embed", cs["contents"])),
            )
        self._conn.commit()

    def get_all_chunksets(self) -> list[dict]:
        rows = self._conn.execute(
            "SELECT * FROM chunksets ORDER BY file_path, local_index"
        ).fetchall()
        return [dict(r) for r in rows]

    def update_chunkset_embedding(self, chunkset_id: int, embedding: bytes):
        self._conn.execute(
            "UPDATE chunksets SET embedding = ? WHERE chunkset_id = ?",
            (embedding, chunkset_id),
        )
        self._conn.commit()

    def get_all_chunkset_embeddings(self) -> list[tuple[int, bytes | None]]:
        rows = self._conn.execute(
            "SELECT chunkset_id, embedding FROM chunksets ORDER BY chunkset_id"
        ).fetchall()
        return [(r["chunkset_id"], r["embedding"]) for r in rows]

    def status(self) -> dict:
        files = self._conn.execute("SELECT file_path FROM files").fetchall()
        chunk_count = self._conn.execute("SELECT COUNT(*) as c FROM chunks").fetchone()["c"]
        chunkset_count = self._conn.execute("SELECT COUNT(*) as c FROM chunksets").fetchone()["c"]
        has_emb = self._conn.execute(
            "SELECT COUNT(*) as c FROM chunksets WHERE embedding IS NOT NULL"
        ).fetchone()["c"] > 0
        return {
            "files": [r["file_path"] for r in files],
            "total_chunks": chunk_count,
            "total_chunksets": chunkset_count,
            "has_embeddings": has_emb,
        }


# ═══════════════════════════════════════════════════════════════════════
# Incremental indexing — append-only fast path
# ═══════════════════════════════════════════════════════════════════════


def _hash(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def update_file(store: Store, file_path: str) -> dict:
    """Incrementally update index for a single file."""
    file_path = os.path.realpath(file_path)
    stat = os.stat(file_path)
    record = store.get_file_record(file_path)

    if record and record["mtime"] == stat.st_mtime:
        return {"status": "unchanged"}

    with open(file_path, "r", encoding="utf-8") as f:
        full_text = f.read()

    # Try incremental (append-only fast path)
    if record and record["byte_offset"] > 0:
        prefix = full_text[: record["byte_offset"]]
        prefix_hash = _hash(prefix)
        if prefix_hash == record["content_hash"]:
            new_text = full_text[record["byte_offset"]:]
            if not new_text.strip():
                store.upsert_file_record(
                    file_path, len(full_text.encode("utf-8")),
                    prefix_hash, stat.st_mtime,
                )
                return {"status": "unchanged"}
            return _incremental_update(store, file_path, full_text, new_text, stat.st_mtime)

    return _full_reindex(store, file_path, full_text, stat.st_mtime)


def _incremental_update(store, file_path, full_text, new_text, mtime):
    last_heading = store.get_last_heading_chunk(file_path)
    if last_heading:
        depth = last_heading["depth"]
        prefix = "#" * max(1, depth + 1) + " " + last_heading["content"] + "\n"
        chunker_input = prefix + new_text
        skip_first = True
    else:
        chunker_input = new_text
        skip_first = False

    arrow_text = indent_light(chunker_input, extract_title=not skip_first)
    new_chunks = parse_indented_text(arrow_text)
    new_chunks = normalize_depths(new_chunks)

    if skip_first and new_chunks:
        new_chunks = new_chunks[1:]

    if not new_chunks:
        store.upsert_file_record(file_path, len(full_text.encode("utf-8")), _hash(full_text), mtime)
        return {"status": "updated", "new_chunks": 0, "new_chunksets": 0}

    max_idx = store.get_max_local_index(file_path)
    for i, chunk in enumerate(new_chunks):
        chunk["chunk_index"] = max_idx + 1 + i
    new_chunks = normalize_depths(new_chunks)

    store.insert_chunks(file_path, new_chunks)
    new_chunksets = chunks_to_chunksets(new_chunks)
    existing_cs = len(store.get_all_chunksets())
    for cs in new_chunksets:
        cs["chunkset_index"] = existing_cs + cs["chunkset_index"]
    store.insert_chunksets(file_path, new_chunksets)

    store.upsert_file_record(file_path, len(full_text.encode("utf-8")), _hash(full_text), mtime)
    return {"status": "updated", "new_chunks": len(new_chunks), "new_chunksets": len(new_chunksets)}


def _full_reindex(store, file_path, full_text, mtime):
    store.delete_file_data(file_path)
    arrow_text = indent_light(full_text)
    chunks = parse_indented_text(arrow_text)
    chunks = normalize_depths(chunks)

    if not chunks:
        store.upsert_file_record(file_path, len(full_text.encode("utf-8")), _hash(full_text), mtime)
        return {"status": "reindexed", "new_chunks": 0, "new_chunksets": 0}

    store.insert_chunks(file_path, chunks)
    chunksets = chunks_to_chunksets(chunks)
    store.insert_chunksets(file_path, chunksets)
    store.upsert_file_record(file_path, len(full_text.encode("utf-8")), _hash(full_text), mtime)
    return {"status": "reindexed", "new_chunks": len(chunks), "new_chunksets": len(chunksets)}


# ═══════════════════════════════════════════════════════════════════════
# Retrieval — tree-walk expansion + context assembly
# ═══════════════════════════════════════════════════════════════════════


def expand_chunk_ids(chunks: list[dict], hit_chunk_ids: list[int]) -> list[int]:
    """Expand hit chunk IDs to include ancestors."""
    chunk_by_idx = {c["chunk_index"]: c for c in chunks}
    expanded: set[int] = set(hit_chunk_ids)
    for cid in hit_chunk_ids:
        current = cid
        while current is not None:
            expanded.add(current)
            parent = chunk_by_idx.get(current, {}).get("parent_chunk_index")
            current = parent
    return sorted(expanded)


def assemble_context(chunks: list[dict], chunk_ids: list[int]) -> str:
    """Assemble readable context with [...] gap markers."""
    chunk_by_idx = {c["chunk_index"]: c for c in chunks}
    lines: list[str] = []
    prev_idx: int | None = None
    for cid in chunk_ids:
        chunk = chunk_by_idx.get(cid)
        if chunk is None:
            continue
        if prev_idx is not None and cid - prev_idx > 1:
            lines.append(ELLIPSIS_MARKER)
        indent = "  " * chunk["depth"]
        lines.append(f"{indent}{chunk['content']}")
        prev_idx = cid
    return "\n".join(lines)


# ═══════════════════════════════════════════════════════════════════════
# Semantic search — auto-selects OpenAI (if OPENAI_API_KEY) or model2vec
# ═══════════════════════════════════════════════════════════════════════

from model2vec import StaticModel

_M2V_MODEL = "minishlab/potion-retrieval-32M"
_M2V_CUTOFF = 0.10
_M2V_DIMS = 512
_OAI_MODEL = "text-embedding-3-large"
_OAI_CUTOFF = 0.25
_OAI_DIMS = 3072


def _get_openai_client():
    """Return OpenAI client if API key is set and SDK available, else None."""
    if not os.environ.get("OPENAI_API_KEY"):
        return None
    try:
        from openai import OpenAI
        return OpenAI()
    except ImportError:
        return None


class _EmbedderBase:
    """Common logic for cosine search over stored embeddings."""

    min_score: float = 0.0
    expected_dims: int = 0

    def __init__(self, store: Store):
        self._store = store
        self._chunkset_ids: list[int] = []
        self._chunkset_map: dict[int, dict] = {}
        self._embeddings: np.ndarray | None = None
        self._build_index()

    def _embed_texts(self, texts: list[str]) -> np.ndarray:
        raise NotImplementedError

    def _embed_query(self, query: str) -> np.ndarray:
        raise NotImplementedError

    def _build_index(self):
        chunksets = self._store.get_all_chunksets()
        if not chunksets:
            return
        self._chunkset_map = {cs["chunkset_id"]: cs for cs in chunksets}
        stored = self._store.get_all_chunkset_embeddings()

        # Detect dimension mismatch (model switch) — wipe stale embeddings
        dim_ok = True
        for _, emb_bytes in stored:
            if emb_bytes is not None:
                dim = len(emb_bytes) // 4  # float32 = 4 bytes
                if dim != self.expected_dims:
                    dim_ok = False
                break

        needs_reembed = not dim_ok or not stored or any(
            emb is None for _, emb in stored
        )

        if needs_reembed:
            if not dim_ok:
                # Wipe all embeddings so they get recomputed
                for cs_id, _ in stored:
                    self._store.update_chunkset_embedding(cs_id, None)
            texts = [cs.get("to_embed") or cs["contents"] for cs in chunksets]
            embeddings = self._embed_texts(texts)
            for cs, emb in zip(chunksets, embeddings):
                emb_bytes = emb.astype(np.float32).tobytes()
                self._store.update_chunkset_embedding(cs["chunkset_id"], emb_bytes)
            self._chunkset_ids = [cs["chunkset_id"] for cs in chunksets]
            self._embeddings = embeddings.astype(np.float32)
        else:
            ids, embs = [], []
            for cs_id, emb_bytes in stored:
                if emb_bytes is not None:
                    arr = np.frombuffer(emb_bytes, dtype=np.float32)
                    ids.append(cs_id)
                    embs.append(arr)
            if embs:
                self._chunkset_ids = ids
                self._embeddings = np.stack(embs)

    def search(self, query: str, top_k: int = 10) -> list[dict]:
        if self._embeddings is None or len(self._chunkset_ids) == 0:
            return []
        query_vec = self._embed_query(query)
        norms = np.linalg.norm(self._embeddings, axis=1)
        query_norm = np.linalg.norm(query_vec)
        denom = norms * query_norm
        denom = np.where(denom > 0, denom, 1.0)
        scores = np.dot(self._embeddings, query_vec) / denom
        scores = np.nan_to_num(scores, nan=0.0, posinf=0.0, neginf=0.0)
        top_indices = np.argsort(scores)[-top_k:][::-1]
        hits = []
        for idx in top_indices:
            score = float(scores[idx])
            if score < self.min_score:
                continue
            cs_id = self._chunkset_ids[idx]
            cs = self._chunkset_map.get(cs_id)
            if cs is None:
                continue
            hits.append({
                "chunkset_id": cs_id,
                "file_path": cs["file_path"],
                "chunk_ids": json.loads(cs["chunk_ids"]) if isinstance(cs["chunk_ids"], str) else cs["chunk_ids"],
                "contents": cs["contents"],
                "score": score,
            })
        return hits


class Model2VecSearch(_EmbedderBase):
    """Local vector search using model2vec (30MB, no API key)."""

    min_score = _M2V_CUTOFF
    expected_dims = _M2V_DIMS

    def __init__(self, store: Store):
        self._model = StaticModel.from_pretrained(_M2V_MODEL)
        super().__init__(store)

    def _embed_texts(self, texts):
        return self._model.encode(texts).astype(np.float32)

    def _embed_query(self, query):
        return self._model.encode([query])[0].astype(np.float32)


class OpenAISearch(_EmbedderBase):
    """Vector search using OpenAI text-embedding-3-large."""

    min_score = _OAI_CUTOFF
    expected_dims = _OAI_DIMS

    def __init__(self, store: Store, client):
        self._client = client
        super().__init__(store)

    def _embed_texts(self, texts):
        # OpenAI API: max 2048 inputs per call
        all_embs = []
        for i in range(0, len(texts), 2048):
            batch = texts[i:i + 2048]
            resp = self._client.embeddings.create(model=_OAI_MODEL, input=batch)
            all_embs.extend([e.embedding for e in resp.data])
        return np.array(all_embs, dtype=np.float32)

    def _embed_query(self, query):
        resp = self._client.embeddings.create(model=_OAI_MODEL, input=[query])
        return np.array(resp.data[0].embedding, dtype=np.float32)


def _create_search(store: Store) -> _EmbedderBase:
    """Auto-select: OpenAI if OPENAI_API_KEY set, else model2vec."""
    client = _get_openai_client()
    if client is not None:
        try:
            return OpenAISearch(store, client)
        except Exception:
            pass
    return Model2VecSearch(store)


# ═══════════════════════════════════════════════════════════════════════
# Cheatsheet search — semantic hits → per-file cheatsheet assembly
# ═══════════════════════════════════════════════════════════════════════


class CheatsheetSearch:
    """Semantic search with per-file cheatsheet assembly.

    Auto-selects OpenAI (if OPENAI_API_KEY set) or model2vec.
    Hits below the model's min_score cutoff are filtered out.
    Per-file limit prevents any single file from dominating results.
    """

    def __init__(self, store: Store):
        self._store = store
        self._search = _create_search(store)

    def search(self, query: str, top_k: int = 5, max_per_file: int = 3) -> list[dict]:
        # Fetch more than top_k to have headroom after cutoff filtering
        hits = self._search.search(query, top_k=top_k * 3)
        if not hits:
            return []

        # Assemble cheatsheets: group hits by file, merge chunk_ids,
        # deduplicate, expand ancestors, produce one context block per file.
        # Per-file limit prevents a single large file from hogging all slots.
        file_hits: dict[str, list] = {}
        file_scores: dict[str, float] = {}
        for hit in hits:
            fp = hit["file_path"]
            file_hits.setdefault(fp, [])
            if len(file_hits[fp]) < max_per_file:
                file_hits[fp].append(hit)
            file_scores[fp] = max(file_scores.get(fp, 0), hit["score"])

        sorted_files = sorted(file_scores, key=lambda f: file_scores[f], reverse=True)

        results = []
        for file_path in sorted_files:
            fhits = file_hits[file_path]
            all_chunk_ids: list[int] = []
            for h in fhits:
                all_chunk_ids.extend(h["chunk_ids"])
            seen: set[int] = set()
            unique_ids: list[int] = []
            for cid in all_chunk_ids:
                if cid not in seen:
                    seen.add(cid)
                    unique_ids.append(cid)

            file_chunks = self._store.get_chunks_for_file(file_path)
            if file_chunks:
                chunk_dicts = [
                    {
                        "chunk_index": c["local_index"],
                        "content": c["content"],
                        "depth": c["depth"],
                        "parent_chunk_index": c["parent_chunk_id"],
                    }
                    for c in file_chunks
                ]
                expanded_ids = expand_chunk_ids(chunk_dicts, unique_ids)
                context = assemble_context(chunk_dicts, expanded_ids)
            else:
                context = "\n".join(h["contents"] for h in fhits)
                expanded_ids = unique_ids
            results.append({
                "file_path": file_path,
                "score": file_scores[file_path],
                "context": context,
                "chunk_ids": expanded_ids,
            })
        return results


# ═══════════════════════════════════════════════════════════════════════
# Public API
# ═══════════════════════════════════════════════════════════════════════


def index(
    path: str | Path = ".agent/",
    db_path: str | Path | None = None,
    glob_pattern: str = "**/*.md",
) -> dict:
    """Index all markdown files in a directory."""
    path = Path(path)
    if db_path is None:
        db_path = path / ".poma-memory.db"
    store = Store(db_path)
    total_chunks = 0
    total_chunksets = 0
    files_indexed = 0
    for md_file in sorted(path.glob(glob_pattern)):
        if md_file.name.startswith("."):
            continue
        result = update_file(store, str(md_file))
        if result["status"] in ("updated", "reindexed"):
            files_indexed += 1
            total_chunks += result.get("new_chunks", 0)
            total_chunksets += result.get("new_chunksets", 0)
    store.close()
    return {
        "files_indexed": files_indexed,
        "chunks_created": total_chunks,
        "chunksets_created": total_chunksets,
    }


def search(
    query: str,
    path: str | Path = ".agent/",
    db_path: str | Path | None = None,
    top_k: int = 5,
) -> list[dict]:
    """Search indexed content using semantic similarity + cheatsheet assembly."""
    path = Path(path)
    if db_path is None:
        db_path = path / ".poma-memory.db"
    store = Store(db_path)
    cs = CheatsheetSearch(store)
    results = cs.search(query, top_k=top_k)
    store.close()
    return results


def status(
    path: str | Path = ".agent/",
    db_path: str | Path | None = None,
) -> dict:
    """Show index status."""
    path = Path(path)
    if db_path is None:
        db_path = path / ".poma-memory.db"
    if not Path(db_path).exists():
        return {"files": [], "total_chunks": 0, "total_chunksets": 0, "has_embeddings": False}
    store = Store(db_path)
    info = store.status()
    store.close()
    return info


# ═══════════════════════════════════════════════════════════════════════
# MCP Server (optional — requires `pip install "mcp>=1.2.0"`)
# ═══════════════════════════════════════════════════════════════════════


def _run_mcp_server():
    """Start poma-memory MCP server."""
    try:
        from mcp.server.fastmcp import FastMCP
    except ImportError:
        print("MCP not installed. Run: pip install 'mcp>=1.2.0'", file=sys.stderr)
        sys.exit(1)

    mcp = FastMCP("poma-memory")

    @mcp.tool()
    def poma_search(query: str, path: str = ".agent/", top_k: int = 5) -> str:
        """Search indexed .agent/ content with structure-preserving hierarchical context."""
        results = search(query=query, path=path, top_k=top_k)
        if not results:
            return "No results found."
        output = []
        for i, r in enumerate(results, 1):
            output.append(
                f"--- Result {i} (score: {r['score']:.4f}) ---\n"
                f"File: {r['file_path']}\n"
                f"{r['context']}"
            )
        return "\n\n".join(output)

    @mcp.tool()
    def poma_index(path: str = ".agent/", file: str | None = None, glob: str = "**/*.md") -> str:
        """Index or re-index markdown files for semantic search."""
        if file:
            p = Path(path)
            db_path = str(p / ".poma-memory.db")
            store = Store(db_path)
            result = update_file(store, file)
            store.close()
            return (
                f"{file}: {result['status']}"
                f" ({result.get('new_chunks', 0)} chunks,"
                f" {result.get('new_chunksets', 0)} chunksets)"
            )
        result = index(path=path, glob_pattern=glob)
        return (
            f"Indexed {result['files_indexed']} files:"
            f" {result['chunks_created']} chunks,"
            f" {result['chunksets_created']} chunksets"
        )

    @mcp.tool()
    def poma_status(path: str = ".agent/") -> str:
        """Show poma-memory index status for a directory."""
        info = status(path=path)
        if not info["files"]:
            return "No indexed files. Use poma_index to index .agent/ first."
        lines = [
            f"Files:     {len(info['files'])}",
            f"Chunks:    {info['total_chunks']}",
            f"Chunksets: {info['total_chunksets']}",
            f"Semantic:  {'yes' if info['has_embeddings'] else 'no'}",
        ]
        for f in info["files"]:
            lines.append(f"  - {f}")
        return "\n".join(lines)

    print("poma-memory MCP server starting", file=sys.stderr)
    mcp.run(transport="stdio")


# ═══════════════════════════════════════════════════════════════════════
# CLI
# ═══════════════════════════════════════════════════════════════════════

def _cli():
    import argparse

    parser = argparse.ArgumentParser(
        prog="poma-memory",
        description="Structure-preserving markdown memory for AI agents",
    )
    sub = parser.add_subparsers(dest="command")

    # index
    p_idx = sub.add_parser("index", help="Index markdown files")
    p_idx.add_argument("--path", default=".agent/", help="Directory to index")
    p_idx.add_argument("--file", help="Single file to index (incremental)")
    p_idx.add_argument("--glob", default="**/*.md", help="File pattern")

    # search
    p_search = sub.add_parser("search", help="Search indexed content")
    p_search.add_argument("query", help="Search query")
    p_search.add_argument("--path", default=".agent/", help="Directory that was indexed")
    p_search.add_argument("--top-k", type=int, default=5, help="Number of results")

    # status
    p_status = sub.add_parser("status", help="Show index status")
    p_status.add_argument("--path", default=".agent/", help="Directory that was indexed")

    # mcp
    sub.add_parser("mcp", help="Start MCP server")

    args = parser.parse_args()

    if args.command == "index":
        if args.file:
            p = Path(args.path)
            db_path = str(p / ".poma-memory.db")
            store = Store(db_path)
            result = update_file(store, args.file)
            store.close()
            print(f"{args.file}: {result['status']} "
                  f"({result.get('new_chunks', 0)} chunks, "
                  f"{result.get('new_chunksets', 0)} chunksets)")
        else:
            result = index(path=args.path, glob_pattern=args.glob)
            print(f"Indexed {result['files_indexed']} files: "
                  f"{result['chunks_created']} chunks, "
                  f"{result['chunksets_created']} chunksets")

    elif args.command == "search":
        results = search(query=args.query, path=args.path, top_k=args.top_k)
        if not results:
            print("No results found.")
        for i, r in enumerate(results, 1):
            print(f"\n--- Result {i} (score: {r['score']:.4f}) ---")
            print(f"File: {r['file_path']}")
            print(r["context"])

    elif args.command == "status":
        info = status(path=args.path)
        if not info["files"]:
            print("No indexed files.")
        else:
            print(f"Files:     {len(info['files'])}")
            print(f"Chunks:    {info['total_chunks']}")
            print(f"Chunksets: {info['total_chunksets']}")
            print(f"Semantic:  {'yes' if info['has_embeddings'] else 'no'}")
            for f in info["files"]:
                print(f"  - {f}")

    elif args.command == "mcp":
        _run_mcp_server()

    else:
        parser.print_help()


if __name__ == "__main__":
    _cli()
