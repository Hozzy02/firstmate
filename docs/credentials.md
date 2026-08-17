# Credential management

This document is the single owner of Firstmate's credential architecture, trust model, private policy schema, provider-adapter contract, captain-only boundaries, and secondmate credential rules.
[`bin/fm-credential.sh`](../bin/fm-credential.sh) owns the exact command mechanics and help text.
[`tests/fm-credential.test.sh`](../tests/fm-credential.test.sh) is the portable sentinel regression for the guarantees described here.

## Trust model

Firstmate workers run as the same operating-system user as the operator.
The version 1 credential broker reduces accidental leakage and excessive ambient access.
It is not a hard sandbox against a malicious or compromised worker running as that same user.
A mode-0600 file, same-user process environment, same-user socket, or host-local service-account token remains reachable to sufficiently determined code under that identity.
True least-privilege containment requires separate operating-system identities, containers or sandboxes with distinct security principals, or an external broker that authenticates workers independently of the shared account.
Until that isolation exists, credential grants are policy and audit controls rather than a claim of hostile-worker containment.

Project tools that legitimately receive a deployment credential can use or exfiltrate it during that command.
The adapter narrows which command receives the credential and how long it exists, but it cannot make untrusted project code safe.

## Secret-handling invariants

- A worker requests an approved operation through an opaque alias and never receives a generic plaintext `get` operation.
- A secret never appears in process arguments, pane input, task metadata, status events, audit records, diagnostics, reports, test fixtures committed to the repository, or timing records.
- A secret is never added to the long-lived worker environment or sent through a terminal backend.
- A secret reference is private inventory metadata, not a secret value, and stays in the gitignored home policy.
- The broker resolves a secret only after policy, task identity, operation, expiration, provider, and audit preflight checks pass.
- The broker keeps the resolved value in its private subshell and gives it only to the exact provider child through the adapter's declared channel.
- Stdin or an inherited file descriptor is preferred when the provider supports it.
- A mode-0600 ephemeral file is allowed only when a provider requires a file, and traps remove it after the command.
- A command-scoped environment variable is the last-mile delivery channel only when the provider requires one.
- Provider output is bounded and exact-value redacted without replacing the provider's real exit status.
- Audit data contains identities and classifications only.
- Provider errors are classified without replaying raw authentication responses.
- Missing, expired, indeterminate, interactive-only, or policy-denied credentials fail closed.
- Ambient provider authentication never substitutes for an alias that was explicitly requested.

The version 1 implementation uses a protected temporary file only while reading one value from 1Password and protected bounded capture files only while redacting provider output.
Those files live under the effective Firstmate home's `state/` directory with a private runtime directory and are removed by traps.
The sentinel regression scans task state, worktrees, audit data, command output, and runtime residue after each operation.
Cloudflare token values must be non-empty, at most 8,192 bytes, contain no whitespace, and use only the adapter's accepted ASCII token characters.

## Private policy file

The effective home policy is `config/credentials.json` under `FM_HOME`.
The file is gitignored and contains no secret values.
Create it with mode `0600`, or use mode `0400` when no local writer needs it.
The broker refuses a missing file, symlink, non-regular file, foreign owner, link count other than one, group or other access, or a policy directory that resolves outside the effective home.
JSON must be UTF-8, must contain no duplicate key at any level, and must match this schema exactly.

```json
{
  "version": 1,
  "aliases": {
    "dash.cloudflare.deploy": {
      "adapter": "cloudflare-wrangler",
      "project": "dash.lifelinevending.com",
      "environment": "production",
      "reference": "op://<vault-id>/<item-id>/<field-id>",
      "delivery": "env:CLOUDFLARE_API_TOKEN",
      "operations": ["deploy", "deploy-dry-run", "whoami"],
      "expires_at": null,
      "captain_only_rotation": true
    }
  }
}
```

[`docs/examples/credentials.json`](examples/credentials.json) is a copyable non-secret example.

### Top-level fields

- `version` is required and must be the integer `1`.
- `aliases` is required and must be an object keyed by unique exact alias names.
- No other top-level key is accepted.

An alias name may contain ASCII letters, digits, dots, underscores, and dashes.
An alias name must begin with an ASCII letter or digit.
Aliases are opaque handles and must not embed a secret value.

### Alias fields

- `adapter` is required and names one implemented provider adapter.
- `project` is required and names exactly one registered project.
- `environment` is required and names exactly one provider environment.
- `reference` is required and must be an `op://vault/item/field` reference with three non-empty path segments.
- `delivery` is required and must equal the adapter's fixed delivery channel.
- `operations` is required and must be a non-empty duplicate-free subset of the adapter's fixed operation allowlist.
- `expires_at` is required and is either `null` or a UTC RFC3339 timestamp ending in `Z`.
- `captain_only_rotation` is required and must match the adapter's rotation classification.
- No other alias key is accepted.

The `project` and `environment` values are exact atoms rather than patterns.
The policy has no command, executable, argument-template, file-path, or shell-string field.
The adapter owns all executable and argument construction.
Common token patterns in any string value are rejected as likely inline secrets.
Unknown adapters, operations, delivery channels, and keys are rejected.

The current schema accepts only the `cloudflare-wrangler` adapter.
Its delivery must be `env:CLOUDFLARE_API_TOKEN`.
Its operations may contain only `deploy`, `deploy-dry-run`, and `whoami`.
Its static-token rotation flag must be `true`.

## Command interface

Policy validation requires `jq` and `python3`, with Python used only to reject duplicate JSON keys before normal schema parsing.
Credential resolution requires the 1Password CLI `op` and provider probing requires Wrangler either in the task's local `node_modules/.bin` or on `PATH`.

Run a non-secret readiness check with:

```sh
bin/fm-credential.sh doctor
```

`doctor` validates the private policy, checks parser and provider prerequisites, probes each configured alias, and reports classifications without values or references.
An invalid policy or unavailable alias makes `doctor` fail.

Check one alias with:

```sh
bin/fm-credential.sh status dash.cloudflare.deploy
```

`status` reports `available`, `available-expiring`, `expired`, `missing`, `missing-backend`, `missing-provider`, `credential-invalid`, `credential-revoked-or-expired`, `insufficient-scope`, `network-failure`, or `provider-failure`.
A static token with an `expires_at` value in the next 30 days remains usable but reports `available-expiring` with its non-secret timestamp.

Run an approved operation with:

```sh
bin/fm-credential.sh exec <task-id> <alias> -- <adapter-operation>
```

`exec` requires a safe, single-link task metadata file under the effective home's `state/` directory.
The metadata must contain exactly one non-empty `project=`, `kind=`, and `worktree=` field.
Version 1 provider operations require `kind=ship`.
The recorded project must resolve exactly to `FM_HOME/projects/<alias-project>`.
The recorded worktree becomes the provider command's working directory.

The caller supplies an adapter operation rather than an executable.
The adapter chooses either the recorded worktree's executable `node_modules/.bin/wrangler` or an executable `wrangler` found on `PATH`.
The caller cannot request `env`, `printenv`, `sh`, `bash`, login, logout, auth, an arbitrary executable, or an unknown operation.
Version 1 uses an explicit empty caller-argument allowlist for each Wrangler operation.
The caller cannot pass aliases, flags, positional arguments, paths, or boolean negations after the operation.
The broker sets `CLOUDFLARE_ENV` from the alias, so command arguments cannot change the authorized environment.

`exec` first probes the credential with `wrangler whoami` for deployment operations.
The probe output is discarded on success.
A failed probe stops deployment and returns the probe's real exit status with a non-secret failure class.
The selected provider operation's output is capped at 65,536 bytes per stream and exact-value redacted.
The broker returns the selected provider operation's real exit status.

Every authorized or denied `exec` attempt that reaches audit preflight appends one tab-separated line to `state/credential-audit.log`.
The line contains task, alias, adapter, operation, UTC start and end timestamps, exit class, and numeric exit code.
The audit log must remain an owned, single-link, mode-0600 regular file.
Arguments, references, provider response bodies, environment values, and secret fingerprints are not audited in version 1.

## Provider-adapter contract

Every adapter must declare and enforce all of the following properties in code and in this owner document.

- The source backend and exact reference form identify where the credential is resolved.
- The project, environment, and purpose scope define the grant's identity boundary.
- The delivery channel defines the only child input that may carry the credential.
- The probe establishes availability without printing credential material.
- The expiry and refresh classification states whether the credential refreshes automatically, expires statically, or requires interactive recovery.
- The rotation owner identifies who may create, replace, switch, or revoke the credential.
- The allowed operations and executables form a fixed allowlist owned by adapter code.
- The safe argument policy prevents a caller from changing project, environment, authentication, configuration path, or executable.
- The output classifier distinguishes missing credentials, revoked or expired credentials, insufficient scope, provider availability, and other provider failures.
- The adapter states whether project code executed by the provider can access the credential.
- Captain-only actions are listed explicitly.

No adapter means no credential delivery.
Adding an adapter requires a behavior test with a generated sentinel, negative policy and provider paths, output redaction, exit-status preservation, and cleanup assertions.

## Cloudflare Wrangler adapter

The `cloudflare-wrangler` adapter stores one scoped Cloudflare API token per project and environment in one 1Password item.
An account-owned token is preferred where the Cloudflare product supports it.
A scoped user token is acceptable when an account-owned token is unavailable.
Personal OAuth and legacy global API keys are not accepted as alias storage.

The 1Password reference names only the token field.
The token receives only the account, zone, resource, and deployment permissions needed by that alias.
Provider-side IP or TTL restrictions should be used when they fit the deployment environment.

The adapter resolves the token through `op read` only inside the broker's private runtime.
The broker's `OP_SERVICE_ACCOUNT_TOKEN` or `OP_SESSION` is removed before Wrangler starts.
Wrangler receives `CLOUDFLARE_API_TOKEN` only in its exact child environment.
Legacy Cloudflare key and email variables are removed from that child.
The child receives an isolated temporary `HOME` and `XDG_CONFIG_HOME`, so the operator's stored Wrangler OAuth state is unavailable.
[Cloudflare's Wrangler environment documentation](https://developers.cloudflare.com/workers/wrangler/system-environment-variables/) defines `CLOUDFLARE_API_TOKEN` as the automation credential.
[Cloudflare's Wrangler command documentation](https://developers.cloudflare.com/workers/wrangler/commands/general/) gives the API-token environment variable precedence over stored OAuth credentials.
The isolated auth home is a second enforcement layer that makes ambient OAuth fallback unavailable when an alias is requested.

The adapter maps operations as follows.

| Operation | Fixed Wrangler command | Additional behavior |
| --- | --- | --- |
| `whoami` | `wrangler whoami` | Acts as the non-secret provider probe |
| `deploy` | `wrangler deploy` | Runs `whoami` first and then performs the deployment |
| `deploy-dry-run` | `wrangler deploy --dry-run` | Runs `whoami` first and cannot drop the fixed dry-run flag |

Static Cloudflare API tokens do not refresh.
They have no mutable refresh cache, so the adapter needs no per-alias serialization lock and supports concurrent isolated runtimes.
`expires_at` tracks a known provider-side expiry.
The broker refuses an expired timestamp and warns during the final 30 days.
An absent provider-side expiry is represented by `null` and requires an external captain-owned rotation schedule.

Provider output classifications are diagnostic heuristics rather than an authorization oracle.
Explicit revoked or expired responses report `credential-revoked-or-expired`.
Invalid or unauthorized responses report `credential-invalid`.
Permission and HTTP 403 responses report `insufficient-scope`.
Transport, DNS, timeout, and connection responses report `network-failure`.
Every other non-zero Wrangler response reports `provider-failure`.
The original provider exit status remains the command exit status.

Wrangler may execute or bundle project code while the credential is in its process environment.
That access is inherent to the deployment operation and remains inside the same-user soft boundary.

## Captain-only boundaries

The fleet may validate policy, probe an approved alias, resolve it for an already approved operation, execute that operation, classify failures, warn about expiry, and clean up runtime material.
The following actions remain captain-only.

- Create the initial 1Password custom vaults and bootstrap a restricted service account or other broker identity.
- Approve a new alias, project, environment, purpose, operation, or expanded provider permission.
- Approve a service-account vault grant or any other trust-domain expansion.
- Complete interactive OAuth, OIDC, SSO, MFA, passkey, biometric, keychain, or browser consent.
- Import an existing private SSH key through the supported 1Password desktop workflow.
- Create, rotate, or revoke root, administrator, bootstrap, token-minting, or other security-principal credentials.
- Rotate a static Cloudflare API token or change its resource and permission scope.
- Decide incident scope and revocation after suspected compromise.
- Enable agent forwarding, a long-lived interactive approval window, or a stronger operating-system isolation design.

The version 1 broker has no create, import, rotate, revoke, login, or raw retrieval command.

## Secondmate rules

A secondmate receives a filtered credential policy containing only explicitly granted aliases for its registered projects.
The primary policy is never added to `FM_INHERITABLE_CONFIG` and is never copied wholesale.
Version 1 validation detects a secondmate home through `.fm-secondmate-home` and rejects any alias whose project is absent from that home's `data/projects.md` registry.
The registry check is a provisioning boundary in the same-user trust model and does not replace explicit alias approval.

Every remote host uses its own 1Password service account or provider workload identity.
That identity is limited to the host's approved project and environment vaults.
The primary never forwards `OP_SESSION`, `OP_SERVICE_ACCOUNT_TOKEN`, a personal SSH agent, cloud OAuth refresh files, browser cookies, or secret environment values.
Remote job execution preserves its existing `env -i` boundary.
A remote worker invokes the host-local broker after the remote home has been provisioned with a filtered policy and host-local identity.

Local secondmates remain subject to the same-user soft boundary even though each has an isolated `FM_HOME`.
Removing an alias grant must converge to policy denial without deleting or exposing unrelated backing secrets.

## Current limits

Version 1 implements policy validation and the Cloudflare Wrangler adapter only.
Task-lifecycle alias grants, proactive session-start diagnostics, filtered policy transfer, remote doctor integration, SSH key creation, and provider-native short-lived adapters remain later slices.
The absence of those later integrations does not relax this document's secret-handling invariants.
