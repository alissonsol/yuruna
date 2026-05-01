# Windows Hyper-V Troubleshooting

## Cleaning Up Old Files

Run `Remove-OrphanedVMFiles.ps1`. It removes any files not tied to an existing VM, including downloaded base images — re-run `Get-Image.ps1` afterward.

Back to [[Windows Hyper-V Host Setup](README.md)]
