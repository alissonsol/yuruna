# Amazon Linux running in Windows Hyper-V - Nerd-Level Details

Copyright (c) 2019-2026 by Alisson Sol et al.

## 1) Get all in!

What can you do during [The Long Dark Tea-Time of the Soul](https://en.wikipedia.org/wiki/The_Long_Dark_Tea-Time_of_the_Soul)?

This is an update of a previous effort to get Amazon Linux working with Hyper-V locally [here](https://github.com/alissonsol/experiments/tree/main/2025/2025-09.amazon.linux.hyper-v). That was already an update from another effort that was based on [Amazon WorkSpaces](https://github.com/alissonsol/archive/tree/main/WorkSpaces/2019-03.WorkSpaces.AmazonLinux.setup). See [requirements and limitations](https://docs.aws.amazon.com/linux/al2023/ug/hyperv-supported-configurations.html). Instructions here were tested using Amazon Linux 2023 (not Amazon Linux 1 or Amazon Linux 2). Unless instructions indicate it differently, commands and environment variables used are from [PowerShell](https://github.com/powershell/powershell).

This version uses all the "shortcuts" from the previous effort. If you need more customization, you need to go back [here](https://github.com/alissonsol/experiments/tree/main/2025/2025-09.amazon.linux.hyper-v) and follow the more detailed instructions.

### 1.1) Downloading the latest files

Check that the PowerShell version is a recent one (> 7.5) and that you run from an Administrator window.

```powershell
> $PSVersionTable.PSVersion

Major  Minor  Patch  PreReleaseLabel BuildLabel
-----  -----  -----  --------------- ----------
7      5      4
```

<mark>Run the PowerShell script [`Get-Image.ps1`](./Get-Image.ps1).</mark>

## 2) Creating the VM(s)

One VM is good. Many VMs: far better.

This is how to quickly create VMs with specific configuration. First, the steps that needed to be executed just one time per host machine.
- In order to automate the process of creating the `seed.iso` files, download and install the latest [Windows Assessment and Deployment Kit (Windows ADK)](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install).
- Confirm that the path to the executable `oscdimg.exe` is correct at the top of the `VM.common.psm1` PowerShell module.
- The PowerShell script `Get-Image.ps1` needs to be executed at least once per host machine.

<mark>Now, for each VM to be created.</mark>
- Configure the files in the `vmconfig` folder.
  - A minimal change that is suggested: change the `local-hostname` in the `meta-data` file.
  - See the instructions [here](https://github.com/alissonsol/experiments/tree/main/2025/2025-09.amazon.linux.hyper-v) to recreate the `seed.iso` file.
- Execute the PowerShell script `New-VM.ps1 <vmname>`.
  - For example, `New-VM.ps1 amazon-linux01`
    - This will create a VM named `amazon-linux01`. It reads configuration from the `seed.iso` file created with the information from the `vmconfig` folder at that point in time. This generated `seed.iso` is placed in a folder with `<vmname>` under the `$localVhdxPath` (since the file name needs to be `seed.iso` for every VM).
- From the Hyper-V Manager, start the new virtual machine.
- Login and change the password.
  - Unless you changed the defaults in the [vmconfig/user-data](./vmconfig/user-data) file, at this point the user is `ec2-user` and the password is `amazonlinux`.
  - Having to type the password again to confirm you want to change it is as annoying as it gets!
  - At this point, if there is any update since the Amazon Linux image was last downloaded, you will be asked to execute the command `/usr/bin/dnf check-release-update`. Proceed as per the instructions to upgrade the operating system binaries before proceeding.
- Navigate to the root folder (`cd /`) and execute `sudo bash amazon.linux.update.bash`.
  - The section `runcmd` in the `user-data` file already downloaded the file `amazon.linux.update.bash` to the root of the target VM. After executing the Bash script, the Graphical User Interface and the tools from section 2 are installed.
- Execute `sudo reboot now` and the VM reboots already in the GUI mode with the tools.

### 2.1) Changing memory allocation

The VM is created with 16 GB of RAM by default. To change the memory allocation for an existing VM (the VM must be stopped first):

```powershell
# Stop the VM if running
Stop-VM -Name "amazon-linux01" -Force
# Set memory to desired value (e.g., 32 GB)
Set-VM -Name "amazon-linux01" -MemoryStartupBytes 32768MB -MemoryMinimumBytes 32768MB -MemoryMaximumBytes 32768MB
# Start the VM again
Start-VM -Name "amazon-linux01"
```

To change the default for new VMs, edit the `New-VM.ps1` script and replace `16384MB` with the desired value in megabytes (e.g., `32768MB` for 32 GB).

<mark>CHECKPOINT: This is a great time to create a checkpoint `VM Configured` for each VM.</mark>

- If lost track, all you did so far was to configure the data files, execute two PowerShell scripts, change a password, execute a Bash script, and reboot. You are now in a GUI and can start a browser or VS Code.
  - Technically, you can add the line to run `bash amazon.linux.update.bash` to the `user-data` file. That usually ends-up creating a confusing first login that is still under the command line interface, instead of the GUI, when the password needs to be changed. It is a personal preference to do that, which technically removes one step in the process (execute a Bash script).

Test VM connectivity.
- Open a terminal and get the IP for each VM: `ifconfig` or `ifconfig eth0`.
- Ping to another IP address. Try DNS resolution: `ping www.google.com`.
- For convenience, you can find the IP addresses for the running guests from the Hyper-V host with this PowerShell command:
  - `Get-VM | Where-Object {$_.State -eq "Running"} | Get-VMNetworkAdapter | Select-Object VMName, IPAddresses`

<mark>Technically, that is all folks!</mark> You should now be able to follow the OpenClaw [Getting Started](https://docs.openclaw.ai/start/getting-started). You have the requirements installed, and can start by running the onboarding wizard: `openclaw onboard --install-daemon`. Note: you may benefit from installing and configuring other required software ahead of time, like AI connectors, email clients, messaging clients, etc.

## 3) Optional

This assumes that the user has already executed the "tools" installation, and so Visual Studio Code is available to edit any files, the Firefox Browser is available to visit sites, etc. These are all optional. The commands below are "hacks" for x86_64 architectures and locked to versions of the keys and packages. Update as needed.

- Install PowerShell
  - `sudo dnf install powershell -y`

## 4) TODO

### 4.1) GUI resolution improvement

This is a good contribution opportunity, since it is still a "TODO". The following path was tested, but instructions didn't work.
- Instructions for server from the [Tutorial: Configure TigerVNC server on AL2023](https://docs.aws.amazon.com/linux/al2023/ug/vnc-configuration-al2023.html).
- Client tested from: [Download TightVNC](https://www.tightvnc.com/download.php).

Tried changing the resolution to 1920x1080, and still got 1024x768. For now, since working with multiple VMs, not a roadblock, and just an inconvenience.
