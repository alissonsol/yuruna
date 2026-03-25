# Windows 11 Unattended Configuration

The `autounattend.xml` file automates the Windows 11 installation process. It is placed on a seed ISO and mounted as a DVD drive during VM creation. Windows Setup automatically detects it and follows the configuration without manual interaction.

## Product Keys

The `autounattend.xml` defaults to the **Windows 11 Pro** generic installation key. This key allows installation to complete without requiring a purchased license. The system will be in an unactivated state after installation.

### Generic Installation Keys (for automated install)

These keys are publicly provided by Microsoft for installation purposes. They allow the OS to install and function without immediate activation.

| Edition | Generic Installation Key |
|---|---|
| **Windows 11 Pro** (default) | `VK7JG-NPHTM-C97JM-9MPGT-3V66T` |
| Windows 11 Home | `YTMG3-N6DKC-DKB77-7M9GH-8HVX7` |
| Windows 11 Enterprise | `XGVPP-NMH47-7TTHJ-W3FW7-8HV2C` |
| Windows 11 Education | `YNMGQ-8RYV3-4PGQ3-C8XTP-7CFBY` |

### KMS Client Keys (for enterprise/lab environments)

KMS (Key Management Service) client keys are designed for enterprise environments where a local KMS server handles activation. These are useful for internal lab setups where machines do not need to activate against Microsoft's retail servers.

| Edition | KMS Client Key |
|---|---|
| **Windows 11 Pro** | `W269N-WFGWX-YVC9B-4J6C9-T83GX` |
| Windows 11 Home | N/A (Home does not support KMS) |
| Windows 11 Enterprise | `NPPR9-FWDCX-D2C8J-H872K-2YT43` |
| Windows 11 Education | `NW6C2-QMPVW-D7KKK-3GKT6-VCFB2` |
| Windows 11 Pro for Workstations | `NRG8B-VKK3Q-CXVCJ-9G2XF-6Q84J` |

Reference: [Microsoft KMS Client Activation Keys](https://learn.microsoft.com/en-us/windows-server/get-started/kms-client-activation-keys)

## Changing the Edition

To install a different edition, edit `autounattend.xml` and change:

1. The `<Key>` value in the `<ProductKey>` section to the corresponding key from the tables above.
2. The `<Value>` in the `<InstallFrom>` section to match the edition name (e.g., `Windows 11 Enterprise`).

## Activating After Installation

After installation, you can activate using a purchased retail key via PowerShell (run as Administrator):

```powershell
# Uninstall the generic key
slmgr /upk
# Install your purchased key
slmgr /ipk XXXXX-XXXXX-XXXXX-XXXXX-XXXXX
# Activate online
slmgr /ato
```

## License Deactivation

Before wiping a VM that used a retail key, deactivate the license to free it for reuse:

```powershell
# Uninstall the product key
slmgr /upk
# Clear the key from the registry
slmgr /cpky
```
