# spike/sample-java — LSP integration fixture

A minimal Maven Java project with a real inheritance graph, used as the fixture
for the code-navigation integration tests
(`Tests/OnyxIntegrationTests/LSPManagerIntegrationTests.swift`):

- `Shape` (interface) ← `AbstractShape` (abstract) ← `Circle`, `Square`
- `Rectangle` implements `Shape` directly
- `Main` calls `area()` from several sites

So the tests can assert real results: implementors of `Shape`, subtypes of
`AbstractShape`, callers of `area()`.

> The throwaway `jdtls-spike` harness that originally proved the transport
> (Eclipse JDT over a clean byte pipe, local + SSH) has been retired now that
> the production `LSPManager` shipped. Its findings live on in
> `docs/adr/ADR-007-lsp-no-pty-transport.md` and
> `docs/lsp-code-navigation-plan.md`. See git history (`Sources/JDTLSSpike`)
> if you need the original harness.

## Running the integration tests

Install jdtls locally (Java 21+ and python3 required):

```sh
mkdir -p ~/.onyx/jdtls && \
curl -fsSL https://download.eclipse.org/jdtls/snapshots/jdt-language-server-latest.tar.gz \
  | tar xz -C ~/.onyx/jdtls
swift test --filter LSPManagerIntegrationTests
```

The SSH-path test additionally needs `ONYX_LSP_SSH_HOST` (+ `_USER`/`_PORT`/
`_IDENTITY`) pointing at a reachable host with jdtls installed.
