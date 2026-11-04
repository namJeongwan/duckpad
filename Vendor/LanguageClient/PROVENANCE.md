# LanguageClient subset

- Upstream: https://github.com/ChimeHQ/LanguageClient
- Version: 0.8.2, commit `4f28cc3cad7512470275f65ca2048359553a86f5`.
- License: BSD-3-Clause, retained verbatim in `LICENSE`.

Only InitializingServer, StatefulServer, AsyncStreamTap, and Server+Shutdown are
included. They retain upstream initialization, capability registration, request
forwarding, and shutdown behavior. The target preserves upstream Swift 5 language
mode. Duckpad supplies the authenticated XPC/stdio data channel separately.

The unused file-watching/process-environment wrappers are excluded. In particular,
the upstream package pulls in FSEventsWrapper, whose pinned checkout contains
all-rights-reserved headers and no redistribution license; those sources are not
included or linked in Duckpad. The subset requires only the BSD-licensed LSP and
JSONRPC packages and the MIT-licensed Semaphore package.

One local change replaces a fatal error on a server-to-client request during
initialization with forwarding to the client event stream. LSP progress/config
requests must not crash the application before the initialize reply arrives.
These files are maintained in-tree and are not generated.

Trailing whitespace is normalized for repository checks.
