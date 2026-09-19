<a id="42aaf735-0001"></a>

<a id="contornos-e-perguntas-frequentes-do-yuruna"></a>

# Soluções alternativas e perguntas frequentes do Yuruna

Notas, perguntas frequentes e soluções alternativas do desenvolvimento,
seguidas de solução de problemas por SO convidado. Problemas do lado do
hospedeiro ficam na documentação de hospedeiro: [Windows Hyper-V](../host-hyperv.md) -
[macOS UTM](../host-macos.md).

<a id="42aaf735-0002"></a>

## Conectividade

**A conexão com <http://localhost> falha** -- no Windows, pare o HTTP e
os processos relacionados. Descubra o que retém a porta 80 com
`netstat -nao | find ":80"` e então `net stop http`. Quando isso for
bloqueado por
[Os serviços HTTP não podem ser parados quando o Microsoft Web Deployment Service está instalado](https://learn.microsoft.com/en-us/troubleshoot/iis/http-service-fail-stopped),
execute também `net stop msdepsvc`, reinicie e tente de novo. Se o
`BranchCache` continuar exigindo uma parada, desabilite-o via
[`Disable-BC`](https://learn.microsoft.com/en-us/powershell/module/branchcache/disable-bc).
O [HSTS](https://en.wikipedia.org/wiki/HTTP_Strict_Transport_Security) do
navegador também pode ser a causa: remova localhost (ou o seu site de
desenvolvimento) da
[lista HSTS pré-carregada](https://www.chromium.org/hsts/) -- abra
`chrome://net-internals/#hsts` (`edge://net-internals/#hsts` no Edge) ->
em "Delete domain security policies" digite o site -> Delete.

**Um contêiner é alcançável por encaminhamento de porta, mas não pelo
ingress em localhost** -- confirme que as portas necessárias não estão
retidas por outros processos antes de implantar. O Docker Desktop
costuma retê-las
([docker/for-mac#4903](https://github.com/docker/for-mac/issues/4903));
saia do Docker e inicie-o de novo -- o item de menu Restart não basta.
Veja também **Depurando o localhost** abaixo.

**Um exemplo falha quando executado duas vezes, ou depois de outro
exemplo** -- execute, limpe e, se a porta 80 ainda estiver ocupada, saia
do Docker e comece de novo. Verifique as portas expostas com
`kubectl get svc --all-namespaces`.

**O registro local não funciona no macOS** -- confirme que a porta 5000
não está em uso
([Stack Overflow](https://stackoverflow.com/questions/69818376/localhost5000-unavailable-in-macos-v12-monterey)):
`lsof -nP -iTCP -sTCP:LISTEN | grep 5000`.

**Aplicações dentro do contêiner não conseguem se conectar ao mundo
externo** -- verifique se o `kube-proxy` alcança o IP do hospedeiro. Descubra o
IP do hospedeiro (`ipconfig`/`ifconfig`), entre no `kube-proxy` com exec,
instale o `ping` se necessário (veja **Depurando de dentro de um
contêiner mínimo** abaixo) e faça ping para fora.

<a id="42aaf735-0003"></a>

## Geral

**Qual é a resposta para a questão fundamental da vida, do universo e de
tudo mais?** -- `42`. É por isso que todos os exemplos usam prefixos
fáceis de achar e substituir, começando com `yrn42`.

**Mudando de máquina de desenvolvimento** -- recursos e componentes de
nuvem criados em uma máquina podem ser retomados em outra. Importe o
contexto do cluster e o `resources.output.yml`; o comando de importação
está no `cluster.tf` do template de recurso. Veja também
[mesclagem de configurações do Kubernetes](https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/).

**`Error: can't find external program "pwsh"`** -- verifique se há
PowerShell 7.0+ com `$PSVersionTable`. Instalação:
<https://aka.ms/powershell>. Versões usadas nos testes:
[Dependências de preflight](../operator.md#b2-preflight-dependencies).

**PowerShell instalado para apenas um usuário** -- uma instalação por
usuário (um MSI por usuário ou o pacote da Microsoft Store, ambos sob
`%LOCALAPPDATA%`) só pode ser executada pela conta que a instalou. Toda
outra conta do hospedeiro, incluindo o usuário de teste do Yuruna, recebe
`Access is denied` -- portanto `test/New-LocalTestUser.ps1` não consegue
definir a política de execução do PowerShell 7 dessa conta, e uma tarefa
agendada apontada para o mesmo `pwsh.exe` falha do mesmo jeito. Verifique
com `(Get-Command pwsh).Source`; qualquer coisa sob `C:\Users\` é por
usuário. Corrija a partir de um prompt elevado:

```powershell
winget uninstall --id Microsoft.PowerShell
winget install --id Microsoft.PowerShell --scope machine
```

<a id="42aaf735-0004"></a>

## Notas de desenvolvimento

**Obter dados de log de dentro de uma VM** -- copiar/colar costuma
funcionar; quando não funciona, <https://privatebin.at> aceita >512 KB
(como o pastebin).

**Arquivos marcados como `assume-unchanged`** -- os scripts marcam alguns
arquivos para que edições locais não apareçam no git. Reverta com
`git update-index --really-refresh`.

**Nomes de registro do Docker** -- as nuvens precisam de um nome único +
[FQDN](https://en.wikipedia.org/wiki/Fully_qualified_domain_name).
Mudar o nome pode exigir edições em `config/<cloud>/components.yml`.

**Colisões de contexto do Kubernetes** -- mantenha contextos de várias
nuvens lado a lado com `kubectl config rename-context old-name new-name`.

**Depuração do cert-manager** --
[FAQ do cert-manager](https://cert-manager.io/docs/faq/acme/); inspecione
`certificaterequests` em Custom Resources. Certificados curinga precisam
de DNS01 (não HTTP01) -- veja
[tipos de desafio](https://letsencrypt.org/docs/challenge-types/).

**Depurando de dentro de um contêiner mínimo** -- a maioria das imagens
vem sem `ping`:

```bash
apt-get update && apt-get install -y iputils-ping
```

Compilar fora do contêiner com `dotnet restore` pode exigir o
[`nuget`](https://learn.microsoft.com/en-us/nuget/install-nuget-client-tools)
no PATH; às vezes `nuget restore <name>.proj` precisa rodar antes de
`dotnet restore <name>.proj`. Depuração de ingress:
[exemplos do kubernetes/ingress-nginx](https://github.com/kubernetes/ingress-nginx/tree/master/docs/examples/grpc).

**Recuperação do Docker Desktop** -- "Reset to factory defaults", em
Troubleshoot, é a correção mais rápida. Depois remova `~/.kube` e
reabilite o Kubernetes (perde parte da configuração).

Para `docker-credential-desktop executable file not found in $PATH`:
em `~/.docker/config.json` renomeie `credsStore` -> `credStore` (ou
remova a entrada, ou instale `osxkeychain`/`wincred`).

**O Azure descarta o IP estático ao excluir seu ingress** -- confirmado
[aqui](https://stackoverflow.com/questions/66435282/how-to-make-azure-not-delete-public-ip-when-deleting-service-ingress-controlle).
A solução alternativa tem efeitos colaterais; prefira `clear` + recompilação de
recursos/componentes/cargas de trabalho.

**`Invoke-Expression: Cannot bind argument to parameter 'Command' because it is an empty string`**
-- normalmente é uma expressão de shell que não retornou nada; acrescente
`$true`.

**Editar um serviço ativo** -- `kubectl edit svc <name> -n <ns>` (também
configMaps, pods etc.); ao chegar no estado desejado, codifique-o como
instruções `kubectl patch`.

**Depurando o localhost** -- redefinir o cluster Kubernetes do Docker e
reconectar os contextos costuma ajudar. `automation/context-copy.ps1
-sourceContext <src> -destinationContext <dst>`; os nomes de contexto
estão em `resources.output.yml`. Veja
[docker/for-mac#4903](https://github.com/docker/for-mac/issues/4903).

**PodSecurityPolicy** -- `kubectl get psp -A` /
`kubectl delete psp <name>`.

**O seletor da última versão pontual do Ubuntu ordena pela versão
interpretada, não pela string do nome de arquivo** --
`Resolve-UbuntuServerStableImage` em
[`host/modules/Yuruna.UbuntuImage.psm1`](../../host/modules/Yuruna.UbuntuImage.psm1)
(consumido por todo `Get-Image.ps1` de cada convidado em Hyper-V, UTM e
KVM -- noble + resolute) resolve a ISO "estável mais recente" casando a
expressão regular `ubuntu-[\d.]+-live-server-<arch>\.iso` com a listagem
do diretório do release e depois ordenando as correspondências pela
`[version]` interpretada de cada nome de arquivo, em ordem decrescente,
e pegando a primeira.
A chave `[version]` é essencial: um simples
`Sort-Object Value -Descending` é lexicográfico, então, assim que o
Ubuntu publicar uma versão pontual `.10`+, `ubuntu-24.04.10-...` fica
ANTES de `ubuntu-24.04.2-...` (porque `'1' < '2'`) e o seletor fixaria a
`24.04.9` enquanto releases.ubuntu.com já serve a `.10` -- sintoma:
`Selected stable ISO: ubuntu-<NN>.04.9-live-server-<arch>.iso`.
Preserve a ordenação com chave de versão (e seu fallback para valores
não interpretáveis) em qualquer reescrita; uma edição no módulo
compartilhado afeta todos os chamadores de cada convidado.

<a id="42aaf735-0005"></a>

## Um neto desanexado prende o pipe do chamador no Windows

Criar um pwsh filho com qualquer fluxo padrão redirecionado (inclusive
`& pwsh ... *> $null`)
liga a herança de handles para esse filho. `Invoke-StatusServiceBounce` em
[`test/modules/Test.ConfigServiceSync.psm1`](../../test/modules/Test.ConfigServiceSync.psm1)
executa `Start-StatusService.ps1 -Restart` em um pwsh filho, e o serviço
de status que ele inicia é um neto que sobrevive ao reinício por design.
Com a herança ligada, esse serviço herda a ponta de escrita do pipe de
stdout do chamador e a mantém aberta por toda a sua vida: a leitura nunca
chega a EOF, então o reinício bloqueia no SERVIÇO, e não no filho que
saiu segundos atrás. O mesmo redirecionamento também engole todas as
linhas de progresso, então o sintoma é um travamento silencioso e sem
limite de tempo. Redirecionar os fluxos do próprio filho para arquivos
NÃO fecha a brecha -- um pipe herdável mais acima na ancestralidade
(qualquer chamador que capture a nossa saída) é repassado do mesmo jeito.

A correção é criar o processo sem `-Redirect*` e sem `-NoNewWindow`, o
que faz o PowerShell usar `ShellExecute`; isso não passa nenhum handle
herdável, então nada abaixo na cadeia consegue prender um pipe em ponto
algum. O filho escreve o próprio transcript com `Tee-Object` e o chamador
acompanha esse arquivo enquanto espera. O `-NonInteractive` vai no filho
para que um prompt falhe rápido em vez de bloquear em uma janela oculta
que ninguém pode responder. A espera precisa usar
`Process.WaitForExit(ms)` apenas no filho -- `Start-Process -Wait` espera
por toda a árvore de descendentes, o que inclui o serviço de status,
reintroduzindo a espera sem limite pelo outro lado.

O Unix não tem `ShellExecute`, mas seu serviço desanexado roda sob
`nohup` apontado para `/dev/null` + `server.err` e não consegue prender
os fluxos do chamador, então redirecionar os fluxos do próprio filho para
arquivos ali é seguro e dá o mesmo acompanhamento ao vivo.

<a id="42aaf735-0006"></a>

## Importação aninhada não global apaga a visão do chamador sobre um módulo

O PowerShell mantém **uma versão ativa por módulo** em uma sessão. Quando
um módulo é reimportado *sem* `-Global` de dentro de outro módulo, essa
cópia aninhada assume o lugar da versão ativa e a visão que o chamador
original tinha das funções exportadas desaparece. A chamada seguinte
falha com `The term '<Function>' is not recognized`.

A armadilha dispara nos dois sentidos:

- **O chamador perde sua visão.** `Initialize-YurunaHost` (de
  `test/modules/Test.HostContract.psm1`) desce em cascata até
  `host/<host type>/modules/Yuruna.Host.psm1`, que importa de forma
  aninhada o `test/modules/Test.CachingProxyService.psm1` **sem** `-Global`.
  Qualquer script que tenha importado o `Test.CachingProxyService` para si
  perde `Read-CachingProxyServiceState`, `Save-CachingProxyServiceState`,
  `Invoke-CachingProxyServiceProbe` e `Get-CachingProxyServiceStatePath` no
  instante em que `Initialize-YurunaHost` roda.
- **Módulos alheios perdem a deles.** Um script invocado com `&` a partir
  de um contexto de módulo (o executor de ciclo interno chamando
  `Remove-TestVMFiles.ps1`, ou o serviço de status chamando o contrato de
  hospedeiro) que faz uma importação `-Force` *sem* `-Global` tira o módulo da
  tabela global para todo módulo não relacionado, de modo que uma chamada
  posterior ao contrato vinda de `Test.SequenceEngine` não resolve. Essa é
  a *classe de regressão legacy-eviction*.

**A regra:** reimporte com `-Global -Force` imediatamente **depois** de
toda chamada a `Initialize-YurunaHost` e antes de tocar nos exports
afetados, e sempre passe `-Global` quando um script que pode ser invocado
a partir de um contexto de módulo importar um módulo compartilhado.

Locais que dependem dessa ordem: `test/service/Start-CachingProxyServiceVM.ps1`,
`test/service/Stop-CachingProxyServiceVM.ps1`, `test/service/Repair-CachingProxyServiceForwarder.ps1`,
`test/Test-CachingProxyService.ps1`, `test/service/Start-StatusService.ps1`,
`test/Remove-TestVMFiles.ps1`, `test/lab/Set-LabToken.ps1`.

Os sintomas de uma reimportação faltando são silenciosos, porque o `try`
ao redor normalmente engole o erro de resolução:

- `Start-StatusService.ps1` deixa `runtime/caching-proxy-service.txt` com o
  que a execução anterior escreveu, então o banner da página de status
  informa "not detected" enquanto o banner do próprio executor -- rodando
  na sessão do `Yuruna.Host`, onde `Read-CachingProxyServiceState` *está*
  visível -- informa corretamente "detected".
- `Start-CachingProxyServiceVM.ps1` deixa de persistir o IP de cache
  descoberto, então os provisionadores de convidado e o caminho rápido do
  serviço de status refazem a descoberta completa a cada ciclo.

Captura durável: `feedback_module_force_import_evicts_global`.

<a id="42aaf735-0007"></a>

## `utmctl start` sai com 0 sem iniciar a VM

Em um bundle recém-importado, `utmctl start` pode retornar 0 na camada de
RPC enquanto o UTM ainda está finalizando a ingestão do bundle -- a
requisição de início é descartada em silêncio e a VM permanece
`stopped`. Portanto o código de saída sozinho não é evidência de que a VM
está rodando: um chamador que confia nele anuncia um serviço que não
existe e depois culpa o que rodar em seguida (cloud-init, a compilação de
um daemon, uma montagem NAS) por um convidado que nunca inicializou.

A correção é verificar a transição em vez do código de saída: o `Start-VM`
(`Start-UtmVM`) do contrato de hospedeiro tenta de novo e interpreta o
`utmctl status`, e toda subida de serviço o acompanha com
`Wait-VMRunning` antes de fazer qualquer coisa adiante. Não improvise
`open` + `utmctl start`; esse caminho também pula o watchdog do diálogo
de argumentos personalizados do QEMU, sem o qual o UTM trava em uma
janela modal e a subida não roda sem supervisão.

<a id="42aaf735-0008"></a>

## Solução de problemas no convidado

Notas para problemas que aparecem dentro de um convidado provisionado, e
não no hospedeiro.

<a id="42aaf735-0009"></a>

### Amazon Linux 2023

**"Display Output Is Not Active"** -- confirme que há uma GUI instalada. O
primeiro boot do Amazon Linux (especialmente no macOS UTM) tem apenas um
terminal anexado; mude para essa janela para fazer login.

<a id="42aaf735-000a"></a>

### Ubuntu Server

Solução de problemas comum aos convidados Ubuntu Server (24.04, 26.04,
...). Substitua `<release>` nos caminhos abaixo pelo seu release (`24`,
`26`, ...) -- por exemplo, os caminhos de busca e execução do 24.04 usam
`guest/ubuntu.server.24/...` (`ubuntu.server.24.update.sh`).

**O autoinstall nunca começa; o console é uma parede de
`subiquity/Network/_send_update: CHANGE eth0`** -- o instalador não está
travado, está esperando. O subiquity pergunta
`Continue with autoinstall? (yes|no)` poucos segundos depois do boot,
pergunta uma única vez e não repete a pergunta com um Enter vazio -- só um
`yes` ou `no` literal faz a coisa andar. Seu controlador de rede escreve
um par `start:` / `finish:` no mesmo console para cada evento de link,
então a pergunta rola para fora da tela enquanto o instalador continua
esperando atrás dela. O prompt segue vivo: digite `yes` + Enter no console
e a instalação prossegue. Reiniciar a VM também funciona (a ISO pergunta
de novo), mas é a correção mais lenta. Qualquer coisa que atrase o
executor para além do boot do próprio convidado o coloca nesse estado --
na maioria das vezes uma pausa de etapa do operador, que segura o executor
enquanto o convidado continua imprimindo; veja
[control-routes.md](../control-routes.md#pause-and-resume-the-flag-file-back-channel).
O harness responde a isso sozinho quando a etapa define
`blindAfterSeconds`.

**Problemas de boot** -- procure pistas em
`/var/log/installer/installer-journal.txt`. Se o instalador em modo texto
parecer travado, use `Ctrl+Alt+F2` (ou `F3`) para mudar para um TTY e
então verifique `/var/log/installer` ou `/var/log/cloud-init.log` em busca
de `Error` ou `Failed to load` -- esses costumam apontar a linha de
configuração problemática.

**O login no console não aceita a senha** -- use `Ctrl+Alt+F3` para um TTY
alternativo e então execute
`/usr/local/lib/yuruna/fetch-and-execute.sh guest/ubuntu.server.<release>/ubuntu.server.<release>.update.sh`
duas ou três vezes, até não sobrar nenhuma atualização ou limpeza, e
`sudo reboot now`.

**Fuso horário incorreto** -- detectado automaticamente na instalação por
geolocalização de IP (cloud-init). Para definir manualmente:

```bash
timedatectl list-timezones | grep <region>
sudo timedatectl set-timezone America/Los_Angeles
timedatectl                       # verify
```

<a id="42aaf735-000b"></a>

### Windows 11

**winget não disponível** -- depois de uma instalação nova, atualize o
**App Installer** na Microsoft Store e reinicie o terminal. Como
alternativa:

```powershell
Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe
```

**Scripts bloqueados pela política de execução** --

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
```

As contas criadas por `test/New-LocalTestUser.ps1` já trazem isso: a
política é definida na criação, a partir de um logon único como a nova
conta, ou no primeiro sign-in dela pela tarefa agendada
`YurunaExecutionPolicy-<account>` quando a conta não tem senha com a qual
a execução que a criou possa fazer logon (`-NoPassword`,
`-ForcePasswordChange`). O comando acima é para contas criadas de
qualquer outra forma.

**O Docker Desktop exige reinício** -- se os comandos `docker` falharem
depois da instalação: reinicie o computador, abra o Docker Desktop e
espere o ícone da bandeja parar de animar.

**Kubernetes não disponível no Docker Desktop** -- Docker Desktop ->
**Settings** -> **Kubernetes** -> marque **Enable Kubernetes** -> **Apply
& restart**.

**Fuso horário incorreto** -- **Settings** -> **Time & Language** ->
**Date & time**. Ative **Set time zone automatically** ou escolha um
manualmente.

**Ativação do Windows** -- a VM é instalada com uma chave genérica (não
ativada). Para ativar:

```powershell
slmgr /ipk XXXXX-XXXXX-XXXXX-XXXXX-XXXXX
slmgr /ato
```

Chaves de produto: [Windows 11 ...](../../host/windows.hyper-v/guest.windows.11/vmconfig/README.md).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Última revisão: 2026.09.18

Voltar para [Yuruna](../../README.md)
