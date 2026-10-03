Offline build dependencies, vendored as ordinary source files (no submodules):

- OpenZeppelin Contracts **v5.1.0**, the recursive import closure used by this project.
  Source: https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.1.0
  License: `openzeppelin-contracts/LICENSE` (MIT).
- forge-std **v1.9.7**, complete `src/` for tests and the supplied deployment harness.
  Source: https://github.com/foundry-rs/forge-std/tree/v1.9.7
  Licenses: `forge-std/LICENSE-MIT` and `forge-std/LICENSE-APACHE`.

No dependency download is needed to compile or test with the pinned Solidity compiler installed.
