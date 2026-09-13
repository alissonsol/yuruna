<a id="42ad660e-0001"></a>

# Guia do operador Yuruna

Runbook de inicialização de uma única máquina de teste Yuruna: da linha
de base do sistema operacional até um ciclo de teste aprovado, mais as
duas VMs de serviço que beneficiam uma máquina standalone
(caching-proxy, stash).

[Seção A: Início rápido](#seção-a-início-rápido) é a sequência completa
de comandos -- execute-a de cima a baixo, ou deixe que
[A.0](#a0-atalho-o-script-de-configuração-standalone) execute o miolo
(A.3-A.7). [Seção B: Aprofundamento](#seção-b-aprofundamento) explica
cada etapa; leia-a quando uma etapa exigir julgamento ou falhar.
Para um laboratório -- várias máquinas compartilhando um
caching-proxy-service, armazenamento apoiado em NAS e o serviço
pool-control -- conclua A.1-A.2 em cada máquina e continue com o
[Guia do operador de laboratório](../lab-operator.md).

---

<a id="42ad660e-0002"></a>

## Seção A: Início rápido

Comece com um hospedeiro recém-instalado de Windows 11
Pro/Enterprise/Education (ou Windows Server), macOS 26+ ou Ubuntu 26+:
32 GB de RAM, 512 GB de disco livre, 16+ núcleos físicos, virtualização
habilitada no firmware, sistema operacional ativado e atualizado,
acesso de rede a github.com
([B.1](#b1-linha-de-base-do-sistema-operacional-pressuposta)-[B.2](#b2-dependências-de-preflight)).
"Elevado" significa um PowerShell de Administrador no Windows, `sudo`
no macOS / Ubuntu. Siga as instruções de cada etapa para sua plataforma:
no macOS e no Ubuntu, execute `install/setup.ps1` sem `sudo`; ele pede
elevação apenas para as operações que precisam.

<a id="42ad660e-0003"></a>

### A.0 Atalho: o script de configuração standalone

**Faça [A.1](#a1-instalar-o-framework) e
[A.2](#a2-criar-o-usuário-de-teste) primeiro** -- o `setup.ps1` não
instala nada, não clona nada e não cria nenhum usuário de teste.
Depois, conectado como a conta de teste, a partir da pasta do
framework:

```
pwsh install/setup.ps1
```

Ele pergunta o que não consegue inferir (standalone ou laboratório,
configurações do hospedeiro, onde fica o armazenamento) e então executa
[A.3](#a3-habilitar-a-automação-de-testes)-[A.7](#a7-iniciar-o-serviço-stash)
em ordem, terminando no portão do `Test-Config`. No Windows, ele se
relança elevado uma vez. Não executa nenhum ciclo --
[A.8](#a8-executar-um-ciclo-de-teste)-[A.9](#a9-executar-ciclos-contínuos)
continuam sendo sua tarefa. Reexecutar é seguro e adota VMs de serviço
saudáveis; `-Rebuild` força a substituição delas (~15 minutos para o
caching-proxy). Parâmetros, `-WhatIf`, execuções não assistidas,
cobertura e comportamento em caso de falha:
[B.0](#b0-o-script-de-configuração-guiada).

As etapas abaixo são o caminho manual -- leia-as quando uma etapa
exigir julgamento, falhar sob o `setup.ps1` ou você estiver reparando
um hospedeiro.

<a id="42ad660e-0004"></a>

### A.1 Instalar o framework

Cole o comando de uma linha do sistema operacional do hospedeiro
([B.3](#b3-instalar-o-framework)).

Windows (PowerShell, autoeleva-se):

```
irm "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/windows.hyper-v.ps1?nocache=$(Get-Date -Format yyyyMMddHHmmss)" | iex
```

macOS (Terminal):

```
/bin/bash -c "$(curl -fsSL "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/macos.utm.sh?nocache=$(date +%Y%m%d%H%M%S)")"
```

Ubuntu (Terminal):

```
bash <(curl -fsSL "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/ubuntu.kvm.sh?nocache=$(date +%Y%m%d%H%M%S)")
```

**Reinicie se o instalador disser RESTART REQUIRED.** O framework fica
em `~/git/yuruna` (`%USERPROFILE%\git\yuruna` no Windows); execute
todos os comandos abaixo a partir dessa pasta.

<a id="42ad660e-0005"></a>

### A.2 Criar o usuário de teste

Elevado ([B.4](#b4-criar-o-usuário-de-teste-do-yuruna)):

```
pwsh test/New-LocalTestUser.ps1 -Admin
```

Mantenha o `-Admin`: sem ele a conta não consegue elevar, e o
instalador para antes de começar. Veja
[B.4](#b4-criar-o-usuário-de-teste-do-yuruna) para reparar uma conta
criada sem ele.

**Conecte-se com a nova conta (padrão `yurunatest`) para tudo o que vem
a seguir**, e repita o comando de uma linha de
[A.1](#a1-instalar-o-framework) nessa sessão -- o clone é por usuário,
e a segunda execução é rápida.

> **Laboratório?** Mude agora para o
> [Guia do operador de laboratório](../lab-operator.md) -- ele continua a
> partir desta etapa.

<a id="42ad660e-0006"></a>

### A.3 Habilitar a automação de testes

Elevado no Windows; sem `sudo` no macOS e no Ubuntu
([B.5](#b5-habilitar-a-automação-de-testes)):

```
pwsh test/lab/Enable-TestAutomation.ps1
```

No Windows, saia e entre novamente se ele relatar mudanças no
dimensionamento da tela.

*Executado para você pelo
[A.0](#a0-atalho-o-script-de-configuração-standalone), a menos que esta
máquina apenas hospede serviços.*

<a id="42ad660e-0007"></a>

### A.4 Configurar e validar

Edite o `test/test.config.yml` -- no mínimo `repositories.projectUrl`
(e `GH_TOKEN` se for privado) e `guestSequence` -- e então valide
([B.6](#b6-configurar-e-validar)):

```
pwsh test/Test-Config.ps1
```

Corrija todos os FAIL antes de prosseguir.

*O [A.0](#a0-atalho-o-script-de-configuração-standalone) cria o arquivo
e executa esta validação, mas as edições continuam sendo suas -- ele
nunca toca em `guestSequence` nem em `GH_TOKEN`.*

<a id="42ad660e-0008"></a>

<a id="a5-criar-o-armazenamento-do-pool-e-do-stash"></a>

### A.5 Criar o armazenamento do grupo e do stash

**Armazenamento nesta máquina (sem NAS)** -- elevado no Windows, sem
`sudo` no macOS e no Ubuntu. Um único comando idempotente cria as pastas,
contas, compartilhamentos, montagens e a
configuração
([B.7](#b7-compartilhamentos-locais-para-o-armazenamento-do-pool-e-do-stash)):

```
pwsh test/lab/New-LocalLabStorage.ps1
```

Ele pergunta apenas onde o armazenamento deve ficar (sugerindo um
padrão por sistema operacional), grava `networkStorage.*` e as duas
entradas do cofre, e chama o `New-Lab` para você. Adicione
`-EnableReplication` para arquivar os ciclos concluídos no
compartilhamento do grupo. Um laboratório posterior na mesma máquina
precisa apenas de `pwsh test/lab/New-Lab.ps1 -Name <lab-name>` -- ele
reaproveita as pastas e contas que já estão aqui.

*O [A.0](#a0-atalho-o-script-de-configuração-standalone) executa isto
quando você responde `local`. `nas` apenas monta o que
`networkStorage.*` já nomeia; `none` pula o armazenamento compartilhado
e, com ele, o serviço stash.*

**Armazenamento em um NAS ou em um servidor de arquivos separado** --
esta máquina não pode criar contas lá. Crie as pastas e o cofre do
laboratório aqui e depois conceda as permissões de compartilhamento no
próprio dispositivo:

```
pwsh test/lab/New-Lab.ps1 -Name <lab-name> -Root <storage-root>
```

`<lab-name>` é minúsculo (letras, dígitos, hifens); `<storage-root>` é,
por exemplo, `D:\work` ou `/srv/yuruna`. Compartilhe as duas pastas que
ele criou -- uma conta dedicada por compartilhamento, usando as senhas
que o `New-Lab` acabou de gerar no cofre do laboratório:

```powershell
# Elevated, Windows example
New-LocalUser yuruna-pool  -Password (Read-Host -AsSecureString 'yuruna-pool password')
New-LocalUser yuruna-stash -Password (Read-Host -AsSecureString 'yuruna-stash password')
New-SmbShare -Name yuruna.pool  -Path D:\work\yuruna.pool  -FullAccess yuruna-pool
New-SmbShare -Name yuruna.stash -Path D:\work\yuruna.stash -FullAccess yuruna-stash
icacls D:\work\yuruna.pool  /grant 'yuruna-pool:(OI)(CI)M'
icacls D:\work\yuruna.stash /grant 'yuruna-stash:(OI)(CI)M'
```

Depois preencha `networkStorage.*` no `test.config.yml` e guarde as
duas senhas de compartilhamento no cofre do hospedeiro
([Definindo as senhas SMB no cofre](../test-config.md#setting-the-smb-passwords-in-the-vault)).

<a id="42ad660e-0009"></a>

### A.6 Iniciar o serviço caching-proxy

Elevado no Windows, não elevado no macOS
([B.8](#b8-iniciar-o-serviço-caching-proxy--painéis)):

```
pwsh test/service/Start-CachingProxyServiceVM.ps1
```

Defina `vmStart.cachingProxyIp` no `test.config.yml` com o IP da VM do
proxy e então execute novamente `pwsh test/Test-Config.ps1`.

*O [A.0](#a0-atalho-o-script-de-configuração-standalone) faz tudo isso,
incluindo gravar o IP.*

<a id="42ad660e-000a"></a>

### A.7 Iniciar o serviço stash

Elevado no Windows ([B.9](#b9-iniciar-o-serviço-stash)):

```
pwsh test/service/Start-StashServiceVM.ps1
```

*Executado para você pelo
[A.0](#a0-atalho-o-script-de-configuração-standalone), a menos que o
armazenamento tenha sido pulado.*

<a id="42ad660e-000b"></a>

### A.8 Executar um ciclo de teste

Depure aqui até ficar verde ([B.10](#b10-executar-um-ciclo-de-teste)):

```
pwsh test/Invoke-TestProject.ps1
```

<a id="42ad660e-000c"></a>

### A.9 Executar ciclos contínuos

([B.11](#b11-executar-ciclos-contínuos)):

```
pwsh test/Start-TestRunner.ps1
```

Acompanhe o progresso no painel de status que ele inicia em
`http://<host>:8080/`.

---

<a id="42ad660e-000d"></a>

## Seção B: Aprofundamento

A ordem do início rápido é deliberada: cada etapa valida a anterior, e
verificações baratas rodam antes das caras (validação da configuração
antes da compilação da VM do caching-proxy-service). Cada etapa abaixo
nomeia seu script e aponta para o documento de referência que detém os
detalhes.

<a id="42ad660e-000e"></a>

### B.0 O script de configuração guiada

Referência para o
[A.0](#a0-atalho-o-script-de-configuração-standalone). O
`install/setup.ps1` roda *depois* que o bootstrapper do sistema
operacional (`install/windows.hyper-v.ps1`, `install/macos.utm.sh`,
`install/ubuntu.kvm.sh`) colocou as dependências e o clone no lugar.
Ele precisa do pwsh 7; seu preflight falha a execução se o
`powershell-yaml` estiver ausente e aponta para o bootstrapper.

**O que ele cobre, etapa por etapa:**

| Etapa do início rápido | O `setup.ps1` faz isso? |
| ---------------------- | ----------------------- |
| [A.1](#a1-instalar-o-framework) instalar o framework | Não -- bootstrapper, à mão, primeiro |
| [A.2](#a2-criar-o-usuário-de-teste) criar o usuário de teste | Não -- `New-LocalTestUser.ps1`, à mão, primeiro |
| [A.3](#a3-habilitar-a-automação-de-testes) habilitar a automação de testes | Sim -- executa `Enable-TestAutomation -SkipPoolStorage`, a menos que `runTests: false` |
| [A.4](#a4-configurar-e-validar) configurar e validar | Em parte -- cria ou atualiza o `test/test.config.yml` a partir do template e termina no portão do `Test-Config`; as edições no meio continuam sendo suas |
| [A.5](#a5-criar-o-armazenamento-do-pool-e-do-stash) armazenamento do grupo e do stash | Sim para `kind: local` -- executa o `New-LocalLabStorage`. Para `kind: nas` ele apenas **monta** o que `networkStorage.*` já nomeia |
| [A.6](#a6-iniciar-o-serviço-caching-proxy) caching-proxy-service | Sim -- adota uma VM saudável; caso contrário a substitui, espera até 15 minutos pelo serviço agregador de grupo e então grava `vmStart.cachingProxyIp`. `-Rebuild` força a substituição |
| [A.7](#a7-iniciar-o-serviço-stash) serviço stash | Sim -- adota uma VM saudável ou substitui uma não saudável, a menos que o armazenamento tenha sido pulado. `-Rebuild` força a substituição |
| [A.8](#a8-executar-um-ciclo-de-teste) um ciclo de teste | Não |
| [A.9](#a9-executar-ciclos-contínuos) ciclos contínuos | Não -- a mensagem final aponta você para `pwsh test/Start-TestRunner.ps1` |

Ele também cria as pastas de imagem, VM, log e runtime. O `setup.ps1`
*em si* edita exatamente duas chaves no `test.config.yml`, por
substituição de linha que preserva comentários: `projectUrl` (quando
você fornece um) e `vmStart.cachingProxyIp`. Os scripts que ele executa
gravam mais coisas -- responder `local` executa o
`New-LocalLabStorage.ps1`, que grava as seis chaves `networkStorage.*`
e as duas entradas do cofre
([A.5](#a5-criar-o-armazenamento-do-pool-e-do-stash)). Nada toca em
`guestSequence` nem em `GH_TOKEN`.

<a id="42ad660e-000f"></a>

#### Reexecução, e a exceção das VMs de serviço

Cada etapa roda em um `pwsh` filho, e uma etapa que consegue perceber
que já foi feita -- arquivo de configuração presente, armazenamento de
grupo montado, `cachingProxyIp` correspondente -- é pulada, portanto
reexecutar é seguro.

**As VMs de serviço são a exceção:** seus scripts de inicialização
tomam a decisão de reaproveitamento. Uma VM saudável é adotada em
segundos; uma VM não saudável, meio removida ou ausente é substituída.
Use `-Rebuild` para forçar a substituição que aplica a configuração de
seed alterada. Reserve cerca de 15 minutos para recompilar o proxy. Uma
execução só remove um serviço que ela vai recompilar, então uma
reexecução standalone deixa em funcionamento o serviço pool-control de
um laboratório anterior.

<a id="42ad660e-0010"></a>

#### O que encerra uma execução

Estas falhas encerram a execução: o preflight, o arquivo de
configuração, o armazenamento (sempre que `storage.kind` for `local` ou
`nas`), o serviço caching-proxy, a espera pelo agregador e um NAS que
não monta quando `storage.onFailure` é `stop`.

O armazenamento encerra a execução porque tudo o que vem depois ou
precisa dos compartilhamentos ou grava estado do hospedeiro que os pressupõe
-- os aliases do arquivo hosts, os serviços stash e download-agent, o
grupo de um laboratório.

`storage.onFailure` decide o que significa um NAS que não monta, com ou
sem acompanhamento. O padrão é `stop`; defina como `local` (com
`storage.localRoot`) para levantar compartilhamentos locais reais no
lugar.

Qualquer outra coisa que falhe gera um aviso, é registrada na lista
Failed final e a execução continua. **Uma lista Failed não vazia sai
com código diferente de zero** -- incluindo um portão `Test-Config` que
falhou -- de modo que o código de saída nunca declara pronto um hospedeiro
quebrado. Corrija o que a lista nomeia e execute novamente.

Uma etapa que não pôde rodar porque algo de que ela depende falhou é
reportada como `BLOCK` e listada em **Blocked** no relatório final,
separadamente de **Skipped**: pular é uma decisão, bloquear é uma
consequência. Etapas bloqueadas não somam ao código de saída -- a falha
de onde vieram já somou.

<a id="42ad660e-0011"></a>

#### Parâmetros

O script declara `-AnswerFile`, `-logLevel`, `-LogPath` e `-Rebuild`;
`-WhatIf` e `-Confirm` vêm do `SupportsShouldProcess`.

`-WhatIf` mostra a prévia da lista ordenada de tarefas: nada muda,
nenhuma elevação é necessária e o arquivo de respostas não é gravado
(as perguntas continuam sendo feitas).

`-Rebuild` derruba e recompila todas as VMs de serviço que a execução
tocar, em vez de adotar uma saudável. É assim que um endereço ou uma
credencial alterada chega a um convidado, porque a seed é gravada no
momento da compilação. Isso também torna uma reexecução cara -- cerca
de 15 minutos para o proxy, mais um cache Squid frio -- então
descarte-o ao reexecutar para corrigir algo que o proxy não grava na
seed. O cabeçalho do log da execução registra os switches com que cada
execução foi invocada.

`-logLevel` é a [cascata compartilhada](../loglevels.md) e alcança todo
script que a execução inicia, então execute novamente com
`-logLevel Debug` quando uma etapa falhar dentro de um script filho. O
log da execução é sempre gravado por completo; o nível só decide o que
também chega ao terminal. `-LogPath` continua um log de execução
existente (usado pelo relançamento elevado do Windows).

<a id="42ad660e-0012"></a>

#### Execuções não assistidas: o arquivo de respostas

Uma execução sem `-AnswerFile` salva o que você respondeu em
`install/setup.answers.standalone.yml`. Forneça esse arquivo de volta
para repetir a execução sem perguntas:

```
pwsh install/setup.ps1 -AnswerFile install/setup.answers.standalone.yml
```

Uma execução não assistida com `storage.kind: local` precisa incluir
`storage.localRoot`. O `New-LocalLabStorage.ps1` roda como filho com o
stdin fechado, então uma pergunta que ele faça não chega a ninguém -- a
execução para no primeiro segundo e nomeia a chave, em vez de adivinhar
um caminho e criar ali contas do sistema operacional e
compartilhamentos. Uma execução interativa também não pergunta: ela
adota a convenção da plataforma (`/srv/yuruna` no Ubuntu,
`/Users/Shared/yuruna` no macOS, `<data drive>\Shares\yuruna` no
Windows) e registra no log da execução que fez isso. Defina a chave
para colocar o armazenamento em qualquer outro lugar.

O conjunto inteiro de respostas é verificado antes de qualquer coisa
mudar na máquina: um arquivo inutilizável é recusado no primeiro
segundo, com uma mensagem por problema nomeando a chave que o corrige.

As chaves standalone que ele lê (qualquer outra coisa no arquivo é
ignorada, e uma seção que este script não lê gera um aviso -- um
`storages:` digitado errado leva junto todas as chaves abaixo dele):

```yaml
setup:
  type: standalone       # standalone | lab
  runTests: true         # false = this machine only hosts services
  projectUrl: ''         # '' keeps whatever test.config.yml has;
                         # omit the key for the script's built-in default
storage:
  kind: local            # local | nas | none ('none' is standalone-only)
  localRoot: '/srv/yuruna'   # kind: local -- required unattended (see above)
  networkPath: '//ypool-nas/work/yuruna.pool'   # kind: nas only; required
  networkUser: 'yuruna-pool'                    # kind: nas only
  onFailure: stop        # stop | local -- if a NAS mount fails
```

`storage.localRoot` é onde os compartilhamentos locais são criados (as
convenções por sistema operacional acima). É também o que o
`storage.onFailure: local` precisa: um NAS que monta nunca usa a chave,
então um arquivo sem ela é aceito, e a execução avisa que o fallback
que ela declara não pode de fato rodar.

O arquivo que uma execução guiada grava carrega os valores que ela
*resolveu*, não as respostas como foram digitadas -- então a raiz de
armazenamento em que ela se fixou está lá, e o arquivo pode configurar
a próxima máquina. Se faltar uma chave para uma repetição não
assistida, a execução avisa quando grava o arquivo, em vez de deixar a
próxima máquina descobrir.

<a id="42ad660e-0013"></a>

### B.1 Linha de base do sistema operacional (pressuposta)

Um hospedeiro recém-instalado com Windows 11 Pro/Enterprise/Education (ou
Windows Server), macOS 26+ ou Ubuntu 26+. Linha de base testada: 32 GB
de RAM, 512 GB de disco livre, 16+ núcleos físicos. A pilha de
ferramentas que o framework espera está listada em
[B.2](#b2-dependências-de-preflight).

<a id="42ad660e-0014"></a>

### B.2 Dependências de preflight

Antes de executar o instalador, confirme:

- **Licença / ativação** -- o Windows precisa estar ativado e ser uma
  edição compatível com Hyper-V (Pro ou superior; o Home não tem Hyper-V).
- **Atualizações do sistema operacional aplicadas** -- atualizações pendentes podem forçar uma reinicialização no meio da instalação.
- **Virtualização habilitada no firmware** -- Intel VT-x / AMD-V
  (Ubuntu: `grep -E 'vmx|svm' /proc/cpuinfo` precisa retornar algo).
- **Acesso de rede a github.com** -- o instalador clona o framework.

O instalador reverifica as linhas de base de hardware e pergunta antes
de prosseguir em um hospedeiro abaixo da especificação -- exceto a contagem
de núcleos físicos no Windows, que é reportada como recomendação e
nunca pergunta. Alguns exemplos também pressupõem um domínio registrado
cujo DNS você controla. Antes de instalar certificados em localhost,
execute `mkcert -install` uma vez (pode exigir elevação).

<a id="42ad660e-0015"></a>

#### Ferramentas necessárias

O instalador do hospedeiro ([B.3](#b3-instalar-o-framework)) coloca a maioria
delas no lugar; instale-as à mão ao rodar sem ele, ou para reparar uma
instalação parcial. Execute o
`Test-Requirement.ps1` para comparar as ferramentas presentes com as
versões usadas nos testes
([`automation/Yuruna.Requirement.yml`](../../automation/Yuruna.Requirement.yml)).

- Instale o [PowerShell Core](https://github.com/powershell/powershell) 7.6.4+ -- o piso definido em [`Yuruna.Requirement.yml`](../../automation/Yuruna.Requirement.yml); qualquer versão anterior falha no `Test-Requirement.ps1`.
  No Windows, a partir de um PowerShell de Administrador:
  - Instale-o para todos os usuários: `winget install --id Microsoft.PowerShell --scope machine`. Uma cópia por usuário fica sob `%LOCALAPPDATA%`, onde nenhuma outra conta pode executá-la, então o usuário de teste de [B.4](#b4-criar-o-usuário-de-teste-do-yuruna) não consegue rodar o `pwsh` de jeito nenhum.
  - `Set-ExecutionPolicy -ExecutionPolicy RemoteSigned` (veja [políticas de execução](https://go.microsoft.com/fwlink/?LinkID=135170))
  - `Install-Module -Name powershell-yaml`
- Instale o [Git](https://git-scm.com/downloads)
  - `git config --global user.name "Your Name"`
  - `git config --global user.email "Your@email.address"`
  - `git config --global core.autocrlf input`
- Usando uma máquina Hyper-V no Windows? Habilite a [virtualização aninhada](https://learn.microsoft.com/en-us/virtualization/hyper-v-on-windows/user-guide/nested-virtualization)
- Usando UTM no macOS? A virtualização aninhada (necessária para o Docker
  Desktop dentro da VM) exige macOS 15 Sequoia+, chip Apple M3+, UTM v4.6+ e
  o backend Apple Virtualization (não o QEMU).
- Instale o [Docker Desktop](https://docs.docker.com/desktop/)
  - Habilite o [Kubernetes](https://docs.docker.com/get-started/orchestration/)
  - Instale o [Docker buildx](https://github.com/docker/buildx) no path.
- Instale o [Helm](https://helm.sh/docs/intro/install/) no path.
  - Download: [`https://github.com/helm/helm/releases`](https://github.com/helm/helm/releases)
- Instale o [OpenTofu](https://opentofu.org/docs/intro/install/) no path.
- Instale o [wget](https://www.gnu.org/software/wget/) no path.
  - Binários para Windows em [eternallybored.org](https://eternallybored.org/misc/wget/)
- Instale o [mkcert](https://github.com/FiloSottile/mkcert) no path.
  - Execute `mkcert -install`

<a id="42ad660e-0016"></a>

#### Ferramentas de nuvem

Necessárias apenas para os exemplos que implantam em uma nuvem; um hospedeiro
somente local pode pular esta lista.

- AWS
  - Crie uma [Conta AWS](https://aws.amazon.com/free)
  - Instale a [AWS CLI](https://aws.amazon.com/cli/)
- Azure
  - Crie uma [Conta Azure](https://azure.microsoft.com/en-us/free/)
  - Instale a [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)
- Google Cloud SDK
  - Crie uma [Conta Google Cloud](https://console.cloud.google.com/freetrial)
  - Instale a [CLI do Google Cloud SDK](https://cloud.google.com/sdk/docs/install)
- Provedor de DNS e instruções para criar um registro A
  - Instruções para o [Amazon Route 53](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/resource-record-sets-creating.html)
  - Instruções para o [Azure DNS](https://learn.microsoft.com/en-us/azure/dns/dns-getstarted-portal)
  - Instruções para o [Google Cloud DNS](https://cloud.google.com/dns/docs/records)

<a id="42ad660e-0017"></a>

#### Ferramentas recomendadas

- Instale a versão mais recente do [Visual Studio Code](https://code.visualstudio.com/)
  - Instale a extensão [Docker](https://marketplace.visualstudio.com/items?itemName=ms-azuretools.vscode-docker).
  - Instale a extensão [Kubernetes](https://marketplace.visualstudio.com/items?itemName=ms-kubernetes-tools.vscode-kubernetes-tools).
- Instale o [Graphviz](https://graphviz.org/download/) no path.
- Instale o [K9S](https://k9scli.io/topics/install/) no path.

Os scripts podem funcionar com versões mais antigas, mas os testes usaram as fixadas.

<a id="42ad660e-0018"></a>

### B.3 Instalar o framework

Comandos: [A.1](#a1-instalar-o-framework); os comandos de uma linha
pertencem ao [install/README.md](../../install/README.md), também em
<https://yuruna.link/420f54a5>. O instalador instala as dependências,
clona o framework e semeia o `test/test.config.yml` quando ausente. A
primeira habilitação do Hyper-V dispara RESTART REQUIRED -- reinicie
antes de continuar. Como alternativa, faça `git clone` e execute você
mesmo o `install/<host>.{ps1,sh}` correspondente; instalações com
verificação de assinatura e fixação de release:
[install/README.md](../../install/README.md).

<a id="42ad660e-0019"></a>

### B.4 Criar o usuário de teste do Yuruna

```
pwsh test/New-LocalTestUser.ps1 -Admin
```

Elevado (Administrador / sudo). Cria uma conta local dedicada do
sistema operacional (padrão `yurunatest`) que detém a operação dos
testes, para que o harness nunca rode sob o seu perfil pessoal. O
`-Admin` a torna administradora local -- obrigatório, porque etapas
posteriores elevam. Criada sem ele, a conta não consegue elevar e o
instalador se recusa. Dois caminhos de volta: conceda os direitos a
partir de uma conta de administrador -- `sudo dseditgroup -o edit -a yurunatest -t user admin`
(macOS), `sudo usermod -aG sudo yurunatest` (Ubuntu) ou
`Add-LocalGroupMember` no grupo S-1-5-32-544 (Windows) -- e então
desconecte e reconecte essa conta, porque uma sessão mantém a lista de
grupos com que começou; ou execute novamente com `-Admin`, que se
oferece para excluir a conta e seu diretório home e criá-la de novo
depois que você confirmar; `-Force` responde a essa confirmação
antecipadamente, então uma execução não assistida recria a conta em uma
única chamada. Esse é o caminho destrutivo -- veja antes o que ele
remove com `-Force -WhatIf`, e note que ele se recusa a excluir a conta
com que você está executando, uma conta do sistema ou uma conta com
sessão de login aberta. A senha é pedida interativamente (duas vezes) e
fica imediatamente utilizável, a menos que o cofre de autenticação já
tenha uma para a conta: essa é reutilizada, de modo que uma conta
recriada continua correspondendo à credencial que o Yuruna distribui
(`-PromptForPassword` recusa esse comportamento). Adicione
`-ForcePasswordChange` para uma credencial inicial de uso único. A
conta também é registrada sob a extensão de autenticação padrão do
Yuruna -- no `users.yml` de runtime, ignorado pelo git, semeado a
partir do template versionado quando o hospedeiro ainda não tem nenhum; uma
entrada que já declara o nome é reutilizada como está, nunca
sobrescrita. Multiplataforma; detalhes na ajuda baseada em comentários
de `test/New-LocalTestUser.ps1`.

Conecte-se como este usuário para tudo o que vem a seguir, para que a
configuração, o cofre e o estado de runtime pertençam à conta de teste.
O clone é por usuário -- por isso A.2 repete o comando de uma linha de
instalação na sessão do usuário de teste; o trabalho pesado já foi
feito, então essa execução apenas clona e semeia a configuração.

<a id="42ad660e-001a"></a>

### B.5 Habilitar a automação de testes

```
pwsh test/lab/Enable-TestAutomation.ps1
```

Opt-in explícito que transforma esta máquina em um hospedeiro de teste:
suspensão da tela, protetor de tela, bloqueio de tela, dimensionamento
da tela (Windows), concessões TCC (macOS). Administrador no Windows;
sem elevação no macOS e no Ubuntu -- o script pede `sudo` quando necessário.
Idempotente; suporta `-WhatIf`. No Windows, saia e entre
novamente se ele relatar mudanças no dimensionamento da tela -- o OCR
precisa de escala de 100%. Detalhes:
`host/<platform>/Enable-TestAutomation.ps1`. Para desfazer, veja
[Restaurar a máquina ao estado original](#restaurar-a-máquina-ao-estado-original).

<a id="42ad660e-001b"></a>

### B.6 Configurar e validar

Edite o `test/test.config.yml` (criado a partir de
`test/test.config.yml.template`; referência de parâmetros:
[test-config.md](../test-config.md)). Mínimo para uma primeira execução:
`repositories.projectUrl` (e `GH_TOKEN` se for privado), `guestSequence`.
Depois valide:

```
pwsh test/Test-Config.ps1
```

Verifica a configuração e as configurações de `test/extension/*`, sonda
a acessibilidade de GitHub e Resend, e dispara uma notificação de teste
de fumaça (`-SkipSend` para apenas validar). Corrija todos os FAIL
antes de prosseguir -- isto leva segundos e a próxima etapa leva muitos
minutos.

<a id="42ad660e-001c"></a>

<a id="b7-compartilhamentos-locais-para-o-armazenamento-do-pool-e-do-stash"></a>

### B.7 Compartilhamentos locais para o armazenamento do grupo e do stash

O armazenamento durável ([pool-storage.md](../pool-storage.md),
[stash-guide.md](../stash-guide.md)) é apoiado por dois compartilhamentos
SMB3. Em uma única máquina os dois ficam aqui, e
**`test/lab/New-LocalLabStorage.ps1` prepara a camada inteira em um
único comando idempotente e compatível com `-WhatIf`**; comandos:
[A.5](#a5-criar-o-armazenamento-do-pool-e-do-stash). Ele sugere uma
raiz de armazenamento em `/srv/yuruna` (Ubuntu), `/Users/Shared/yuruna`
(macOS) ou `<drive>\Shares\yuruna` (Windows, primeiro disco não do
sistema). Ele chama o `New-Lab` para as pastas, o cofre do laboratório
e o repositório de intenção, e então faz o que o `New-Lab`
deliberadamente deixa de lado:

- **Uma conta local por camada** -- `yuruna-pool` e `yuruna-stash`,
  cada uma restrita ao seu próprio compartilhamento e a mais nada: não
  é administradora, sem shell interativo, oculta na janela de login do
  macOS e, no Ubuntu, sem nenhuma senha do sistema operacional (a
  credencial SMB vive no passdb do próprio Samba).
- **Um servidor SMB** -- iniciado no Windows, Compartilhamento de
  Arquivos habilitado no macOS, `samba` + `cifs-utils` instalados no Ubuntu.
- **Um compartilhamento por camada**, concedendo acesso apenas à conta
  daquela camada, para que uma credencial de grupo vazada não alcance o
  compartilhamento do stash.
- **O cofre** -- cada senha armazenada sob uma `vaultKey` não vazia, o
  que mantém o `Get-Password` fora do caminho de autogeração (uma senha
  aleatória que o compartilhamento nunca teve).
- **A montagem e a configuração** -- os dois compartilhamentos
  montados, as seis chaves `networkStorage.*` gravadas;
  `-EnableReplication` também define
  `networkStorage.moveLogsToPoolStorage`.

Os compartilhamentos são locais, mas consumidos **como se fossem
remotos**: cada camada ganha um alias no arquivo hosts (`ypool-nas`,
`ystash-nas`) que resolve para o loopback, e a montagem roda sobre SMB
por esse nome via o mesmo `Connect-YurunaPoolStorage` que o ciclo não
assistido usa. Um laboratório de máquina única portanto exercita o
mesmo código de replicação, gating e montagem que um apoiado em NAS;
migrar depois para hardware real só muda para onde o alias resolve. No
Windows os dois nomes também são registrados como isenções de loopback
NTLM (`BackConnectionHostNames`) e `EnableLinkedConnections` é definido
-- sem eles a máquina recusa sua própria conexão SMB ou mostra as
unidades mapeadas apenas para processos elevados; ambos passam a valer
na próxima reinicialização ou no próximo login.

**Mais laboratórios na mesma máquina.** Execute o `New-Lab` sozinho; as
contas de compartilhamento são **de toda a máquina**, então ele
**reutiliza** o que já está presente em vez de cunhar um segundo
conjunto:

- O `-Root` pode ser omitido -- a raiz de armazenamento é lida de volta
  do cofre de um laboratório existente, então um erro de digitação não
  pode colocar as pastas de um segundo laboratório em outro lugar.
- Credenciais que já estão no cofre do hospedeiro são **reutilizadas**, não
  regeneradas: uma senha nova deixaria a conta do sistema operacional,
  o servidor SMB e as outras máquinas do laboratório com a antiga, de
  modo que toda montagem conduzida pelo novo cofre falharia. O `-Force`
  (que reescreve o arquivo do cofre do laboratório) ainda reutiliza em
  vez de rotacionar -- a rotação também precisa alcançar a conta do
  sistema operacional e o compartilhamento, então continua sendo um ato
  deliberado e separado.

As pastas de armazenamento mantêm o operador como dono; a conta de
compartilhamento é adicionada ao lado (ACE herdada no Windows/macOS,
grupo + setgid no Linux). Isso permite que o `New-Lab` crie o
repositório de intenção do próximo laboratório na pasta do grupo, e
evita a recusa de "dubious ownership" do git que o chown para a conta
de compartilhamento provocaria.

**É apenas para armazenamento local.** Um NAS ou servidor de arquivos
separado detém suas próprias contas -- crie-as **naquele dispositivo**.
Use o `test/lab/New-Lab.ps1` para as pastas e o cofre do laboratório,
compartilhe-as lá, depois preencha `networkStorage.*` e guarde as
senhas dos compartilhamentos no cofre do hospedeiro
([Definindo as senhas SMB no cofre](../test-config.md#setting-the-smb-passwords-in-the-vault)).
O cofre do laboratório guarda os valores gerados para copiar entre
máquinas; o cofre do hospedeiro é o que o harness lê. Defina os três caminhos
`networkStorage.poolStorage*` para arquivar os ciclos no
compartilhamento (adicione `moveLogsToPoolStorage: true` para que a
pasta local de cada ciclo seja excluída assim que sua cópia for
verificada).

<a id="42ad660e-001d"></a>

### B.8 Iniciar o serviço caching-proxy + painéis

```
pwsh test/service/Start-CachingProxyServiceVM.ps1
```

Compila a VM `yuruna-caching-proxy-service` e expõe as portas 80
(certificado CA), 3128/3129 (Squid), 3000 (Grafana), 9302 (métricas).
Elevado no Windows; não elevado no macOS. Defina
`vmStart.cachingProxyIp` no `test.config.yml` com o IP do proxy para
que os ciclos o encontrem. A VM de cache sobrevive a reinstalações do
framework. Detalhes: [caching.md](../caching.md#caching-proxy-service--test-harness-operator-reference).

<a id="42ad660e-001e"></a>

### B.9 Iniciar o serviço stash

```
pwsh test/service/Start-StashServiceVM.ps1
```

Levanta a VM `yuruna-stash-service` -- a caixa de entrega compartilhada
para arquivos e trechos (UI web + scp). Elevado no Windows. Ela monta o
compartilhamento `yuruna.stash` de
[B.7](#b7-compartilhamentos-locais-para-o-armazenamento-do-pool-e-do-stash),
então prepare isso primeiro. Sem login; apenas redes confiáveis. Guia
do usuário: [stash-guide.md](../stash-guide.md).

<a id="42ad660e-001f"></a>

### B.10 Executar um ciclo de teste

```
pwsh test/Invoke-TestProject.ps1
```

Ciclo único: apaga `project/`, reclona `repositories.projectUrl`,
executa um único ciclo exatamente como o executor faria, e sai. Depure
aqui até ficar verde -- um ciclo sem laço em volta é o lugar mais
barato para depurar.

<a id="42ad660e-0020"></a>

### B.11 Executar ciclos contínuos

```
pwsh test/Start-TestRunner.ps1
```

O laço externo resiliente: puxa o framework, executa um ciclo em um
processo interno novo, repete; em caso de falha, pausa até que novos
commits cheguem ou um tempo limite passe
([runner-outer-loop.md](../runner-outer-loop.md)). Ele inicia
automaticamente o painel de status em `http://<host>:8080/` -- sem
etapa separada de `Start-StatusService.ps1`.

---

<a id="42ad660e-0021"></a>

<a id="trazer-as-vms-de-serviço-de-volta-após-reiniciar-o-host"></a>

## Trazer as VMs de serviço de volta após reiniciar o hospedeiro

Reiniciar o hospedeiro não danifica nada: deixa toda VM de serviço registrada
no hipervisor e desligada. Nada então as liga de volta, e as duas
consequências não são iguais --

- o **caching-proxy-service** apenas se degrada: os convidados baixam
  direto, devagar;
- o **serviço stash** é fatal para um ciclo: o aquecimento o resolve,
  não encontra nada, e todo estágio de carga de trabalho é pulado.

Então um hospedeiro reiniciado pode continuar queimando ciclos que nunca
poderão passar, parecendo saudável o tempo todo, até que um operador
perceba.

**O executor cobre isso por conta própria.** Todo início de ciclo roda
uma varredura que inicia qualquer VM de serviço que esteja registrada
mas não em execução, e relata o que fez. A varredura é barata em um
hospedeiro saudável -- uma consulta de estado por serviço -- e é por isso que
ela roda a cada ciclo em vez de apenas no boot: ela também pega um
serviço que morreu ou foi parado no meio da sessão. Um serviço
*ausente* não é uma falha e nunca dispara nada. Um hospedeiro standalone
legitimamente não roda nenhum serviço stash, então ausente significa
"não é tarefa deste hospedeiro"; só uma VM registrada mas parada é algo que
este hospedeiro detém e não conseguiu iniciar. A espera de saúde da varredura
é deliberadamente não autoritativa -- um convidado recém-retomado pode
demorar a reabrir seu listener, e os portões reais rodam depois e detêm
o veredito.

**Inicie o que já está compilado; não recompile.** Uma recompilação
custa ~15 minutos e joga fora um cache Squid quente; um início custa
segundos e o preserva. Recompilar é a escalada para uma VM que não
sobe, nunca a primeira resposta para uma que está apenas desligada.

Em um hospedeiro sem nenhum ciclo em execução para fazer isso por você -- uma
estação de trabalho usada interativamente, ou uma máquina recém
reiniciada antes de uma execução manual -- levante-as com os scripts
comuns de [A.6](#a6-iniciar-o-serviço-caching-proxy) e
[A.7](#a7-iniciar-o-serviço-stash), que adotam uma VM saudável em vez
de recompilá-la.

---

<a id="42ad660e-0022"></a>

## Restaurar a máquina ao estado original

```
pwsh test/lab/Disable-TestAutomation.ps1
```

O inverso de [B.5](#b5-habilitar-a-automação-de-testes). Ele repassa o
que você passar para `host/<platform>/Disable-TestAutomation.ps1`, que
aceita `-StopServices` e `-WhatIf`. No Windows ele exige um PowerShell
já elevado (ele **não** se autoeleva); macOS e Ubuntu preparam o `sudo`
uma vez.

O relatório final dele distingue três coisas:

- **Restaurado.** As configurações do hospedeiro são recolocadas a partir de
  `status/runtime/host.pre-automation.json`, o instantâneo que o
  `Enable-TestAutomation` gravou antes de mudar qualquer coisa:
  suspensão da tela, bloqueio de tela, tempo limite de inatividade e
  dimensionamento de tela/texto no Windows; `pmset`, protetor de
  tela/bloqueio de tela, cantos ativos, logout automático e hora de
  rede no macOS; as chaves de energia/sessão/protetor de tela do GNOME,
  `timedatectl set-ntp` e o estado habilitado de `libvirtd`/`virtlogd`
  no Ubuntu. Um ajuste que estava *não definido* antes da automação é
  removido onde for possível, não regravado como zero. **Sem captura,
  sem restauração** -- um ajuste não capturado é listado em "Left as it
  is". O arquivo de captura é mantido para que o comando possa ser
  executado novamente; exclua-o você mesmo quando terminar.
- **Removido de vez.** Apenas o que é comprovadamente do próprio
  framework, pelo nome: no Windows, a regra de firewall da porta de
  status e a regra `Yuruna: Allow ICMPv4 Echo Request`; no Ubuntu, a
  regra allow do `ufw` para a porta de status, mais a participação nos
  grupos `libvirt` / `kvm` e a ACL de `libvirt-qemu` em `$HOME` --
  esses dois últimos apenas quando a captura prova que o
  `Enable-TestAutomation` os adicionou. O macOS não remove nada.
- **Apenas reportado.** A lista final `NOT reversed (deliberately)`
  nomeia o que ele não vai tocar, a maior parte com o comando para você
  mesmo executar: pacotes e módulos do PSGallery, o cofre de
  credenciais (nunca removido automaticamente), tudo que está sob
  `~/yuruna`, e a configuração `networkStorage.*` com sua credencial e
  suas montagens. O Windows acrescenta Hyper-V, `vmms` e W32Time (o
  bootstrapper habilitou esses); o macOS, as concessões TCC e a
  atribuição do UTM ao Dock; o Ubuntu, a rede padrão do libvirt, os
  convidados definidos aqui e o drop-in de sudoers do armazenamento de
  grupo.

As VMs de serviço permanecem no ar a menos que você passe
`-StopServices` -- restaurar as configurações do hospedeiro e derrubar
serviços são intenções diferentes. `-WhatIf` não restaura nada e ainda
imprime as duas listas.

Ele se recusa a rodar enquanto um executor de testes detém o diretório
de runtime deste hospedeiro, nomeando o PID vivo -- restaurar o bloqueio de
tela sob um ciclo em execução apagaria a captura no meio da execução.
Pare o executor primeiro.

---

<a id="42ad660e-0023"></a>

## Contas de administrador das VMs

Cada VM de serviço é semeada com seu próprio administrador, e cada
senha vive sob sua própria chave de cofre:

| VM | Administrador |
| -- | ------------- |
| `yuruna-caching-proxy-service` | `caching-proxy-service-admin` |
| `yuruna-pool-control-service` | `pool-control-service-admin` |
| `yuruna-stash-service` | `stash-admin` |
| `yuruna-download-agent-service` | `download-agent-service-admin` |

(`yuruna-pool-control-service` aparece quando um laboratório compila
essa VM -- [lab-operator.md](../lab-operator.md).) Uma única conta
compartilhada significaria uma única entrada no cofre: compilar
qualquer VM sobrescreveria a senha com que as outras foram
provisionadas, e os logins de console delas parariam de funcionar
silenciosamente.

O painel do serviço download-agent protege suas ações mutantes com o
**Token do laboratório** rotativo de 6 caracteres do painel de hospedeiros do Yuruna --
verificado com o agregador de grupo, nunca armazenado no cofre; nada
para cunhar ou rotacionar à mão
([download-agent.md](../download-agent.md#unlocking-the-actions)). Uma
entrada `download-agent-service-passcode` obsoleta de uma compilação
anterior pode ser excluída; nada a lê.

Uma VM cuja seed nomeou um administrador diferente o mantém até ser
recompilada -- os nomes acima valem a partir da próxima compilação de
cada VM. O `Move-CachingProxyService.ps1` conversa com duas VMs de
cache ao mesmo tempo, então passe `-OldUser` quando a conta da VM de
origem for diferente do padrão. Remova uma entrada de cofre superada
somente depois que toda VM provisionada com ela tiver sido recompilada.

O `users.yml.template` declara todos os quatro. Um `users.yml`
existente não é reinicializado -- as novas entradas do template são
mescladas uma a uma, e apenas enquanto não carregarem significado para
o operador (sem chave de cofre, sem mapeamento corporativo) -- de modo
que um hospedeiro com `strict: true` adota o administrador de um novo serviço
sem edição manual. Veja
[test-config.md](../test-config.md).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Última revisão: 2026.09.13

Voltar para [Yuruna](../../README.md)
