# Windows 11 Unattended Configuration

`autounattend.xml` automates Windows 11 install. It rides a seed ISO mounted as a DVD; Windows Setup detects it and runs unattended.

## Product Keys

Defaults to the **Windows 11 Pro** generic installation key — installs without a purchased license; system is unactivated afterwards.

### Generic Installation Keys (for automated install)

Public Microsoft keys; install and function without immediate activation.

| Edition | Generic Installation Key |
|---|---|
| **Windows 11 Pro** (default) | `VK7JG-NPHTM-C97JM-9MPGT-3V66T` |
| Windows 11 Home | `YTMG3-N6DKC-DKB77-7M9GH-8HVX7` |
| Windows 11 Enterprise | `XGVPP-NMH47-7TTHJ-W3FW7-8HV2C` |
| Windows 11 Education | `YNMGQ-8RYV3-4PGQ3-C8XTP-7CFBY` |

### KMS Client Keys (enterprise/lab)

For environments where a local KMS server handles activation.

| Edition | KMS Client Key |
|---|---|
| **Windows 11 Pro** | `W269N-WFGWX-YVC9B-4J6C9-T83GX` |
| Windows 11 Home | N/A (no KMS support) |
| Windows 11 Enterprise | `NPPR9-FWDCX-D2C8J-H872K-2YT43` |
| Windows 11 Education | `NW6C2-QMPVW-D7KKK-3GKT6-VCFB2` |
| Windows 11 Pro for Workstations | `NRG8B-VKK3Q-CXVCJ-9G2XF-6Q84J` |

Reference: [Microsoft KMS Client Activation Keys](https://learn.microsoft.com/en-us/windows-server/get-started/kms-client-activation-keys).

## Changing the Edition

Edit `autounattend.xml`:

1. `<Key>` in `<ProductKey>` → the key from the tables above.
2. `<Value>` in `<InstallFrom>` → the edition name (e.g. `Windows 11 Enterprise`).

## Activating After Installation

Elevated PowerShell:

```powershell
slmgr /upk                                       # uninstall generic key
slmgr /ipk XXXXX-XXXXX-XXXXX-XXXXX-XXXXX         # install purchased key
slmgr /ato                                       # activate online
```

## License Deactivation

Before wiping a VM that used a retail key:

```powershell
slmgr /upk                                       # uninstall product key
slmgr /cpky                                      # clear registry
```
