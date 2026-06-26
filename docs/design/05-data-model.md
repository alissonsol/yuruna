# Configuration data model

> One sentence: the YAML schema the engine and harness read — project deploy
> data and test-harness runtime data — as two entity-relationship views.

See [Design overview](00-index.md) · [Yuruna Architecture](../architecture.md).

Derived from `yuruna-project/{example,template}/<project>/`,
`automation/Set-*` (which read `config/<cloud>/*.yml`), `test/test.config.yml`,
and the `test/extension/{authentication,notification}` configs validated by
`test/schemas/{users,vault,notification.transports}.schema.yml`.
No secret values appear here — only field names.

## Project deploy data model

```mermaid
erDiagram
    PROJECT ||--|{ CLOUD_CONFIG : "per cloud"
    PROJECT ||--o{ SEQUENCE : "test/{gui,ssh}"
    CLOUD_CONFIG ||--|| RESOURCES : resources.yml
    CLOUD_CONFIG ||--|| COMPONENTS : components.yml
    CLOUD_CONFIG ||--|| WORKLOADS : workloads.yml

    PROJECT {
        string name
        path components_dir
        path workloads_dir
    }
    CLOUD_CONFIG {
        enum cloud "localhost aws azure gcp"
    }
    RESOURCES {
        map globalVariables
        list resources "name, template vars"
    }
    COMPONENTS {
        map globalVariables
        list components "project, buildPath"
    }
    WORKLOADS {
        map globalVariables
        list workloads "helm kubectl shell"
    }
    SEQUENCE {
        string action
        string description
        map variables
    }
```

## Test-harness runtime data model

```mermaid
erDiagram
    TEST_CONFIG ||--o{ GUEST : guestSequence
    TEST_CONFIG ||--|| USERS_MAP : "authentication ext"
    TEST_CONFIG ||--|| TRANSPORTS : "notification ext"
    USERS_MAP ||--o{ VAULT_ENTRY : "vaultKey / localOsPasswordRef"
    GUEST ||--o{ STATUS_EVENT : "cycle events"

    TEST_CONFIG {
        list guestSequence
        map repositories "frameworkUrl projectUrl"
        map testCycle "stepTimeoutMinutes cycleDelaySeconds"
        map vmCommunication "keystrokeMechanism vncPort"
        map statusService "isEnabled port"
        map pool "enabled intentGitUrl networkReplicate"
        map networkStorage "poolNetworkPath stashNetworkPath"
    }
    GUEST {
        string guestKey
        string hostType
        string vmName
    }
    USERS_MAP {
        bool strict
        string localOsUser
        map corporate "domain sam upn"
        string vaultKey
        string localOsPasswordRef
    }
    VAULT_ENTRY {
        string password
        string previousPassword
        datetime updatedUtc
    }
    TRANSPORTS {
        map transports "resend apiKey fromEmail"
        map subscribers "event transport address"
    }
    STATUS_EVENT {
        string event
        string state
        datetime utc
    }
```

`USERS_MAP` (`users.yml`) maps each logical sequence username to a login
identity; its `vaultKey` / `localOsPasswordRef` resolve into `VAULT_ENTRY`
(`vault.yml`), the per-cycle secret store wiped on cycle success. `TRANSPORTS`
(`transports.yml`) pairs provider credentials (`transports.resend`) with
per-event-code `subscribers`. Six entities — within the [≤7 rule](00-index.md#the-7-rule-grouping-decisions).

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.06.26
