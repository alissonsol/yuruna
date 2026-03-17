# Yuruna Ubuntu Instructions

See the full list of [requirements](./requirements.md) for details on each tool.

## Automated installation

Use the [yuruna](../vde/docs/yuruna.md) post-VDE setup script to install all requirements on an Ubuntu Desktop guest. Open a terminal and enter the commands:

```bash
/bin/bash -c "$(wget --no-cache -qO- https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/vde/guest.ubuntu.desktop/ubuntu.desktop.yuruna.bash)"
```

After the script completes, follow the [manual steps](../vde/docs/yuruna.md#manual-steps-after-the-script-completes) to finish the setup.

Back to the main [readme](../README.md)
