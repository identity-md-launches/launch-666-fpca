# Additional contributor tests

The new tests run offline with `forge test` and use the existing committed dependencies.
No RPC, FFI, environment mutation, or configuration changes are required.

- `CatsAliveAdversarial.t.sol`: receiver callback forwarding, nested report and transfer
  rollback, uncaught mint reentry and guard recovery, approval cleanup, cancelled and
  superseded ownership handovers, reporter rotation, rejection atomicity, and exact
  report expiry boundaries. Its three fuzz properties each run 1,000 inputs. Since the
  constructor stopped comparing `originalMintTimestamp` with the deployment clock, one
  example deploys with a date one day ahead and shows that minting and rendering work
  but every report is rejected until the clock reaches that date; the value is
  immutable, so the deployer must verify it before launch.
- `CatsAliveInvariants.t.sol`: five actors and thirteen random actions, with an
  independent ledger for owners, balances, approvals, supply, administrative roles,
  pause state, and accepted reports. The campaign uses 256 sequences of 96 calls;
  unexpected handler reverts fail the run. It begins with four NFTs despite a
  three-cat game cohort. The 64-NFT handler ceiling bounds test resources, not mint
  supply. Expected failed calls must leave the independent model unchanged.
- `CatsAliveMetadataProperties.t.sol`: four properties with 1,000 inputs each parse
  actual SVG output rather than reconstructing it from renderer helpers. The renderer now
  has two branches: for 1 through 64 cats every sprite is serialized with its own seeded
  transform, and the property parses each one, requires a positive gutter inside its own
  grid cell, exactly `count` sprites, no empty grid row, no `<pattern>` or `<rect>`, and a
  pairwise bounding-box check that no two sprites overlap or touch. For 65 through
  100,000 cats the repeated 4x4 tile is required and the painted rectangles must cover
  exactly `count` whole cells. A third property checks the sixteen tile transforms, and
  the fourth round-trips UTC dates against an independent Gregorian-calendar calculation.
  Examples check the branch switch end to end through `imageSVG` at 64, 65 and 1 cats,
  shared art across mint numbers, transfers and mint pause, and distinguish unknown counts
  from true zero.

The balance invariant accounts for every NFT reachable through the handler. Separate
callback tests exercise contract recipients and nested calls. These tests establish
onchain state and rendering properties, not the correctness or availability of live
Fren Pet API observations, historical mint facts, or marketplace HTML support.
The static-view limitation is reported in the requested root `.imd-findings.json`.
