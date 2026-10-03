# Cats Alive (Fren Pet)

One non-upgradeable ERC-721 application: `src/CatsAlive.sol:CatsAlive`.
Name and symbol are **FPCA**, supply starts at **0**, and `mint()` is an unlimited,
free mint to the caller. Token display names are `Cats Alive (Fren Pet) #N`.
There is no fungible token, pool, royalty, payment mechanism, or premint.

## Artwork and live data

The contract generates base64 JSON metadata, an SVG image, and interactive HTML.
The original Fren Pet cat sprite, all rendering code and styles are embedded in
the deployed bytecode. No IPFS, image host, external script, or external font is
needed. `external_url` links to `https://pet.game`.

Both views have a `#342E2E` background, a centered `#DBFEE6` count at **36pt**
above the bottom line, and centered **30pt** `Fren Pet Cats Still Alive` text.
The font stack is Inter, Arial, Helvetica, sans-serif; the local system fallback
is intentional, and the artwork never downloads a font. The mint number and
observation status appear in the top margin. All tokens use the same data and
art logic; only the mint number is token-specific.

The two views have different freshness properties:

| View | Count source | Layout changes |
| --- | --- | --- |
| SVG `image`, raw `imageSVG(id)` | Latest authorized onchain report | On a new block when fetched again; same-block calls are deterministic |
| HTML `animation_url`, raw `animationHTML(id)` | Starts with that report; attempts a validated API query on opening and each minute | Randomizes on each opening, successful API refresh, or click |

The HTML fetches **data only** from `https://api.pet.game/`. If the viewer blocks
JavaScript, network requests, data URLs or animations, live interaction will
not work there; the SVG remains available. API failures, incomplete results,
schema changes, inconsistent indexing, or stale observations retain the last
valid count. The source is labeled `Onchain` or `API`. The HTML marks old data
stale as its viewer clock advances. API display updates never change contract
state or attest that the API is truthful.

An EVM `tokenURI` call cannot itself fetch HTTP or detect a human viewing an
image. Marketplace caching can prevent a new fetch. Consequently **a fresh
count and new jumble on every view cannot be guaranteed in every marketplace**.
An active reporter keeps the static fallback current; a compatible interactive
viewer obtains the latest indexed count independently.

Every count has exactly that many sprites. Each cat has a varying size and
jitter within its own cell, with a strictly positive margin, so cats never
touch or overlap. The SVG repeats a randomized 4-by-4 tile and paints only
whole cells, including the partial final row. This keeps RPC computation and
metadata size bounded. The HTML gives every cat an independently randomized
placement within the same spacing rules. At very large populations the cats
necessarily become small; geometric separation does not imply legibility at
100,000 cats on a 1,000px canvas. Randomness is cosmetic and confers no value or
mint advantage.

## Meaning of “alive” and historical mint information

The API's cat species is identified by DNA prefix `6-`. This project interprets
alive as **not dead/burned**, including recoverable hibernating cats: status is
not `4`, and owner is neither the zero address nor the conventional dead
address. Other living states include hungry, starving, dying and training.
See [the research record](docs/research.md) for the executed query and limits
of API status/indexer freshness. This is an operational interpretation, not an
independently verified game-state oracle. An expired cat awaiting a death/burn
update may still be counted until the keeper/indexer processes it. The helper
does not invent a different timeout rule from incompletely verified game logic.

The original count, original UTC mint date, and one-time-mint claim could not
be established from the available records. **They must be verified before
deployment.** Existing API records are not a substitute for issuance history.
The immutable constructor values produce the requested statement:

> N cats were originally minted on YYYY-MM-DD as a one-time mint. No new cats
> will ever be minted.

The field immediately clarifies that this describes the original game cats;
FPCA minting is unlimited. The contract does not control Fren Pet's issuance.
If the historical claim cannot be substantiated, do not deploy this immutable
statement as fact. Test values and live API observations are **not deployment
parameters**.

## Build and check offline

The compiler is pinned to **Solidity 0.8.26**, with Cancun EVM output,
optimization and `bytecode_hash = "none"`. All imported Solidity dependencies
are ordinary committed files in `lib/`. With the pinned compiler and Foundry
installed:

```sh
forge build
forge test
forge fmt --check
node --test test/viewer.test.cjs
python3 -m unittest discover -s tools -p 'test_*.py'
```

No tests read environment variables, fetch network data, use FFI, or grant
Foundry filesystem access. The Node tests use only built-in modules. The Python
tests use the standard library and local `cast` for hashing/ABI checks. These
additional tests validate the embedded browser program and reporter helper;
the required contract checks are entirely in Foundry.

`assets/viewer.js` is the readable viewer source. If changed, run
`python3 tools/embed_viewer.py` to update the committed Solidity string and
then `forge fmt`. Builds do not run a generator. The viewer test verifies the
source and committed string match. Sprite provenance, hashes and the offline
conversion tool are in [assets/PROVENANCE.md](assets/PROVENANCE.md).

## Deployment parameters

Deploy exactly one `CatsAlive` contract on Base, chain ID 8453, using the
normal deployment handoff. Its nonpayable constructor is:

```solidity
constructor(
    address initialOwner,
    address initialReporter,
    uint32 originalCats,
    uint64 originalMintTimestamp,
    uint32 maxReportAge
)
```

| Parameter | Required choice |
| --- | --- |
| `initialOwner` | Explicit administration wallet supplied by the launch owner (`$owner` in a launch manifest); nonzero. Never infer it from a factory's `msg.sender`. |
| `initialReporter` | Explicit nonzero account that will verify and publish observations; may equal owner if that is the chosen operating model. |
| `originalCats` | Verified original closed game-cat cohort, from 1 through 100,000. This bounds the **reported game population**, never FPCA supply. |
| `originalMintTimestamp` | Verified original mint date as UTC Unix seconds, nonzero, no later than deployment, and before 2100-01-01. The displayed date is UTC. |
| `maxReportAge` | Staleness threshold, 60 through 604,800 seconds; choose an operational cadence comfortably shorter than this. |

All configuration is complete in the constructor. No initialization call,
proxy, external renderer, signed wallet configuration or deployed dependency
is needed. Minting begins enabled. The initial report is explicitly **unknown**:
metadata says `alive_cats: null`, status `unreported`, and the art shows `--`
and no cats until data is available. The HTML can independently display a valid
API result even before the first report.

The launch manifest is a separate deployment handoff; this assignment does not
invent historical inputs or an operator address, emit a guessed manifest, or
deploy/send transactions. No constructor depends on `msg.sender` ownership.

## Operation and permissions

- **Mint:** in the verified block explorer's Write Contract tab, connect a
  wallet and call `mint()` with **zero ETH**. Repeat without a wallet or supply
  limit. Each call creates the next number, starting at 1. The caller pays gas.
  Contract wallets must implement `IERC721Receiver`.
- **Owner:** can `pause()` and `unpause()` **minting only**, and replace the
  reporter with `setReporter(address)`. Existing transfers, approvals, metadata
  and report updates remain available while paused. Ownership uses
  `transferOwnership(address)` then `acceptOwnership()` by the recipient;
  proposing zero cancels a pending handover. Renunciation is disabled to avoid
  permanently trapping a pause or losing reporter recovery.
- **Reporter:** calls `publishCount(uint32 alive, uint64 observationTime,
  bytes32 evidenceHash)`. The count must not exceed `originalCats`. The source
  observation must be newer than the previous report, no earlier than the
  original mint, not in the future, and no older than `maxReportAge`. A nonzero
  evidence hash is required. Counts may increase for corrections/revivals.
  A compromised owner can appoint a dishonest reporter: this is an explicit
  trust assumption, not an API proof.
- **Holders:** ordinary ERC-721 transfers and approvals with no protocol fee,
  transfer limit or administrative confiscation. There is no burn function or
  withdrawal function; do not send unrelated assets to this contract.

Prepare a report with the included unsigned helper, substituting the verified
constructor count and configured age:

```sh
python3 tools/prepare_report.py --original-cats VERIFIED_COUNT --max-age AGE_SECONDS --output /tmp/cats-report.json
```

The helper checks a complete API result between stable index observations,
hashes canonical evidence with Ethereum Keccak via `cast`, and produces
unsigned calldata plus readable arguments. It never reads keys or sends a
transaction. The operator must archive the evidence, compare `observedAt()`
with the new observation (skip duplicates), verify the destination/chain, and
submit through its own signing process. The first report is ordinary ongoing
data publication, not contract initialization.

Keep indexer lag, schema/status changes, game-cohort definitions, local clock
accuracy, Base transaction confirmation and report age monitored. Do not
substitute zero on failures. Investigate any expansion of the cat cohort or
change to death/revival semantics. The helper and viewer deliberately reject
responses requiring more than 1,000 rows instead of silently truncating; a
new adapter and, for the immutable viewer, new deployment would be needed if
the API population/schema changes incompatibly.

The report hash permits evidence reconciliation but does not authenticate the
server or prove completeness/finality. The current API has no block hash in
its index metadata, so stable block number/timestamp checks cannot prove the
absence of a reorg. Publishing emits `CountPublished` and ERC-4906
`BatchMetadataUpdate(1,totalSupply)` for indexers. Time-only staleness/layout
changes emit no event: refresh from `tokenURI` when needed.

## Validation and limits

Foundry tests cover success/failure minting, reentry and receiver rollback,
authorization, free transfers under pause, approval cleanup, two-step ownership,
report bounds/replay/freshness, metadata decoding, factory ownership, runtime
size/forbidden opcodes, maximum-population rendering cost, sprite geometry and
UTC leap dates. Viewer and helper tests use offline success/failure fixtures.
The maximum-population metadata is kept below 30KB and the test enforces a
5-million-gas rendering ceiling. The deployed application remains under the
24,576-byte EIP-170 runtime limit.

A separate agent reviewed the contract/rendering logic. Automated checks and
that bounded review are not a production security audit. Slither and Mythril
were not run. No mainnet transaction, explorer verification, live signer
setup or real marketplace/browser compatibility certification was performed.

Project source is MIT licensed; vendored code and Fren Pet artwork retain the
license/provenance notes supplied with them.
