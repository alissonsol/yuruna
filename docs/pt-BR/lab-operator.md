<a id="42383647-0001"></a>

# Guia do operador de laboratório Yuruna

Runbook de subida para um laboratório Yuruna: várias máquinas
compartilhando um caching-proxy-service, armazenamento de grupo e de
stash apoiado em NAS e um serviço pool-control, organizadas em grupos e
com conjuntos de testes atribuídos.

A [Seção A: Início rápido](#seção-a-início-rápido) é a sequência
completa de comandos -- primeiro os serviços compartilhados, depois
máquina por máquina. A [Seção B: Aprofundamento](#seção-b-aprofundamento)
explica cada etapa. O guia termina com um exemplo prático de
[divisão em dois grupos](#dois-pools-executando-dois-conjuntos-de-testes-diferentes).

Pré-requisito: toda máquina do laboratório concluiu o
[guia do operador](../operator.md) até A.2 (conectada como o usuário de
teste). Os serviços compartilhados são compilados uma única vez, na
máquina mais potente; todas as outras máquinas apontam para eles.

> **Atalho para o beacon.** [install/setup.ps1](../../install/setup.ps1)
> executa a metade de serviços compartilhados deste início rápido --
> [A.1](#a1-habilitar-a-automação-de-testes-todas-as-máquinas)-[A.6](#a6-subir-a-primeira-máquina)
> -- como um único comando guiado:
>
> ```
> pwsh install/setup.ps1    # choose "Lab"
> ```
>
> Ele executa exatamente os scripts abaixo, então os dois caminhos
> continuam intercambiáveis. Ele configura **apenas a máquina em que
> roda** -- as máquinas que entram ainda executam o `Set-LabToken.ps1`
> e a sincronização por conta própria
> ([A.7](#a7-inscrever-cada-máquina-adicional)). Reexecutar adota VMs
> de serviço saudáveis; `-Rebuild` as substitui (~15 minutos para o
> proxy). Cobertura, `-WhatIf` e execuções não assistidas:
> [B.0](#b0-o-script-de-configuração-guiada-em-um-beacon).

---

<a id="42383647-0002"></a>

## Seção A: Início rápido

"Elevado" significa um PowerShell de Administrador no Windows.
Execute os comandos a partir da pasta `yuruna`. A única
exceção no Windows é `install/setup.ps1`: inicie-o em qualquer
PowerShell e ele se relança elevado uma vez, logo no começo.

**No macOS e no Ubuntu, não coloque `sudo` na frente destes scripts.**
Eles rodam sem elevação e pedem `sudo` para as operações que precisam.
Rodar um deles como root deixa os arquivos com dono root. No macOS,
o root também não tem sessão gráfica, então o registro no UTM, o
`utmctl` e o watchdog de diálogos falham; o UTM, rodando como você,
não consegue abrir os arquivos do root. Recupere com
`sudo chown -R "$USER" ~/yuruna` e execute de novo sem elevação; os
scripts são idempotentes.

<a id="42383647-0003"></a>

### A.1 Habilitar a automação de testes (todas as máquinas)

Em cada máquina do laboratório: elevado no Windows; sem `sudo` no macOS e no Ubuntu
([B.1](#b1-habilitar-a-automação-de-testes-todas-as-máquinas)):

```
pwsh test/lab/Enable-TestAutomation.ps1
```

No Windows, saia e entre novamente na sessão se ele relatar mudanças de
escala de exibição.

**Caminho guiado** -- no beacon, `install/setup.ps1` executa esta etapa
(pulada se a máquina só hospeda serviços). Todas as outras máquinas do
laboratório executam o comando acima manualmente.

<a id="42383647-0004"></a>

### A.2 Criar o armazenamento do laboratório

Execute onde o armazenamento fica -- em uma máquina que monta o caminho
do NAS, ou na máquina de serviços compartilhados se não houver NAS
([B.2](#b2-armazenamento-do-laboratório-compartilhamentos-pool-e-stash-idealmente-em-um-nas)).

**Armazenamento nesta máquina (sem NAS)** -- um único comando faz tudo
(pastas, contas, compartilhamentos, montagens, configuração). Elevado no
Windows; no macOS e no Ubuntu execute-o **sem** `sudo`:

```
pwsh test/lab/New-LocalLabStorage.ps1
```

Ele pergunta apenas onde o armazenamento deve ficar (sugerindo um padrão
por sistema operacional), chama `New-Lab` e grava `networkStorage.*` e
as entradas do cofre -- depois pule para o último parágrafo desta etapa.
Um laboratório posterior na mesma máquina precisa apenas de
`pwsh test/lab/New-Lab.ps1 -Name <lab-name>` -- ele reaproveita as pastas
e as contas que já estão aqui.

**Armazenamento em um NAS ou em um servidor de arquivos separado** --
crie as pastas e o cofre do laboratório aqui, depois crie as contas e
conceda as permissões de compartilhamento **naquele dispositivo**:

```
pwsh test/lab/New-Lab.ps1 -Name <lab-name> -Root <storage-root>
```

`<lab-name>` é minúsculo (letras, dígitos, hifens); `<storage-root>` é,
por exemplo, `D:\work` ou `/srv`. Compartilhe as duas pastas que ele
criou -- uma conta dedicada por compartilhamento, usando as senhas que o
`New-Lab` acabou de gerar no cofre do laboratório:

```powershell
# On the machine hosting the shares (elevated, Windows example)
New-LocalUser yuruna-pool  -Password (Read-Host -AsSecureString 'yuruna-pool password')
New-LocalUser yuruna-stash -Password (Read-Host -AsSecureString 'yuruna-stash password')
New-SmbShare -Name yuruna.pool  -Path D:\work\yuruna.pool  -FullAccess yuruna-pool
New-SmbShare -Name yuruna.stash -Path D:\work\yuruna.stash -FullAccess yuruna-stash
icacls D:\work\yuruna.pool  /grant 'yuruna-pool:(OI)(CI)M'
icacls D:\work\yuruna.stash /grant 'yuruna-stash:(OI)(CI)M'
```

Depois, em cada máquina que você configurar manualmente -- a máquina de
serviços compartilhados agora e a primeira máquina de ciclos em
[A.6](#a6-subir-a-primeira-máquina) -- preencha `networkStorage.*` em
`test/test.config.yml` e guarde as duas senhas de compartilhamento no
cofre do hospedeiro ([Definir as senhas SMB no cofre](../test-config.md#setting-the-smb-passwords-in-the-vault)).
Máquinas inscritas em [A.7](#a7-inscrever-cada-máquina-adicional)
recebem as duas coisas pela sincronização.

**Caminho guiado** -- `install/setup.ps1` executa o
`New-LocalLabStorage.ps1` no beacon quando você responde que o
armazenamento fica aqui. Para um NAS ele apenas **monta** o que
`networkStorage.*` já nomeia -- não cria nada no NAS, então faça os
comandos acima primeiro. Uma montagem que falha pergunta se deve parar
ou recorrer a compartilhamentos locais; de forma não assistida,
`storage.onFailure` decide (padrão `stop`). Um laboratório não pode
recusar o armazenamento compartilhado: o serviço stash e o
armazenamento de intenção do grupo precisam dele.

<a id="42383647-0005"></a>

### A.3 Iniciar o serviço caching-proxy (um por laboratório)

Na máquina de serviços compartilhados; elevado no Windows, sem elevação
no macOS ([B.3](#b3-iniciar-o-serviço-caching-proxy--painéis)):

```
pwsh test/service/Start-CachingProxyServiceVM.ps1
```

Anote o IP da VM do proxy que o script imprime -- o
`vmStart.cachingProxyIp` de cada máquina
([A.6](#a6-subir-a-primeira-máquina)) aponta para ele.

O bloco "Lab token" do painel "Yuruna hosts" do Grafana mostra o código
de 6 caracteres que as etapas seguintes resgatam para inscrever hospedeiros.
Ele rotaciona cerca de uma vez por minuto -- leia-o de novo a cada vez
que executar o `Set-LabToken.ps1`.

**Caminho guiado** -- `install/setup.ps1` inicia esta VM, espera pelo
agregador do grupo e grava o `vmStart.cachingProxyIp` **desta** máquina.
Todas as outras máquinas recebem o valor manualmente ou pela
sincronização.

<a id="42383647-0006"></a>

### A.4 Iniciar o serviço stash

Elevado no Windows, sem elevação no macOS; precisa da configuração de
A.2 nesta máquina ([B.4](#b4-iniciar-o-serviço-stash)):

```
pwsh test/service/Start-StashServiceVM.ps1
```

**Caminho guiado** -- `install/setup.ps1` o inicia assim que o
armazenamento estiver configurado; caso contrário, lista o serviço stash
como pulado.

<a id="42383647-0007"></a>

### A.5 Iniciar o serviço pool-control

Elevado no Windows, sem elevação no macOS
([B.5](#b5-iniciar-o-serviço-pool-control)):

```
pwsh test/service/Start-PoolControlServiceVM.ps1
pwsh test/lab/Set-LabToken.ps1 -LabToken <code>
```

`<code>` é o valor atual do bloco "Lab token"
([A.3](#a3-iniciar-o-serviço-caching-proxy-um-por-laboratório)); o
`Set-LabToken.ps1` inscreve este hospedeiro no laboratório.

**Caminho guiado** -- `install/setup.ps1` faz as duas linhas, lendo o
token rotativo do endpoint de métricas do agregador -- sem bloco para
copiar -- e imprimindo um comando pronto para copiar e colar se não
conseguir. Ele também garante a existência do grupo `default` e valida o
armazenamento de intenção; [pool-admin.md](../pool-admin.md) cobre a
administração manual. Ele não liga a inscrição automática
([B.5](#b5-iniciar-o-serviço-pool-control)).

<a id="42383647-0008"></a>

### A.6 Subir a primeira máquina

Na máquina que rodará ciclos primeiro: edite `test/test.config.yml` --
no mínimo `repositories.projectUrl` (e `GH_TOKEN` se for privado) e
`guestSequence`, mais os valores de `networkStorage.*` e as senhas de
compartilhamento de [A.2](#a2-criar-o-armazenamento-do-laboratório) e o
`vmStart.cachingProxyIp` de
[A.3](#a3-iniciar-o-serviço-caching-proxy-um-por-laboratório) -- depois
inscreva, valide e execute
([B.6](#b6-configurar-a-primeira-máquina)):

```
pwsh test/lab/Set-LabToken.ps1 -LabToken <code>
pwsh test/Test-Config.ps1
pwsh test/Invoke-TestProject.ps1
pwsh test/Start-TestRunner.ps1
```

Pule o `Set-LabToken.ps1` se esta for a máquina de serviços
compartilhados -- [A.5](#a5-iniciar-o-serviço-pool-control) já a
inscreveu. Corrija todo FAIL do `Test-Config`; depure o
`Invoke-TestProject` até ficar verde; depois deixe o executor ciclando
-- ele serve o painel de status em `http://<host>:8080/`.

**Caminho guiado** -- no beacon, `install/setup.ps1` já criou
`test/test.config.yml`, definiu `repositories.projectUrl` (se
informado) e `vmStart.cachingProxyIp` e executou esta etapa de
validação do `Test-Config`; a inscrição de
[A.5](#a5-iniciar-o-serviço-pool-control) também semeia `pool.enabled`
e `pool.intentGitUrl`. `guestSequence` e `GH_TOKEN` nunca são tocados.
Ele não executa ciclos -- `Invoke-TestProject.ps1` e
`Start-TestRunner.ps1` ficam com você.

<a id="42383647-0009"></a>

### A.7 Inscrever cada máquina adicional

> **Primeira vez, ou uma máquina que ainda precisa da conta de teste?**
> [Adicionando uma máquina a um laboratório](../lab-new-machine.md)
> percorre essa mesma sequência por completo -- criando a conta,
> entrando nela, a credencial do GitHub e o primeiro relatório do
> `Test-Config.ps1`.

Em cada máquina restante ([B.7](#b7-cada-máquina-adicional)):

```
pwsh test/lab/Set-LabToken.ps1 -LabToken <code>
pwsh test/lab/Sync-HostConfiguration.ps1 -ReferenceHost <ip-or-name>
pwsh test/Invoke-TestProject.ps1
```

A sincronização copia a configuração do hospedeiro de referência convertida
para este hospedeiro e termina executando o `Test-Config.ps1`.

Se a máquina antes era um **hospedeiro autônomo**, execute
`pwsh test/pool/Convert-ToPoolWorker.ps1 -ReferenceHost <ip-or-name>` no
lugar da sincronização. Ele faz a mesma sincronização e depois aposenta
os serviços locais que o laboratório agora fornece -- que, do
contrário, continuam vencendo a busca e servindo silenciosamente os
ciclos deste hospedeiro ([B.7](#b7-cada-máquina-adicional)).

Quando o `Invoke-TestProject`
estiver verde, abra a interface do serviço pool-control em
`http://<pool-control-service-vm-ip>/`, adicione o hospedeiro a um grupo,
atribua um conjunto de testes e então:

```
pwsh test/Start-TestRunner.ps1
```

**Caminho guiado** -- nenhum: `install/setup.ps1` nunca toca uma segunda
máquina. A inscrição automática continua desligada
([B.5](#b5-iniciar-o-serviço-pool-control)), então uma máquina inscrita
aqui não pertence a nenhum grupo até você colocá-la em um.

---

<a id="42383647-000a"></a>

## Seção B: Aprofundamento

<a id="42383647-000b"></a>

### B.0 O script de configuração guiada em um beacon

Referência para o atalho no topo deste guia. No modo laboratório, o
`install/setup.ps1` cobre, somente no beacon: as configurações do hospedeiro
([A.1](#a1-habilitar-a-automação-de-testes-todas-as-máquinas)), o
armazenamento ([A.2](#a2-criar-o-armazenamento-do-laboratório)), os
serviços caching-proxy
([A.3](#a3-iniciar-o-serviço-caching-proxy-um-por-laboratório)), stash
([A.4](#a4-iniciar-o-serviço-stash)) e pool-control
([A.5](#a5-iniciar-o-serviço-pool-control)), a inscrição do próprio
hospedeiro -- lendo o token rotativo do endpoint aberto de métricas do
agregador do grupo no proxy (`<proxy-ip>:9400/metrics`) -- e o trabalho
com `test.config.yml` e a etapa de validação de
[A.6](#a6-subir-a-primeira-máquina), além de garantir a existência do
grupo `default`. As configurações do hospedeiro são puladas se a máquina só hospeda
serviços; o serviço stash é pulado a menos que o armazenamento esteja
configurado.

**Ele deixa deliberadamente para você:** instalar e clonar (execute
primeiro o bootstrapper do sistema operacional); criar qualquer coisa
em um NAS -- ele apenas monta o que `networkStorage.*` já nomeia,
criando o ponto de montagem local (e no Ubuntu, antes disso, o drop-in
de sudoers do armazenamento do grupo, já que a montagem usa `sudo -n`),
e um `networkStorage.*` vazio faz a etapa falhar nomeando as chaves que
ela esperava; a varredura de inscrição automática
([B.5](#b5-iniciar-o-serviço-pool-control)); e os ciclos, de modo que
[A.6](#a6-subir-a-primeira-máquina) ainda termina com você.

A subida adota uma VM de serviço saudável e substitui uma que esteja
não saudável, parcialmente removida ou ausente. `-Rebuild` substitui
todas as VMs de serviço da execução; reserve cerca de 15 minutos para o
proxy.

Uma execução interativa grava as respostas que ela *resolveu* em
`install/setup.answers.lab.yml`; devolva esse arquivo com `-AnswerFile`
para montar o próximo beacon do mesmo jeito. A única chave de
laboratório é `lab.name`, acima do conjunto autônomo. O grupo `default`
não é uma escolha: toda execução o cria no armazenamento de intenção
quando não há nenhum, deixando um existente intacto.

Uma execução não assistida com `storage.kind: local` também precisa de
`storage.localRoot`, e é recusada no primeiro segundo sem ele -- o
`New-LocalLabStorage.ps1` roda como processo filho com o stdin fechado,
então não há como perguntar. Uma execução interativa também não
pergunta: ela adota a convenção da plataforma e registra isso no log da
execução. Em um beacon, uma falha de armazenamento encerra a execução,
porque o armazenamento de intenção do grupo e o serviço stash ficam
nele.

Parâmetros, semântica de reexecução e o que faz uma execução falhar são
compartilhados com o caminho autônomo:
[operator.md B.0](../operator.md#b0-the-guided-setup-script). Para
devolver uma máquina ao estado anterior, veja
[test/lab/Disable-TestAutomation.ps1](../../test/lab/Disable-TestAutomation.ps1)
([B.1](#b1-habilitar-a-automação-de-testes-todas-as-máquinas)).

<a id="42383647-000c"></a>

### B.1 Habilitar a automação de testes (todas as máquinas)

```
pwsh test/lab/Enable-TestAutomation.ps1
```

Execute em cada máquina do laboratório. Adesão explícita que a
transforma em um hospedeiro de teste: suspensão do monitor, protetor de tela,
bloqueio de tela, escala de exibição (Windows), concessões de TCC
(macOS). Administrador no Windows; sem elevação no macOS e no Ubuntu --
sob `sudo`, seus módulos do PowerShell vão parar no perfil do root.
Idempotente; suporta `-WhatIf`. No Windows, saia e entre novamente na
sessão se ele relatar mudanças de escala de exibição -- o OCR precisa
de escala de 100%. Detalhes:
`host/<platform>/Enable-TestAutomation.ps1`.

**Devolver uma máquina ao estado anterior** --
`pwsh test/lab/Disable-TestAutomation.ps1` é o inverso; detalhamento
completo: [operator.md](../operator.md#putting-the-machine-back). Em uma
máquina de laboratório, `-StopServices` também para as VMs
caching-proxy, stash e pool-control -- na máquina de serviços
compartilhados isso derruba o laboratório inteiro, e é por isso que ele
vem desligado por padrão.

Duas observações específicas do laboratório: ele **se recusa a rodar
enquanto um executor de testes é dono do diretório de runtime** -- o
estado normal de um hospedeiro de laboratório em ciclo, então pare o executor
primeiro -- e ele nada sabe sobre **inscrição**: as chaves `pool.*` e a
chave de autenticação interna ficam onde estão. Para sair de um grupo,
use os comandos de administração de grupo
([pool-admin.md](../pool-admin.md)); para tirar um hospedeiro do painel, use
`test/pool/Remove-PoolHost.ps1`.

<a id="42383647-000d"></a>

<a id="b2-armazenamento-do-laboratório-compartilhamentos-pool-e-stash-idealmente-em-um-nas"></a>

### B.2 Armazenamento do laboratório: compartilhamentos do grupo e do stash (idealmente em um NAS)

As camadas de rede duráveis ([pool-storage.md](../pool-storage.md),
[stash-guide.md](../stash-guide.md)) são sustentadas por dois
compartilhamentos SMB3 -- `yuruna.pool` e `yuruna.stash` -- em um NAS
se você tiver um, senão na máquina que hospeda os serviços
compartilhados. O `test/lab/New-Lab.ps1` cria as pastas, o cofre do
laboratório e o repositório semeado de intenção do grupo em uma única
etapa idempotente, executada onde o armazenamento fica; comandos:
[A.2](#a2-criar-o-armazenamento-do-laboratório).

Ele gera uma credencial por conta de compartilhamento no cofre do
laboratório -- YAML puro protegido por permissões de sistema de
arquivos, de modo que ele continua **copiável para as outras máquinas
do laboratório** (arquivos presos ao DPAPI não seriam
descriptografados em outro lugar; veja
`test/schemas/lab.vault.schema.yml`). Compartilhar as pastas é tarefa
sua -- uma conta dedicada por compartilhamento, como no exemplo de A.2;
qualquer servidor Samba/SMB com os mesmos nomes de compartilhamento e
contas funciona. Depois, em cada máquina, preencha `networkStorage.*`,
ponha as senhas de compartilhamento no cofre e defina
`networkStorage.moveLogsToPoolStorage:
true` nos hospedeiros que devem arquivar ciclos
([test-config.md](../test-config.md)).

**Quando o armazenamento fica na máquina em que você está, o
`test/lab/New-LocalLabStorage.ps1` faz a etapa inteira no lugar** -- as
contas, o servidor SMB, os compartilhamentos, as entradas do cofre, as
montagens e as seis chaves `networkStorage.*`, além da chamada a
`New-Lab`. Idempotente, aceita `-WhatIf`, e `-MoveLogs` para
`networkStorage.moveLogsToPoolStorage`. Detalhes:
[operator.md B.7](../operator.md#b7-local-shares-for-pool-and-stash-storage).

Os compartilhamentos são consumidos por aliases do arquivo hosts
(`ypool-nas`, `ystash-nas`) que resolvem para loopback, de modo que um
laboratório de uma máquina só exercita o mesmo código de montagem e
replicação que um com NAS
([operator.md B.7](../operator.md#b7-local-shares-for-pool-and-stash-storage)).

Uma máquina **autônoma** ganha mais um alias, `yuruna-dash`, apontando
para a VM do serviço caching-proxy em vez do loopback: ele torna o painel
Yuruna hosts `http://yuruna-dash:3000/d/yuruna-pool/yuruna-hosts`, uma
URL que vale a pena guardar nos favoritos porque sobrevive à
recompilação da VM de cache em uma nova concessão DHCP. O `setup.ps1` o
reescreve a cada execução a partir do mesmo endereço que grava em
`vmStart.cachingProxyIp`. Um laboratório não ganha esse alias -- seu
proxy é compartilhado, e todas as outras máquinas chegam a ele por essa
chave de configuração.

O alias é **local do hospedeiro de propósito** -- as VMs de serviço não o
usam. Dentro de um convidado, `127.0.0.1` é o loopback do próprio
convidado (a montagem falha com `cifs_mount ... -111`), então cada
compilação de VM grava o endereço em que este hospedeiro é alcançável a
partir da rede daquela VM: o endereço de LAN para uma VM em bridge, o
gateway do hipervisor para uma com NAT. Duas consequências: o endereço
é fixado no momento da **compilação**, então um hospedeiro que muda de
endereço (ou alterna entre Wi-Fi e Ethernet) precisa que as VMs de
serviço sejam recompiladas; e a porta TCP 445 de entrada precisa estar
alcançável a partir da rede da VM para que um convidado em bridge
consiga montar.

**Adicionar mais laboratórios àquela máquina** exige apenas o `New-Lab`:
as contas de compartilhamento valem para a máquina inteira, então ele
reaproveita a raiz e as credenciais já presentes em vez de cunhar um
segundo conjunto -- veja
[operator.md B.7](../operator.md#b7-local-shares-for-pool-and-stash-storage).

**Ele serve apenas para armazenamento local.** Um NAS é dono das
próprias contas -- crie-as no dispositivo e depois aponte
`networkStorage.*` para ele, como acima.

<a id="42383647-000e"></a>

### B.3 Iniciar o serviço caching-proxy + painéis

```
pwsh test/service/Start-CachingProxyServiceVM.ps1
```

Um proxy serve o laboratório inteiro. Compila a VM
`yuruna-caching-proxy-service` e expõe as portas 80 (certificado da CA),
3128/3129 (Squid), 3000 (Grafana), 9302 (métricas). Elevado no
Windows; sem elevação no macOS. Em cada máquina do laboratório, defina
`vmStart.cachingProxyIp` com o IP deste proxy. A compilação cunha uma
chave de autenticação interna no cofre deste hospedeiro quando não existe
nenhuma, e o painel "Yuruna hosts" do Grafana mostra o "Lab token"
rotativo de 6 caracteres que as etapas seguintes resgatam para
inscrever hospedeiros. A VM de cache sobrevive a reinstalações do framework.
Detalhes:
[caching.md](../caching.md#caching-proxy-service--test-harness-operator-reference).

<a id="42383647-000f"></a>

### B.4 Iniciar o serviço stash

```
pwsh test/service/Start-StashServiceVM.ps1
```

Sobe a VM `yuruna-stash-service` -- a caixa de depósito de todo o
laboratório para arquivos e trechos (interface web + scp). Elevado no
Windows, sem elevação no macOS. Ela monta o compartilhamento
`yuruna.stash` de
[B.2](#b2-armazenamento-do-laboratório-compartilhamentos-pool-e-stash-idealmente-em-um-nas),
então configure isso primeiro. Sem login; apenas redes confiáveis. Guia
do usuário: [stash-guide.md](../stash-guide.md).

Em um hospedeiro macOS com rota padrão por **Wi-Fi**, esta VM é compilada em
UTM Shared NAT em vez de bridge -- o vmnet não consegue fazer bridge de
um uplink Wi-Fi, então uma VM em bridge nunca receberia uma concessão
DHCP. Ela fica então invisível para a LAN no endereço próprio, e o
script encaminha uma porta do hospedeiro: os pares a alcançam em
`<host-lan-ip>:2222` (remapeada, porque o sshd do próprio Mac é dono da
22) em vez de `<vm-ip>:22`. Conectar um cabo Ethernet -- inclusive um
adaptador Ethernet USB, do qual o vmnet faz bridge sem problema -- a
devolve para bridge na próxima recompilação; o script avisa quando o
modo da VM deixa de corresponder ao uplink do hospedeiro.

<a id="42383647-0010"></a>

### B.5 Iniciar o serviço pool-control

```
pwsh test/service/Start-PoolControlServiceVM.ps1
```

Sobe a VM `yuruna-pool-control-service` -- interface do operador + API
para a intenção do grupo: criar grupos, adicionar hospedeiros, atribuir
conjuntos de testes. Elevado no Windows, sem elevação no macOS. Em um
hospedeiro macOS com Wi-Fi ela é compilada em UTM Shared NAT
([B.4](#b4-iniciar-o-serviço-stash)) e encaminhada -- os pares abrem
`http://<host-lan-ip>:8081/` (os encaminhamentos por serviço nunca
mudam: caching-proxy `:80`, stash `:2222`, pool-control `:8081`,
download-agent `:8082`). O cloud-init compila o daemon dentro do
convidado (sem precisar de `go` no hospedeiro) e persiste seu log de
auditoria + status em `poolStorageNetworkPath` -- configure os
compartilhamentos
([B.2](#b2-armazenamento-do-laboratório-compartilhamentos-pool-e-stash-idealmente-em-um-nas))
primeiro. A interface está na porta 80
(`http://<pool-control-service-vm-ip>/`), também linkada na tabela
Extension hosts do painel "Yuruna hosts" do Grafana. Inscreva este hospedeiro
com `test/lab/Set-LabToken.ps1 -LabToken <code>` (o valor do bloco "Lab
token"); o script busca a chave de autenticação interna compartilhada e
a coloca no cofre do hospedeiro. O `install/setup.ps1` faz isso para o beacon
-- mas **a inscrição automática continua desligada** até que um bloco
`autoEnrollment` nomeie um grupo de destino no `pools.yml` do
armazenamento de intenção *e* o daemon rode com `--auto-enroll`; até
lá, um hospedeiro inscrito não entra em nenhum grupo por conta própria.
Adicione `-HostSideProof` para rodá-lo diretamente neste hospedeiro
(interface em `http://<host>:8090/`, precisa de `go` + `pwsh`).
Detalhes: [Serviço pool-control](../pool-admin.md#pool-control-service).

Cada VM de serviço tem a própria conta de administrador e chave de cofre
-- veja
[Contas de administrador das VMs](../operator.md#vm-administrator-accounts).

<a id="42383647-0011"></a>

### B.6 Configurar a primeira máquina

Na máquina que rodará ciclos primeiro (qualquer uma delas):

1. **Inscreva-se no laboratório** -- `pwsh test/lab/Set-LabToken.ps1
   -LabToken <code>` (valor atual do bloco "Lab token"); já feito para
   a máquina de serviços compartilhados em
   [B.5](#b5-iniciar-o-serviço-pool-control). Sem o token, o hospedeiro ainda
   cicla de forma autônoma, mas nunca reporta aos painéis do
   laboratório.
2. **Configure e valide** -- edite `test/test.config.yml` e execute
   `pwsh test/Test-Config.ps1`
   ([guia do operador B.6](../operator.md#b6-configure-and-validate));
   inclua os valores de `networkStorage.*` e as senhas de
   compartilhamento de
   [B.2](#b2-armazenamento-do-laboratório-compartilhamentos-pool-e-stash-idealmente-em-um-nas)
   e o `vmStart.cachingProxyIp` de
   [B.3](#b3-iniciar-o-serviço-caching-proxy--painéis).
3. **Um ciclo local** -- `pwsh test/Invoke-TestProject.ps1` até ficar
   verde; um ciclo sem laço em volta é o lugar mais barato para depurar.
4. **Ciclos contínuos** -- `pwsh test/Start-TestRunner.ps1`; ele inicia
   automaticamente o painel de status em `http://<host>:8080/`
   ([runner-outer-loop.md](../runner-outer-loop.md)).

<a id="42383647-0012"></a>

### B.7 Cada máquina adicional

Passo a passo, com as partes humanas (conta de teste, entrada na sessão,
credencial do GitHub, leitura do primeiro relatório de validação):
[Adicionando uma máquina a um laboratório](../lab-new-machine.md).

1. **Linha de base do SO, verificação prévia, instalação, usuário de
   teste** -- guia do operador até
   [A.2](../operator.md#a2-create-the-test-user); reinicie se o instalador
   pedir.
2. **Habilite a automação de testes** --
   `pwsh test/lab/Enable-TestAutomation.ps1`
   ([B.1](#b1-habilitar-a-automação-de-testes-todas-as-máquinas)).
3. **Inscreva-se no laboratório e depois sincronize a configuração de
   um hospedeiro existente:**

   ```
   pwsh test/lab/Set-LabToken.ps1 -LabToken <code>
   pwsh test/lab/Sync-HostConfiguration.ps1 -ReferenceHost <ip-or-name>
   ```

   O `Set-LabToken.ps1` resgata no agregador o código do bloco "Lab
   token" e guarda a chave de autenticação interna no cofre deste
   hospedeiro. A sincronização então copia o `test.config.yml` do hospedeiro de
   referência convertido para este hospedeiro (caminhos de
   compartilhamento, pontos de montagem, aliases de hospedeiro) e **termina
   executando o Test-Config.ps1**. Se o agregador estiver
   inacessível, pule o `Set-LabToken.ps1` e passe a chave bruta (do
   cofre do hospedeiro de serviços compartilhados) para a sincronização:
   `-InternalAuthKey '<raw-key>' -PersistInternalAuthKey`. Nenhum
   caching-proxy-service local é necessário -- o
   `vmStart.cachingProxyIp` sincronizado aponta para o compartilhado.

   Antes de sobrescrever qualquer coisa, a sincronização compara a
   configuração obtida com o `test.config.yml.template` deste hospedeiro e
   interrompe para perguntar se o hospedeiro de referência está atrasado em
   relação a ele -- listando chaves aposentadas que ele ainda usa,
   chaves atuais que lhe faltam e chaves que o schema descartou.
   Corrija na origem (`pwsh tools/Update-TestConfigNaming.ps1` +
   `Test-Config.ps1` lá) e sincronize de novo. `-AllowStaleReference`
   aceita a divergência; sob `-NonInteractive`, uma referência
   desatualizada faz a execução falhar sem ele, de modo que uma
   sincronização não assistida não consegue propagar uma configuração
   migrada pela metade.
   **Uma máquina que era um hospedeiro autônomo precisa da conversão, não
   da sincronização.** O `Sync-HostConfiguration.ps1` substitui a
   configuração; ele não aposenta aquilo para onde a configuração
   antiga apontava, e uma VM de serviço local remanescente *vence*.
   As áreas de extensão são resolvidas como fixação do operador ->
   **uma VM neste hospedeiro** -> o registro do grupo, então uma máquina que
   mantém o próprio serviço stash continua usando-o e nunca consulta o
   do laboratório -- e os ciclos dela passam enquanto isso. Parar a VM
   também não basta: a varredura de cada ciclo reinicia toda VM de
   serviço registrada mas parada. Use:

   ```
   pwsh test/lab/Set-LabToken.ps1 -LabToken <code>
   pwsh test/pool/Convert-ToPoolWorker.ps1 -ReferenceHost <ip-or-name>
   ```

   Ele executa a sincronização acima e depois aposenta todas as VMs de
   serviço locais (caching-proxy, stash, pool-control,
   download-agent) pelo `Stop-*ServiceVM.ps1` de cada serviço -- que
   também limpa o marcador de extensão e atualiza o
   `host.registration.json`, de modo que o hospedeiro sai da linha Extension
   hosts do painel dentro de uma sondagem do agregador --, remove os
   aliases do arquivo hosts que aqueles serviços possuíam e verifica o
   estado final. `-KeepCachingProxy` mantém um Squid local aquecido em
   um link lento. Adicione `-WhatIf` para pré-visualizar; isso não
   exige elevação.

   A chave de autenticação interna é **obrigatória** para a conversão.
   Sem ela, as entradas de cofre que esta máquina cunhou para os
   compartilhamentos que ela mesma servia sobreviveriam, e o
   armazenamento do laboratório nunca viu essas senhas -- a montagem
   falha mais tarde com um erro de credencial que ninguém liga a esta
   etapa.

   O armazenamento é relatado, nunca excluído:
   `pwsh test/lab/Clear-LocalLabStorage.ps1` retira os
   compartilhamentos SMB, as contas `yuruna-pool` / `yuruna-stash` e
   as isenções de loopback, depois imprime os tamanhos sob a raiz do
   armazenamento e o comando exato para recuperá-los. Comece com
   `-ReportOnly`.
4. **(Recomendado) um ciclo local** -- `pwsh test/Invoke-TestProject.ps1`
   para provar que o hospedeiro está verde de forma autônoma antes de o grupo
   comandá-lo.
5. **Entre em um grupo e receba atribuições** -- abra a interface do
   serviço pool-control em `http://<pool-control-service-vm-ip>/`
   (linkada como "Pool-control service" na tabela Extension hosts do
   painel "Yuruna hosts" do Grafana), adicione este hospedeiro a um grupo e
   atribua um conjunto de testes. Equivalente na CLI:
   `test/pool/Add-HostToPool.ps1` + `test/pool/Set-PoolTestSet.ps1`
   ([pool-admin.md](../pool-admin.md)). Depois inicie
   `pwsh test/Start-TestRunner.ps1`.

---

<a id="42383647-0013"></a>

## Solução de problemas na subida

Sintomas específicos deste runbook. Problemas de montagem de
armazenamento em geral estão em
[pool-storage.md](../pool-storage.md#operating--troubleshooting).

**O `New-LocalLabStorage.ps1` para em `[5/8]` com um erro de saída 131
que menciona o .NET ou o `libhostfxr` (macOS).** A etapa se relança sob
`sudo` para gravar `/etc/hosts`, e um PowerShell do Homebrew não
consegue iniciar sem o `DOTNET_ROOT` que seu wrapper define. Registre a
localização do runtime uma vez e execute de novo -- o script retoma de
onde parou:

```
echo "$(brew --prefix dotnet)/libexec" | sudo tee /etc/dotnet/install_location_$(uname -m)
```

As instalações atuais gravam esse arquivo para você; só hospedeiros mais
antigos precisam disso.

**As duas montagens SMB falham em `[8/8]` com um erro de autenticação, e
a senha está correta (macOS).** O `smbd` aceita apenas a credencial
SMB-NT, que o `sysadminctl` não cria; as versões atuais a habilitam e a
comprovam. Para reparar uma conta criada antes, por conta:

```
sudo pwpolicy -u yuruna-pool -sethashtypes SMB-NT on
sudo sysadminctl -resetPasswordFor yuruna-pool -newPassword '<the lab-vault password>'
```

O tipo de hash só afeta senhas definidas *depois*, então a redefinição é
obrigatória. A senha está em
`test/status/extension/authentication/lab.<lab-name>.vault.yml`.

**Um script de VM de serviço relata sucesso, mas a VM não está rodando,
ou culpa o cloud-init / a compilação do daemon / o NAS por uma VM que
nunca inicializou.** Os três scripts verificam que a VM atingiu
`running` antes de qualquer coisa a jusante e falham nomeando o estado
que observaram, então esse sintoma significa que os scripts estão
desatualizados.

**A VM pool-control nunca monta o compartilhamento do grupo --
`cifs_mount failed w/return code = -111`.** O nome de servidor do
compartilhamento foi resolvido para algo local do hospedeiro (`mount error(13)`
é, em vez disso, uma credencial rejeitada -- veja acima). As compilações
atuais gravam no seed um endereço alcançável a partir do convidado; uma
VM mais antiga precisa ser recompilada. Confirme de dentro do
convidado:

```
getent hosts ypool-nas          # what the guest resolves, if anything
grep cifs /etc/fstab            # the ip= option should name the host
```

**O bundle ou os artefatos pertencem ao root e o UTM não abre a VM
(macOS).** Alguma coisa foi executada com `sudo`. Veja a observação no
topo da [Seção A](#seção-a-início-rápido):
`sudo chown -R "$USER" ~/yuruna` e depois execute de novo sem elevação.

---

<a id="42383647-0014"></a>

<a id="dois-pools-executando-dois-conjuntos-de-testes-diferentes"></a>

## Dois grupos executando dois conjuntos de testes diferentes

Um exemplo prático: um laboratório, dois grupos de hospedeiros, cada um
executando um corpo diferente de testes. Os nomes são apenas exemplos.

Suponha quatro hospedeiros registrados e verdes de forma autônoma
([B.7](#b7-cada-máquina-adicional)), o NAS do grupo
([B.2](#b2-armazenamento-do-laboratório-compartilhamentos-pool-e-stash-idealmente-em-um-nas))
e a VM do serviço pool-control
([B.5](#b5-iniciar-o-serviço-pool-control)). `<intent-url>` é a URL git
gravável da intenção do grupo; todo comando que altera a intenção a
recebe.

<a id="42383647-0015"></a>

### 1. Definir os dois conjuntos de testes

Um conjunto de testes é um **par** nomeado de repositórios de framework
e de projeto: um membro em grupo substitui as URLs de `repositories.*`
por ele durante o ciclo e executa o plano `test.runner.yml` do projeto
atribuído. Dois corpos de testes, portanto, significam dois
repositórios de projeto -- ou dois branches ou forks de um só. O
`GH_TOKEN` nunca é guardado na intenção do grupo; ele permanece local ao
hospedeiro.

Registre os dois pares na biblioteca de conjuntos de testes do
armazenamento de intenção:

```powershell
pwsh test/pool/Set-PoolTestSetDefinition.ps1 -Name testset1 -FrameworkUrl <framework-url> -ProjectUrl <project-a-url> -IntentGitUrl <intent-url>
pwsh test/pool/Set-PoolTestSetDefinition.ps1 -Name testset2 -FrameworkUrl <framework-url> -ProjectUrl <project-b-url> -IntentGitUrl <intent-url>
```

<a id="42383647-0016"></a>

<a id="2-criar-os-dois-pools"></a>

### 2. Criar os dois grupos

```powershell
pwsh test/pool/New-Pool.ps1 -PoolId poola -DisplayName 'Pool A' -IntentGitUrl <intent-url>
pwsh test/pool/New-Pool.ps1 -PoolId poolb -DisplayName 'Pool B' -IntentGitUrl <intent-url>
```

`-PoolId` é permanente -- o `New-Pool.ps1` cunha um `poolGuid` estável
para ele (o "Pool ID" do painel), então renomear depois significa um
grupo novo e bifurca o histórico de telemetria.

<a id="42383647-0017"></a>

### 3. Dividir os hospedeiros entre eles

Um hospedeiro pertence a **no máximo um grupo**, e é isso que torna a divisão
significativa. Cada `-HostId` é o `runtime/host.uuid` daquele hospedeiro:

```powershell
pwsh test/pool/Add-HostToPool.ps1 -PoolId poola -HostId <host-1-uuid> -IntentGitUrl <intent-url>
pwsh test/pool/Add-HostToPool.ps1 -PoolId poola -HostId <host-2-uuid> -IntentGitUrl <intent-url>
pwsh test/pool/Add-HostToPool.ps1 -PoolId poolb -HostId <host-3-uuid> -IntentGitUrl <intent-url>
pwsh test/pool/Add-HostToPool.ps1 -PoolId poolb -HostId <host-4-uuid> -IntentGitUrl <intent-url>
```

<a id="42383647-0018"></a>

<a id="4-atribuir-um-conjunto-de-testes-a-cada-pool"></a>

### 4. Atribuir um conjunto de testes a cada grupo

```powershell
pwsh test/pool/Set-PoolTestSet.ps1 -PoolId poola -Name testset1 -FrameworkUrl <framework-url> -ProjectUrl <project-a-url> -IntentGitUrl <intent-url>
pwsh test/pool/Set-PoolTestSet.ps1 -PoolId poolb -Name testset2 -FrameworkUrl <framework-url> -ProjectUrl <project-b-url> -IntentGitUrl <intent-url>
```

Um grupo contém exatamente um `testSet`; atribuir substitui o anterior.
Os membros não dividem o trabalho: cada membro de `poola` clona
`<project-a-url>` e executa o plano completo dele, reportando sob o
grupo.

<a id="42383647-0019"></a>

### 5. Verificar antes do próximo ciclo

```powershell
pwsh test/pool/Test-PoolIntent.ps1 -IntentGitUrl <intent-url>          # schema-validates the intent files
pwsh test/pool/Get-PoolStatus.ps1  -PoolId poola -IntentGitUrl <intent-url>
pwsh test/pool/Get-PoolStatus.ps1  -PoolId poolb -IntentGitUrl <intent-url>
```

O `Test-PoolIntent.ps1` também impõe a regra de um grupo por hospedeiro; o
`Get-PoolStatus.ps1` mostra os membros, o `desiredState` e o conjunto de
testes atribuído. Nenhum dos dois sonda as URLs dos repositórios -- um
erro de digitação só aparece quando o próximo ciclo de um membro clona.
Cada executor puxa a intenção no início do ciclo, então as atribuições
entram em vigor no ciclo seguinte, sem reiniciar nada.

<a id="42383647-001a"></a>

<a id="6-operar-os-dois-pools-de-forma-independente"></a>

### 6. Operar os dois grupos de forma independente

`desiredState` é por grupo, então um pode ficar pausado enquanto o outro
continua ciclando:

```powershell
pwsh test/pool/Set-PoolDesiredState.ps1 -PoolId poolb -State paused -IntentGitUrl <intent-url>
pwsh test/pool/Set-PoolDesiredState.ps1 -PoolId poolb -State run    -IntentGitUrl <intent-url>
```

Para mover um hospedeiro do Pool A para o Pool B, drene-o primeiro, deixe o
ciclo atual terminar, depois remova e adicione de novo:

```powershell
pwsh test/pool/Set-PoolDesiredState.ps1  -PoolId poola -State drain  -IntentGitUrl <intent-url>
pwsh test/pool/Remove-HostFromPool.ps1   -PoolId poola -HostId <host-2-uuid> -IntentGitUrl <intent-url>
pwsh test/pool/Add-HostToPool.ps1        -PoolId poolb -HostId <host-2-uuid> -IntentGitUrl <intent-url>
pwsh test/pool/Set-PoolDesiredState.ps1  -PoolId poola -State run    -IntentGitUrl <intent-url>
```

A drenagem interrompe o processo do executor em todos os membros do Pool A; então,
reinicie o `Start-TestRunner.ps1` nos hospedeiros que ficaram -- e no hospedeiro
movido depois que ele estiver no Pool B. Referência completa de
comandos e limitações: [pool-admin.md](../pool-admin.md).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Última revisão: 2026.09.24

Voltar para [Yuruna](../../README.md)
