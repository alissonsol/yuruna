# Windows Hyper-V Troubleshooting

## Cleaning Up Old Files

- Execute the script `Remove-OrphanedVMFiles.ps1`.
- Ensure you understand that this will remove any files not associated with existing VMs. That may include the downloaded original images, which will then need to be downloaded again using the `Get-Image.ps1` scripts.

Back to [[Windows Hyper-V Host Setup](README.md)]
