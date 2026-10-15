# Files

- [Driving Search with ./bench and test worlds](bench-and-test-worlds.md) - The Bench — a same-user Unix socket that lets a script drive a running Search in flask-marked tabs of its own — its consent mark, security and protocol; the ./bench CLI and its test-run-only commands; isolated test worlds (SEARCH_PROBE, --test, --world), hidden probes that must never show a window, fresh.sh, and the search-bench agent skill.
- [Test suites](test-suites.md) - Every kind of test in the repository and how to run it — the SearchTests XCTest target (swift test), standalone swiftc harnesses (test-find, HistoryRegression, extension files), Python probe tests that drive a hidden built app through the bench in their own worlds, and what is deliberately left to hand checks on a release candidate.
