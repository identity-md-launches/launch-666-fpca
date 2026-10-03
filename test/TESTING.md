# Additional contributor tests

The new tests run offline with `forge test` and use the existing committed dependencies.
No RPC, FFI, environment mutation, or configuration changes are required.

- `CatsAliveAdversarial.t.sol`: receiver callback forwarding, nested report and transfer
  rollback, uncaught mint reentry and guard recovery, approval cleanup, cancelled and
  superseded ownership handovers, reporter rotation, rejection atomicity, and exact
  report expiry boundaries. Its three fuzz properties each run 1,000 inputs.
- `CatsAliveInvariants.t.sol`: five actors and thirteen random actions, with an
  independent ledger for owners, balances, approvals, supply, administrative roles,
  pause state, and accepted reports. The campaign uses 256 sequences of 96 calls;
  unexpected handler reverts fail the run. It begins with four NFTs despite a
  three-cat game cohort. The 64-NFT handler ceiling bounds test resources, not mint
  supply. Expected failed calls must leave the independent model unchanged.
- `CatsAliveMetadataProperties.t.sol`: three properties with 1,000 inputs each parse
  actual SVG rectangles and sprite transforms, and round-trip UTC dates against an
  independent Gregorian-calendar calculation. Examples check shared art across mint
  numbers, transfers and mint pause, and distinguish unknown counts from true zero.

The balance invariant accounts for every NFT reachable through the handler. Separate
callback tests exercise contract recipients and nested calls. These tests establish
onchain state and rendering properties, not the correctness or availability of live
Fren Pet API observations, historical mint facts, or marketplace HTML support.
The static-view limitation is reported in the requested root `.imd-findings.json`.
