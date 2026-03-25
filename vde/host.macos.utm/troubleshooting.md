# macOS UTM Host Troubleshooting

WARNING: This is not a section for everyone. Instructions are intentionally brief — don't follow them unless you know what you are doing!

## Packages, PATH, and Homebrew issues

- If some packages, like PowerShell, weren't installed using `Homebrew`, those won't be updated by cycles of `brew update` and `brew upgrade`.
- Moreover, there may be packages installed by different methods, used according to PATH order ([DLL hell](https://en.wikipedia.org/wiki/DLL_hell) has company!).
- For fixing most of those situations, use the script `brew-doctor-fix.sh`.
- At times, you may still need to proceed with manual steps, like `brew uninstall powershell` and then follow with a reinstall `brew install powershell`.

## Cleaning Up Old Files

- Execute the script `Remove-OrphanedVMFiles.ps1`.
- Ensure you understand that this will remove any files not associated with existing VMs. That may include the downloaded original images, which will then need to be downloaded again using the `Get-Image.ps1` scripts.

Back to [[macOS UTM Host Setup](README.md)]
