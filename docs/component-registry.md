# Component registry login

The component-push pipeline in
[`automation/Yuruna.Component.psm1`](../automation/Yuruna.Component.psm1)
needs to log into the target container registry before pushing the
built image. Today's supported registries (Azure ACR, AWS ECR, Google
Artifact Registry, Docker Hub, generic Docker login) each use a
different CLI and a different credential model. The dispatcher in
[`automation/Yuruna.Component.Registry.psm1`](../automation/Yuruna.Component.Registry.psm1)
asks the credential-provider registry in
[`test/modules/Test.CredentialProvider.psm1`](../test/modules/Test.CredentialProvider.psm1)
"what is the login command for `<host>`?" and pipes the answer
through the same `Invoke-ComponentCommand` wrapper that handles
build / tag / push — so the `registryLogin` phase shares
`docker.stderr.log` and `docker.rc` with the rest of the pipeline.

The dispatcher keeps registry knowledge out of `Yuruna.Component`,
which carries no per-registry branching like
`if ($registryLocation -like '*azurecr.io*')`. Adding a new registry
kind (ECR, GAR, Docker Hub, Harbor, Nexus, …) is one
`Register-CredentialProvider` call; nothing in `Yuruna.Component`
changes.

## Cross-tree boundary

Yuruna.Component lives in `automation/`; the credential-provider
registry lives in `test/modules/`. This is the only `automation/ ->
test/` import edge in the codebase, and it is justified because the
providers are deployment-time knowledge, not test-time knowledge —
the module naming is what places the registry under
`test/modules/`. The bridge file
[`automation/Yuruna.Component.Registry.psm1`](../automation/Yuruna.Component.Registry.psm1)
concentrates the boundary so future readers see it in one place.

## Public surface

| Function | Module | Used by |
|---|---|---|
| `Register-CredentialProvider -Type -Pattern -Authenticator [-LoginCommand]` | `Test.CredentialProvider` | Built-in registrations at module load; external modules can add more |
| `Get-CredentialProvider -Target` | `Test.CredentialProvider` | Dispatcher; introspection |
| `Get-CredentialProviderMatrix` | `Test.CredentialProvider` | Startup capability matrix |
| `Repair-Credential -Target` | `Test.CredentialProvider` | Self-heal path: re-auth after a 401 mid-push |
| `Clear-CredentialProvider` | `Test.CredentialProvider` | Tests only |
| `Resolve-ComponentRegistryLogin -RegistryLocation` | `Yuruna.Component.Registry` | The push pipeline; returns the login command string or `$null` |

Each provider exposes two scriptblocks with disjoint use cases:

- **`Authenticator`** — self-heal path
  (`Repair-Credential` after a 401). Runs the auth in-process
  (calls `az acr login`, `gcloud auth print-access-token | docker
  login`, …). Returns `[bool]`.
- **`LoginCommand`** — batch pipeline
  (`Yuruna.Component` push). Returns the shell command string the
  push pipeline pipes through its own logging wrapper. Returns
  `$null` when the environment doesn't have the credentials (the
  pipeline silently skips the login phase and lets the operator's
  pre-existing docker credential helper take over).

## Built-in providers

| Type | Pattern | Login command shape |
|---|---|---|
| `azurecr` | `\.azurecr\.io(/\|$)` | `az acr login -n <registry>` |
| `ecr` | `\.dkr\.ecr\.[^.]+\.amazonaws\.com(/\|$)` | `aws ecr get-login-password --region <region> \| docker login --username AWS --password-stdin <host>` |
| `gar` | `-docker\.pkg\.dev(/\|$)` | `gcloud auth print-access-token \| docker login -u oauth2accesstoken --password-stdin https://<host>` |
| `dockerhub` | `^(index\.)?docker\.io(/\|$)` | `$env:YURUNA_DOCKER_HUB_PASSWORD \| docker login --username $env:YURUNA_DOCKER_HUB_USERNAME --password-stdin` |
| `docker-generic` | `.+` | `$env:YURUNA_REGISTRY_PASSWORD \| docker login --username $env:YURUNA_REGISTRY_USERNAME --password-stdin <host>` |

Order matters and is preserved: more specific patterns precede the
catch-all `docker-generic`. The path-suffix tolerance
(`(/$|$)`) lets `foo.azurecr.io/myimage` match the same provider as
the bare host.

## Credential env vars

Docker Hub and `docker-generic` read credentials from environment
variables; the others derive auth from the operator's existing CLI
context (`az login`, `aws configure`, `gcloud auth login`):

| Env var | Used by |
|---|---|
| `YURUNA_DOCKER_HUB_USERNAME` / `YURUNA_DOCKER_HUB_PASSWORD` | `dockerhub` provider |
| `YURUNA_REGISTRY_USERNAME` / `YURUNA_REGISTRY_PASSWORD` | `docker-generic` provider |

When either env-var pair is missing, the corresponding provider's
`LoginCommand` returns `$null` — the push pipeline silently skips
the login phase and the operator's pre-existing docker credential
helper handles the push. This is the "no login needed" default for
any registry without provider-supplied credentials.

## Adding a new registry kind

1. Pick a `Type` name (`harbor`, `nexus`, `quay`, …) and a regex
   `Pattern` matching the host shape.
2. Implement both scriptblocks (self-heal `Authenticator` and batch
   `LoginCommand`); return `[bool]` and `[string]` respectively.
3. Call `Register-CredentialProvider` at the bottom of
   [`Test.CredentialProvider`](../test/modules/Test.CredentialProvider.psm1)
   in registration order — more specific patterns first.
4. The push pipeline picks up the new provider on the next outer
   restart; nothing in `Yuruna.Component` changes.

## Related

- [Host-condition registry](host-condition-registry.md) — same `New-YurunaRegistry` primitive, different domain.
- [Host I/O registry](host-io.md) — the older, two-level registry that established the pattern.
- [Remediation dispatcher](remediation.md) — calls `Repair-Credential` when a push fails with 401.

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.06.19

Back to [Yuruna](../README.md)
