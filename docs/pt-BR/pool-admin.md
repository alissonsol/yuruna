<a id="4207d71a-0001"></a>

<a id="yuruna-pool-admin-guide----assign-test-sequences-to-a-host-pool"></a>

# Guia de administração de grupos do Yuruna -- atribua sequências de teste a um grupo de hospedeiros

> **Público deste guia.** Um **administrador / operador de grupo** que executa vários hospedeiros de teste
> do Yuruna e quer que eles compartilhem trabalho e apresentem relatórios juntos. Este *não* é um guia para escrever
> sequências de teste ou código do ambiente de testes e pressupõe que as **sequências de teste já existam** (as
> que um único hospedeiro executa a partir de `test.runner.yml`); sua tarefa aqui é direcionar um conjunto de
> hospedeiros para o projeto que as executa.

<a id="4207d71a-0002"></a>

<a id="what-a-pool-is"></a>

## O que é um grupo

Um **grupo** é um conjunto nomeado de hospedeiros de teste que executam o mesmo trabalho atribuído e apresentam relatórios
sob um único rótulo (o `poolId`). Você gerencia um grupo editando um pequeno arquivo
de **configuração** -- `pools.yml` -- por meio de alguns comandos de administração. Você nunca acessa os
hospedeiros diretamente: cada executor **busca** a configuração a cada ciclo e age de acordo com ela.

A configuração tem três partes:

- **members** -- quais hospedeiros pertencem ao grupo (por seu ID estável de hospedeiro).
- **repositories** -- os repositórios do framework e do projeto que o grupo executa (suas
  **Framework URL** e **Project URL**); o `test.runner.yml` do próprio projeto define
  o trabalho. Um grupo sem esses repositórios mantém cada membro nos repositórios que ele próprio
  configurou.
- **configuredState** -- se o grupo está em execução, em pausa ou finalizando o ciclo atual.

```
  you --run--> admin CLI --writes--> pools.yml  (configuration git repo on the caching-proxy-service)
                                          |
  every host --pulls read-only each cycle-+--> runs the pool's project, reports under <poolId>
```

O repositório de configuração contém **apenas arquivos sem segredos** (`pools.yml`,
`guests.compatibility.yml`). Nenhuma credencial passa por ele.

**O planejamento é descentralizado -- não há despacho central.** Um membro de um
grupo que contém repositórios muda para o framework e o projeto do grupo durante
o ciclo e resolve, por conta própria, o plano do `test.runner.yml` desse projeto, exatamente
como um hospedeiro independente resolve o seu. Os membros não coordenam nem dividem
o trabalho: cada um executa o plano inteiro. `guests.compatibility.yml` também não restringe
o plano -- `Test-PoolConfiguration.ps1` valida esse arquivo, e nenhum executor o lê.
A mudança apenas acrescenta essa possibilidade e faz o melhor esforço -- um grupo sem repositórios,
ou um manifesto de grupo que o executor não consegue ler, mantém o hospedeiro em seus próprios
repositórios configurados, em vez de gerar uma exceção ou interromper o laço.

**A própria busca** é uma pequena estrutura Git, opcional e desabilitada por padrão: um hospedeiro
com `pool.enabled: false`, ou cujo armazenamento de configuração está inacessível, simplesmente
continua executando ciclos como hospedeiro único. Cada executor clona/busca o repositório de configuração
pela LAN, encontra seu grupo ao localizar seu `hostId` estável em
`members[]` -- a única fonte de verdade para a composição do grupo -- e aplica
o `configuredState` obtido (`run`/`paused`/`drain`) ao laço externo
exatamente como faz com o sinalizador local `control.cycle-restart`. Toda chamada Git tem
um limite de tempo de relógio e proteção contra solicitações de credenciais
(`GIT_TERMINAL_PROMPT=0`, `GIT_ASKPASS` vazio, `GCM_INTERACTIVE=never`,
e entrada padrão fechada imediatamente), portanto um remoto travado ou inacessível falha rapidamente
em vez de bloquear o laço sem supervisão -- ou, no caminho que usa apenas `pwsh`,
um laço interativo.

<a id="4207d71a-0003"></a>

<a id="before-you-start"></a>

## Antes de começar

1. **O armazenamento de configuração existe.** A VM do caching-proxy-service inicializa um repositório Git bare em
   `/mnt/ypool-nas/pool-configuration.git` e o disponibiliza **somente para leitura por HTTP** em
   `http://<proxy>/pool-configuration.git`. Isso é configurado automaticamente quando o caching-proxy-service é
   provisionado.
2. **Cada hospedeiro habilitou a participação.** No `test/test.config.yml` de cada hospedeiro, defina o bloco `pool`:
   ```yaml
   pool:
     enabled: true
     configurationGitUrl: http://<proxy>/pool-configuration.git   # the READ-ONLY HTTP url
     localClonePath: ''                              # optional; defaults under runtime/
   ```
   Um hospedeiro com `pool.enabled: false` (o padrão) executa de forma independente.
3. **Você conhece o ID de cada hospedeiro.** Cada hospedeiro tem um ID estável em `runtime/host.uuid` -- uma
   cadeia hexadecimal de 32 caracteres com prefixo `42`, também exibida como `hostId` na página de status do próprio hospedeiro e
   no painel do grupo. Sempre que um ID COMPLETO é apresentado, ele usa
   hífens no formato GUID (`42abcdef-0123-4567-89ab-cdef01234567`); os armazenamentos contêm apenas o hexadecimal.
4. **Você pode gravar no repositório de configuração.** A URL HTTP acima é somente para leitura. Os comandos de administração
   precisam de um caminho/URL **gravável**, portanto execute-os **no caching-proxy-service** sobre o repositório local
   (`/mnt/ypool-nas/pool-configuration.git`), ou sobre qualquer remoto gravável com autenticação prévia.
   Informe-o com `-ConfigurationGitUrl <writable-url>`, ou defina `pool.configurationGitUrl` com um valor gravável
   no `test.config.yml` de onde você executa a CLI de administração (assim, pode omitir o sinalizador).
   As CLIs de administração reutilizam o mesmo invólucro Git de `Test.PoolSync`, com tempo limitado e proteção contra prompts,
   usado pelo caminho de busca do executor, e cada alteração é validada pelo esquema **antes** do commit,
   portanto uma configuração malformada nunca alcança o armazenamento do qual o grupo inteiro busca dados.

Execute os comandos abaixo a partir da raiz do repositório. As etapas 1, 2 e 4 também indicam a
página do pool-control service (`http://<pool-control>/`) que faz a mesma alteração
executando o mesmo comando; uma alteração feita lá é desbloqueada com o token do laboratório
([Desbloqueio das ações](#4207d71a-0012)), em vez de receber `-ConfigurationGitUrl`.

O proxy de cache monta o armazenamento do grupo com permissão de gravação para
root e de leitura para o grupo `www-data` (arquivos `0640`, diretórios `0750`).
As credenciais do NAS permanecem privadas. O Apache serve arquivos Git estáticos,
portanto os executores usam clones e buscas completos; esse transporte não
suporta operações superficiais. As reconstruções preservam o repositório de
configuração existente e suas configurações Git. O
`yuruna-pool-configuration.timer` repete a preparação a cada minuto após o fim de
uma execução, inclusive quando o NAS fica disponível depois da inicialização,
e atualiza os metadados Git estáticos dos repositórios cujos hooks de push não
podem ser executados no CIFS.

Para diagnosticar o acesso, consulte `http://<proxy>/pool-configuration-status` e
`http://<proxy>/config-fetch-pool-status`. O primeiro informa o estado do
armazenamento, do repositório, das permissões de leitura do Apache, das respostas
HTTP e de uma verificação de clone completo por HTTP; a data e hora indicam a
última execução. Os erros detalhados dos comandos ficam em
`journalctl -u yuruna-pool-configuration.service` na VM. O resumo de prontidão
da inicialização inclui esse resultado. `Test-CachingProxyService.ps1` também
verifica `HEAD` e `info/refs` do Git a partir do hospedeiro que o executa, para
que uma resposta HTTP 403 ou uma página HTML não seja confundida com acesso
funcional ao grupo apenas porque a porta 80 responde. O executor mantém sua
configuração em cache quando uma busca falha; sem cache, ele executa de forma
independente e não pode receber alterações do grupo até que o acesso seja
restabelecido.

Os testes de regressão do serviço são executados em um hospedeiro de
desenvolvimento Linux com Apache 2, Git, PowerShell, Python 3, curl e jq:
`python3 -m unittest discover -s host/vmconfig/tests -p test_pool_configuration.py -v`.

<a id="4207d71a-0004"></a>

<a id="step-1----create-the-pool"></a>

## Etapa 1 -- Crie o grupo

```powershell
pwsh test/pool/New-Pool.ps1 -PoolId lab -DisplayName 'Lab pool' -ConfigurationGitUrl <writable-url>
```

- `-PoolId` é um nome curto, em minúsculas, válido para DNS (`a-z 0-9 -`). Ele se torna o **rótulo
  permanente** da telemetria desse grupo no painel, portanto escolha-o com cuidado -- renomeá-lo
  depois divide o histórico.
- O grupo começa vazio (`configuredState: run`, sem membros e sem repositórios).
- No pool-control service: a página Pools (`/pools`) recebe **Pool id**
  e, opcionalmente, **Display name**; depois, selecione **Create pool**.

<a id="4207d71a-0005"></a>

<a id="step-2----add-the-hosts"></a>

## Etapa 2 -- Adicione os hospedeiros

Execute uma vez por hospedeiro:

```powershell
pwsh test/pool/Add-HostToPool.ps1 -PoolId lab -HostId 42abcdef0123456789abcdef01234567 -ConfigurationGitUrl <writable-url>
```

- `-HostId` é o `runtime/host.uuid` do hospedeiro (`42` + 30 caracteres hexadecimais). A coluna
  **Host ID** do painel do grupo mostra seus primeiros 8 caracteres e revela o ID completo, com hífens no formato GUID,
  pelo menu da própria célula; todos os comandos de administração de grupos aceitam esse formato, portanto um valor
  copiado do painel funciona ao ser colado, e cada comando o exibe de volta da mesma maneira.
  A composição do grupo é a única fonte de verdade; adicionar novamente um hospedeiro não altera nada.
- No pool-control service: escolha o grupo no seletor **Pool** do hospedeiro na
  página Hosts (`/hosts`).
- Para remover um hospedeiro depois, veja a **Etapa 6** abaixo (se estiver em execução, deixe-o finalizar o ciclo primeiro).

<a id="4207d71a-0006"></a>

<a id="step-3----choose-the-framework-and-project-repositories"></a>

## Etapa 3 -- Escolha os repositórios do framework e do projeto

Um grupo executa um par de repositórios: uma **Framework URL** (o repositório
do framework Yuruna) e uma **Project URL** (o projeto cujo próprio `test.runner.yml` define
o trabalho). Quando um grupo contém ambas, cada membro substitui seus próprios
`repositories.frameworkUrl` / `repositories.projectUrl` por elas durante o ciclo
e executa o plano do `test.runner.yml` desse projeto. Um grupo que não contém nenhuma mantém
cada membro em seus próprios repositórios configurados.

`GH_TOKEN` nunca é armazenado na configuração do grupo; ele permanece local ao hospedeiro, portanto a
credencial de cada membro deve poder ler ambos os repositórios (veja
[Acesso ao projeto](#4207d71a-000f)). Nada é cadastrado antecipadamente: a Etapa 4
registra ambas as URLs diretamente no grupo.

<a id="4207d71a-0007"></a>

<a id="step-4----set-the-repositories-on-the-pool"></a>

## Etapa 4 -- Defina os repositórios do grupo

```powershell
pwsh test/pool/Set-PoolRepository.ps1 -PoolId lab -FrameworkUrl <framework-url> -ProjectUrl <project-url> -ConfigurationGitUrl <writable-url>
pwsh test/pool/Set-PoolRepository.ps1 -PoolId lab -Clear -ConfigurationGitUrl <writable-url>   # back to each member's own repositories
```

- Um grupo contém **exatamente um** par; defini-lo substitui o anterior, e
  `-Clear` o remove.
- `-FrameworkUrl` e `-ProjectUrl` são usados juntos. Espaços nas extremidades de cada valor são removidos, e um valor
  vazio, que contenha espaços em branco ou um caractere de controle, ou que comece com `-`
  é recusado.
- As URLs são registradas diretamente em `pools.yml`, portanto a configuração é
  autossuficiente -- nenhum arquivo do repositório do projeto participa dela:

  ```yaml
  schemaVersion: 4
  pools:
    - poolId: lab
      # ...poolGuid, displayName, members, configuredState...
      repositories:
        frameworkUrl: <framework-url>
        projectUrl: <project-url>
  ```

  Referência completa dos campos: [`test/schemas/pools.schema.yml`](../../test/schemas/pools.schema.yml);
  exemplo completo: [`test/pool/examples/pools.yml`](../../test/pool/examples/pools.yml).
- O grupo de destino da inscrição automática nunca contém repositórios: defini-los
  nele é recusado, e `-Clear` é permitido ([Inscrição automática](#4207d71a-0014)).
- Nada consulta as URLs quando elas são definidas: um erro de digitação só aparece quando o
  próximo ciclo de um membro tenta clonar.
- No pool-control service: a célula **Framework / Project** do grupo na
  página Pools ([Framework / Project](#4207d71a-0024)).

<a id="4207d71a-0008"></a>

<a id="step-5----verify"></a>

## Etapa 5 -- Verifique

```powershell
pwsh test/pool/Test-PoolConfiguration.ps1             # schema-validates pools.yml (+ guests.compatibility.yml); host-in-one-pool invariant
pwsh test/pool/Get-PoolStatus.ps1 -PoolId lab  # shows members, configuredState, and repositories
```

Não há nada para "implantar": cada executor recebe a nova configuração no início de seu
**próximo ciclo**, portanto não é preciso reiniciar o hospedeiro. Depois que um hospedeiro do grupo concluir um ciclo,
confirme o efeito no painel **Yuruna hosts** do Grafana (ele agrupa todos os hospedeiros sob
seu `poolId`), ou diretamente: `curl -sk https://<proxy>:9400/api/v1/pool-status`.

`Test-PoolConfiguration.ps1` valida o documento armazenado pelo schemaVersion 4.
Os leitores aceitam as versões 2 e 3 em memória e preservam `run`, `paused` e
`drain` ao converter `desiredState` em `configuredState`. As URLs do `testSet`
da versão 2 passam para `repositories`. Campos de estado duplicados com o
mesmo valor são unificados durante a migração; valores conflitantes são
recusados antes de qualquer alteração. A versão 4 aceita apenas `configuredState`.

Atualize o framework em todos os executores, na VM pool-control-service e nos
checkouts de administração antes de migrar o repositório compartilhado.
Binários antigos não reconhecem o novo campo e não devem continuar usando
um repositório da versão 4. Em seguida, execute:

```powershell
pwsh tools/Update-TestConfigNaming.ps1 -ConfigPath <test.config.yml>
pwsh test/pool/Update-PoolConfigurationSchema.ps1 -ConfigurationGitUrl <writable-url>
```

O primeiro comando renomeia `pool.intentGitUrl` para `pool.configurationGitUrl`
e preserva o valor da URL. O segundo valida, faz commit e push da migração
quando executado pelo operador; um repositório atualizado permanece intacto.
Atualizar este checkout por si só não migra nenhum grupo em execução.

Novas instalações usam `pool-configuration.git`. Executar novamente
`New-Lab.ps1` ou a inicialização do serviço adota um repositório gerenciado
`pool-intent.git` existente, preservando seu histórico Git. `New-Lab.ps1`
também atualiza os metadados do vault para schemaVersion 2
(`configurationGitPath`), preservando as credenciais. Atualize URLs explícitas
de sistema de arquivos ou `git://` para o caminho adotado; o proxy mantém a
rota HTTP antiga como alias de atualização. URLs personalizadas não são
reescritas automaticamente.

O comando público é `Set-PoolConfiguredState.ps1`; sua rota de API e operação
de retransmissão são `/api/pool/configured-state` e `configured-state`. O daemon
usa `--configuration-git-url` e `POOL_CONTROL_CONFIGURATION_GIT_URL`.
A chave de ambiente antiga é lida apenas como alternativa de atualização,
com precedência para a nova chave. Atualize a unidade do serviço junto com o binário.

<a id="4207d71a-0009"></a>

<a id="step-6----operate-the-pool"></a>

## Etapa 6 -- Opere o grupo

```powershell
pwsh test/pool/Set-PoolConfiguredState.ps1 -PoolId lab -State paused -ConfigurationGitUrl <writable-url>   # run | paused | drain
pwsh test/pool/Remove-HostFromPool.ps1  -PoolId lab -HostId 42<...30 hex...> -ConfigurationGitUrl <writable-url>
```

- **run** -- execute ciclos normalmente.
- **paused** -- conclua o ciclo em andamento e aguarde (verificando novamente a cada ~30 s) até que você o defina
  novamente como `run`.
- **drain** -- pare após o ciclo atual; o processo executor termina. Adicione o hospedeiro novamente e
  reinicie seu executor para voltar ao grupo.
- **Remoção de um hospedeiro em execução:** defina `drain` primeiro, deixe-o parar e depois use `Remove-HostFromPool`.

Os ciclos em andamento sempre terminam, portanto pausa/finalização nunca corrompem uma execução que está acumulando resultados.

<a id="4207d71a-0023"></a>

<a id="handing-over-a-re-keyed-host"></a>

## Transferência de um hospedeiro com identidade renovada

Quando uma máquina recebe uma nova imagem ou um novo clone, ela pode responder com um novo ID de hospedeiro enquanto
o agregador ainda lembra seu ID anterior. Na página `/hosts` do pool-control,
**Hand over** aparece na linha antiga apenas quando o novo ID responde no
mesmo endereço. A ação move a participação no grupo em um único commit no armazenamento de configuração, registra
no agregador um alias persistente da identidade antiga para a nova e remove imediatamente a linha ativa
antiga. Ela informa uma falha se o agregador não conseguir persistir o alias;
tente novamente com o mesmo par após corrigir o erro. Repetir uma transferência concluída é
seguro.

A linha do hospedeiro atual vincula seus IDs anteriores a uma visualização combinada do histórico.
Essa visualização inclui linhas de ciclos, eventos e incidentes de ambos os IDs e exige
uma sessão desbloqueada do pool-control. Os registros do Loki mantêm seu ID de hospedeiro original,
e os caminhos dos ciclos arquivados permanecem no lugar, portanto links diretos antigos continuam funcionando.
Os painéis de logs brutos do Loki no Grafana ainda mostram o ID original de cada registro. A tabela **Pool
hosts** agrupa as contagens históricas de Pass e Fail sob o ID atual para
o intervalo de tempo selecionado, e `/api/v1/pool-stats` faz o mesmo. Use o link do histórico
combinado em `/hosts` para inspecionar ciclos individuais entre ambos os IDs.

O coletor precisa de `-handover-state-file` em armazenamento persistente. A unidade
systemd provisionada fornece `/var/lib/pool-aggregator-service/handovers.json` por meio de
`StateDirectory=pool-aggregator-service`. Um registro de transferências ausente é carregado como vazio; um
registro corrompido ou não suportado impede o agregador de iniciar. Uma
transferência bem-sucedida é persistida antes de ser informada como bem-sucedida, portanto seu
alias sobrevive a uma reinicialização e o ID desativado permanece desativado.

<a id="4207d71a-000a"></a>

<a id="purging-a-stale-host"></a>

## Exclusão completa de um hospedeiro obsoleto

`Remove-HostFromPool` apenas remove um hospedeiro de `members[]` de UM grupo. Um hospedeiro que
executou ciclos também deixa um registro de identidade `hosts/info.<hostId>.yml` e pastas de ciclos
replicadas no NAS e -- separadamente -- continua aparecendo no painel **Yuruna hosts**,
que é a visualização em memória consultada pelo próprio pool-aggregator-service (cada hospedeiro
é mantido durante o TTL de hospedeiro do agregador após o último contato -- 24h por padrão, definido com
`-host-ttl`), *não* os registros do NAS. Para desativar completamente um hospedeiro obsoleto -- uma execução descartável de
`example/nested.host`, uma máquina desativada, um ID que nunca retornará -- use:

```powershell
pwsh test/pool/Remove-PoolHost.ps1 -HostId 42<...30 hex...>          # add -WhatIf to preview
```

Ele (1) lê `networkStorage.poolStorageLocalPath` de `test.config.yml` e exclui
`<poolStorageLocalPath>/hosts/info.<hostId>.yml` + `<poolStorageLocalPath>/hosts/<hostId>/` + o caminho legado `<poolStorageLocalPath>/<hostId>/`; (2) remove
o ID de `members[]` de TODOS os grupos (precisa de `pool.configurationGitUrl`; sem ele, os registros do NAS
ainda são removidos e a alteração da composição é ignorada com um aviso); e (3) pede
ao agregador que **esqueça** o hospedeiro (`POST /api/v1/forget-host`), para que ele saia do
painel AGORA, em vez de após o TTL de hospedeiro. A etapa 3 exige habilitação e faz o melhor esforço: ela
só ocorre quando uma chave de autenticação interna e um caching-proxy-service estão configurados (o mesmo
transporte bearer com CA fixada usado no envio ao grupo), e um token ausente / agregador inacessível
é ignorado silenciosamente -- o painel ainda se limpa sozinho ao vencer o TTL. Um hospedeiro que
ainda está ativo é redescoberto na próxima consulta do agregador, portanto pare-o/deixe-o finalizar o ciclo
antes de esquecê-lo. O comando recusa o UUID deste próprio hospedeiro, ou um registro visto pela última vez há < 24 h,
a menos que `-Force` seja usado. Execute-o em um hospedeiro com o compartilhamento do grupo montado.

<a id="4207d71a-0025"></a>

<a id="a-step-failure-names-the-caching-proxy"></a>

## Uma falha de etapa nomeia o proxy de cache

Uma mensagem do lado do convidado que culpa o proxy de cache -- um pull de imagem
que não alcançou o cache de registro, um download de pacote que expirou no cache
web -- tem duas causas que parecem idênticas de dentro do convidado: o proxy está
indisponível, ou aquele convidado perdeu seu caminho até ele. Compare estas três
verificações ao longo do intervalo da falha; sondagens bem-sucedidas depois
disso podem não revelar uma falha transitória.

1. **O painel Yuruna hosts, linha *Drill-down: caching proxy*.** Ajuste o intervalo
   de tempo em torno do minuto da falha; o painel *Step failures that name the
   caching proxy* dessa linha lista o evento com sua hora UTC. Blocos de liveness e
   de caminho de pull verdes, a linha de todos os outros convidados ainda presente
   nos painéis por cliente, e a linha do convidado com falha ausente, apontam para
   o caminho desse convidado; siga para a verificação 2. Blocos vermelhos, ou todas
   as linhas de clientes terminando ao mesmo tempo, apontam para uma falha de
   serviço compartilhado ou de rede: continue no painel cache-health (o painel da
   própria VM do proxy). O significado de cada bloco e painel está em
   [pool-dashboard](https://yuruna.link/422226cb).
2. **A pasta da falha no hospedeiro, ao lado de `last_failure.json`.** O hospedeiro
   grava ali dois arquivos no momento da falha: `network-cross-check.json`, cujo
   veredito registra o que o próprio hospedeiro ainda alcançava naquele instante, e,
   em hospedeiros Hyper-V, `vm-network.state.txt`, o estado do adaptador de rede e
   do switch virtual do convidado como o hospedeiro os viu. Leia o veredito primeiro:
   um hospedeiro que alcançou o proxy enquanto o adaptador de seu convidado estava desconectado, ou
   ligado a um switch sem uplink, nomeia uma falha do lado do hospedeiro, e o
   arquivo de estado diz qual; um hospedeiro que não alcançou nada nomeia seu
   próprio uplink.
   Para downloads da web, leia também `cacheHttpTcp` e `cacheHttpsTcp`: o registro
   e a página de saúde podem responder enquanto a porta 3128 ou 3129 não responde.
   Essas são observações do lado do hospedeiro no momento da captura; uma conexão
   já restabelecida ou uma falha restrita ao caminho NAT do convidado pode deixar
   todas as sondagens bem-sucedidas.
3. **Os logs do proxy para o endereço do próprio convidado, no minuto da falha.**
   No Grafana Explore contra a fonte de dados Loki, com o intervalo de tempo
   ajustado para aquele minuto e o endereço de laboratório do convidado no lugar do
   exemplo:

   ```
   {job="squid"} |= "192.0.2.57"
   {job="zot"} | json | clientIP=~"192.0.2.57:.*"
   ```

   Linhas de outros clientes e nenhuma deste convidado sustentam a hipótese de
   uma falha antes de o proxy registrar uma solicitação; elas não identificam
   onde uma conexão TCP ficou bloqueada. Linhas deste convidado com resposta
   lenta ou falha mostram que sua solicitação chegou ao proxy e fornecem as
   próximas evidências a examinar.

<a id="4207d71a-000b"></a>

<a id="command-summary"></a>

## Resumo dos comandos

Todos os comandos abaixo ficam em `test/pool/`.

| Comando | Ação | Parâmetros principais |
|---|---|---|
| `New-Pool.ps1` | criar um grupo | `-PoolId` (obrigatório), `-DisplayName`, `-ConfiguredState` |
| `Remove-Pool.ps1` | excluir um grupo (recusa um que ainda tenha membros, a menos que `-Force`) | `-PoolId` (obrigatório), `-Force` |
| `Add-HostToPool.ps1` | adicionar um hospedeiro | `-PoolId` (obrigatório), `-HostId` (obrigatório) |
| `Remove-HostFromPool.ps1` | remover um hospedeiro dos membros de UM grupo | `-PoolId` (obrigatório), `-HostId` (obrigatório) |
| `Move-PoolHostIdentity.ps1` | substituir o ID de um hospedeiro com identidade renovada em um único commit no armazenamento de configuração | `-OldHostId` (obrigatório), `-NewHostId` (obrigatório) |
| `Remove-PoolHost.ps1` | **excluir completamente** um hospedeiro obsoleto: excluir seus registros do NAS e remover TODAS as participações | `-HostId` (obrigatório), `-Force`, `-ConfigPath` |
| `Set-PoolRepository.ps1` | definir as URLs de framework e projeto do grupo (substitui as existentes), ou removê-las | `-PoolId` (obrigatório), depois `-FrameworkUrl` + `-ProjectUrl` (obrigatórios juntos) ou `-Clear` |
| `Set-PoolConfiguredState.ps1` | executar / pausar / finalizar o ciclo | `-PoolId` (obrigatório), `-State` (obrigatório) |
| `Get-PoolStatus.ps1` | ler os membros e os repositórios do grupo (configuração) | `-PoolId` |
| `Get-PoolConfiguration.ps1` | exibir o armazenamento de configuração inteiro como JSON (o que o painel lê) | -- |
| `Test-PoolConfiguration.ps1` | validar os arquivos de configuração | -- |
| `Update-PoolConfigurationSchema.ps1` | migrar `pools.yml` para `schemaVersion: 4` uma vez (uma nova execução não altera nada) | -- |
| `Convert-ToPoolWorker.ps1` | transformar uma máquina independente em um trabalhador de um laboratório existente | `-ReferenceHost` (obrigatório), `-InternalAuthKey`, `-KeepCachingProxy` |

Todos os comandos que fazem alterações aceitam `-WhatIf` (prévia) e `-Confirm`, validam contra os
esquemas **antes** de gravar e fazem `git commit` + `push` por você. Quando omitido, `-ConfigurationGitUrl` usa
`pool.configurationGitUrl` de `test.config.yml`. Um push malsucedido **faz o comando falhar**
(saída diferente de zero): uma alteração com commit local, mas sem push, não é persistente, e um comando de administração
posterior a descarta -- recupere executando novamente a partir de um local gravável (no proxy: um `file://`
ou caminho local para o repositório bare), ou exclua a pasta do clone de administração para descartar a alteração local e
clonar novamente do remoto. Todos os comandos têm ajuda completa: por exemplo, `Get-Help test/pool/Set-PoolRepository.ps1 -Full`.
<a id="4207d71a-000c"></a>

## Pool-control service

O Pool-control service é a interface do operador e a API para a configuração dos grupos na LAN. Ele
controla o armazenamento Git da configuração dos grupos; os executores apenas
BUSCAM esse armazenamento em modo somente leitura. Todos os botões usam as CLIs de administração acima,
portanto a interface e a linha de comando não podem divergir.

<a id="4207d71a-000d"></a>

<a id="what-it-does"></a>

### O que ele faz

- **Board** (`/`) &mdash; um cartão por grupo para o período escolhido (1h, 24h, 7d
  ou 30d): quantos hospedeiros apresentam relatórios, a taxa de sucesso, as contagens de ciclos e
  falhas e o projeto executado &mdash; sua Project URL, ou *os
  projetos dos próprios hospedeiros* quando os membros executam os seus. O cartão também sinaliza hospedeiros
  que não conseguem ler o projeto do grupo (abaixo). O painel não altera nada.
- **Pools** (`/pools`) &mdash; criar um grupo (gera seu `poolGuid` estável), controlar
  o **Pool Status** de todos os membros (abaixo), definir os repositórios **Framework / Project**
  do grupo (abaixo), adicionar/remover hospedeiros (um hospedeiro
  pertence a, no máximo, um grupo), excluir um grupo vazio.
- **Hosts** (`/hosts`) &mdash; todos os hospedeiros conhecidos pelo agregador *e* todos os que
  a varredura de rede encontrou, não apenas os membros de grupos, portanto um hospedeiro que nunca foi
  inscrito automaticamente &mdash; ou nunca foi cadastrado &mdash; fica visível junto com
  o motivo. Colunas: **Host ID** (link para a página de status desse hospedeiro),
  **Hostname**, **Type** (o tipo de hospedeiro sem seu prefixo `host.`, por exemplo,
  `ubuntu.kvm`), **Memory**, **Cores**, **Total Storage** e **Free Storage**
  (o relatório de hardware do próprio hospedeiro, lido de seu status service),
  **Control** (o valor transmitido: `ready` / `none` / `mismatch` /
  `skew`), **Framework** e **Project** (abaixo), e o
  seletor **Pool**, que *move* o hospedeiro.
  O armazenamento é o que a máquina mantém: cada grupo de espaço conta uma vez &mdash; os
  volumes de um contêiner APFS são um único grupo de 2 TB, não cinco &mdash; e
  o armazenamento conectado (uma unidade USB ou Thunderbolt, um cartão, uma imagem montada, um
  compartilhamento de rede) fica de fora, pois não se pode planejar com base nele e um compartilhamento
  seria contado uma vez por hospedeiro que o monta.
  **Hostname** é a única coluna omitida em uma leitura sem credencial &mdash;
  a visualização que o grupo mantém de um hospedeiro não contém o nome da máquina de propósito, e esta página
  também é exibida sem supervisão, portanto o nome só chega depois que o navegador é
  desbloqueado (abaixo). **Show hostnames** solicita o token do laboratório; chegar pelo
  link do painel desbloqueia a página automaticamente.
- **Scan** (`/scan`) &mdash; varrer uma rede em busca de hospedeiros Yuruna e adicionar os que
  respondem à lista monitorada, sejam membros de grupos ou não (abaixo).
- **Diagnostics** (`/diagnostics`) &mdash; todas as dependências acessadas por uma requisição da interface,
  verificadas na ordem em que a requisição as acessa; uma verificação que falha indica o que
  corrigir no convidado.

Hosts e Pools podem ser ordenados por qualquer cabeçalho de coluna &mdash; clicar no que já está ordenado
inverte a ordem, e as colunas que contêm um controle são ordenadas pelo valor que
esse controle representa (**Framework / Project** pelas URLs salvas, não pelo texto digitado
que ainda não foi salvo; **Members** pela quantidade de membros). A ordem sobrevive à
releitura feita pela própria página a cada minuto, portanto uma tabela deixada ordenada continua assim. Cada
uma dessas tabelas começa com uma coluna contadora que numera as linhas *como exibidas*: ela
mostra 1&hellip;n pela página, qualquer que seja a ordenação, indicando quantos grupos ou
hospedeiros existem.

Salvar **Framework / Project** de um grupo executa o mesmo `Set-PoolRepository.ps1`
da Etapa 4, portanto os membros se comportam exatamente como no caminho da CLI das Etapas 3-4 acima.

<a id="4207d71a-000e"></a>

<a id="framework-and-project----which-repositories-is-each-host-on"></a>

### Framework e Project -- quais repositórios cada hospedeiro usa?

As duas colunas de repositório em `/hosts` são o relato do próprio hospedeiro sobre o que ele
executa: o checkout do **framework** a partir do qual seu status service é executado e o
clone do **projeto** ao lado dele. Cada célula informa o nome do repositório -- o último segmento
de `remote.origin.url` desse clone, portanto `https://github.com/alius-git/amisad.dev`
é exibido como `amisad.dev` --, o que torna a tabela um inventário de todo o laboratório: uma olhada mostra
quais máquinas usam `yuruna`, quais usam uma bifurcação dele e qual projeto cada uma
está testando.

Cada célula também contém um **link** para esse repositório, portanto um nome diferente do
esperado leva ao próprio repositório com um clique, em vez de exigir que se digite uma URL novamente.
O link é o `remote.origin.url` do próprio hospedeiro, seja qual for seu destino: um
remoto SSH (`git@github.com:owner/repo.git`) abre em seu equivalente `https://`, e
um hospedeiro que executa a partir de uma **cópia local** tem um link para esse caminho como URL `file:` -- a maioria dos
navegadores não segue esse tipo de link em uma página servida, mas ele ainda identifica o local
e pode ser copiado. Uma credencial incluída em um remoto é removida no hospedeiro, antes que
a URL seja servida. Uma célula cujo hospedeiro não informou nenhuma URL permanece como texto simples.

| Valor | Significado | O que fazer |
| --- | --- | --- |
| nome de repositório | o clone mantido por este hospedeiro, nomeado por seu próprio `remote.origin.url`, com um link para ele | nada |
| **`No access`** | o hospedeiro foi configurado com um repositório que não consegue ler -- uma credencial sem acesso ou uma URL que não respondeu. O link aponta para a URL que falhou | conceda ao `GH_TOKEN` desse hospedeiro acesso ao repositório, ou corrija a URL em seu `test.config.yml` |
| `--` | o hospedeiro não tem esse clone *nem* um configurado (o projeto fica dentro da árvore), ou ainda não respondeu | nada |

O clone responde antes da rede: ele é o que a máquina realmente
acompanha -- nem sempre a URL configurada, pois os repositórios de um grupo
a substituem durante um ciclo -- e não custa uma viagem de ida e volta. Apenas um hospedeiro sem
clone legível consulta a URL com a qual foi configurado, distinguindo
"não consegue lê-lo" de "ainda não o clonou"; essa consulta ocorre *depois* de
a resposta ser enviada, portanto nunca faz as outras colunas do hospedeiro excederem seu prazo junto com ela,
e esse hospedeiro mostra `--` durante uma atualização antes que sua resposta chegue. Assim como as
colunas de hardware, essas informações são lidas ao carregar a página e em **Refresh**, não na
contagem regressiva do rodapé.

<a id="4207d71a-000f"></a>

<a id="project-access----can-each-host-read-what-its-pool-assigned"></a>

### Acesso ao projeto -- cada hospedeiro consegue ler o que seu grupo atribuiu?

Um grupo pode atribuir a um hospedeiro um `projectUrl` que sua credencial Git não consegue ler:
a atribuição é central, a credencial é local ao hospedeiro, e `GH_TOKEN`
deliberadamente nunca passa pela configuração do grupo. Portanto, cada hospedeiro também executa um
`git ls-remote` sobre uma URL **atribuída pelo grupo** no início de um ciclo, *antes*
do clone -- o problema é identificado no hospedeiro que o tem, em vez de aparecer
minutos depois como um erro genérico de inicialização. Apenas uma URL atribuída pelo grupo é consultada
dessa forma; o `projectUrl` do próprio hospedeiro já é verificado previamente pelo clone, e
consultá-lo duas vezes custaria uma viagem de ida e volta a todo hospedeiro fora de um grupo, sem benefício.

Essa resposta acompanha o registro de cadastro do hospedeiro e responde a uma pergunta
diferente daquelas colunas -- *o que o grupo mandou este hospedeiro ler*, não
*o que o hospedeiro mantém*. Ela aparece no sinalizador de atenção do grupo no painel
e como uma dica na célula **Project** do hospedeiro.

| Valor | Significado | O que fazer |
| --- | --- | --- |
| `ok` | a consulta leu o projeto atribuído | nada |
| `denied` | a credencial Git deste hospedeiro não consegue ler o projeto atribuído -- um repositório privado ou um token sem acesso a ele | conceda ao `GH_TOKEN` desse hospedeiro acesso ao repositório, **ou** defina a Project URL do grupo com um projeto que todos os membros consigam ler |
| `unreachable` | o repositório não respondeu -- rede ou DNS, não permissão | nada; é transitório, e o clone do ciclo tenta novamente com a espera progressiva normal |
| ausente | nenhuma consulta foi executada: o hospedeiro não está em um grupo, seu grupo não contém repositórios, o hospedeiro não respondeu ou o agregador está indisponível | nada |

`denied` **faz o ciclo desse hospedeiro falhar**, e ele *não* retorna ao seu
próprio projeto: um ciclo aprovado executando algo que o grupo nunca atribuiu informaria
incorretamente a cobertura do grupo. Ele recebe a classificação `project_access_denied`, que
encaminha o caso para intervenção do operador, em vez de consumir tentativas de correção automática
em um problema que nenhuma repetição resolve -- portanto, todos os membros de um grupo com uma atribuição inválida
passam a indicar falha até que alguém aja, dando ao problema a visibilidade pretendida. O painel identifica os
mesmos hospedeiros em um sinalizador de atenção do grupo, que é informativo e não altera
nenhum estado.

Uma ressalva de tempo: o hospedeiro publica `host.registration.json` antes que os
repositórios do grupo substituam os seus, portanto essa resposta descreve a visão do ciclo *anterior*.
Logo após mudar os repositórios de um grupo, espere um ciclo em que a informação
ainda não esteja atualizada.

<a id="4207d71a-0010"></a>

<a id="pool-status--pausing-and-continuing-every-member-at-once"></a>

### Pool Status — pausa e continuação de todos os membros de uma vez

A coluna **Pool Status** em `/pools` controla, de um só lugar, os botões Pause/Continue da
página de status de cada membro. Ela oferece exatamente o que um único
hospedeiro oferece:

| Opção | O que cada membro faz |
| --- | --- |
| **Continue** | continua o que estava fazendo (ambos os sinalizadores de pausa são desativados) |
| **Pause after cycle** | conclui o ciclo em andamento e aguarda |
| **Pause after step** | conclui a etapa em andamento e aguarda |

Um hospedeiro tem dois sinalizadores independentes de pausa, e escolher uma das três opções aqui
deixa **no máximo um** deles ativado em cada membro &mdash; portanto a coluna sempre
identifica algo que um hospedeiro realmente está fazendo. A célula mostra o que os membros informam
neste momento: uma das três opções quando todos concordam, **Mixed** quando divergem ou um
membro não respondeu (os hospedeiros divergentes são listados abaixo do
seletor), `--` quando nenhum respondeu. Os hospedeiros continuam podendo ser controlados individualmente por
suas próprias páginas de status; esta ação altera todos e depois lê o estado deles novamente.

Isso **não** é o `configuredState` do grupo (`run`/`paused`/`drain`): esse
é uma configuração persistente no Git, aplicada em um limite de
ciclo, e `drain` encerra o processo executor. Pool Status atua nos sinalizadores de pausa
ativos &mdash; o significado de "pare o laboratório agora e depois deixe-o continuar"
no meio do ciclo. `configuredState` não tem página própria; grave-o com
`Set-PoolConfiguredState.ps1` (tabela acima).

Controlar as rotas de controle de outro hospedeiro exige uma **prova de controle** (veja
[control-routes.md](../control-routes.md)), que o serviço obtém de uma das duas
formas, nesta ordem:

1. a chave de autenticação interna de `--auth-token-file`
   (padrão `/etc/yuruna/internal-auth.key`), se presente &mdash; sem viagem de ida e volta; ou
2. o redirecionamento `/go/host` do agregador do grupo, a mesma prova que um navegador
   recebe de um link de hospedeiro no painel.

Nada incorpora esse arquivo de token a uma VM de serviço, portanto o caminho 2 é o que normalmente
atende a essa necessidade. Quando nenhum está disponível, a alteração é recusada **uma vez**, indicando
o arquivo, em vez de acumular um `403` por hospedeiro.

A própria prova de controle é um HMAC baseado na chave de autenticação
interna compartilhada, enviado no cabeçalho `X-Yuruna-Control` -- veja
[control-routes.md](../control-routes.md#where-the-proof-comes-from) para conhecer todo o
mecanismo. Três implementações independentes (o agregador do grupo, o verificador PowerShell do próprio hospedeiro
de destino e o cliente Go deste serviço) precisam derivar esse
HMAC de forma idêntica, byte a byte, como garante um vetor de teste de referência
compartilhado.

Os membros são controlados individualmente e os resultados são informados individualmente: `2 applied, 1 failed
-- 42ab12cd (the host holds no lab token ...)`. Um hospedeiro que nunca foi inscrito,
está desligado ou possui outro token do laboratório falha por conta própria, sem impedir a alteração
dos demais. Cada ação distribuída é gravada no log de auditoria, com a quantidade de alterações
que foram aplicadas.

<a id="4207d71a-0024"></a>

<a id="framework--project----which-repositories-each-pool-runs"></a>

### Framework / Project -- quais repositórios cada grupo executa

A coluna **Framework / Project** em `/pools`, logo após **Pool Status**, é
onde se definem os repositórios do framework e do projeto de um grupo. Salvar executa o
mesmo `Set-PoolRepository.ps1` da [Etapa 4](#4207d71a-0007), portanto cada membro recebe
a alteração no início de seu próximo ciclo, sem reinicialização. Um grupo novo
começa com ambas as caixas vazias: crie-o primeiro e depois preencha sua linha.

Cada célula contém duas caixas de texto empilhadas sem rótulos visíveis, cada uma com a largura
da coluna: **Framework URL** em cima e **Project URL** abaixo. Uma
caixa vazia mostra seu nome como texto de exemplo, e um leitor de tela anuncia
a qual grupo cada caixa pertence. Uma URL maior que sua caixa rola horizontalmente conforme
o cursor se move (teclas de seta, Home e End, ou uma seleção); a caixa nunca mostra
uma barra de rolagem.

- **Salvar.** O botão **Save** da linha, na coluna Actions, fica habilitado
  enquanto qualquer caixa diferir do que o grupo contém. **Save**, ou Enter em
  qualquer caixa, grava a alteração; a primeira alteração da sessão solicita o
  token do laboratório ([Desbloqueio das ações](#4207d71a-0012)).
- **Ambas ou nenhuma.** Preencha ambas as caixas para definir os repositórios do grupo; esvazie
  ambas para removê-los, de modo que cada membro retorne aos seus próprios repositórios
  configurados. Com apenas uma caixa preenchida, a página informa isso e não envia nada.
- **Confirmação.** Quando o grupo tem membros, a página pergunta primeiro, indicando quantos
  hospedeiros mudarão para o novo projeto -- ou, ao limpar, retornarão aos
  seus próprios projetos.
- **Texto não salvo.** O que você digita sobrevive à releitura feita pela página a cada minuto
  até ser salvo, e a ordenação da coluna usa as URLs salvas, não o texto
  das caixas.
- **O grupo de destino da inscrição automática.** Suas caixas ficam desabilitadas, com a observação
  de que os hospedeiros chegam ali automaticamente e continuam executando seu próprio projeto
  ([Inscrição automática](#4207d71a-0014)). Se, ainda assim, o armazenamento contiver
  repositórios para ele, as caixas os mostram, continuam desabilitadas e **Clear**
  substitui **Save**.
- **Verificações.** Espaços nas extremidades de ambas as URLs são removidos, e uma que contenha espaços em branco ou um
  caractere de controle, ou comece com `-`, é recusada. Nada consulta as URLs
  quando são salvas: uma incorreta só aparece quando o próximo ciclo de um membro
  tenta clonar, ou no painel quando a credencial de um membro não consegue ler o
  projeto ([Acesso ao projeto](#4207d71a-000f)).

Esta coluna indica o que o grupo manda seus membros executarem. As colunas **Framework** e
**Project** em `/hosts` ([Framework e Project](#4207d71a-000e)) indicam
o que cada hospedeiro mantém.

A automação faz a mesma alteração com `POST /api/pool/repositories` e o
corpo `{"poolId": "...", "frameworkUrl": "...", "projectUrl": "..."}` -- ambas
as URLs vazias as removem -- ou com a ferramenta MCP
`pool_control_set_pool_repositories`, que também remove quando ambas as URLs são
omitidas. Ambas as opções recebem a credencial de gravação descrita em
[Desbloqueio das ações](#4207d71a-0012).

<a id="4207d71a-0011"></a>

<a id="architecture"></a>

### Arquitetura

Um pequeno daemon Go (`test/extension/pool-control-service/server`, módulo `pool-control-service`) que:

- Serve as páginas estáticas incorporadas e uma API JSON. CSP restrita nas páginas; DOM protegido contra XSS.
  A superfície completa, dividida pela barreira de autorização de cada rota:

  | Autenticação | Rotas |
  |---|---|
  | aberta (GET) | `/healthz`, `/api/hostinfo`, `/api/session`, `/api/board`, `/api/hosts`, `/api/hosts/facts`, `/api/state`, `/api/scan`, `/api/diagnostics`, `/api/pool/host-control` |
  | aberta (POST) | `/api/login`, `/api/unlock-proof` -- as duas formas de ENTRAR na barreira |
  | lab-token | `/api/pool` (POST, DELETE), `/api/pool/configured-state`, `/api/pool/host`  (POST, DELETE), `/api/pool/move-host`, `/api/pool/adopt-rekey`, `/api/pool/repositories`, `/api/pool/host-control`, `/api/scan`, `/api/scan/forget`, `/api/hosts/history` (GET) |
  | lab-token **e** credencial de atualização | `/api/host/refresh` (POST) -- veja [Atualização remota do hospedeiro](#remote-host-refresh) |

  As leituras são abertas na LAN confiável, para que uma tela de parede não precise de credencial;
  tudo que reescreve a configuração dos grupos passa por `gate.Require`.
- **Lê `GET /api/v1/pool-stats` do agregador** para obter os números dos
  cartões do painel: contagens de ciclos concluídos por **hospedeiro** em um intervalo predefinido.
  Por hospedeiro, e não por grupo, porque essa rota retorna apenas o que o Loki consegue
  responder, e a composição do grupo fica no armazenamento de configuração que o agregador nunca
  leu -- sua única noção de grupo é o `poolId` que um hospedeiro anuncia sobre si. O
  serviço de controle faz essa junção porque já lê `members[]`. Essa
  divisão permite que o painel mostre um cartão para um grupo cujos hospedeiros estão todos
  silenciosos (`0` apresentando relatórios), em vez de o grupo desaparecer porque nenhum fluxo do Loki
  o mencionou. Somente leitura e aberto, como `pool-status`.
- **Executa as CLIs PowerShell de administração de grupos** em `test/pool/` (`Get-PoolConfiguration.ps1`,
  `New-Pool.ps1`, `Remove-Pool.ps1`, `Set-PoolConfiguredState.ps1`,
  `Add-HostToPool.ps1`, `Remove-HostFromPool.ps1`, `Move-PoolHostIdentity.ps1`,
  `Set-PoolRepository.ps1`), em vez de reimplementar
  Git + YAML + validação de esquema + commit/push em Go &mdash; uma única implementação
  oficial. Um push malsucedido aparece na interface como erro.
- **Controla as rotas de controle dos próprios membros** para Pool Status
  (`/api/pool/host-control`): a única parte daqui que atua em outras máquinas,
  em vez de no armazenamento de configuração. A composição vem da configuração e os endereços
  vêm do agregador, pois a noção de grupo do agregador é um rótulo que um
  hospedeiro anuncia sobre si &mdash; ele não consegue dizer quem pertence ao grupo.
- **Anuncia a si mesmo** ao pool-aggregator service (beacon, área `pool-control-service`) e, por meio
  do marcador `runtime/pool-control-service.json` e de `host.registration.json`, aparece na
  tabela Extension hosts (exibido como "Pool-control service"). Qualquer um dos caminhos sozinho exibe a linha.
- Persiste um **log de auditoria** (`audit.jsonl`) e **status.json** (última gravação,
  resultado da última publicação, sinal de vida, legibilidade da configuração, saúde) em
  `poolStorageNetworkPath/pool-control-service/` (o NAS do grupo), sobrevivendo a reinicializações. `/healthz`
  serve esse status. Um laço de monitoramento consulta a configuração a cada `--monitor-interval`.

O próprio `default.psm1` da área é sua presença no hospedeiro: ele torna a área
visível para `Get-ExtensionAreaName`, dá a ela uma entrada na matriz de capacidades e
fornece a verificação prévia de acessibilidade que um chamador precisa antes de usar
um endereço resolvido do painel. `Get-PoolControlServiceInfo` retorna a mesma tabela hash uniforme de
status usada pelo vocabulário de cmdlets no hospedeiro de cada área de extensão,
atualmente uma implementação provisória cujos sinalizadores permanecem `$false` até que a verificação de status no hospedeiro
contra uma VM ativa do painel seja conectada. `Test-PoolControlServiceHost` é a
verificação prévia de acessibilidade, com o mesmo contrato de `Test-DownloadAgentServiceHost` e
da verificação prévia do stash.

O **pool-aggregator service**, do qual ele lê `/api/v1/pool-stats` e ao qual
se anuncia, é um daemon separado, somente para leitura, na máquina do caching-proxy-service.
Ele não precisa de uma lista de hospedeiros configurada: descobre automaticamente os membros de grupos pelo
log de acesso do Squid, identifica cada um por seu `hostId` estável
(`runtime/host.uuid`, independente de DHCP e DNS), em vez de seu endereço, e
envia transições de ciclos e eventos por etapa ao Loki e ao Prometheus para o
painel de grupos do Grafana. Ser somente para leitura e poder ser encerrado sem afetar nenhum
executor é deliberado -- nada no agendamento ou na execução de um ciclo de teste
depende de ele estar ativo. Projeto completo:
[o README do próprio agregador](../../test/extension/pool-aggregator-service/README.md).

**Por que cada serviço de extensão se anuncia (beacons) independentemente do
hospedeiro.** O status service do próprio hospedeiro também informa esse serviço em seu
registro de cadastro, mas o painel lê esse registro *por meio* do status service
do hospedeiro -- portanto, assim que esse processo está inativo, algo que uma reinicialização de hospedeiro
costuma deixar para trás, a linha Extension hosts desaparece mesmo que o
próprio serviço ainda esteja ativo e atendendo. O beacon (`POST /announce`, uma saudação
repetida na inicialização, um novo anúncio a cada intervalo e uma despedida de melhor esforço no
desligamento) cobre esse período; por isso ele precisa continuar funcionando
quando nada mais no hospedeiro funciona.

<a id="4207d71a-0012"></a>

<a id="unlocking-the-actions"></a>

### Desbloqueio das ações

Tudo que este serviço altera **é** configuração de grupos &mdash; quais grupos
existem, quais hospedeiros pertencem a eles e quais repositórios de framework e projeto
cada um executa &mdash; portanto toda
rota que faz alterações usa a barreira de gravação que
[docs/extensions-api.md](../extensions-api.md#the-lab-token-rule) aplica a todos os
serviços de extensão:

- **Em um navegador**, a primeira alteração que você tenta fazer solicita o **token do laboratório**
  rotativo de 6 caracteres que o painel Yuruna hosts mostra em seu próprio cartão.
  Informá-lo troca o código por um cookie de sessão (7 dias, HttpOnly,
  SameSite=Lax para que o link direto do painel o mantenha) e reenvia a alteração que
  você estava fazendo. Não há nada para configurar: o daemon já conhece o
  agregador, e o agregador é responsável pelos códigos.
- **Na automação**, envie a chave de autenticação interna como
  `Authorization: Bearer ...`. O daemon a lê de `--auth-token-file`
  (padrão `/etc/yuruna/internal-auth.key`, ausente por padrão). Nada incorpora esse
  arquivo à imagem inicial da VM, portanto o bearer exige habilitação: coloque o token nesse local
  por conta própria em uma VM de serviço controlada pela automação.

**As leituras são abertas**, como o `pool-status` do próprio agregador e todos os outros
serviços de extensão: o painel é exibido em uma tela de parede sem credencial, e
nada do que ele mostra é um segredo que a LAN já não possa ler do grupo.

Essa barreira deliberadamente **não é autenticação por usuário.** Ela bloqueia uma pessoa desconhecida na LAN
e uma visita acidental; não informa *quem* atribuiu algo, motivo
pelo qual cada alteração ainda é registrada no log de auditoria com o endereço que
a fez -- o mesmo raciocínio da [regra do token do
laboratório](../extensions-api.md#the-lab-token-rule) em outros lugares. Se algum dia for necessária
rastreabilidade por operador, esta é a parte a substituir.

Um agregador inativo impede o desbloqueio do painel &mdash; uma
falha segura deliberada, informada como `503` com o motivo `lab-token-unavailable`,
em vez de como código incorreto, para que um operador não digite novamente um código correto até
desistir.

<a id="4207d71a-001f"></a>

<a id="remote-host-refresh"></a>

### Atualização remota do hospedeiro

Um hospedeiro cujo hipervisor ou executor de testes travou pode receber daqui uma solicitação para reparar
a si mesmo, um hospedeiro de cada vez: recuperar um executor parado por travamento, iniciar um serviço de
hipervisor interrompido ou reiniciar um travado, quando o hospedeiro permitir -- o
nível **restart** da própria escala de atualização do hospedeiro, nunca alterações de pacotes ou
configurações. É o mesmo reparo que `test/lab/Invoke-HostRefresh.ps1` executa no
hospedeiro; este serviço apenas autoriza e entrega a solicitação. O controle de todo o grupo
(`/api/pool/host-control` e sua ferramenta MCP) nunca executa uma atualização: recusa a
ação antes que qualquer chamada saia deste serviço.

A atualização remota fica **desabilitada até ser provisionada** e permanece desabilitada para um hospedeiro, a menos que
todas estas condições sejam atendidas:

- este serviço contém ambos os segredos de atualização (abaixo);
- o hospedeiro instalou sua própria chave de verificação;
- o hospedeiro executa em uma plataforma qualificada para atualização remota -- atualmente,
  apenas Ubuntu KVM; hospedeiros macOS e Windows informam `unqualified`;
- o status service do hospedeiro anuncia a atualização como disponível, e o agregador
  do grupo leu esse anúncio recentemente (o objeto `refresh` do hospedeiro na
  página Hosts e em `/api/hosts`).

<a id="4207d71a-0020"></a>

<a id="the-three-secrets"></a>

#### Os três segredos

A atualização remota usa segredos próprios. O token do laboratório, um cookie de sessão do laboratório e
a chave de autenticação interna nunca a autorizam: a chave do laboratório pode ser obtida
pelo código de inscrição do painel, e uma sessão do laboratório, por uma prova de controle
pública.

| Segredo | Formato | Onde fica |
|---|---|---|
| Autoridade de assinatura | uma linha `yhra1.<key>` | a máquina do operador e `/etc/yuruna/host-refresh/authority.key` deste serviço (`-refresh-authority-file`) |
| Credencial do operador | uma linha `yhrc1.<key>` | o operador ou a automação e `/etc/yuruna/host-refresh/operator.credential` deste serviço (`-refresh-credential-file`) |
| Chave de verificação do hospedeiro | uma linha `yhrk1.<hostId>.<key>` | `$HOME/.yuruna/host-refresh/remote-verifier.key` de cada hospedeiro |

Cada arquivo deve poder ser lido apenas por seu proprietário (`chmod 600`); um arquivo
ausente, malformado ou legível por outras pessoas desabilita a atualização remota com uma linha de log
que informa o nome do arquivo, nunca seu conteúdo. O serviço também recusa uma
autoridade ou credencial igual à chave de autenticação interna e uma
credencial igual à autoridade. Cada chave de hospedeiro é derivada da autoridade
apenas para aquele hospedeiro, portanto um hospedeiro comprometido pode verificar solicitações para si, mas
não pode assinar nada para outro hospedeiro.

<a id="4207d71a-0021"></a>

<a id="provisioning"></a>

#### Provisionamento

`test/lab/Set-HostRefreshCredential.ps1` cria e move os segredos e
não solicita nenhuma entrada. As etiquetas em sua saída são nomes sem segredos que você pode comparar;
os próprios segredos nunca chegam à saída.

```powershell
# 1. On the operator's machine: create the authority and the credential.
pwsh test/lab/Set-HostRefreshCredential.ps1 -NewAuthority
# Copy authority.key and operator.credential from the printed directory to the
# pool-control VM's /etc/yuruna/host-refresh/, owner-only, then restart the service.

# 2. Still on the operator's machine: write one host's key.
pwsh test/lab/Set-HostRefreshCredential.ps1 -ExportHostKey -HostId <hostId> -OutputPath ./<hostId>.key

# 3. On that host, after moving the file there privately: install it, then delete the file.
pwsh test/lab/Set-HostRefreshCredential.ps1 -InstallHostKey -KeyPath ./<hostId>.key

# Status of this host's key and of the local authority; withdraw a host.
pwsh test/lab/Set-HostRefreshCredential.ps1
pwsh test/lab/Set-HostRefreshCredential.ps1 -RemoveHostKey
```

Um hospedeiro que também é a máquina da autoridade pode dispensar o transporte:
`-InstallHostKey -AuthorityDirectory <dir>`. `-NewAuthority -Rotate` substitui
a autoridade e a credencial; todas as chaves de hospedeiros derivadas da autoridade antiga
deixam de verificar, portanto exporte e instale novamente a chave de cada hospedeiro. Se uma rotação
informar que gravou `authority.key`, mas não `operator.credential`, execute
`-NewAuthority -Rotate` novamente. Cada ação aceita `-WhatIf`, que mostra uma prévia
sem criar nada, mesmo em um hospedeiro que ainda não tenha um diretório de estado
privado.

<a id="4207d71a-0022"></a>

<a id="asking-a-host-to-refresh"></a>

#### Solicitação de atualização a um hospedeiro

```bash
curl -s -X POST http://<pool-control>/api/host/refresh \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $(cat internal-auth.key)" \
  -H "X-Yuruna-Refresh-Credential: $(cat operator.credential)" \
  -d '{"hostId":"<hostId>","requestId":"<uuid>","tier":"restart","maxRung":"start-if-stopped"}'
```

A solicitação precisa da credencial comum de gravação **e** da credencial de atualização
em seu próprio cabeçalho. O corpo contém exatamente `hostId`, `requestId` (um UUID em minúsculas
que o chamador gera uma vez e reutiliza em cada nova tentativa), `tier` (`restart`) e,
opcionalmente, `maxRung` (`probe`, `reclaim`, `start-if-stopped`,
`restart-if-hung` ou `restart-broker`, padrão `restart-broker`; o hospedeiro
o reduz ao que consegue executar). Qualquer outra chave -- incluindo todas as grafias de force ou
hard-stop -- é recusada.

Este serviço verifica a capacidade anunciada pelo hospedeiro, obtém sua
prova comum de controle, assina uma prova de atualização vinculada àquele hospedeiro, ID de solicitação,
nível e limite máximo, que expira em dois minutos, e envia ambas ao
`/control/host-refresh` do hospedeiro. Uma falha de transporte provoca um reenvio, uma vez, da mesma
solicitação. Respostas:

| Status | Significado |
|---|---|
| 202 | aceita: `action` é `spawned` ou `already_claimed`; consulte `stateUrl` periodicamente |
| 200 | este ID de solicitação já foi concluído: `replay`, `verdict`, `state` |
| 400 / 413 | o corpo foi recusado (`code` informa o motivo) |
| 401 / 429 / 503 | uma credencial está ausente ou incorreta, a origem está limitada, ou a atualização remota não está provisionada (`reason` é `refresh_credential_required`, `refresh_auth_throttled` ou `refresh_auth_unconfigured`; uma autoridade ausente é `pool.host_refresh_signing_unconfigured`) |
| 404 / 409 | o hospedeiro é desconhecido, não tem endereço, não anuncia atualização remota (`hostReason`), está ocupado com `activeRequestId`, ou já usou este ID de solicitação de outro modo ou até a conclusão |
| 502 | o hospedeiro recusou (`hostStatus`, `hostReason`, por exemplo, `refresh_proof_expired` quando os relógios diferem em mais de um minuto) ou respondeu de forma inutilizável |
| 503 / 504 | o hospedeiro não conseguiu iniciar ou não respondeu; `retryable` é verdadeiro -- tente novamente com o mesmo ID de solicitação |

A ferramenta MCP `pool_control_refresh_host` recebe os mesmos quatro argumentos e só é
listada enquanto ambos os segredos estão provisionados. Ela usa exatamente a mesma barreira de autorização da
rota: a solicitação MCP precisa da credencial comum de gravação e do
cabeçalho `X-Yuruna-Refresh-Credential`, portanto um cliente que só pode enviar
`Authorization` não consegue usá-la.

Cada solicitação é gravada no log de auditoria como ação `host-refresh`, com o
hospedeiro, ID de solicitação, nível, limite máximo, resultado e status e motivo do hospedeiro --
nunca uma credencial, chave ou prova --, e cada credencial recusada é gravada como
`refresh-credential`, com seu endereço de origem.

O Pool-control serve HTTP sem criptografia, portanto a credencial e as provas atravessam a LAN
em texto simples, como as outras credenciais do laboratório. Uma prova está vinculada a um hospedeiro
e uma solicitação e expira em dois minutos, e reenviá-la apenas repete a
mesma solicitação; a credencial permanece válida até que você a rotacione.

<a id="4207d71a-0013"></a>

<a id="running-it"></a>

### Execução

**Padrão &mdash; em sua própria VM:**

```powershell
pwsh test/service/Start-PoolControlServiceVM.ps1 [-VMName yuruna-pool-control-service]
# stop (and tear down the VM) with test/service/Stop-PoolControlServiceVM.ps1
```

Como Start-CachingProxyServiceVM / Start-StashServiceVM, isso inicia o serviço em uma
VM dedicada. `host/vmconfig/pool-control-service.base.user-data` prepara um convidado Ubuntu
que compila o daemon, instala pwsh + `powershell-yaml`, monta o NAS do grupo por CIFS
para o diretório de estado e o executa com systemd (`guest/ubuntu.server.26/ubuntu.server.26.pool-control-service.sh`).
O `guest.pool-control-service/New-VM.ps1` específico de cada hipervisor (seguindo a cadeia da VM do stash-service)
gera a imagem inicial com `/etc/yuruna/{globalization.env,pool.env,host.env,pool-nas.cifs.cred}` e um
nome de usuário distinto para o convidado. **O hospedeiro não precisa da cadeia de ferramentas `go`.** A
linha Extension-hosts então aponta para a VM (IP próprio do beacon); excluir a VM
remove a linha depois do TTL do anúncio.

Depois que a VM inicia, o lançador espera que o daemon atenda em `:80`
(45 min por padrão, estendendo-se a no máximo o dobro enquanto o SSH confirma
que o cloud-init está em execução ou ainda não iniciou; substitua com
`YURUNA_POOL_CONTROL_SERVICE_READY_TIMEOUT_SECONDS=<seconds>`) antes de
informar que o daemon está pronto &mdash; um IP sozinho não significa que o
serviço está "ativo": o convidado ainda precisa compilá-lo. Uma compilação
confirmada como ainda em andamento encerra a espera com o resultado não fatal
`StillBuilding` e um marcador inativo. Se a ativação falhar, ele obtém o log de compilação,
`cloud-init status` e o journal de `pool-control-service.service` pela chave SSH
do ambiente de testes e os exibe, para que uma compilação malsucedida mostre o motivo, em vez de uma URL inacessível.
(Esse log só pode ser lido por root; a conta `yuruna` do ambiente de testes tem `sudo` NOPASSWD, portanto
`sudo tail /var/log/cloud-init-output.log` o lê &mdash; um `tail` simples retorna
`Permission denied`.)

**No hospedeiro (prova / alternativa):**

```powershell
pwsh test/service/Start-PoolControlServiceVM.ps1 -HostSideProof [-Port 8090] [-AggregatorUrl <url>]
# UI at http://<host>:8090/ ; stop with test/service/Stop-PoolControlServiceVM.ps1
```

`-HostSideProof` compila e executa o daemon diretamente neste hospedeiro, em vez de em uma VM.
Precisa de `go` + `pwsh` no PATH e do checkout do framework (as CLIs ficam em
`<repo>/test/pool/*.ps1`).

<a id="4207d71a-0014"></a>

<a id="auto-enrollment"></a>

### Inscrição automática

Um hospedeiro que cadastrou seu token do laboratório e não está em **nenhum grupo** pode entrar em um
grupo sem que você o adicione. Esse recurso **vem desabilitado**: a varredura só ocorre quando um
bloco `autoEnrollment` no `pools.yml` do armazenamento de configuração define `enabled: true` e indica um grupo de destino
*e* o daemon é executado com `--auto-enroll` (`--auto-enroll-interval`, padrão 60s,
define a frequência).

Depois de habilitado, cada execução periódica faz exatamente isto e nada mais:

- **Os candidatos são hospedeiros cujo campo `control` é `ready` na comunicação.**
  "Remote" e "onsite" são mapeamentos de *exibição* do Grafana para esse mesmo campo e
  não aparecem em nenhuma parte da API &mdash; um predicado escrito com essas palavras
  nunca encontra nenhum hospedeiro e parece exatamente com "ninguém precisava ser inscrito".
- **Apenas hospedeiros em zero grupos são adicionados.** Isso preserva, pela própria construção, a regra de que "um hospedeiro pertence a,
  no máximo, um grupo" e significa que a varredura nunca pode mover um hospedeiro que você
  colocou deliberadamente em um grupo.
- **`autoEnrollment.excluded[]` é respeitado**, portanto um hospedeiro que você removeu do
  grupo de destino nunca é adicionado novamente &mdash; caso contrário, você e um temporizador de 60 segundos
  disputariam isso para sempre.
- **Não haver nada a fazer significa que nada acontece**: nenhum commit, nenhum push, nenhuma linha de auditoria.
- **Cada execução periódica registra a contagem de candidatos**, para que "nunca inscreve ninguém" tenha uma leitura
  diferente de "não há ninguém para inscrever".

A falha é **limitada, não atômica**. Cada hospedeiro tem sua própria execução de CLI, commit e
push, portanto uma falha no meio deixa os hospedeiros anteriores inscritos. A inscrição
é idempotente e pode ser retomada, portanto a próxima execução periódica termina o trabalho.

**O grupo de destino nunca contém repositórios.** Seus membros continuam executando seus
próprios projetos configurados: `Set-PoolRepository.ps1` recusa definir repositórios
ali, `Test-PoolConfiguration.ps1` reprova um armazenamento que os contém, a página Pools
mostra as caixas **Framework / Project** do grupo desabilitadas, e um executor que ainda
as encontra as ignora com um aviso. Para remover repositórios deixados ali por uma edição
manual, use **Clear** na página Pools ou
`Set-PoolRepository.ps1 -PoolId <target-pool> -Clear`.

<a id="4207d71a-0015"></a>

<a id="network-scan----finding-hosts-nobody-registered"></a>

### Varredura de rede -- encontre hospedeiros que ninguém cadastrou

Um hospedeiro chega às páginas do grupo ao se cadastrar no agregador. Uma máquina
que executa um status service do Yuruna, mas nunca se inscreveu, é, portanto,
invisível em todas as interfaces de grupos, mesmo quando está na mesma sub-rede respondendo
a consultas. A página **Scan** consulta a rede.

**O que ela faz.** Cada endereço da rede informada é consultado em
`/livecheck` na porta do status-service do hospedeiro (8080 por padrão,
`--scan-port`). Um endereço só conta como hospedeiro Yuruna quando essa resposta
*se identifica* como `yuruna-status-service` &mdash; um 200 de algum outro servidor
web na mesma porta não basta. Depois, cada hospedeiro que responde é consultado para obter
seu próprio registro de cadastro, de onde vêm seu ID de hospedeiro, nome de máquina e tipo;
um hospedeiro que não informa seu nome ainda é registrado, pelo endereço.

**O que ela não faz.** Nada muda nos hospedeiros examinados, e a configuração do grupo
nunca é gravada: um hospedeiro descoberto é **monitorado, não inscrito**. Ele aparece
na página Hosts marcado como `discovered`, sem grupo e com sua coluna **Control**
vazia &mdash; essa é a leitura que o grupo faz de um *membro*. Suas colunas de hardware e
repositórios ainda são preenchidas: elas são a resposta do próprio hospedeiro sobre si,
solicitada no endereço em que a varredura o alcançou.
Seu **endereço** é o link para sua página de status, e seu ID de hospedeiro é texto simples:
o ID de um hospedeiro de grupo aponta pelo `/go/host` do agregador, que resolve o que
esse hospedeiro cadastrou, e um hospedeiro descoberto não cadastrou nada &mdash; portanto o
endereço, onde a varredura acabou de obter uma resposta, é o único caminho de entrada que funciona.
Colocá-lo em um grupo continua sendo sua decisão, feita pelo seletor Pool dessa linha.
(Um hospedeiro que nunca informou um ID não pode ser colocado em um grupo, pois
a participação é registrada pelo ID; seu seletor informa isso.)

**O intervalo, em notação CIDR.** Um endereço e um comprimento de prefixo:
`192.168.7.0/24` são as 254 máquinas cujos primeiros três números são `192.168.7`.
Um comprimento de prefixo maior cobre menos endereços (`/32` é uma máquina); um menor
cobre mais. É válido digitar um endereço dentro da rede &mdash;
`192.168.7.34/24` significa a mesma sub-rede. O campo informa quantos endereços sua
entrada cobre antes de você pressionar Scan e recusa qualquer valor acima de **4096 endereços**
(mais amplo que `/20`): um `/8` digitado por engano está a uma tecla de `/24` e colocaria
dezesseis milhões de tentativas de conexão na rede do laboratório.

**A varredura.** A mesma varredura ocorre automaticamente a cada **15 minutos**
(`--scan-interval`, `0` desliga o temporizador e deixa o botão da página como a
única forma de iniciar uma varredura). Sem `--scan-cidr`, ela examina o `/24` em torno do
endereço do próprio serviço, calculado novamente a cada execução, para que um serviço que mudou de sub-rede
examine aquela em que está agora. Uma varredura programada que coincide com uma já em execução é
ignorada, em vez de enfileirada.

**O que a página mostra.** Os endereços consultados à medida que são processados, o progresso da
execução e, depois, apenas os hospedeiros que ela **adicionou** &mdash; um hospedeiro Yuruna que
já era monitorado é contado, não listado novamente. Abaixo ficam todos os hospedeiros
que a descoberta viu nos últimos 14 dias (`--scan-ttl`), com os horários do primeiro e do último contato e um botão **Forget**
para uma máquina desativada. Tanto iniciar uma varredura quanto esquecer um
hospedeiro exigem o token do laboratório; ler a página não exige.

A lista pertence a este serviço, mantida ao lado do log de auditoria em `--state-dir`
(`discovered-hosts.json`), portanto sobrevive a uma indisponibilidade do agregador &mdash; justamente
o caso para o qual ela existe. Sem um diretório de estado, fica na memória e é reconstruída pela
próxima varredura.

<a id="4207d71a-0016"></a>

## Download-agent service

O Download-agent service é o baixador de imagens de convidados compartilhado pelo grupo. Ele mantém
um **Download pool** no NAS do grupo (`<pool root>/images/...`), verifica novamente cada
imagem contra sua origem de forma programada e serve os artefatos aos hospedeiros por
HTTP -- portanto um laboratório baixa uma ISO ou imagem de nuvem da internet uma vez, em vez de
uma vez por hospedeiro. Ele precisa de armazenamento de grupo configurado -- sem um compartilhamento, o serviço
é ignorado.

<a id="4207d71a-0017"></a>

<a id="what-it-does-1"></a>

### O que ele faz

- **Mantém o conjunto de imagens.** Uma entrada por `(hostType, imageKey, arch, variant)`, armazenada
  com nomes de geração (nome de arquivo do fornecedor + prefixo SHA-256 do artefato), com
  um pequeno ponteiro `current.<arch>.<variant>.json` gravado por último, para que uma
  atualização nunca renomeie sobre um arquivo que um hospedeiro está recebendo como fluxo. São mantidas a geração atual
  e uma anterior.
- **Mantém as imagens atualizadas.** Um verificador em segundo plano percorre o conjunto a cada
  `downloadAgentService.scanIntervalSeconds` e atua em qualquer item que vá expirar dentro
  de `prefetchLeadSeconds` de seu prazo `freshnessSeconds`. As consultas de atualização vão
  **diretamente** à origem, nunca pelo cache do Squid -- um HEAD via proxy
  retornaria cabeçalhos congelados na época do pré-aquecimento e certificaria dados desatualizados como atuais. Os
  downloads de bytes usam o cache e recorrem à origem diretamente quando o proxy falha. Quando uma
  atualização falha, o artefato anteriormente verificado continua disponível para ser servido.
- **Preenche o conjunto automaticamente.** Com `autoSeed` habilitado (o padrão), ele lê a lista de hospedeiros do
  agregador do grupo, determina os tipos de hospedeiro realmente presentes e
  baixa antecipadamente as famílias estáveis para eles. Os hospedeiros para os quais o agregador não tem status
  são atendidos sob demanda.
- **Anuncia a si mesmo.** Um beacon ao pool-aggregator service e o
  marcador `runtime/download-agent-service.json` o colocam na tabela
  Extension hosts do painel como "Download-agent service", com um link direto para sua interface.

<a id="4207d71a-0018"></a>

<a id="the-ui-and-its-three-actions"></a>

### A interface e suas três ações

O daemon serve uma interface de página única em `http://<agent-vm-ip>/` -- o cabeçalho do
agente (versão, disponibilidade do grupo, estado da concessão temporária, frequência do verificador, resultado do último
preenchimento), uma linha por imagem com seu indicador de estado, nome de arquivo atual, tamanho em disco,
`lastVerifiedAt` e tempo até expirar, resultado da soma de verificação, URL de origem e progresso
ao vivo dos downloads em andamento, além de uma linha de totais que responde "o que está consumindo o
compartilhamento". As leituras são abertas na LAN. Três ações por linha exigem autorização:

- **Force refresh** -- verificar novamente contra a origem agora; baixar apenas se ela
  mudou. Também pode ser usada em uma linha ausente para iniciar o primeiro download.
- **Delete** -- cancelar qualquer download em andamento, remover primeiro o ponteiro e depois
  todas as gerações e arquivos auxiliares. A próxima solicitação de um hospedeiro ou execução de preenchimento baixa novamente
  da origem; esse é o caminho para "forçar um novo download". As cópias locais dos hospedeiros
  não são alteradas.
- **Prune previous** -- remover apenas a geração anterior para recuperar espaço; a
  atual continua disponível para ser servida.

Cada ação é acrescentada a `<pool root>/download-agent-service/audit.jsonl`. As
mesmas três existem como rotas de API para automação, que também aceitam a chave de
autenticação interna compartilhada como bearer.

<a id="4207d71a-0019"></a>

<a id="unlocking-the-actions-1"></a>

### Desbloqueio das ações

**Normalmente, não há nada para desbloquear.** Abra uma interface de serviço pela tabela *Extension hosts*
do painel *Yuruna hosts*, e ela já chega desbloqueada: esse
link passa pelo redirecionamento `/go/stash` do agregador, que entrega à página uma
prova de controle de curta duração no fragmento da URL (nunca enviada a um servidor, nunca em
um log de acesso), e a página a troca por uma sessão ao chegar. A solicitação
abaixo aparece quando não há uma prova para usar -- a página foi aberta
digitando seu endereço, por um favorito, ou a prova expirou enquanto a aba permanecia aberta.

A solicitação **Unlock actions** do painel recebe o **token do laboratório** rotativo de 6 caracteres
que o painel Yuruna hosts já exibe em seu próprio cartão -- o mesmo
código que `test/lab/Set-LabToken.ps1` troca para inscrever um hospedeiro. Leia-o no cartão,
digite-o, e esse navegador permanece desbloqueado por uma semana. Nada é provisionado
ou armazenado na VM do agente.

O daemon não avalia o código por conta própria: ele o encaminha à troca
`POST /api/v1/lab-token` do agregador, que é responsável pela rotação. Portanto, um agregador
inativo impede o desbloqueio do painel -- uma falha segura deliberada,
respondida como `503 lab-token-unavailable`, em vez de "código incorreto". A automação
não é afetada; as mesmas rotas recebem `Authorization: Bearer <internal-auth-key>`.

O código é público na LAN por construção (o agregador o publica em
seu `/metrics` aberto). Ele impede um clique acidental em Delete; não é um segredo, e
é útil porque expira por conta própria.

Sem um agregador para consultar e sem uma chave de autenticação interna configurada, as rotas que fazem alterações
respondem `503` -- nunca permitem uma gravação sem autorização.

<a id="4207d71a-001a"></a>

<a id="running-it-1"></a>

### Execução

```powershell
pwsh test/service/Start-DownloadAgentServiceVM.ps1 [-VMName yuruna-download-agent-service]
# stop (and tear down the VM) with test/service/Stop-DownloadAgentServiceVM.ps1
```

Como no pool-control service, o daemon é compilado **dentro** do convidado (sem cadeia de ferramentas
`go` no hospedeiro), a partir de `host/vmconfig/download-agent-service.base.user-data` +
`guest/ubuntu.server.26/ubuntu.server.26.download-agent-service.sh`, que
monta o compartilhamento do grupo por CIFS em `/mnt/yuruna-pool`. O lançador espera que o
daemon atenda em `:80` (45 min por padrão, estendendo-se a no máximo o dobro
enquanto o SSH confirma que o cloud-init está em execução ou ainda não iniciou; substitua com
`YURUNA_DOWNLOAD_AGENT_SERVICE_READY_TIMEOUT_SECONDS=<seconds>`) e obtém o
log de compilação dentro do convidado e o journal quando a ativação falha. Uma
compilação confirmada como ainda em andamento encerra a espera com o resultado
não fatal `StillBuilding` e um marcador inativo. `install/setup.ps1` executa o
par de parada/inicialização por você em um laboratório ou em um hospedeiro independente
que define `downloadAgentService.enabled: true`, sempre que o armazenamento está configurado
(`enabled: false` omite essa etapa em ambos os modos), e nunca faz a configuração falhar por causa disso. Chaves de configuração:
[test-config.md](../test-config.md#downloadagentservice--the-pool-wide-image-downloader).

<a id="4207d71a-001b"></a>

<a id="design-choices"></a>

## Escolhas de projeto

- **Um par de framework e projeto por grupo** -- divida os hospedeiros em dois grupos para
  executar dois conjuntos de testes lado a lado.
- **As URLs dos repositórios não são consultadas** -- `Set-PoolRepository.ps1` e a página Pools
  registram as URLs dos repositórios sem cloná-los, e `Test-PoolConfiguration.ps1`
  verifica o formato, não a acessibilidade.
- **Os membros não dividem o trabalho** -- cada membro executa o
  plano completo do `test.runner.yml` do projeto atribuído; não há agendamento por convidado entre os membros.

<a id="4207d71a-001c"></a>

<a id="advanced-two-more-optional-poolsyml-blocks"></a>

## Avançado: mais dois blocos opcionais de `pools.yml`

Eles ainda não têm um comando dedicado -- escreva-os diretamente em `pools.yml` (valide com
`Test-PoolConfiguration.ps1`); veja [`test/schemas/pools.schema.yml`](../../test/schemas/pools.schema.yml):

- **`config.testCycle`** -- substitui os ajustes de ciclo de teste para todo o grupo (por exemplo,
  `stepTimeoutSeconds`, `autoRemediation.enabled`); o valor do grupo tem prioridade sobre a configuração de cada hospedeiro.
- **`gating`** -- limiares de alertas de saúde do grupo (o quórum de membros saudáveis e quanto tempo deve passar antes de um
  grupo ser marcado como "degraded"). Informativo: controla os alertas e o painel, nunca bloqueia um
  ciclo. A entrega é configurada separadamente no hospedeiro de alertas (veja a documentação do notificador).

<a id="4207d71a-001d"></a>

<a id="default-off--safety"></a>

## Desabilitado por padrão e segurança

A camada de grupos exige habilitação em todas as suas partes: um hospedeiro sem bloco `pool`, ou um grupo sem
membros ou sem repositórios, executa seu `test.runner.yml` local exatamente como um
hospedeiro independente. Um armazenamento de configuração inacessível faz o executor recorrer à última cópia válida
e depois à execução independente -- um grupo nunca impede um hospedeiro de testar.

<a id="4207d71a-001e"></a>

<a id="see-also"></a>

## Veja também

- [control-routes.md](../control-routes.md) -- o que um hospedeiro aceita dos botões de ação do
  painel e a configuração única da chave de autenticação interna que permite usá-los a partir de outra máquina.
- [pool-storage.md](../pool-storage.md) -- replicação opcional dos dados de observabilidade do grupo para o NAS
  (um recurso separado, exclusivo do NAS).
- [test/extension/pool-aggregator-service/README.md](../../test/extension/pool-aggregator-service/README.md) --
  o painel de grupos somente para leitura e o coletor de telemetria.
- [test-config.md](../test-config.md) -- as chaves de configuração de `pool` no hospedeiro.
- [pool-dashboard.md](../pool-dashboard.md) -- o significado de cada painel do painel Yuruna
  hosts, incluindo a linha do proxy de cache de onde a receita de triagem acima começa.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.10.22

Voltar para [Yuruna](../../README.md)
