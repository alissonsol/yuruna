# `yuruna` Ubuntu instructions

Installing the [requirements](./requirements.md) for Ubuntu still demands several manual steps. Moreover, some of the instructions are outdated. Below are the steps taken to get the requirements working in a Ubuntu machine (v20.04).

## Some initial steps

Enable ssh (so can connect from VS Code)

```shell
sudo apt-get install -y ssh
sudo systemctl enable --now ssh
sudo systemctl status ssh
```

Install network tools and Git

```shell
sudo apt-get install -y net-tools apt-transport-https curl
sudo apt-get install -y git
```

Next, you can install Visual Studio and the extension directly from the Visual Installer in Ubuntu. The reference also has up-to-date instructions.

## Docker

Now for "[the long dard teatime of the soul](https://en.wikipedia.org/wiki/The_Long_Dark_Tea-Time_of_the_Soul)"

```shell
sudo apt-get install -y docker.io
sudo systemctl enable docker
sudo systemctl start docker
sudo systemctl status docker
sudo chmod 666 /var/run/docker.sock
sudo groupadd docker
sudo usermod -aG docker $USER
newgrp docker
docker run hello-world
```

Next, disable the swap file.

- First, use `sudo vi /etc/fstab` (or you preferred editor) and comment the line for the swapfile.
- Then, execute `sudo swapoff -a`

## Kubernetes

If everything is working so far and you are working on a virtual machine, save a checkpoint!

```shell
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add
sudo apt-add-repository "deb http://apt.kubernetes.io/ kubernetes-xenial main"
sudo apt-get update
sudo apt-get install -y kubeadm kubelet kubectl
sudo apt-mark hold kubeadm kubelet kubectl
sudo kubeadm config images pull
```

Replace [ubuntu-dev] to match your hostname

```shell
sudo hostnamectl set-hostname [ubuntu-dev]
sudo kubeadm init --pod-network-cidr=10.244.0.0/16
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
kubectl taint nodes --all node-role.kubernetes.io/master-
kubectl taint nodes --all node.kubernetes.io/not-ready-
kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml
kubectl get nodes
kubectl describe nodes
sudo chown $(id -u):$(id -g) /run/flannel/subnet.env
sudo setcap CAP_NET_BIND_SERVICE=+eip /usr/bin/kubectl
```

## Homebrew

```shell
sudo apt-get install -y build-essential curl file git
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install.sh)"
```

Replace [user] with your account

```shell
echo 'eval $(/home/linuxbrew/.linuxbrew/bin/brew shellenv)' >> /home/[user]/.profile
eval $(/home/linuxbrew/.linuxbrew/bin/brew shellenv)
```

## Other requirements

Another good time for a checkpoint. Install using `brew` or `snap`, depending on what worked!

```shell
sudo snap install powershell --classic
brew install helm
brew install terraform
sudo apt-get install -y libnss3-tools
brew install mkcert
mkcert -install
brew install graphviz
```

Below is needed because context is created with different name

```shell
kubectl config rename-context kubernetes-admin@kubernetes docker-desktop
kubectl config get-contexts
```

## CLI for clouds

Wow! Almost there. Another checkpoint? [Azure](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli-linux?pivots=apt) looks longer, but at least it was easier to find. Great job AWS! Google also works, after some other paths failed...

```shell
sudo apt-get update
sudo apt-get install ca-certificates curl apt-transport-https lsb-release gnupg
curl -sL https://packages.microsoft.com/keys/microsoft.asc |
    gpg --dearmor |
    sudo tee /etc/apt/trusted.gpg.d/microsoft.gpg > /dev/null
AZ_REPO=$(lsb_release -cs)
echo "deb [arch=amd64] https://packages.microsoft.com/repos/azure-cli/ $AZ_REPO main" |
    sudo tee /etc/apt/sources.list.d/azure-cli.list
sudo apt-get update
sudo apt-get install azure-cli
brew install awscli
snap install google-cloud-sdk --classic
```

Back to main [readme](../README.md)
