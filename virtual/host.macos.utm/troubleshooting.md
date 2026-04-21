# macOS UTM Host Troubleshooting

**Warning:** This is not a section for everyone. Instructions are intentionally brief — don't follow them unless you know what you are doing!

## Packages, PATH, and Homebrew issues

- Packages not installed via `Homebrew` (e.g. PowerShell) won't be updated by `brew update` / `brew upgrade` cycles.
- Packages installed by different methods can shadow each other via PATH order ([DLL hell](https://en.wikipedia.org/wiki/DLL_hell) has company!).
- For most of those situations, use `brew-doctor-fix.sh`.
- Occasionally you may still need manual steps, e.g. `brew uninstall powershell` followed by `brew install powershell`.

## Cleaning Up Old Files

- Run `Remove-OrphanedVMFiles.ps1`.
- Note: this removes any files not associated with existing VMs, including downloaded base images — you would then need to re-run the relevant `Get-Image.ps1` scripts.

Back to [[macOS UTM Host Setup](README.md)]
