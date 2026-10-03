# Fren Pet source research

Research date: 2026-10-03 UTC. These are observed external facts, not values to
hardcode as a perpetual live count.

## Working API

`https://api.pet.game/` serves a Ponder GraphQL playground. A JSON POST to the
same URL works without an API key. This query was executed successfully:

```graphql
query Cats {
  _meta { status }
  pets(where: { dna_starts_with: "6-" }, limit: 1000) {
    totalCount
    items { id dna status createdAt timeUntilStarving owner }
    pageInfo { hasNextPage endCursor }
  }
}
```

Introspection confirms `dna` is a **String**, `status`, `createdAt`, and
`timeUntilStarving` are **Int**, and the page has `totalCount`, `items`, and
`pageInfo`. Old published API examples using an integer-array DNA field are
outdated for this endpoint. Paginate with `after: endCursor` if necessary.
Reject GraphQL errors and incomplete pagination; never silently publish zero
when an API request fails.

At indexed Base block **52112264**, timestamp **1791013875**
(2026-10-03 07:51:15 UTC), the query returned **37** rows. All had DNA `6-6-6`;
**34** had a nonzero owner and a status other than 4. The other three had status
4 and the zero owner. These numbers describe the snapshot, not the original
cat mint supply. The requested example token 15845 appeared with DNA `6-6-6`
and status 0.

The [official game frontend](https://pet.game/) identifies DNA's first element
6 as the cat species. Its deployed
[pet utility bundle](https://pet.game/_next/static/chunks/3865-bb53b90f245d91a1.js)
maps statuses 0 through 6 respectively to happy, hungry, starving, dying, dead,
hibernating, and training. The frontend treats zero/dead owners as dead and
also evaluates hunger timers. Hashed frontend URLs can change on redeployment.

The [official gameplay documentation](https://docs.frenpet.xyz/gameplay)
describes a seven-day hibernation period after feeding expires and a burn on
death. Counting only status 0 would incorrectly exclude living hungry,
starving, dying, and hibernating cats. The operational interpretation here is
**cats still in existence, including recoverable hibernating cats**. A reporter
must check status semantics, nonzero/non-burn owner, timer transitions and
indexer lag against current game behavior before attesting a value. An indexed
status can lag time-driven state changes; a GraphQL count alone is not a proof.

The current frontend's revive UI also exposes deadlines: hibernating status 5
uses `timeUntilStarving` as its revive deadline, while a pet needing hibernation
is shown `timeUntilStarving + 604800`. Its Kill action appears for expired
status-5 pets. Exact contract revival/death guards were not independently
verified, so the helper/viewer deliberately count remaining nonburned cats
rather than inventing an automatic death rule. This can include a pending-death
cat until a keeper/status/burn update occurs. The inspected API snapshot had no
nonburned expired status-5 rows and no nonburned active rows more than seven
days past their timer, so no current discrepancy was demonstrated. Operators
must verify this definition against their intended meaning of “alive.”

## History is a deployment input

An authoritative original cat supply and original mint date were **not
established** by the queried sources. Existing cat rows have `createdAt`
values mostly on 2024-02-26; one is on 2024-03-01. These may reflect a
migration or only surviving historical records. They do not establish the
original limited mint size or a single original mint date.

The deployer must independently substantiate the original cat cohort, count,
date and one-time-mint claim from Fren Pet's historical issuance records before
setting immutable metadata parameters. Do not use 37, 34, or the earliest
currently indexed `createdAt` as a substitute. This history concerns Fren Pet
game cats; the Cats Alive / FPCA commemorative collection is an unlimited free
mint and starts with zero issued tokens.

## Oracle and viewing limitations

An EVM view cannot make an HTTP request or observe a browser view event.
An authorized reporter must retrieve and validate the API data offchain and
submit the resulting count and observation timestamp onchain. The contract
then renders the latest onchain observation. Monitor indexer block age,
schema changes, reorgs, failed transactions and stale observations; retain the
last valid value rather than fabricating a new one. The reporter is a trust
dependency, not a cryptographic proof of the API result.

Different calls at identical chain state are deterministic. A block-dependent
layout can vary between blocks; the self-contained interactive animation also
varies on viewer load where supported. It requests current indexed data from
the API on load and once a minute, validates the schema, population bound and
observation age, and retains the onchain snapshot or last valid API count on
failure. The current API allows cross-origin POSTs, including a `null` origin
used by data URLs, but marketplace content policies can still deny them.
Marketplace caching and unsupported animation mean that a universal fresh
value or new jumble on every human view cannot be guaranteed by a contract alone.

## Preparing a report without signing

`tools/prepare_report.py` is a Python standard-library helper. It fetches the
API, validates a complete page of at most 1000 cats, rejects unknown statuses,
checks freshness, and prepares `publishCount(uint32,uint64,bytes32)` calldata.
It invokes the local Foundry `cast` executable for Ethereum Keccak-256 and ABI
encoding. It never reads a private key or broadcasts a transaction.

Replace these two placeholders with the deployed contract's verified
`originalCats()` and `maxReportAge()` values:

```text
python3 tools/prepare_report.py --original-cats VERIFIED_COUNT --max-age MAX_REPORT_AGE --output report.json
```

The default maximum age is 3600 seconds. The output contains `report`, unsigned
`calldata`, and the exact normalized `evidence` used for the provenance hash.
The hash covers UTF-8 JSON serialized with sorted keys, no spaces, and ASCII
escaping (`json.dumps(evidence, sort_keys=True, separators=(",", ":"),
ensure_ascii=True)`). Retain this artifact with each submitted report.

The helper checks index metadata before and after the cat query and retries
at most three times if it changes. Ponder currently exposes block number and
timestamp, **not a block hash**; unchanged values reduce cross-block races but
are not a finality or cryptographic consistency proof. A hash is additionally
validated and compared if the endpoint begins returning one. More than 1000
rows fails closed instead of publishing a partial page. A changed schema,
malformed response, lagged index, future timestamp or excess alive count also
fails closed and produces no new report.

An authorized operator still verifies the cohort/history and source accuracy,
checks that `observedAt` exceeds the contract's previous observation, confirms
the transaction remains within `maxReportAge`, and submits using their own
wallet or explorer. The helper's interpretation includes non-burned
hibernating cats and excludes status 4, the zero owner and the burn owner.

Run its independent, offline success/failure checks with:

```text
python3 -B -m unittest discover -s tools -p 'test_*.py' -v
```

## Artwork references

The [official branding page](https://docs.frenpet.xyz/branding) links to the
[brand PDF](https://docs.frenpet.xyz/assets/files/frenpet-brand-guidelines-e3650af0953ee0ce0bd1d08e9d4e4a60.pdf)
and [asset archive](https://docs.frenpet.xyz/assets/files/assets-d2b99dc9a0a77f453a603edc0e94b29f.zip).
The PDF was reachable directly. The
[requested OpenSea example](https://opensea.io/item/base/0x5b51cf49cb48617084ef35e7c7d7a21914769ff1/15845)
was not accessible to the web reader, but its HTML and linked SVG were
retrieved directly for the local artwork reference. Its cat identity was also
confirmed through the API and official frontend species mapping. Asset use
relies on the permission stated in the assignment; the current branding page
links downloads but does not itself contain an explicit copyright waiver.
