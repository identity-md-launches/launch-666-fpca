"""Offline success/failure checks: python3 -m unittest discover -s tools."""

import copy
import io
import json
import pathlib
import shutil
import tempfile
import unittest
from unittest.mock import patch

import prepare_report as report


NOW = 1_800_000_000
OWNER = "0x" + "A1" * 20


def meta(number=100, timestamp=NOW, block_hash=None):
    block = {"number": number, "timestamp": timestamp}
    if block_hash is not None:
        block["hash"] = block_hash
    return {"data": {"_meta": {"status": {"base": {"id": 8453, "block": block}}}}}


def cat(token_id, status=0, owner=OWNER):
    return {
        "id": token_id, "dna": "6-6-6", "status": status,
        "createdAt": NOW - 100_000, "timeUntilStarving": NOW + 1000, "owner": owner,
    }


def page(rows):
    return {"data": {"pets": {
        "totalCount": len(rows), "items": rows,
        "pageInfo": {"hasNextPage": False, "endCursor": None},
    }}}


class Queries:
    def __init__(self, responses):
        self.responses = list(responses)
        self.queries = []

    def __call__(self, query):
        self.queries.append(query)
        if not self.responses:
            raise AssertionError("Unexpected extra source query")
        return self.responses.pop(0)


class SnapshotTests(unittest.TestCase):
    def snapshot(self, rows, original_cats=100, index=None, now=NOW, max_age=3600):
        index = meta() if index is None else index
        return report.prepare_snapshot(
            original_cats, max_age,
            query=Queries([index, page(rows), copy.deepcopy(index)]), clock=lambda: now,
        )

    def test_alive_includes_hibernation_and_training_excludes_burns(self):
        rows = [cat(i, status=i) for i in range(7)]
        rows.extend([cat(10, owner=report.ZERO_OWNER), cat(11, owner=report.BURN_OWNER.upper().replace("0X", "0x"))])
        evidence = self.snapshot(list(reversed(rows)))
        self.assertEqual(evidence["aliveCats"], 6)
        self.assertEqual(evidence["totalCount"], 9)
        self.assertEqual(evidence["indexedBlock"]["timestamp"], NOW)
        self.assertEqual(evidence["cats"][0]["owner"], OWNER.lower())
        self.assertEqual([row["id"] for row in evidence["cats"]], sorted(row["id"] for row in rows))

    def test_empty_complete_population_can_report_zero(self):
        self.assertEqual(self.snapshot([])["aliveCats"], 0)

    def test_original_population_bound(self):
        with self.assertRaisesRegex(report.ReportError, "exceeds"):
            self.snapshot([cat(1), cat(2)], original_cats=1)

    def test_staleness_boundary_and_future(self):
        self.assertEqual(self.snapshot([], index=meta(timestamp=NOW - 3600))["aliveCats"], 0)
        for timestamp, message in [(NOW - 3601, "stale"), (NOW + 1, "future")]:
            with self.subTest(timestamp=timestamp), self.assertRaisesRegex(report.ReportError, message):
                self.snapshot([], index=meta(timestamp=timestamp))

    def test_creation_after_index_rejected(self):
        row = cat(1)
        row["createdAt"] = NOW + 1
        with self.assertRaisesRegex(report.ReportError, "creation"):
            self.snapshot([row])

    def test_changed_index_retries_and_uses_new_observation(self):
        queries = Queries([
            meta(100, NOW - 2), page([cat(1)]), meta(101),
            meta(101), page([cat(1), cat(2)]), meta(101),
        ])
        evidence = report.prepare_snapshot(10, query=queries, clock=lambda: NOW)
        self.assertEqual(evidence["aliveCats"], 2)
        self.assertEqual(evidence["indexedBlock"]["number"], 101)
        self.assertEqual(len(queries.queries), 6)

    def test_changing_index_rejected_after_three_attempts(self):
        queries = Queries([response for _ in range(3) for response in [meta(1), page([]), meta(2)]])
        with self.assertRaisesRegex(report.ReportError, "3 snapshot attempts"):
            report.prepare_snapshot(10, query=queries, clock=lambda: NOW)
        self.assertEqual(len(queries.queries), 9)

    def test_changed_hash_at_same_height_is_not_accepted(self):
        first = meta(block_hash="0x" + "11" * 32)
        second = meta(block_hash="0x" + "22" * 32)
        queries = Queries([first, page([cat(1)]), second, second, page([]), second])
        evidence = report.prepare_snapshot(10, query=queries, clock=lambda: NOW)
        self.assertEqual(evidence["aliveCats"], 0)
        self.assertEqual(evidence["indexedBlock"]["hash"], "0x" + "22" * 32)

    def test_schema_and_graphql_failures(self):
        broken = [None, {}, {"data": None}, {"data": {}, "errors": [{"message": "unavailable"}]}]
        for response in broken:
            with self.subTest(response=response), self.assertRaises(report.ReportError):
                report.indexed_block(response)
        index = meta()
        index["data"]["_meta"]["status"]["base"]["id"] = 1
        with self.assertRaisesRegex(report.ReportError, "Base"):
            report.indexed_block(index)

    def test_incomplete_and_inconsistent_pages(self):
        for field, value in [("totalCount", 2), ("totalCount", 1001), ("items", None)]:
            response = page([cat(1)])
            response["data"]["pets"][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(report.ReportError):
                report.cat_rows(response)
        for flag in [True, 0, None, "false"]:
            response = page([])
            response["data"]["pets"]["pageInfo"]["hasNextPage"] = flag
            with self.subTest(flag=flag), self.assertRaises(report.ReportError):
                report.cat_rows(response)

    def test_malformed_cats_rejected(self):
        for field, value in [
            ("status", 7), ("status", True), ("status", "0"),
            ("dna", "7-6-6"), ("dna", [6, 6, 6]),
            ("owner", "0x123"), ("createdAt", -1), ("timeUntilStarving", 1.5),
        ]:
            row = cat(1)
            row[field] = value
            with self.subTest(field=field, value=value), self.assertRaises(report.ReportError):
                report.cat_rows(page([row]))
        with self.assertRaisesRegex(report.ReportError, "Duplicate cat"):
            report.cat_rows(page([cat(1), cat(1)]))

    def test_duplicate_json_keys_rejected(self):
        with self.assertRaisesRegex(report.ReportError, "Duplicate JSON"):
            json.loads('{"data":1,"data":2}', object_pairs_hook=report.unique_object)

    def test_configuration_rejected_before_network(self):
        for original, age in [(0, 3600), (100001, 3600), (True, 3600), (1, 0), (1, 604801)]:
            with self.subTest(original=original, age=age), self.assertRaises(report.ReportError):
                report.prepare_snapshot(original, age, query=Queries([]))

    def test_transport_failure_does_not_prepare_zero(self):
        with patch.object(report.urllib.request, "urlopen", side_effect=TimeoutError("offline")):
            with self.assertRaisesRegex(report.ReportError, "request failed"):
                report.api_query(report.CATS_QUERY)


class ArtifactTests(unittest.TestCase):
    def evidence(self):
        return report.prepare_snapshot(10, query=Queries([meta(), page([cat(1)]), meta()]), clock=lambda: NOW)

    def test_keccak_receives_exact_canonical_evidence_and_calldata_parameters(self):
        evidence = self.evidence()
        calls = []

        def fake_cast(arguments):
            calls.append(arguments)
            return "0x" + ("12" * 32 if arguments[0] == "keccak" else "34" * 100)

        artifact = report.build_artifact(evidence, cast=fake_cast)
        self.assertEqual(bytes.fromhex(calls[0][1][2:]), report.canonical_evidence(evidence))
        self.assertEqual(calls[1], ["calldata", report.PUBLISH_SIGNATURE, "1", str(NOW), "0x" + "12" * 32])
        self.assertEqual(artifact["report"]["observedAt"], NOW)
        self.assertEqual(artifact["evidence"], evidence)

    @unittest.skipUnless(shutil.which("cast"), "Foundry cast is required for local Keccak/ABI integration")
    def test_real_ethereum_keccak_and_unsigned_calldata(self):
        self.assertEqual(
            report.local_cast(["keccak", "0x"]),
            "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
        )
        artifact = report.build_artifact(self.evidence())
        calldata = bytes.fromhex(artifact["calldata"][2:])
        self.assertEqual(len(calldata), 100)
        self.assertEqual(int.from_bytes(calldata[4:36], "big"), 1)
        self.assertEqual(int.from_bytes(calldata[36:68], "big"), NOW)
        self.assertEqual("0x" + calldata[68:].hex(), artifact["report"]["evidenceHash"])

    @unittest.skipUnless(shutil.which("cast"), "Foundry cast is required")
    def test_maximum_complete_page_hashes_without_argument_size_failure(self):
        evidence = report.prepare_snapshot(
            1000, query=Queries([meta(), page([cat(i) for i in range(1000)]), meta()]),
            clock=lambda: NOW,
        )
        self.assertGreater(len(report.canonical_evidence(evidence).hex()), 131072)
        artifact = report.build_artifact(evidence)
        self.assertEqual(artifact["report"]["aliveCats"], 1000)

    def test_bad_hash_or_calldata_rejected(self):
        for bad_hash in ["0x" + "00" * 32, "not-a-hash"]:
            with self.subTest(hash=bad_hash), self.assertRaises(report.ReportError):
                report.build_artifact(self.evidence(), cast=lambda _: bad_hash)
        with self.assertRaisesRegex(report.ReportError, "calldata"):
            report.build_artifact(self.evidence(), cast=lambda _: "0x" + "12" * 32)

    def test_cli_output_file_and_failure_exit(self):
        artifact = {"report": {"aliveCats": 1}}
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / "report.json"
            with patch.object(report, "prepare_snapshot", return_value={}), patch.object(report, "build_artifact", return_value=artifact):
                self.assertEqual(report.main(["--original-cats", "10", "--output", str(output)]), 0)
            self.assertEqual(json.loads(output.read_text()), artifact)
        error_output = io.StringIO()
        with patch.object(report, "prepare_snapshot", side_effect=report.ReportError("stale")), patch.object(report.sys, "stderr", error_output):
            self.assertEqual(report.main(["--original-cats", "10"]), 1)
            self.assertIn("stale", error_output.getvalue())


if __name__ == "__main__":
    unittest.main()
