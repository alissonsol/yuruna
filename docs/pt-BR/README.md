<a id="42913bde-0001"></a>

# Yuruna

**O Yuruna assegura que os recursos estejam configurados para verificar componentes diante das cargas de trabalho previstas.**

Três capacidades: configurações reproduzíveis de VMs hospedeiro/convidado para
espaços de trabalho de desenvolvimento, implantação de Kubernetes em
múltiplas nuvens e uma estrutura de testes baseada em VMs. Arquitetura e
convenções: [Arquitetura do Yuruna](../architecture.md).

<a id="42913bde-0002"></a>

## Início seguro

Leia os rascunhos online dos capítulos [0](https://yuruna.link/book/2026/ch00) e [1](https://yuruna.link/book/2026/ch01) de um livro em preparação sobre o framework Yuruna.

<a id="42913bde-0003"></a>

## Início rápido

Consulte o **Aviso de Risco para Administradores** na [Licença Yuruna](../../LICENSE.md).

**1 -- Instale os pré-requisitos.** Cole o comando de uma linha do seu
sistema operacional a partir dos
[scripts de instalação](../../install/README.md#remote-one-liners), ou execute
você mesmo o script correspondente em `install/`. Ele instala as
dependências, clona o framework em `~/git/yuruna`
(`%USERPROFILE%\git\yuruna` no Windows) e cria o
`test/test.config.yml` inicial. Reinicie a máquina se aparecer RESTART
REQUIRED e execute o restante a partir da pasta `yuruna`.

**2 -- Configure o hospedeiro.**

```
pwsh install/setup.ps1
```

Um único comando guiado ([detalhes](../../install/README.md#guided-setup)):
ele desativa a suspensão e o bloqueio de tela, prepara o armazenamento,
compila as VMs do caching-proxy-service e do serviço stash e termina no
portão de validação `Test-Config`. No Windows, ele se reinicia uma vez
com privilégios elevados.

**3 -- Execute seu primeiro teste.**

```
pwsh test/Start-TestRunner.ps1
```

Acompanhe o progresso em `http://localhost:8080/status/`. Cada ciclo
clona novamente o projeto de exemplo (`repositories.projectUrl` na
configuração) e executa as sequências do
[exemplo de website](https://github.com/alissonsol/yuruna-project/tree/main/example/website).

**Mais informações.** [Guia do operador](../operator.md) -- o runbook
completo para uma única máquina, incluindo o usuário de teste dedicado;
[guia do operador de laboratório](../lab-operator.md) -- várias
máquinas como um único laboratório.

<a id="suporte-a-host--convidado"></a>

<a id="42913bde-0004"></a>

## Suporte a hospedeiro / convidado

- hospedeiro [macOS UTM](../../host/macos.utm/README.md)
  - convidados:
  [Amazon Linux 2023](../../host/macos.utm/guest.amazon.linux.2023/README.md) -
  [macOS 26](../../host/macos.utm/guest.macos.26/README.md) -
  [Ubuntu Server 24.04](../../host/macos.utm/guest.ubuntu.server.24/README.md) -
  [Ubuntu Server 26.04](../../host/macos.utm/guest.ubuntu.server.26/README.md) -
  [Windows 11](../../host/macos.utm/guest.windows.11/README.md)
- hospedeiro [Windows Hyper-V](../../host/windows.hyper-v/README.md)
  - convidados:
  [Amazon Linux 2023](../../host/windows.hyper-v/guest.amazon.linux.2023/README.md) -
  [Ubuntu Server 24.04](../../host/windows.hyper-v/guest.ubuntu.server.24/README.md) -
  [Ubuntu Server 26.04](../../host/windows.hyper-v/guest.ubuntu.server.26/README.md) -
  [Windows 11](../../host/windows.hyper-v/guest.windows.11/README.md)
- hospedeiro [Ubuntu KVM/libvirt](../../host/ubuntu.kvm/README.md)
  - convidados:
  [Amazon Linux 2023](../../host/ubuntu.kvm/guest.amazon.linux.2023/README.md) -
  [Ubuntu Server 24.04](../../host/ubuntu.kvm/guest.ubuntu.server.24/README.md) -
  [Ubuntu Server 26.04](../../host/ubuntu.kvm/guest.ubuntu.server.26/README.md) -
  [Windows 11](../../host/ubuntu.kvm/guest.windows.11/README.md)

Depois que o sistema operacional convidado estiver no ar, cargas de
trabalho de teste:
  - [Amazon Linux 2023](../../guest/amazon.linux.2023/README.md)
  - [macOS 26](../../guest/macos.26/README.md)
  - [Ubuntu Server 24.04](../../guest/ubuntu.server.24/README.md)
  - [Ubuntu Server 26.04](../../guest/ubuntu.server.26/README.md)
  - [Windows 11](../../guest/windows.11/README.md)

<a id="42913bde-0005"></a>

## Leia mais

- **[Toda a documentação](../README.md)** -- o que cada documento em `docs/` cobre
- [Requisitos](../operator.md#b2-preflight-dependencies) - [Soluções alternativas e FAQ](../workarounds.md) - [Roadmap](../opportunities.md#roadmap)
- Guias do [operador](../operator.md) de máquina e do [operador de laboratório](../lab-operator.md)
- [Como contribuir](../../CONTRIBUTING.md) - [Contribuidores](../../CONTRIBUTING.md#contributors) - [Oportunidades](../opportunities.md)
- [Changelog](../../CHANGELOG.md) - [Política de segurança](../../SECURITY.md) - [Licença](../../LICENSE.md)

**Aviso de custo**: recursos de nuvem geram cobranças. Sempre remova os
[Recursos do Yuruna ...](../kubernetes.md#cleaning-up-cloud-resources) que você não estiver usando.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Última revisão: 2026.09.08
