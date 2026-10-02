#!/usr/bin/env python3
"""Count short Korean requests in local Codex history without exporting text."""

from __future__ import annotations

import argparse
import collections
import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path


DEFAULT_SOURCES = [Path.home() / ".codex/history.jsonl"]
if os.environ.get("CODEX_HOME"):
    DEFAULT_SOURCES.append(Path(os.environ["CODEX_HOME"]) / "history.jsonl")
DEFAULT_SOURCES.extend(
    (Path.home() / "Library/Application Support/orca/codex-accounts").glob("*/home/history.jsonl")
)
KOREAN = re.compile(r"[\uac00-\ud7a3]")
PHRASES = [
    "push pr 진행", "알려줘", "계속해줘", "진행해줘", "확인해줘", "artifact 확인",
    "확인해봐", "반영해줘", "계속 진행해줘", "신규 이슈 발급해줘", "수정해줘",
    "최신 dev 기준으로 pull 받아줘",
]
WORDS = ["그럼", "지금", "해당", "확인", "이거", "현재"]

# Pasted policy/spec documents and examples are not ordinary direct requests.
EXCLUDED_MARKERS = (
    "# agents.md", "<instructions>", "<system>", "<developer>",
    "<environment_context>", "# global codex instructions", "이런 예시",
    "보험", "system prompt", "ignore all previous instructions",
)


def normalized_key(row: dict) -> tuple[str, int, str]:
    return (str(row.get("session_id", "")), int(row.get("ts", 0)), str(row.get("text", "")))


def load_rows(sources: list[Path]) -> tuple[list[str], int]:
    seen: set[tuple[str, int, str]] = set()
    texts: list[str] = []
    rows_read = 0
    for source in sources:
        if not source.is_file():
            continue
        with source.open(encoding="utf-8") as stream:
            for line in stream:
                try:
                    row = json.loads(line)
                except (json.JSONDecodeError, UnicodeDecodeError):
                    continue
                if not isinstance(row, dict) or "text" not in row:
                    continue
                rows_read += 1
                key = normalized_key(row)
                if key in seen:
                    continue
                seen.add(key)
                texts.append(key[2])
    return texts, rows_read


def is_candidate(text: str) -> bool:
    folded = text.casefold()
    return (
        len(text) <= 500
        and "\n" not in text
        and "\r" not in text
        and bool(KOREAN.search(text))
        and not any(marker in folded for marker in EXCLUDED_MARKERS)
        and not text.lstrip().startswith(("```", "{", "["))
    )


def analyze(sources: list[Path]) -> dict:
    texts, rows_read = load_rows(sources)
    candidates = [text for text in texts if is_candidate(text)]
    phrase_counts = {phrase: sum(phrase.casefold() in text.casefold() for text in candidates) for phrase in PHRASES}
    word_counts = {word: sum(word in text for text in candidates) for word in WORDS}
    return {
        "generated_at_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "method": "deduplicate by session_id+ts+text; count single-line Korean-containing messages <=500 characters after excluding obvious pasted policy/spec/code examples",
        "sources_found": sum(source.is_file() for source in sources),
        "source_rows_read": rows_read,
        "unique_messages": len(texts),
        "short_direct_request_sample": len(candidates),
        "phrase_message_counts": phrase_counts,
        "word_message_counts": word_counts,
        "limitations": "Heuristic sample; counts indicate messages containing each exact phrase, not intent certainty or all user activity. Only aggregates are emitted.",
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sources", nargs="*", type=Path, default=DEFAULT_SOURCES)
    parser.add_argument("--output", type=Path, help="Write aggregate JSON here; defaults to stdout.")
    args = parser.parse_args()
    result = json.dumps(analyze(args.sources), ensure_ascii=False, indent=2) + "\n"
    if args.output:
        args.output.write_text(result, encoding="utf-8")
    else:
        print(result, end="")


if __name__ == "__main__":
    main()
