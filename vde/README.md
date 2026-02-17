# Virtual Development Environment (VDE)

Your first task is to establish a **Virtual Development Environment (VDE)**. The VDE gives you a consistent, reproducible workspace that mirrors our target platforms.

Pick the environment that matches your host machine and follow the linked instructions to create your first VM.

## Windows (Hyper-V) host

Complete the [Windows Hyper-V Host](windows.hyper-v.host/README.md) setup first, then follow the instructions for your guest operating system:

- [Amazon Linux](windows.hyper-v.host/amazon.linux.guest/README.md) guest
- [Ubuntu Desktop](windows.hyper-v.host/ubuntu.desktop.guest/README.md) guest

## macOS (UTM) host

Complete the [macOS UTM Host](macos.utm.host/README.md) setup first, then follow the instructions for your guest operating system:

- [Amazon Linux](macos.utm.host/amazon.linux.guest/README.md) guest
- [Ubuntu Desktop](macos.utm.host/ubuntu.desktop.guest/README.md) guest

## Post-VDE Setup

Once your base VDE is running, proceed to the [Post-VDE Setup](scripts.guest/README.md) instructions to quickly download and execute scripts in the guest environment, which will install additional tools and services such as OpenClaw, Visual Studio Code, and more.
