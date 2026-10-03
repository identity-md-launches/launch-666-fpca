#!/usr/bin/env python3
"""Prepare an unsigned CatsAlive report from the public Fren Pet API.

Python standard library only. Foundry's local `cast` executable provides
Ethereum Keccak-256 and ABI encoding. This program never broadcasts or reads
keys/environment configuration.
"""

import argparse
import json
import pathlib
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request


API_URL = "https://api.pet.game/"
MAX_CATS = 100_000
MAX_ROWS = 1000
MAX_RESPONSE_BYTES = 2 * 1024 * 1024
ZERO_OWNER = "0x" + "0" * 40
BURN_OWNER = "0x" + "0" * 36 + "dead"
PUBLISH_SIGNATURE = "publishCount(uint32,uint64,bytes32)"
META_QUERY = "query ReportIndex { _meta { status } }"
CATS_QUERY = """query ReportCats {
  pets(where: { dna_starts_with: "6-" }, limit: 1000,
       orderBy: "id", orderDirection: "asc") {
    totalCount
    items { id dna status createdAt timeUntilStarving owner }
    pageInfo { hasNextPage endCursor }
  }
}"""


class ReportError(ValueError):
    """An unsafe, incomplete, or unavailable source observation."""


def integer(value, name, minimum=0, maximum=(1 << 64) - 1):
    if type(value) is not int or not minimum <= value <= maximum:
        raise ReportError(f"Invalid {name}: expected integer {minimum}..{maximum}")
    return value


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ReportError(f"Duplicate JSON key: {key}")
        result[key] = value
    return result


def api_query(query):
    request = urllib.request.Request(
        API_URL,
        data=json.dumps({"query": query}).encode("utf-8"),
        headers={"Content-Type": "application/json", "User-Agent": "CatsAlive-report/1"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            body = response.read(MAX_RESPONSE_BYTES + 1)
        if len(body) > MAX_RESPONSE_BYTES:
            raise ReportError("API response exceeds the size limit")
        return json.loads(body, object_pairs_hook=unique_object)
    except (urllib.error.URLError, TimeoutError, OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ReportError(f"API request failed: {exc}") from exc


def response_data(response):
    if not isinstance(response, dict) or response.get("errors"):
        raise ReportError("API returned an invalid response or GraphQL errors")
    data = response.get("data")
    if not isinstance(data, dict):
        raise ReportError("API response has no data object")
    return data


def indexed_block(response):
    try:
        base = response_data(response)["_meta"]["status"]["base"]
        chain_id = integer(base["id"], "chain id")
        block = base["block"]
        result = {
            "number": integer(block["number"], "indexed block number", 1),
            "timestamp": integer(block["timestamp"], "indexed block timestamp", 1),
        }
        if chain_id != 8453:
            raise ReportError("API index does not identify Base chain 8453")
        # Ponder currently has no block hash here. Validate and compare one if
        # it becomes available, but never invent a hash or claim finality.
        if "hash" in block:
            block_hash = block["hash"]
            if not isinstance(block_hash, str) or not re.fullmatch(r"0x[0-9a-fA-F]{64}", block_hash):
                raise ReportError("Invalid indexed block hash")
            result["hash"] = block_hash.lower()
        return result
    except (KeyError, TypeError) as exc:
        raise ReportError("API index metadata has an unexpected schema") from exc


def cat_rows(response):
    try:
        page = response_data(response)["pets"]
        total = integer(page["totalCount"], "cat totalCount", 0, MAX_ROWS)
        rows = page["items"]
        page_info = page["pageInfo"]
        if page_info["hasNextPage"] is not False:
            raise ReportError("Cat result is incomplete; additional pages are not accepted")
        if page_info["endCursor"] is not None and not isinstance(page_info["endCursor"], str):
            raise ReportError("Invalid pagination cursor")
        if not isinstance(rows, list) or len(rows) != total:
            raise ReportError("Cat item count does not match totalCount")
        seen = set()
        normalized = []
        for row in rows:
            token_id = integer(row["id"], "cat id", 0, (1 << 31) - 1)
            if token_id in seen:
                raise ReportError("Duplicate cat id")
            seen.add(token_id)
            dna = row["dna"]
            if not isinstance(dna, str) or not re.fullmatch(r"6-[0-9]+-[0-9]+", dna):
                raise ReportError("Unexpected cat DNA; source species filter may have changed")
            status = integer(row["status"], "cat status", 0, 6)
            owner = row["owner"]
            if not isinstance(owner, str) or not re.fullmatch(r"0x[0-9a-fA-F]{40}", owner):
                raise ReportError("Invalid cat owner")
            normalized.append({
                "id": token_id,
                "dna": dna,
                "status": status,
                "createdAt": integer(row["createdAt"], "cat createdAt", 1, (1 << 31) - 1),
                "timeUntilStarving": integer(
                    row["timeUntilStarving"], "cat timeUntilStarving", 0, (1 << 31) - 1
                ),
                "owner": owner.lower(),
            })
        return sorted(normalized, key=lambda row: row["id"])
    except (KeyError, TypeError) as exc:
        raise ReportError("Cat API response has an unexpected schema") from exc


def prepare_snapshot(original_cats, max_age=3600, query=api_query, clock=time.time, retries=3):
    integer(original_cats, "original cats", 1, MAX_CATS)
    integer(max_age, "max age", 60, 7 * 24 * 60 * 60)
    integer(retries, "retries", 1, 3)
    for _ in range(retries):
        before = indexed_block(query(META_QUERY))
        rows = cat_rows(query(CATS_QUERY))
        after = indexed_block(query(META_QUERY))
        if before != after:
            continue
        observed_at = after["timestamp"]
        now = int(clock())
        if observed_at > now:
            raise ReportError("API index timestamp is in the future; check the local clock")
        if now - observed_at > max_age:
            raise ReportError("API index is stale; refusing to prepare a fresh report")
        if any(row["createdAt"] > observed_at for row in rows):
            raise ReportError("A cat creation timestamp is newer than the indexed block")
        alive = sum(
            row["status"] != 4 and row["owner"] not in (ZERO_OWNER, BURN_OWNER)
            for row in rows
        )
        if alive > original_cats:
            raise ReportError("Alive count exceeds the configured original cat cohort")
        return {
            "source": API_URL,
            "chainId": 8453,
            "indexedBlock": after,
            "definition": "DNA prefix 6-, status != 4, owner neither zero nor burn address; includes hibernation",
            "originalCats": original_cats,
            "totalCount": len(rows),
            "aliveCats": alive,
            "cats": rows,
        }
    raise ReportError("API index changed during all 3 snapshot attempts; retry later")


def canonical_evidence(evidence):
    return json.dumps(evidence, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("utf-8")


def local_cast(arguments):
    command_arguments = arguments
    standard_input = None
    if arguments[0] == "keccak" and len(arguments) == 2:
        # A complete 1000-row observation can exceed the OS argument-size
        # limit. cast reads and decodes the same hex input from stdin.
        command_arguments = ["keccak"]
        standard_input = arguments[1]
    try:
        completed = subprocess.run(
            ["cast", *command_arguments], input=standard_input,
            check=True, capture_output=True, text=True, timeout=15
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise ReportError("Local cast failed; install Foundry and check that cast is on PATH") from exc
    return completed.stdout.strip()


def build_artifact(evidence, cast=local_cast):
    evidence_hash = cast(["keccak", "0x" + canonical_evidence(evidence).hex()])
    if not re.fullmatch(r"0x[0-9a-fA-F]{64}", evidence_hash) or int(evidence_hash, 16) == 0:
        raise ReportError("cast did not produce a valid nonzero Ethereum Keccak-256 hash")
    alive = evidence["aliveCats"]
    observed_at = evidence["indexedBlock"]["timestamp"]
    calldata = cast(["calldata", PUBLISH_SIGNATURE, str(alive), str(observed_at), evidence_hash])
    if not re.fullmatch(r"0x[0-9a-fA-F]{200}", calldata):
        raise ReportError("cast did not produce valid publishCount calldata")
    return {
        "report": {"aliveCats": alive, "observedAt": observed_at, "evidenceHash": evidence_hash},
        "function": PUBLISH_SIGNATURE,
        "calldata": calldata,
        "evidence": evidence,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--original-cats", required=True, type=int, help="Verified CatsAlive.originalCats() value")
    parser.add_argument("--max-age", default=3600, type=int, help="Use deployed maxReportAge() seconds (default 3600)")
    parser.add_argument("--output", type=pathlib.Path, help="Write the report and evidence JSON to this file")
    args = parser.parse_args(argv)
    try:
        artifact = build_artifact(prepare_snapshot(args.original_cats, args.max_age))
        output = json.dumps(artifact, sort_keys=True, indent=2) + "\n"
        if args.output is not None:
            args.output.write_text(output, encoding="utf-8")
        else:
            sys.stdout.write(output)
        return 0
    except (ReportError, OSError) as exc:
        print(f"Report not prepared: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
