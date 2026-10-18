<a id="42fffc2c-0001"></a>

<a id="extensions-api"></a>

# API de extensões

O executor delega nove classes de comportamento intercambiável a **áreas de
extensão** em [`test/extension/`](../../test/extension/) -- autenticação,
transportes de notificação, análise de logs de caching-proxy-service,
gerenciamento do caching-proxy, armazenamento de artefatos do hospedeiro
no stash, agregação de grupos com vários hospedeiros, configuração de grupos,
download de imagens de convidados para todo o grupo e integridade do conteúdo
dos convidados. Uma área é um diretório com um ou mais arquivos `.psm1` e uma
configuração YAML que nomeia o conjunto ativo.

Carregador: [`test/modules/Test.Extension.psm1`](../../test/modules/Test.Extension.psm1).

Algumas áreas são **serviços na rede**, em vez de código carregado em um
ciclo. Elas compartilham uma interface, descrita
[abaixo](#the-extension-interface): um manifesto que declara o serviço,
um SDK em Go para comunicação com o grupo e controle de escritas, e um
módulo do hospedeiro para o marcador de execução. Um novo serviço de extensão
implementa essa interface e é descoberto por existir; ele não acrescenta
nenhum caso a uma lista do framework.

O auxiliar compartilhado de navegador `Y.api` aceita uma resposta 204 vazia.
As demais respostas de sucesso devem conter JSON válido; JSON malformado
rejeita a solicitação para que a interface não confunda uma resposta
inválida com um sucesso vazio. As falhas HTTP mantêm seu status, e o
processamento de fetch e do corpo continua limitado pelo timeout da solicitação.

<a id="42fffc2c-0002"></a>

<a id="areas-today"></a>

## Áreas atuais

| Área | Padrão ativo | O que controla |
|------------------------|----------------|------------------|
| `authentication` | `default` | `${ext:authentication.GetPassword(<user>)}` / `NewRandomPassword()` / `SetPassword()` -- leitura e escrita do cofre pelas sequências. A extensão `default` armazena senhas efêmeras das VMs de teste por ciclo em YAML em texto simples **por decisão de projeto**; consulte [Autenticação -- Modelo de ameaças do cofre do executor de testes](../authentication.md#test-harness-vault--threat-model) para o limite de confiança. Configure outra extensão (DPAPI / chaveiro / gerenciador externo de segredos) antes de controlar qualquer sistema de produção por uma sequência. |
| `notification` | `default` | `Send-Notification -EventCode -EventMessage`; percorre a lista de assinantes e entrega a cada um pelo transporte declarado. A extensão `default` implementa exatamente um transporte, `email` via Resend; qualquer outro valor em `transports.yml` gera o aviso `Unknown transport` e não entrega nada. Uma lista de assinantes vazia ou ausente não executa nenhuma ação e permanece silenciosa (apenas `Verbose`), de modo que um usuário na primeira execução, sem configuração preenchida, não recebe erros. Para integrar um novo transporte, acrescente uma ramificação aqui. |
| `caching-proxy-parser-service` | `default` | Acompanha o log de acesso do Squid em um buffer circular de 100 entradas em memória e o serve em `:9302` como JSON (`/recent-requests`) e uma página HTML autossuficiente. O painel **Recent 100 requests** do Grafana continua lendo o Loki, alimentado pelo Alloy a partir do log do Squid. Inclui um daemon Go que usa apenas a biblioteca padrão (`parse.go` + `main_linux.go` + `caching-proxy-parser-service.service`), compilado na VM do proxy; o `default.psm1` do PowerShell é o wrapper do hospedeiro e exporta `Get-CachingProxyParserServiceManifest`. O parser não persiste nada: o buffer circular é sua política de retenção. |
| `caching-proxy-service` | `default` | O **plano de gerenciamento** da VM caching-proxy-service -- a área que tornou essa VM autodescritiva, em vez de uma linha fixa no cadastro. Um daemon Go com biblioteca padrão e SDK em `:9310` informa o resumo de execução do Squid (pela API de gerenciamento), o estado das opções offline / sem upstream e o catálogo, os registros canary e de pré-aquecimento do zot; ele controla as duas opções do operador, antes disponíveis apenas por SSH. Nenhum serviço que atende tráfego foi movido: Squid (`:3128`/`:3129`), zot (`:5000`), Grafana, Prometheus, Loki e os exportadores permanecem como estavam. É executado na VM do proxy (`--mode local`) ou em outro hospedeiro que alcance essas APIs (`--mode remote`, somente leitura -- consulte [abaixo](#running-the-caching-proxy-service-from-another-host)). |
| `stash-service` | `default` | Recebe artefatos enviados por `scp`/`sftp` (pacotes de diagnóstico, capturas de tela) em um stash respaldado por stash-storage. Inclui um daemon Go em [`server/`](../../test/extension/stash-service/server/) (SCP legado **e** SFTP, arquivos no compartilhamento ystash-nas e índice/arquivos auxiliares SQLite locais à VM), iniciado por `Start-StashServiceVM` + cloud-init, além do wrapper PowerShell `default.psm1`. |
| `pool-aggregator-service` | `default` | **Visão do grupo** com vários hospedeiros, somente leitura (`Get-PoolAggregatorServiceManifest`), mais a parte do grupo na consulta de serviços abaixo (`Get-PoolExtensionHost`). Inclui um daemon Go que usa apenas a biblioteca padrão e roda na máquina caching-proxy-service (hospedeiro dos serviços do grupo): descobre automaticamente os membros pelo log de acesso do Squid, consulta o serviço de status de cada um, identifica-os pelo `hostId` estável e envia transições de status dos ciclos ao Loki. Consulte [`pool-aggregator-service/README.md`](../../test/extension/pool-aggregator-service/README.md). |
| `pool-control-service` | `default` | O painel do operador para a **configuração de grupos**: quais grupos existem, quais hospedeiros pertencem a eles e quais repositórios de framework e projeto cada um executa. Inclui um daemon Go que usa apenas a biblioteca padrão em sua própria VM `yuruna-pool-control-service`, que controla o armazenamento git de configuração do grupo executando as CLIs pool-admin, com uma interface web cujas ações de alteração são desbloqueadas pelo token do laboratório rotativo do dashboard. O `default.psm1` do PowerShell é o par do hospedeiro -- `Get-PoolControlServiceInfo` (stub de status) e `Test-PoolControlServiceHost` (verificação prévia de `/healthz`). Consulte [pool-admin.md](../pool-admin.md#pool-control-service). |
| `download-agent-service` | `default` | **Downloader de imagens de convidados** para todo o grupo: um daemon Go que usa apenas a biblioteca padrão em sua própria VM `yuruna-download-agent-service`, que mantém atualizado um Download pool no compartilhamento do grupo e serve os artefatos aos hospedeiros por HTTP, com uma interface web cujas ações de alteração são desbloqueadas pelo token do laboratório rotativo do dashboard. O `default.psm1` do PowerShell é o par do hospedeiro -- `Get-DownloadAgentServiceInfo` (stub de status) e `Test-DownloadAgentServiceHost` (verificação prévia de `/healthz`). Consulte [download-agent.md](../download-agent.md). |
| `digest` | `default` | Valores SHA-256 que uma etapa de sequência leva ao convidado em seu comando de inicialização, para que um script do convidado verifique o que baixa antes de extrair, instalar ou executar: `${ext:digest.GetFileSha256(<path>)}`, `${ext:digest.GetArchiveSha256(project)}`, `${ext:digest.GetPublishedSha256(<name>)}`, mais a etapa `digest.PublishGuestFileSha256` para um artefato que um convidado compila e outro baixa. O digest trafega pelo mesmo canal digitado que o do próprio script, nunca pelo HTTP pelo qual os bytes chegam. Consulte [`digest/README.md`](../../test/extension/digest/README.md). |

<a id="42fffc2c-0003"></a>

<a id="filesystem-layout"></a>

## Organização do sistema de arquivos

```
test/extension/
+-- authentication/
|   +-- authentication.config.yml       # active: ['default']
|   +-- authentication.contract.yml     # methods + parameter shape this area exports
|   +-- users.yml.template              # vault seed: harness copies on first cycle
|   +-- default.psm1                    # 13 exports: the vault read/write pair, the credential
|                                       # resolvers, and the users.yml reader + its cache reset
+-- notification/
|   +-- notification.config.yml         # active: ['default']
|   +-- notification.contract.yml       # methods this area exports
|   +-- transports.yml.template         # transport-credentials seed (e.g. Resend API key)
|   +-- default.psm1                    # exports Send-Notification
+-- caching-proxy-parser-service/
|   +-- caching-proxy-parser-service.config.yml # active: ['default']
|   +-- caching-proxy-parser-service.contract.yml
|   +-- caching-proxy-parser-service.service    # systemd unit for the in-VM Go daemon
|   +-- go.mod                          # Go daemon source (built into the proxy VM)
|   +-- parse.go                        # regex, ring, counters, handlers -- no build tag
|   +-- main_linux.go                   # the tailer + main; needs syscall.Stat_t for logrotate
|   +-- main_other.go                   # non-Linux entry point, so the module still builds
|   +-- parse_test.go, main_linux_test.go
|   +-- README.md
|   +-- default.psm1                    # host-side wrapper
+-- caching-proxy-service/
|   +-- caching-proxy-service.config.yml        # active: ['default'] + the service manifest
|   +-- caching-proxy-service.contract.yml
|   +-- caching-proxy-service.service   # systemd unit for the in-VM Go daemon
|   +-- go.mod                          # flat module at the area root, like its two
|   |                                   # neighbors in the proxy VM -- that VM has no
|   |                                   # framework checkout, so cloud-init fetches the
|   |                                   # sources file by file and builds them in place
|   +-- main.go, squid.go, switches.go, registry.go
|   +-- main_test.go, squid_test.go
|   +-- default.psm1                    # host-side info stub + /healthz preflight
+-- stash-service/
|   +-- stash-service.config.yml        # active: ['default'] + the service manifest
|   +-- stash-service.contract.yml      # requiredFunction: the info stub, Resolve-Host,
|   |                                   # the /healthz preflight, the address publisher
|   +-- server/                         # Go daemon: main.go + internal/{...}, go.mod + go.sum
|   |                                   # (the one service module with third-party deps),
|   |                                   # and its own README.md
|   +-- default.psm1                    # host-side wrapper
+-- pool-aggregator-service/
|   +-- pool-aggregator-service.config.yml      # active: ['default'] + the service manifest
|   |                                   # (hostedIn, no vmName -- it runs in the proxy VM)
|   +-- pool-aggregator-service.contract.yml    # requiredFunction: Get-PoolAggregatorServiceManifest
|   +-- pool-aggregator-service.service         # systemd unit for the proxy-host Go daemon
|   +-- go.mod, main.go                 # stdlib-only Go daemon source: main.go plus handover.go,
|   |                                   # mcp.go, localization.go, backfill*.go and internal/catalog/
|   +-- *_test.go                       # 32 test files beside it
|   +-- grafana-pool-dashboard.json     # companion Grafana dashboard
|   +-- README.md
|   +-- default.psm1                    # host-side wrapper
+-- pool-control-service/
|   +-- pool-control-service.config.yml         # active: ['default'] + the service manifest
|   +-- pool-control-service.contract.yml
|   +-- server/                         # Go daemon (main.go + internal/{...}, incl. configuration)
|   +-- default.psm1                    # host-side status stub + /healthz preflight
+-- download-agent-service/
|   +-- download-agent-service.config.yml       # active: ['default'] + the service manifest
|   +-- download-agent-service.contract.yml     # requiredFunction: Get-DownloadAgentServiceInfo
|   +-- server/                         # Go daemon (main.go + internal/{...}, incl. imagestore)
|   +-- default.psm1                    # host-side status stub + /healthz preflight
+-- digest/
|   +-- digest.config.yml               # active: ['default']
|   +-- digest.contract.yml             # requiredFunction: the three Get-*Sha256 readers + Publish-GuestFileSha256
|   +-- README.md
|   +-- default.psm1                    # 4 exports: Get-FileSha256, Get-ArchiveSha256,
|                                       # Get-PublishedSha256, Publish-GuestFileSha256
+-- extension-sdk/                      # the shared Go SDK, staged beside each server/
    +-- go.mod, README.md               # at build time -- never copied into one
    +-- beacon/                         # POST /announce presence
    +-- pool/                           # the pool-aggregator read client
    +-- labgate/                        # the lab-token write gate
    +-- webui/                          # shared browser assets (yuruna.core.js runtime)
    +-- mcp/                            # MCP-over-HTTP surface every daemon except caching-proxy-parser-service mounts
```

Nenhum `server/` contém uma cópia do SDK. Cada um o referencia como módulo
irmão (`replace ... => ../extension-sdk`), e a inicialização do convidado o
coloca nesse local durante a compilação. A suíte de serviços de extensão
falha se um serviço reintroduzir uma cópia, remover o `replace` ou deixar de
preparar o módulo.

Os arquivos `<area>.contract.yml` declaram os métodos e a estrutura de
parâmetros que o módulo PowerShell de cada área deve exportar, e
`Import-Extension` os verifica durante o carregamento: um módulo sem um
verbo declarado gera um aviso que informa todas as diferenças. O aviso é
usado em lugar de uma exceção para que uma área desatualizada não interrompa
um ciclo sem relação com ela. Como isso não produz uma falha,
[`Test.ExtensionArea.Tests.ps1`](../../test/modules/Test.ExtensionArea.Tests.ps1)
carrega todas as áreas distribuídas e trata o aviso como falha.
`Resolve-ExtensionMethod`, por outro lado, não impõe essas exigências --
resolve um nome e lança uma exceção apenas se nenhuma das formas for exportada.

Uma área de serviço também contém um bloco `service:` em seu
`<area>.config.yml` -- o manifesto descrito
[abaixo](#1-the-manifest----what-the-area-declares) -- e, quando inclui um
daemon Go, um diretório `server/` com esse daemon.

O estado de cada área (arquivo do cofre, credenciais de transporte) fica em
[`test/status/extension/<area>/`](../../test/status/) -- ignorado pelo git e nunca
distribuído.

`extension-sdk/webui` fornece os recursos de navegador compartilhados por
todas as interfaces de serviço -- hoje, o runtime de `yuruna.core.js`,
enquanto cada serviço ainda mantém sua própria folha de estilos. Um serviço
incorpora suas próprias páginas e scripts e solicita a esse pacote apenas
os nomes que não possui, de modo que exista uma cópia do runtime
compartilhado, em vez de uma por serviço: esses recursos têm uma versão
mínima de navegador ([Safari 16 / iOS 16](../definition.md)), e um serviço com
sua própria cópia pode deixar de atender a esse requisito sem que ninguém
perceba. `//go:embed` não alcança arquivos fora de seu módulo; por isso, os
arquivos compartilhados são incorporados em `webui` e fornecidos por Go,
em vez de referenciados diretamente através do limite do módulo.

<a id="42fffc2c-0004"></a>

<a id="the-loader-api"></a>

## API do carregador

```
Resolve-ExtensionAreaDir        -Area
Read-ExtensionConfig            -Area
Get-ActiveExtensionName         -Area   # ALWAYS wrap in @(...) -- single-entry config unrolls to scalar
Get-ExtensionAreaName                   # every area on disk; directory + config.yml is the whole rule
Import-Extension                -Area [-RequireSingle]
Import-ConfiguredExtension              # all areas at once; per-area failure warns, never throws
Assert-ExtensionContractCoverage -Area -ExtensionName -ExportedFunction
Resolve-ExtensionMethod         -Area -ExtensionName -Method
Get-ExtensionHostAddress        -HostType [-VMName] [-AggregatorBaseUrl] [-TimeoutSeconds]
```

`Resolve-ExtensionMethod` realiza a substituição `${ext:area.Method(...)}`
no YAML das sequências: converte o nome do método em CamelCase para a forma
exportada `Verb-Noun` (por exemplo, `GetPassword` -> `Get-Password`) e
localiza o módulo carregado pelo **caminho absoluto**, não pelo nome do
módulo. Duas áreas podem fornecer um `default.psm1`; a consulta por caminho
mantém inequívocas as exportações de cada área.

<a id="42fffc2c-0005"></a>

<a id="the-extension-interface"></a>

## Interface das extensões

Cinco áreas de extensão declaram manifestos de serviço, e cada nova extensão
costumava exigir cópias dos mesmos cinco itens: um beacon de presença, um cliente de leitura
do agregador, um controle de escrita, um marcador de execução e uma entrada
em três listas fixas no framework. Cada cópia se desviou das outras; assim,
um serviço acabou com uma política de tentativas mais fraca, outro com um
`clientIP` que corrompe IPv6, e o serviço que reescreve a configuração do
grupo ficou sem nenhuma credencial.

A interface tem três camadas, cada uma com uma única fonte de verdade.

<a id="42fffc2c-0006"></a>

<a id="1-the-manifest----what-the-area-declares"></a>

### 1. O manifesto -- o que a área declara

O `<area>.config.yml` de uma área de serviço contém um bloco `service:`,
validado por
[`test/schemas/extension-config.schema.yml`](../../test/schemas/extension-config.schema.yml):

```yaml
active:
  - default
service:
  displayName: Stash service          # the label the Extension hosts column shows
  vmName: yuruna-stash-service        # the VM this host creates; absent = hosted elsewhere
  # hostedIn: caching-proxy-service   # instead of vmName, when the service runs
  #                                   # inside another area's VM -- what the
  #                                   # pool-aggregator manifest declares
  healthPort: 80                      # the port a CONSUMER connects to
  healthPath: /healthz
  startScript: Start-StashServiceVM.ps1   # a NAME; the harness resolves it under test/service/
  stopScript: Stop-StashServiceVM.ps1
  markerBaseUrlKey: stashBaseUrl      # this area's own marker key, kept for older readers
  beaconInterval: 2m                  # must stay under the aggregator's 5-minute health grace
  writeGate: none                     # or lab-token -- see the rule below
```

Esse único bloco alimenta o cadastro de VMs de serviço lido pela varredura
de reinicialização e pela proteção da limpeza
([`Test.ServiceVm.psm1`](../../test/modules/Test.ServiceVm.psm1)), a estrutura
do marcador de execução e a política de controle de escrita. Uma área
**sem** esse bloco é código carregado pelo ciclo (`authentication`,
`notification`) -- não é algo que o grupo possa localizar ou reiniciar;
portanto, não retornar nada para essas áreas é a resposta correta, e não
uma falha.

Executar dentro da VM de outra área é diferente de não ter um manifesto.
`pool-aggregator-service` fica na VM caching-proxy-service e ainda declara
um bloco completo: `hostedIn` no lugar de `vmName`, o que o mantém fora do
cadastro de VMs de serviço, mas permite localizá-lo, verificar sua saúde e
controlar seu acesso como em qualquer outro serviço. `-WithVMOnly` é a
opção que separa os dois casos.

Ele é lido por
[`Test.ExtensionService.psm1`](../../test/modules/Test.ExtensionService.psm1),
**por linhas, nunca por um parser YAML**. Isso ocorre porque o parser nem
sempre está carregado, não porque seu uso seria incorreto: a varredura de
reinicialização e os caminhos de limpeza importam o cadastro isoladamente,
e um leitor que só respondesse quando houvesse um parser disponível
esvaziaria o cadastro -- assim, um hospedeiro reinicializado nunca voltaria
a iniciar suas VMs de serviço, e uma limpeza por correspondência de prefixo
não poderia mais comprovar que as ignoraria. O schema limita o bloco a um
mapeamento simples de escalares; portanto, `key: value` com dois espaços de
recuo é toda a gramática que o leitor processa.

<a id="42fffc2c-0007"></a>

<a id="2-the-go-sdk----talking-to-the-pool-and-gating-writes"></a>

### 2. O SDK em Go -- comunicação com o grupo e controle de escritas

[`test/extension/extension-sdk/`](../../test/extension/extension-sdk/) é um
módulo Go próprio. Os pacotes usados diretamente por um serviço:

| Pacote | O que o serviço recebe |
|---|---|
| `beacon` | Presença por `POST /announce`: saudação na inicialização (com novas tentativas em uma cadência de recuperação que dobra), novo anúncio a cada intervalo e despedida `active:false`. O agregador que recebe os anúncios é definido uma vez, na criação por `New-VM` -- consulte [Quando o caching proxy é reconstruído](#when-the-caching-proxy-is-rebuilt). |
| `pool` | Cliente de leitura para o **provedor de informações**: `Status`, `ExtensionHost(s)`, `ExtensionTarget`, `Healthz` e `Get`/`GetURL` para rotas sem tipagem. |
| `labgate` | Controle de escrita: `Require`, `RequireBearer`, `HandleLogin`, `Session`. |
| `hostrefresh` | Autorização de atualização remota do hospedeiro: a prova de atualização versionada (`Proof`, `Verify` com relógio explícito e tolerância temporal em ambas as direções), o `Signer` que a emite a partir da autoridade de assinatura, o carregador do arquivo secreto e o `Gate` da credencial de atualização, que lê apenas `X-Yuruna-Refresh-Credential`. Apenas pool-control o importa; consulte [Atualização remota do hospedeiro](../pool-admin.md#remote-host-refresh). |

`pool.Host` também contém `Refresh`, a capacidade de atualização do
hospedeiro conforme a última avaliação do agregador (`pool.HostRefresh`:
protocolo, disponibilidade, limite, motivo, estado da chave remota, estado
da solicitação e idade da observação). `Status` a normaliza para seu
vocabulário limitado; um agregador anterior a essa capacidade retorna o
valor de nunca observada, e `RemoteUsable()` é a única verificação que o
chamador aplica antes de enviar uma atualização remota.

Três decisões ficam em `pool` para que não variem entre consumidores: a
política de TLS da LAN confiável (o certificado final do agregador é
assinado pela CA do grupo, em que nenhum convidado confia; por isso, essas
leituras criptografam sem fixar o certificado); `SanitizeBaseURL` em
**todo** campo de resposta que contenha uma URL, pois essas leituras não
verificam quem respondeu e a interface apresenta o que recebe como link;
e um fallback de https->http apenas em falha de *transporte*, já que um
agregador sem certificado final responde em `:9400` sem criptografia,
enquanto uma resposta de protocolo é autoritativa.

Cada daemon é um módulo próprio, compilado **dentro de sua própria VM** a
partir de uma cópia apenas de `<area>/server/` -- um módulo fora desse
diretório não está disponível quando o compilador o procura. Por isso, a
inicialização copia `extension-sdk/` para junto de `server/`, e cada
`go.mod` o resolve como módulo irmão
(`replace yuruna.com/test/extension/extension-sdk => ../extension-sdk`).
Um único módulo compartilhado; nenhum serviço mantém uma cópia. No checkout,
o SDK fica um diretório mais acima; por isso, `tools/Invoke-GoTest.ps1`
compila cada serviço em uma cópia descartável da organização de diretórios
do convidado, em vez de compilar no local do módulo. Consulte
[o README do SDK](../../test/extension/extension-sdk/README.md).

<a id="42fffc2c-0008"></a>

<a id="3-the-host-side-module--the-runtime-marker"></a>

### 3. O módulo do hospedeiro — o marcador de execução

[`Test.ExtensionService.psm1`](../../test/modules/Test.ExtensionService.psm1)
controla `runtime/<area>.json`, a declaração do hospedeiro de que executa
um serviço:

```
Get-ExtensionServiceManifest / -ManifestAll [-WithVMOnly]
Get-ExtensionServiceVmRoster
Write-ExtensionServiceMarker  -Area -Active -VMName -HostType -BaseUrl [-Extra]
Read-/Remove-ExtensionServiceMarker  -Area
Get-ExtensionServiceMarkerBaseUrl    -Marker -Area
Get-ActiveExtensionService           # -> activeExtensions + extensionTargets
```

`-Active` é o **veredito de prontidão**, não a indicação de que a
inicialização foi executada: o agregador usa esse valor para apresentar a
linha e seu link direto; assim, publicar `$true` para um daemon que nunca
abriu sua porta envia os operadores a uma URL indisponível e oculta a falha
real. O endereço é gravado tanto em `baseUrl`, a chave uniforme, quanto na
`markerBaseUrlKey` da própria área, pois um consumidor anterior à chave
uniforme lê apenas a chave por serviço, e um hospedeiro pode executar um
framework mais novo que o agregador ao qual se registra.

**O estado ativo e o endereço são vereditos distintos.** O daemon responder
*dentro* do convidado significa que o serviço está em execução; esse
hospedeiro conseguir abrir um socket até ele é uma conveniência local
separada. Assim, o marcador fica ativo nos dois casos, mas o endereço só é
publicado quando esse hospedeiro confirma o caminho de ponta a ponta:
anunciar um endereço que passa por um encaminhador que aceita a conexão,
mas não consegue se conectar adiante, prende cada par que o segue durante
um timeout inteiro. Presença sem endereço é um estado tratado pelo grupo
-- o anúncio do próprio daemon contém o endereço, e o agregador o confirma
por uma consulta
([abaixo](#only-an-address-the-pool-has-reached-is-answered)).

**A indicação de compilação em andamento fica deliberadamente fora do
marcador.** Um convidado que ainda compila seu daemon não está atendendo;
portanto, o marcador não deve afirmar que está. A inicialização ainda termina
*com sucesso*: a VM foi criada e iniciada, que é a finalidade dessa etapa,
e o daemon conclui o trabalho e se anuncia sem ajuda adicional. Falhar nesse
ponto apresentaria como defeituoso um serviço que apenas ainda não terminou.

[`Write-HostRegistrationRecord`](../../test/modules/Test.Capability.psm1)
converte `Get-ActiveExtensionService` em `activeExtensions` /
`extensionTargets` do registro -- sem um bloco fixo por serviço, para que
uma nova extensão alcance o grupo sem uma edição no gravador do registro.

<a id="42fffc2c-0009"></a>

<a id="the-lab-token-rule"></a>

### Regra do token do laboratório

**Toda rota que altera a configuração do hospedeiro ou do grupo exige uma
de duas credenciais** -- a chave de autenticação interna como bearer, ou uma
sessão desbloqueada pelo token do laboratório rotativo de 6 caracteres
exibido no dashboard *Yuruna hosts*. Não se usa um segredo local do serviço:
distribuir e rotacionar mais uma string compartilhada não acrescenta nada
que um código rotativo de todo o grupo já não ofereça, e seria a única
credencial do laboratório não compreendida pelos outros serviços.

Uma sessão também pode ser desbloqueada por uma **prova de controle**, em
vez do código. Um operador que abre uma interface de serviço pela tabela
*Extension hosts* do dashboard chega com uma prova: o redirecionamento
`/go/stash` do agregador a emite e a deixa no fragmento da URL, e a página
a consome em `POST /api/unlock-proof`. Assim, o operador não precisa voltar
ao dashboard para copiar um código de um bloco para agir em uma página que
acabou de abrir por ele. A prova é a mais fraca das três credenciais por
decisão de projeto -- emitida para uma visita, válida por minutos e
resgatável apenas para uma sessão no serviço ao qual foi levada; já o
código de 6 caracteres pode ser trocado pela própria chave de autenticação
interna.

Uma VM de serviço normalmente não recebe a chave de autenticação interna
(esse arquivo não é incorporado ao seu seed); por isso, em geral ela não
consegue verificar sozinha uma prova recebida. Consulta
`POST /api/v1/control-proof` no agregador, seguindo a mesma divisão de
responsabilidades usada pelo código de 6 caracteres: a validação permanece
com o daemon que detém o segredo. Um serviço que *possui* o token verifica
localmente, sem consulta remota.

O token do laboratório é público na LAN por construção -- o agregador o
publica no `/metrics` aberto e o exibe no bloco do dashboard. É uma proteção
contra cliques acidentais, não um segredo, e seu valor está justamente na
rotação: um código copiado do laboratório deixa de funcionar sozinho.

`labgate` implementa essa regra em código, e o `writeGate:` de cada área a
declara; assim, é possível saber quais serviços controlam suas escritas
sem ler as tabelas de rotas de cada um.

- **`lab-token`** -- `caching-proxy-service` (opções offline e sem upstream),
  `pool-control-service` (grupos, associação e repositórios de cada grupo),
  `download-agent-service` (excluir uma geração, forçar um novo download),
  `pool-aggregator-service` (`/ingest`, `/api/v1/forget-host`,
  `/api/v1/handover-host`), `stash-service` (`DELETE` de um stash,
  individualmente ou de uma página inteira de uma vez).
- **`none`** -- nenhum no momento.

As *leituras* são a finalidade do `stash-service`: navegar e enviar um
arquivo permanecem abertos, pois um convidado que envia um diagnóstico por
`scp` não deve precisar de uma credencial. Apenas `DELETE` é controlado, e
esse controle vale para todo o grupo, não por hospedeiro -- o compartilhamento
stash é montado com acesso de escrita às pastas de todos os hospedeiros;
assim, uma interface desbloqueada pode liberar espaço em qualquer lugar,
inclusive em um hospedeiro desligado.

O controle oferece três propriedades:

- **As leituras comuns permanecem abertas.** Catálogos, painéis, artefatos e
  status podem ser lidos na LAN confiável, como em `pool-status`. Controlar
  esse acesso tornaria uma credencial um pré-requisito para um hospedeiro
  executar seu trabalho e para uma tela de parede exibir um painel. O
  `GET /api/v1/host-history` do agregador exige o bearer interno compartilhado,
  pois os eventos brutos podem conter diagnósticos sensíveis.
- **Falhe de forma fechada e informe a causa.** Um validador inacessível
  responde `503` com motivo `lab-token-unavailable`, nunca `401` -- um
  operador que não distingue código incorreto de validador indisponível
  redigita um código correto até desistir. Um serviço sem nenhuma das
  credenciais configurada responde `503` `auth-unconfigured`, em vez de
  executar uma escrita sem controle.
- **Auditoria no serviço.** Toda tentativa de desbloqueio é registrada com
  o endereço de origem. A auditoria do próprio agregador não consegue
  responder a essa questão: vista de lá, todos os operadores do laboratório
  têm um único endereço de origem.

`POST /announce` é a exceção deliberada e permanece aberto, limitado pela
vinculação à própria identidade, uma consulta de saúde, estado limitado e
uso apenas para telemetria
([abaixo](#post-announce-pool-aggregator-service)).

<a id="42fffc2c-000a"></a>

<a id="building-a-new-extension-service"></a>

### Criação de um novo serviço de extensão

1. `test/extension/<area>/` com `<area>.config.yml` (`active:` + o bloco
   `service:`), `<area>.contract.yml` e `default.psm1`, exportando pelo menos
   um stub de status e uma verificação prévia `Test-<Name>Host` de `/healthz`.
2. `server/` para o daemon Go. Importe `beacon`, `pool` e `labgate` de
   `yuruna.com/test/extension/extension-sdk/...`; proteja toda escrita de
   configuração com `gate.Require`. O SDK é preparado ao lado de `server/`
   durante a inicialização e resolvido por
   `replace yuruna.com/test/extension/extension-sdk => ../extension-sdk`.
3. `test/Start-<Name>VM.ps1` / `Stop-<Name>VM.ps1`, chamando
   `Write-ExtensionServiceMarker` / `Remove-ExtensionServiceMarker` com o
   veredito de prontidão.
4. Um script de inicialização do convidado +
   `host/vmconfig/<area>.base.user-data`, preparando `/etc/yuruna/pool.env`
   (`YURUNA_AGGREGATOR_URL`) e `/etc/yuruna/host.env` (`YURUNA_HOST_ID`), de
   onde vêm o `--aggregator-url` e o `--host-id` do daemon.
5. Acrescente o mapeamento de valor de `area` -> `displayName` a
   [`grafana-pool-dashboard.json`](../../test/extension/pool-aggregator-service/grafana-pool-dashboard.json)
   e à sua cópia inline, para que a célula Extension hosts mostre o rótulo
   em vez do slug.

O cadastro, a matriz de capacidades, o registro, a consulta do grupo e a
varredura de reinicialização passam a reconhecê-lo sem outras edições.

<a id="42fffc2c-000b"></a>

<a id="service-scripts-run-at-erroractionpreference-continue"></a>

### Scripts de serviço são executados com `$ErrorActionPreference` em Continue

Todo script de inicialização e encerramento de serviço deixa
`$ErrorActionPreference` no `Continue` herdado e deve mantê-lo assim. Um
`Stop` no escopo do script não fica limitado ao script: uma função avançada
chamada por ele roda sob a mesma preferência; portanto, todos os auxiliares
que o script chama têm seus erros não terminantes promovidos a terminantes.

Várias etapas dependem exatamente dessa tolerância -- a verificação prévia
do armazenamento avisa e prossegue quando o compartilhamento não responde,
e as etapas de publicação após o boot são relatadas, mas nunca fatais. Sob
`Stop`, cada um desses resultados previstos encerra a inicialização, e seu
motivo fica em um console que já desapareceu quando alguém lê o log da execução.

Quando uma condição precisa interromper o script, ela o faz com
um `Write-Error` explícito seguido de `exit`, como nas verificações prévias
que bloqueiam a execução. Isso mantém cada decisão de interrupção no ponto
que a toma, em vez de espalhá-la por todos os auxiliares que o script chama.

<a id="42fffc2c-000c"></a>

<a id="a-service-that-never-served-fails-loudly"></a>

### Um serviço que nunca atendeu apresenta uma falha explícita

Uma inicialização que termina sem nenhum daemon atendendo retorna um código
diferente de zero, a menos que o SSH confirme que o cloud-init ainda está
executando ou não foi iniciado: essa construção inacabada corresponde ao
resultado não fatal `StillBuilding` descrito acima, com um marcador inativo.
Nos demais casos, um aviso seguido de zero inseriria `<service>: PASS` no resumo
de uma execução para um serviço com falha, pois o chamador registra o código
de saída do script como resultado da etapa.

**Um IP não comprova prontidão.** `New-VM` confirma que a VM tem um
endereço, mas o daemon ainda precisa ser compilado DENTRO do convidado --
apt, a cadeia de ferramentas Go, a própria compilação, uma montagem CIFS e,
por fim, a inicialização pelo systemd -- o que leva vários minutos no
primeiro boot. Consulte `:80` até realmente atender antes de declarar sucesso.

**Colete as evidências antes de sair.** Uma inicialização com falha é o
único momento em que o convidado ainda está em execução e pode responder;
por isso, o log de compilação do convidado, o status do cloud-init e o
journal do serviço são coletados pela chave SSH do executor antes de o
script sair, e o operador vê o motivo sem precisar entrar por SSH às cegas.
`/var/log/cloud-init-output.log` só pode ser lido por root -- um `tail`
simples pela conta do serviço retorna `Permission denied` --; por isso, o
seed dá sudo NOPASSWD à conta `<service>-admin`, e a captura lê o log por
`sudo`. Fixe essa conta com `-User`: é o único login da VM, e
`Get-GuestSshUser` retornaria, de outra forma, uma substituição propagada por
ciclo que uma execução anterior na mesma sessão de shell deixou registrada
para a chave do convidado.

**Informe o que aconteceu, não o que o limite de tempo permitia.** Falhas
muito diferentes chegam a esse ponto -- um endereço que nunca respondeu;
esse endereço e um segundo encontrado pela consulta de último recurso,
também silencioso; apenas o endereço de último recurso; ou nenhum endereço
--, e citar o timeout nominal no último caso descreve uma espera que nunca
ocorreu. Isso leva o leitor a procurar uma longa compilação no convidado
para uma falha que levou segundos. Informe todo endereço ao qual esse
hospedeiro tentou se conectar, pois a próxima ação do leitor é comparar o
endereço do próprio convidado com eles; um endereço omitido é um que ele
não consegue descartar.

<a id="42fffc2c-000d"></a>

<a id="bring-up-knobs"></a>

## Opções de inicialização

Dois conjuntos, em lados opostos do limite.

**No convidado**, cada script de inicialização lê suas próprias variáveis
`<SERVICE>_*` do ambiente em que o cloud-init o executa, e todas possuem um
padrão funcional -- uma variável não definida é o caso normal, não uma
configuração ausente. Seus valores são incorporados à unit systemd do
daemon; assim, um valor só passa a valer na inicialização que o incorpora.

| Serviço | Variáveis |
|---|---|
| `stash-service` | `STASH_HTTP_ADDR` (`0.0.0.0:80`; defina como VAZIO para desativar a interface -- o script usa `-` em vez de `:-` para manter um valor vazio), `STASH_AGGREGATOR_URL` (substitui o valor preparado em `pool.env`), `STASH_PRESENCE_INTERVAL`, `STASH_POOL_WINDOW_DAYS` (`30`), `STASH_BUILD_TAGS` (vazio; `-tags magika` habilita na imagem o backend de detecção ONNX, que também exige o runtime e os arquivos do modelo incluídos como dependências locais) |
| `download-agent-service` | `DOWNLOAD_AGENT_HTTP_ADDR` (`0.0.0.0:80`), `DOWNLOAD_AGENT_PRESENCE_INTERVAL`, `DOWNLOAD_AGENT_AUTH_TOKEN_FILE` (`/etc/yuruna/internal-auth.key`; um arquivo ausente desativa o caminho bearer, em vez de abri-lo) |
| `pool-control-service` | `POOL_CONTROL_HTTP_ADDR` (`0.0.0.0:80`), `POOL_CONTROL_PRESENCE_INTERVAL`, `POOL_CONTROL_AUTH_TOKEN_FILE`, `POOL_CONTROL_SCAN_CIDR` (vazio = derive o /24 ao redor do endereço do próprio daemon), `POOL_CONTROL_SCAN_PORT` (`8080`), `POOL_CONTROL_SCAN_INTERVAL` (`15m`; vazio desativa a varredura e é passado ao daemon como `0`, pois uma duração vazia gera erro de parsing da opção -- a opção de desligar do operador não deve tornar o serviço incapaz de iniciar) |

`<SERVICE>_PRESENCE_INTERVAL` é a cadência do beacon e tem padrão `2m` nos
três serviços. Ela deve permanecer abaixo da tolerância de saúde de cinco
minutos do agregador; consulte
[o manifesto](#1-the-manifest----what-the-area-declares).

**No hospedeiro**, cada `Start-<Service>VM.ps1` espera o daemon responder em
`:80`, e a espera pode ser substituída, pois o primeiro boot compila o
daemon dentro do convidado:

- `YURUNA_STASH_SERVICE_READY_TIMEOUT_SECONDS`
- `YURUNA_POOL_CONTROL_SERVICE_READY_TIMEOUT_SECONDS`
- `YURUNA_DOWNLOAD_AGENT_SERVICE_READY_TIMEOUT_SECONDS`

Os três têm padrão de **2700** segundos e aceitam um inteiro positivo;
qualquer outro valor é ignorado com uma nota verbose, em vez de causar falha
na inicialização. O valor é um mínimo, não um máximo: a espera se estende
além dele -- até, no máximo, o dobro -- enquanto o próprio convidado
responder por SSH que o cloud-init está executando ou não foi iniciado, para que
um hospedeiro lento não seja reprovado por uma compilação em progresso. O
motivo usual para definir uma dessas variáveis é o caso contrário: um valor
curto para uma verificação rápida de uma VM já em execução.

<a id="42fffc2c-000e"></a>

<a id="running-the-caching-proxy-service-from-another-host"></a>

## Execução do serviço caching-proxy a partir de outro hospedeiro

O daemon `caching-proxy-service` é o único serviço de extensão escrito para
rodar fora da VM que descreve. Tudo o que lê é uma API ou um arquivo em um
compartilhamento -- nunca um socket local nem uma chamada ao systemd --;
por isso, o mesmo binário responde na VM do proxy ou em uma máquina que
consiga alcançá-la.

**O plano de dados nunca é movido.** Squid (`:3128`, `:3129`), zot (`:5000`),
Grafana, Prometheus, Loki e os exportadores permanecem na VM
caching-proxy-service em ambos os modos. O que muda de lugar é o plano de
gerenciamento: leitura de estado e alteração de opções. Movê-lo proporciona
isolamento -- um plano de gerenciamento que sobrevive à máquina sobre a
qual informa -- e custa um salto de rede por leitura.

| | `--mode local` (padrão) | `--mode remote` |
|---|---|---|
| Resumo do Squid | páginas de gerenciamento por loopback | páginas de gerenciamento pela LAN, que exige a ACL abaixo |
| estado das opções | os próprios arquivos em `conf.d` | inferido da configuração em execução do Squid, com essa indicação |
| alterações de opções | grava o arquivo de configuração, `squid -k reconfigure` | **501 `caching-proxy-remote-readonly`** |
| catálogo do zot | API do zot por loopback | API do zot pela LAN |
| veredito canary | `/zot-meta` por loopback | `/zot-meta` pela LAN |
| registro de pré-aquecimento | `/var/lib/yuruna` na máquina | ausente, a menos que o compartilhamento esteja montado |

O modo remoto é **somente leitura e recusa a operação, em vez de simular
sucesso**. O Squid padrão não oferece reconfiguração remota: uma alteração
feita fora da máquina poderia ser gravada, mas nunca carregada; por isso,
as duas rotas de opções respondem `501` com motivo
`caching-proxy-remote-readonly` e informam o modo que recusou. Isso descreve
uma característica do Squid, não das permissões -- por isso, a resposta é
`501`, não `403`, e seria necessário um agente na própria máquina para
remover essa limitação.

**A ACL de gerenciamento é o único pré-requisito e não cabe em um arquivo
adicional de configuração.** O `squid.conf` padrão executa
`http_access deny manager` muito antes de incluir `conf.d/*.conf`, e
`http_access` usa a primeira regra correspondente -- portanto, uma regra de
permissão acrescentada em um arquivo adicional não tem efeito. Abrir a
interface de gerenciamento a um leitor remoto exige editar o próprio
`squid.conf` acima dessa negação e combiná-la com um `cachemgr_passwd`.
O seed distribuído não faz isso: o modo local não precisa dessa alteração
(loopback já é permitido pelo `allow localhost manager` padrão), e abrir a
interface de gerenciamento do Squid à LAN é uma mudança de política que
nenhuma VM deve receber para um modo que não executa.

<a id="42fffc2c-000f"></a>

<a id="mcp-endpoints"></a>

## Endpoints MCP

Todo daemon Go, exceto `caching-proxy-parser-service`, atende ao Model
Context Protocol em `POST /mcp` na porta em que já escuta; o framework
central o atende por stdio. A regra que fundamenta toda a interface é que
**MCP acrescenta um protocolo, nunca uma segunda verdade**: uma ferramenta
encapsula uma rota ou um script existente e herda o controle que essa rota
já declara.

Isso é imposto pela estrutura, não por disciplina. Esses daemons constroem
os payloads de leitura dentro do handler; uma ferramenta escrita à mão
exigiria manter a mesma estrutura duas vezes. Em vez disso, `mcp.FromRoute`
CHAMA o handler da rota dentro do processo e retorna o que ele escreveu.
Um corpo, produzido uma vez, por uma função -- a ferramenta não pode
responder de maneira diferente da rota que encapsula, e as suítes de cada
daemon verificam que as duas respostas são iguais.

| Serviço | Endpoint | Ferramentas |
|---|---|---|
| `pool-aggregator-service` | `POST :9400/mcp` | `pool_status`, `pool_extension_hosts`, `pool_stats`, `pool_incidents`, `pool_cycle_links`, `pool_health` |
| `caching-proxy-service` | `POST :9310/mcp` | `caching_proxy_status`, `caching_proxy_recent_requests`, `caching_proxy_switches`, `caching_proxy_hostinfo` e as ferramentas com controle de acesso `caching_proxy_set_offline` / `caching_proxy_set_no_upstream` |
| `stash-service` | `POST :80/mcp` | `stash_list`, `stash_get`, `stash_host`, `stash_hostinfo`, `stash_session` e a ferramenta com controle de acesso `stash_refresh` |
| `pool-control-service` | `POST :80/mcp` | `pool_control_board`, `pool_control_hosts`, `pool_control_host_facts`, `pool_control_state`, `pool_control_diagnostics`, `pool_control_hostinfo`, `pool_control_scan_status`, `pool_control_host_control_state` e as ferramentas com controle de acesso `pool_control_add_host`, `pool_control_move_host`, `pool_control_remove_host`, `pool_control_set_host_control`, `pool_control_set_pool_repositories` e `pool_control_refresh_host` (listada apenas enquanto a atualização remota está provisionada) |
| `download-agent-service` | `POST :80/mcp` | `download_agent_status`, `download_agent_images`, `download_agent_image`, `download_agent_session`, `download_agent_diagnostics`, `download_agent_hostinfo` e as ferramentas com controle de acesso `download_agent_refresh_image` / `download_agent_prune_image` |
| framework central | `test/service/Start-McpServer.ps1` (stdio) | os dez pontos de entrada de `automation/` |

`caching-proxy-parser-service` fica deliberadamente de fora: ele não possui
nenhum mecanismo de autenticação; portanto, não há um controle a ser herdado
por uma ferramenta de alteração, nem algo que torne as ferramentas de
somente leitura uma decisão considerada, em vez de um padrão.

A interface HTTP é atendida por `extension-sdk/mcp`, um pacote construído
com `net/http` e `encoding/json`, em vez do SDK oficial de MCP. Quatro dos
cinco daemons que o disponibilizam usam apenas a biblioteca padrão por
decisão de projeto: são compilados dentro de suas próprias VMs durante a
inicialização, com fontes baixadas arquivo por arquivo, sem cache de módulos
e, muitas vezes, sem acesso a um registro. Acrescentar o SDK oficial o
tornaria a primeira dependência externa de cada um deles, e essa dependência
chegaria pelo próprio caching proxy gerenciado por um desses serviços. O
subconjunto do protocolo necessário a um serviço que realiza principalmente
leituras -- ferramentas por HTTP, sem recursos, prompts ou sampling -- é
pequeno o bastante para que mantê-lo seja mais barato que manter a
dependência. Recursos, prompts, sampling, solicitações iniciadas pelo
servidor e um fluxo SSE estão, portanto, ausentes deliberadamente, não
inacabados: cada método aqui tem uma solicitação e uma resposta, uma
notificação recebe `202` sem corpo, e nenhum desses itens pode ser
acrescentado sem também acrescentar um modelo de sessão que o pacote não tem.

<a id="42fffc2c-0010"></a>

<a id="what-a-tool-may-do-and-who-decides"></a>

### O que uma ferramenta pode fazer e quem decide

A anotação de cada ferramenta faz a mesma declaração que sua rota:

- **Ferramentas de somente leitura dispensam o controle** e têm exatamente
  a exposição da rota GET que encapsulam -- aberta na LAN confiável, como
  `pool-status`. Controlar esse acesso tornaria uma credencial necessária
  para ler um painel.
- **Ferramentas de alteração passam pelo labgate do próprio daemon**, com
  as mesmas três respostas das rotas HTTP: `503` com motivo
  `auth-unconfigured` quando o serviço não tem nenhuma forma de acesso
  configurada; equivalente a `401` quando o controle existe e o chamador
  ainda não o passou; e acesso permitido nos demais casos.
- **Uma ferramenta pode exigir mais que o controle do daemon.**
  `mcp.Tool.Gate` é um segundo controle avaliado na mesma solicitação
  recebida, após o controle do servidor e somente se este a admitiu;
  ambos precisam permitir o acesso, portanto o segundo só pode restringir.
  O handler executa uma solicitação sintetizada sem credencial; por isso,
  uma credencial específica da rota só pode ser verificada aqui.
  `pool_control_refresh_host` o usa para a credencial de atualização, e
  uma ferramenta de somente leitura não pode ter esse controle.
- **Uma recusa de domínio mantém seu próprio token.** Um daemon caching-proxy
  em modo remoto recusa `caching_proxy_set_offline` com
  `caching-proxy-remote-readonly`, a mesma string de seu corpo `501`; assim,
  um operador que conhece uma resposta reconhece a outra.

Quatro dos cinco daemons que disponibilizam MCP oferecem ferramentas de
alteração; o agregador não oferece nenhuma. Cada serviço também deixa de expor
determinadas alterações: as do agregador abrangem um fluxo intenso de telemetria
e uma rota que exclui evidências que um operador pode estar lendo; pool-control
não expõe a criação de grupos, a exclusão de grupos (que faz commit e push do
armazenamento de configuração do grupo) nem varreduras de rede;
o `DELETE` de stash alcança o stash de todos os hospedeiros na montagem
compartilhada, não apenas o próprio; e a rota `ensure` do download agent é
**deliberadamente sem controle de acesso** no HTTP. Por isso, uma ferramenta
para ela não conseguiria refletir o controle da rota e cumprir a regra de
que uma ferramenta de alteração exige o token do laboratório. Essa
contradição precisa ser resolvida antes de haver uma ferramenta para ela.

<a id="42fffc2c-0011"></a>

<a id="why-stdio-for-the-core-and-only-stdio"></a>

### Por que o framework central usa stdio e apenas stdio

Os pontos de entrada do framework central são scripts que um operador
executa em sua própria máquina; por isso, seu servidor roda em primeiro
plano sobre stdin/stdout, sem listener, token ou controle de acesso. O
transporte É o modelo de confiança: um processo que lê o stdin de um
operador foi iniciado por esse operador e pode fazer exatamente o que ele
já faria digitando o mesmo comando. Uma credencial aí não protegeria nada
e sugeriria um limite que não existe.

Esse servidor também interpreta cada ponto de entrada conforme sua forma
real de responder, pois elas não são uniformes: `Test-Runtime` não possui
uma instrução de saída e informa seu veredito no último objeto do pipeline;
`Get-SystemDiagnostic` sempre retorna 0, de modo que zero significa que o
relatório foi produzido, nunca que o hospedeiro está saudável;
`Check-DependencyVersion` emite JSON nativamente, repassado sem alteração;
e `Set-HostAlias` não grava transcript, de modo que uma exceção é seu único
sinal de falha. Interpretar qualquer um deles apenas pelo código de saída
informa o resultado errado.

<a id="42fffc2c-0012"></a>

<a id="connecting-a-client"></a>

### Conexão de um cliente

```json
{
  "mcpServers": {
    "yuruna-core": {
      "command": "pwsh",
      "args": ["-NoProfile", "-File", "test/service/Start-McpServer.ps1"]
    },
    "yuruna-pool": { "url": "http://<proxy>:9400/mcp" },
    "yuruna-cache": { "url": "http://<proxy>:9310/mcp" }
  }
}
```

Um erro JSON-RPC ainda é HTTP `200`: a camada RPC respondeu; um status
diferente de 200 indicaria falha de transporte, um fato diferente que leva o
leitor a procurar no lugar errado. Notificações recebem `202` sem corpo.

<a id="42fffc2c-0013"></a>

<a id="which-framework-snapshot-a-service-vm-is-built-from"></a>

## Snapshot do framework usado para construir uma VM de serviço

Os daemons dos serviços de extensão são binários Go cuja versão é gravada
na COMPILAÇÃO, a partir do arquivo `VERSION` do checkout baixado pelo
convidado. Nada volta a lê-la depois: o convidado compila uma vez, e o
número apresentado na interface, em `/api/hostinfo` e em todos os payloads
de diagnóstico permanece fixo durante toda a vida da VM.

A gravação é uma opção do linker, não um arquivo aberto pelo daemon. Cada
inicialização do convidado lê o `VERSION` do checkout, mantém a primeira
linha com os espaços em branco removidos (um newline final ou CRLF passaria,
de outra forma, a fazer parte da string de versão), usa `dev` se o arquivo
estiver ausente ou vazio e compila com:

```
go build -ldflags "-X main.version=$VERSION_STR" -o <daemon> .
```

Todo daemon declara, portanto, uma `var version` no escopo do pacote,
substituída pelo linker. Sem a opção, a compilação ainda termina com sucesso
-- a variável mantém seu valor zero, o rodapé da interface mostra `dev` ou
nada, e `Assert-ServiceVmFrameworkSource` não consegue mais identificar de
qual checkout veio a VM. Por isso, a suíte de cada daemon verifica o campo
`version` de `/api/hostinfo`, não apenas sua estrutura.

Isso torna o download decisivo. O seed cloud-init baixa o checkout desse
hospedeiro pelo serviço de status (`/yuruna-archive.tar.gz`, com os dados de
localização lidos por sed de `/etc/yuruna/host.env`, nunca carregados por
source) e recorre ao clone do mirror público no GitHub se o hospedeiro não
responder, para que a inicialização continue funcionando fora da LAN. As
duas fontes NÃO são equivalentes: o hospedeiro serve o checkout em que o
operador trabalha, enquanto o mirror é um snapshot publicado que fica
atrasado pelo tempo decorrido desde o último push de release. A fonte que
responder é compilada no daemon minutos depois; assim, um fallback
silencioso para o mirror implanta código mais antigo que depois se apresenta
como atual indefinidamente.

O serviço de status precisa, portanto, estar em execução ANTES de
`New-VM` preparar e iniciar o convidado, não depois -- um servidor iniciado
mais tarde nunca foi visto pelo convidado. A inicialização conserva o
registro `{ShouldStart; Port}` produzido por essa decisão, em vez de
descartá-lo, pois a verificação posterior da fonte do framework precisa
consultar a porta definida nessa decisão; recalculá-la seria uma segunda
leitura da mesma configuração, capaz de discordar da leitura que iniciou
o servidor.

Duas verificações delimitam a compilação, e apenas uma constitui evidência:

- **Antes da compilação**, `Assert-GuestFrameworkSource` recusa uma
  inicialização cujo convidado não poderia alcançar o checkout desse
  hospedeiro. É uma interrupção antecipada e barata que evita a longa
  compilação no convidado, nada mais. Ela não comprova qual endereço o seed
  incorporará, pois isso é definido por tipo de hospedeiro dentro de
  `New-VM.ps1`.
- **Depois que o daemon atende**, `Assert-ServiceVmFrameworkSource` lê o
  que o convidado REALMENTE fez (`/etc/yuruna/framework-source`, gravado
  pelo seed e deixado legível por todos para que a conta não privilegiada
  do serviço possa lê-lo) e compara com o que o daemon realmente informa
  (`/api/hostinfo`). Essa verificação é autoritativa e é a que faz a
  inicialização falhar.

Essa separação é essencial: a verificação prévia é uma previsão, e a
verificação após o boot é uma observação; portanto, apenas a segunda pode
ser usada para afirmar que um serviço implantado executa código atual. A
verificação prévia pode passar e o convidado ainda recorrer ao fallback --
o endereço do hospedeiro é incorporado ao seed, e o convidado tenta
acessá-lo minutos após o primeiro boot; assim, se o hospedeiro mudar de
endereço nesse intervalo, o download vai para o mirror, embora tudo deste
lado pareça correto.

Uma divergência faz a inicialização falhar, mas NÃO retira o marcador de
execução. Uma compilação desatualizada ainda é um serviço em execução;
remover sua linha substituiria um anúncio correto por um falso. O erro
está na declaração da inicialização de que implantou esse checkout;
portanto, é essa declaração que falha. `-AllowMirrorSource` é a exceção
deliberada para uma inicialização fora da LAN: reduz ambas as verificações
a avisos, e o serviço passa a executar código publicado intencionalmente.

As duas verificações informam uma *versão*, um número de release
compartilhado por muitos commits. Informar o *commit* exige algo a mais,
pois `git archive` remove `.git/`, e um convidado inicializado pelo tarball
não possui um repositório para consultar. Por isso, o arquivo inclui dois
arquivos auxiliares na raiz, gravados pelo único streamer compartilhado
pelos dois endpoints de arquivo: `.yuruna-origin` registra o repositório de
origem da árvore, e `.yuruna-revision` registra o nome completo do objeto do
commit usado para gerar o arquivo. O commit é resolvido antes da geração,
e o arquivo é gerado a partir desse nome de objeto, não de `HEAD`; assim,
um commit que chega durante a solicitação não deixa o arquivo auxiliar
descrevendo uma árvore que o tarball não contém.

Os diagnósticos de pool-control os leem nessa ordem: `git rev-parse` quando
o checkout é um repositório, `.yuruna-revision` quando é um arquivo
extraído. Um arquivo auxiliar malformado, ou que contradiga um
`git rev-parse` funcional, não informa revisão e faz a verificação
`framework-revision` falhar, em vez de oferecer um valor não confiável --
uma árvore com repositório e arquivo auxiliar contraditório mistura fontes;
nesse caso, nenhuma das metades descreve o que está implantado.

<a id="42fffc2c-0014"></a>

<a id="finding-a-service-this-host-does-not-run"></a>

## Encontrar um serviço que este hospedeiro não executa

Um hospedeiro que precisa de um serviço de rede — o serviço stash, pool-control service,
download-agent service — geralmente não o executa: o serviço está em outro
hospedeiro, muitas vezes em outra sub-rede, com um endereço que o DHCP pode alterar.
A configuração deste hospedeiro não informa onde ele está; a alternativa seria um
endereço literal fixo, correto apenas até o serviço mudar — quando um ciclo
passaria todo o seu tempo limite tentando acessar uma máquina que já não existe.

`Get-ExtensionHostAddress` é a única chamada que o código cliente faz em seu lugar:

```powershell
Import-Module test/modules/Test.Extension.psm1 -Force -DisableNameChecking
# @() because a single address unrolls to a scalar, and an empty result to
# nothing at all -- the same rule as Get-ActiveExtensionName.
$addresses = @(Get-ExtensionHostAddress -HostType 'stash-service')
foreach ($address in $addresses) {
    if (Test-StashServiceHost -Address $address) { $stash = $address; break }
}
```

`-HostType` é o **slug da área de extensão** que identifica o tipo de serviço
(`stash-service`, `pool-control-service`, `download-agent-service`) — sem relação
com o tipo de hospedeiro de hipervisor retornado por `Get-HostType` (`host.windows.hyper-v`).

A resposta é uma **lista, com os endereços mais próximos primeiro**, e pode estar vazia:

| Ordem | Origem | Atende a |
|---|---|---|
| 1 | `$env:YURUNA_EXTENSION_HOST_<AREA>` — área em maiúsculas, caracteres não alfanuméricos -> `_` (por exemplo, `YURUNA_EXTENSION_HOST_STASH_SERVICE`, `YURUNA_EXTENSION_HOST_DOWNLOAD_AGENT_SERVICE`) | um operador que informa um endereço; essa escolha é intencional, portanto nenhuma descoberta tem precedência sobre ela |
| 2 | Contrato do hospedeiro `Get-VMIp` em `yuruna-<area>` (substitua com `-VMName`; `''` ignora essa origem) — `yuruna-stash-service`, `yuruna-pool-control-service`, `yuruna-download-agent-service` | uma VM de serviço executada **neste** hospedeiro, em seu endereço atual após reconstruções |
| 3 | O grupo — [`/api/v1/extension-hosts`](../../test/extension/pool-aggregator-service/README.md#endpoints-9400) do agregador, consultado por `Get-PoolExtensionHost` | um serviço executado em **outro** hospedeiro, a partir do próprio registro/anúncio — e apenas em um endereço que o próprio agregador tenha alcançado (veja [abaixo](#only-an-address-the-pool-has-reached-is-answered)) |

Como o agregador está na VM caching-proxy-service, conhecer o endereço do proxy
— de que todo hospedeiro já precisa para acessar o cache — basta para localizar
qualquer outro serviço oferecido pelo grupo. Um hospedeiro sem caching-proxy-service
não tem agregador para consultar nem grupo: essa origem não acrescenta nada.

A resposta é uma lista porque apenas o chamador pode determinar qual endereço
é utilizável: ele dispõe da verificação (a checagem prévia do stash exige
`/healthz`, e `Test-DownloadAgentServiceHost` verifica cada candidato de
download-agent da mesma forma), pode preferir uma sub-rede específica e normalmente
tem uma última alternativa própria do ambiente para acrescentar. **Cada entrada
é uma indicação, nunca uma promessa** — verifique uma delas antes de destinar
um ciclo a ela. A consulta não exige autenticação nem verifica o certificado TLS
final do agregador (emitido pela própria CA do proxy, sem entrada de confiança no
repositório de certificados do hospedeiro do ambiente de testes); a resposta contém endereços de
serviços na LAN, não um segredo, e uma resposta errada é rejeitada pela verificação
do chamador.

A chamada nunca lança uma exceção. Cada origem é independente — um grupo que não
responde, um contrato de hospedeiro sem `Get-VMIp`, uma área não atendida — e qualquer
origem vazia reduz a lista. Endereços com espaços em branco ou aspas são
descartados: eles são incorporados a URLs, destinos de `scp` e linhas de ambiente
do convidado entre aspas simples, nas quais um valor assim corrompe o comando em vez
de apenas fazê-lo falhar.

O `Resolve-Host` da extensão stash (a expansão de
`${ext:stash-service.ResolveHost(<vm>)}`) consulta essa função por último,
depois da VM local e do endereço já verificado pela checagem prévia do ciclo.

<a id="42fffc2c-0015"></a>

<a id="asking-the-pool-directly-and-why-an-empty-answer-is-not-one-answer"></a>

#### Consultar o grupo diretamente e por que uma resposta vazia não tem um único significado

A origem 3 é o próprio módulo da área pool-aggregator, e um chamador que queira
apenas essa origem pode usá-lo diretamente:

```powershell
$address = Get-PoolExtensionHostFrom -BaseUrl $aggregatorUrl -Area 'stash-service'
if (-not $address) {
    $why = Get-PoolExtensionHostLastOutcome
    # $why.Outcome: 'no-host' | 'http-error' | 'transport-error' | 'no-aggregator' | 'ok' | 'none'
}
```

`Get-PoolExtensionHostFrom` retorna uma string simples para nunca lançar uma
exceção no ciclo; assim, todas as falhas parecem iguais no ponto da chamada.
Duas delas têm significados muito diferentes: **`no-host`** é uma resposta
conclusiva — o grupo informa que ninguém atende essa área — enquanto
**`transport-error`** descreve a conexão do próprio solicitante e normalmente
se resolve sozinha. Um chamador que interrompe um ciclo por causa da string vazia
relata a primeira situação quando observou a segunda, levando o operador a
procurar um serviço que esteve em execução o tempo todo.

`Get-PoolExtensionHostLastOutcome` guarda o motivo: uma hashtable com
`Outcome`, `Detail` e `Uri`. Ela **tem escopo de sessão e é sobrescrita a cada
consulta**; portanto, leia-a imediatamente após a chamada correspondente.
Uma falha de transporte também gera um aviso em vez de apenas uma mensagem de
log detalhada, porque esse tipo de falha interrompe ciclos.

<a id="42fffc2c-0016"></a>

<a id="only-an-address-the-pool-has-reached-is-answered"></a>

### A resposta contém apenas um endereço que o grupo tenha alcançado

A origem 3 responde com um endereço **que o próprio agregador confirmou** em
`<target>/healthz` e confirma novamente a cada consulta periódica. Isso evita
uma classe de resposta errada contra a qual o consumidor não pode se proteger:
um endereço que existe no hospedeiro que o anunciou, mas é inacessível em qualquer
outro lugar.

Um hospedeiro executa dois tipos de rede de convidado — a LAN que compartilha com as demais
máquinas e uma rede privada do hipervisor, visível apenas para ele (a vmnet
compartilhada do macOS, um Hyper-V Default Switch, o `virbr0` do libvirt).
Para esse hospedeiro, ambas parecem iguais: um endereço RFC 1918 em uma interface ativa,
respondendo em `/healthz`. Assim, uma VM stash iniciada na rede privada é
confirmada de boa-fé e registrada para todo o grupo; cada OUTRO hospedeiro a resolve e
gasta todo o seu tempo limite tentando alcançar uma máquina para a qual não tem
rota — depois disso o ciclo é interrompido, sem ter construído nada.

Duas verificações eliminam esse problema, nos dois pontos que conseguem observar
uma parte dele:

- o **hospedeiro proprietário** recusa anunciar um endereço fora da própria rede
  voltada para o grupo (`Update-StashServiceMarkerAddress`, avaliado por
  `Get-Ipv4PoolSegmentVerdict`), de modo que o endereço nunca entra em
  `host.registration.json`. Ele apenas *recusa*, nunca impõe uma restrição:
  um segmento indeterminável é permitido, e o serviço continua utilizável localmente;
- o **agregador** recusa qualquer endereço que ele próprio não consiga alcançar,
  independentemente da origem que o informou, e deixa de responder com um endereço
  confirmado que permaneça sem resposta por 5 minutos. Ele está na mesma posição
  dos consumidores; portanto, sua verificação é a única que representa o grupo
  em vez de apenas um hospedeiro.

Um endereço recusado fica **suprimido, não é esquecido**: a entrada permanece,
registrando o endereço recusado e o motivo, até que o TTL do anúncio ou uma
mensagem de despedida a remova. Normalmente, um endereço deixa de responder porque
o serviço mudou de endereço e anuncia o novo dentro de um período de beacon —
por isso `beaconInterval` deve permanecer abaixo desses 5 minutos. Se for mais
lento, o grupo fica sem nenhum dos dois endereços durante a diferença entre os
períodos: a área não resolve para nada, embora o serviço continue ativo e acessível
por todo esse tempo. Manter a entrada também torna a falha compreensível, como
`yuruna_pool_extension_unreachable` e uma entrada `suppressed` em `services`
de `/api/v1/extension-hosts` — "anunciado em X, que não responde", em vez de uma
ausência sem explicação.

A seção *Serviços de extensão (registro do grupo)* de `Test-Config.ps1` mostra
o que o grupo mantém — inclusive um registro que recusou e outro que ainda anuncia,
mas que este hospedeiro não consegue alcançar — para que toda essa classe de problemas
seja visível antes do início de um ciclo, em vez de apenas depois de uma falha.

<a id="42fffc2c-0017"></a>

<a id="why-get-activeextensionname-wrap"></a>

## Por que envolver `@(Get-ActiveExtensionName)`

O pipeline do PowerShell transforma um array com um único elemento em um escalar.
Uma configuração com uma entrada `active:` retorna a string `'default'`;
indexar `$names[0]` retorna o caractere `'d'`, não o nome. Use sempre:

```
$names = @(Get-ActiveExtensionName -Area 'authentication')
$extName = $names[0]
```

<a id="42fffc2c-0018"></a>

<a id="why-import-extension-matches-by-absolute-path"></a>

## Por que `Import-Extension` faz a correspondência pelo caminho absoluto

Quando duas áreas fornecem um `default.psm1`, ambos os módulos são registrados
com o mesmo nome de módulo do PowerShell, `'default'`. `Get-Module -Name default`
retorna o que foi importado por último; assim, `Get-Command -Module default
Get-Password` pode resolver para o módulo da área errada.
`Resolve-ExtensionMethod` compara os módulos pelo caminho absoluto de `.psm1`,
garantindo que as exportações pretendidas sejam encontradas.

<a id="42fffc2c-0019"></a>

<a id="adding-a-new-extension-to-an-existing-area"></a>

## Adicionar uma nova extensão a uma área existente

1. Crie `<extname>.psm1` em `test/extension/<area>/`.
2. Acrescente `<extname>` à lista `active:` em `<area>.config.yml`.
3. O carregador a importa no próximo ciclo; referências no YAML da sequência
   a `${ext:<area>.Method(...)}` são encaminhadas ao novo módulo se ele
   exportar `Method`.

Para `notification`, várias extensões ativas são percorridas na ordem de
declaração — cada transporte recebe todos os eventos. Para `authentication`,
o carregador exige **exatamente uma** extensão ativa e lança uma exceção em
caso de ambiguidade (`-RequireSingle`).

<a id="42fffc2c-001a"></a>

<a id="adding-a-new-area"></a>

## Adicionar uma nova área

1. Crie `test/extension/<newarea>/` com um `default.psm1` e um
   `<newarea>.config.yml`.
2. A existência da área a acrescenta à
   [matriz de capacidades](../test-harness.md#capability-matrix-and-cycle-plan-gate) —
   `Get-CapabilityExtensionArea` descobre áreas pelo diretório, sem
   uma lista fixa no código.
3. Documente o contrato que os arquivos `.psm1` da área devem exportar.
   Uma melhoria futura é publicar esquemas JSON junto das configurações (a pasta
   [`test/schemas/`](../../test/schemas/) já contém
   `extension-config.schema.yml` para o envelope comum, que também
   valida o manifesto `service:`).

Para uma área que seja um **serviço na rede**, em vez de código carregado pelo
ciclo, siga [Criar um novo serviço de extensão](#building-a-new-extension-service):
esse procedimento acrescenta o manifesto, o SDK e o marcador a estas etapas.

<a id="42fffc2c-001b"></a>

## POST /announce (pool-aggregator-service)

`handleAnnounce` em `test/extension/pool-aggregator-service/main.go` é a
interface de gravação da presença de extensões: uma VM de serviço (por exemplo,
o beacon do serviço stash) envia por POST `{hostId, area, targetPort, active}`
na inicialização, a cada período de beacon e com `active=false` no desligamento,
para que a linha Extension hosts do painel permaneça disponível quando o serviço
de status do hospedeiro proprietário estiver fora do ar (situação comum após uma
reinicialização do hospedeiro). A rota é deliberadamente aberta (sem bearer, ao
contrário de `/ingest`), porque exigir a chave compartilhada de autenticação
interna impediria o beacon justamente onde ele é necessário. A contenção usa:

1. **Vínculo com a própria identidade** — a URL do serviço anunciado é derivada
   do IP de origem da conexão (ou deve corresponder a ele), de modo que um
   anunciante só pode anunciar a si próprio; o endereço também deve ser roteável
   pelo grupo (loopback, link-local, multicast e valores que não sejam URLs são
   rejeitados com `400`).
2. **Apenas telemetria** — preenche uma linha do painel e um destino de
   redirecionamento; não oferece plano de controle, verificação de hospedeiros nem
   contabilização de ciclos.
3. **Limites definidos** — limite pequeno para o corpo, conjuntos de caracteres
   estritos para hostId/area, no máximo `maxAnnounce` entradas e remoção por TTL.
4. **Mensagens de despedida removem apenas uma entrada pertencente à mesma origem.**
5. **Confirmação antes da resposta** — o manipulador verifica um endereço
   recém-anunciado em `/healthz` (veja
   [acima](#only-an-address-the-pool-has-reached-is-answered)), e a consulta
   periódica o confirma novamente; uma entrada que permaneça sem resposta por
   5 minutos é suprimida até que um novo anúncio a restaure ou o TTL do anúncio
   a remova. Um anúncio é uma afirmação a verificar, não um fato a republicar.

**`2xx` significa registrado, não apenas recebido.** A entrada reside na memória
do coletor; a linha que o manipulador grava no Loki é a única cópia que sobrevive
a uma reinicialização, e a reidratação restaura a linha do painel depois.
Por isso, quando essa gravação não é concluída, o manipulador responde `503` —
o anúncio é mantido e disponibilizado, mas o anunciante recebe a indicação de
tentar novamente. Um beacon só repete as tentativas até o seu *primeiro* sucesso
e depois aguarda um período inteiro de novo anúncio; assim, um `2xx` para um
anúncio não registrado deixaria o grupo sem exibir um serviço saudável por um
período inteiro, em troca de uma repetição que levaria segundos. Os anunciantes
devem, portanto, tratar qualquer resposta diferente de `2xx` como "não concluído"
e manter a frequência de recuperação, como faz o `beacon` do SDK.
Um grupo configurado sem Loki escolhe não manter histórico de anúncios e ainda
responde `2xx`.

`-announce-ttl 0` desativa a rota.

`-host-ttl <duration>` (padrão `24h`) define por quanto tempo um hospedeiro permanece
na visão do grupo após seu último contato; a remoção retira a linha na consulta
periódica seguinte. Dois valores acompanham esse tempo em vez de serem
configurados separadamente, para que não possam ficar na ordem errada:

- o **estado de desduplicação por ciclo** (quais pares `hostId|cycleStartUtc`
  já foram contabilizados) é mantido por uma hora além da linha, para que um
  hospedeiro removido e depois reaparecido não possa recontar um ciclo terminal
  já contabilizado;
- a janela retrospectiva do Loki que resolve o endereço de um hospedeiro ausente para
  links diretos do painel — inclusive o redirecionamento `/go/host`, que emite
  uma prova de controle — acompanha o TTL quando ele aumenta, mas nunca fica
  abaixo de 24h; assim, reduzir o TTL não causa um 404 em um link que o painel
  ainda exibe. (`/go/cycle` e `/go/cycle-share` compartilham um resolvedor,
  e a correspondência da pasta do ciclo mantém uma janela fixa separada de 6h.)

Isso **não** limita os contadores cumulativos `yuruna_pool_cycles_pass_total` /
`_fail_total`: eles nunca expiram por tempo e permanecem até que o processo seja
reiniciado ou `POST /api/v1/forget-host` limpe esse hospedeiro. Reduzir o TTL também não
remove, por si só, um hospedeiro que continua sendo recriado a partir do feed de presença
na reinicialização — `Remove-PoolHost.ps1` / forget-host é o caminho determinístico.

Para alterá-lo, edite `pool-aggregator-service.service` e execute
`systemctl daemon-reload && systemctl restart pool-aggregator-service` — sem reconstrução.
**`daemon-reload` é obrigatório:** uma simples reinicialização executa novamente
a unidade mantida no cache do systemd, e o valor antigo continua em vigor.
Um drop-in também funciona, mas a unidade é `Type=simple`; portanto, ele deve
primeiro limpar `ExecStart` (`ExecStart=` em uma linha própria e depois a
substituição completa), ou o systemd se recusa a carregar o serviço.
Um valor não positivo usa o padrão de 24h. Binários mais antigos não têm essa
opção — em um proxy antigo, verifique
`pool-aggregator-service -h | grep host-ttl` antes de acrescentá-la, ou o serviço
entrará em um ciclo de falhas com `flag provided but not defined`.

<a id="42fffc2c-001c"></a>

<a id="when-the-caching-proxy-is-rebuilt"></a>

### Quando o proxy de cache é reconstruído

A URL do agregador usada pelo beacon é incorporada à seed do convidado no momento
de `New-VM` (`Get-PoolAggregatorServiceSeedUrl` -> `YURUNA_AGGREGATOR_URL` em
`/etc/yuruna/pool.env` -> `--aggregator-url`) e nunca é resolvida novamente
no convidado. Portanto, o novo registro automático de um hospedeiro de extensão depende
do endereço do proxy reconstruído, não da reconstrução em si:

- **Mesmo endereço** — sim, automaticamente, dentro de um período de beacon
  (2 min). O manipulador aceita um anúncio de um `hostId` que o grupo nunca viu e
  confirma o destino por conta própria; assim, a linha não exige descoberta
  anterior. A linha proveniente do *registro* leva mais tempo: um proxy
  reconstruído começa com o log do Squid e o Loki vazios, portanto o hospedeiro
  proprietário só é redescoberto quando voltar a obter conteúdo pelo proxy.
- **Novo endereço** — não. As reconstruções mantêm um MAC determinístico, a menos
  que ele seja sobrescrito, mas o DHCP ainda pode atribuir um novo endereço;
  o beacon continua enviando POST ao endereço que deixou de existir.
  Fixe o MAC do proxy em uma reserva DHCP
  ([caching.md](../caching.md#pinning-the-cache-vms-ip-stable-mac--dhcp-reservation))
  para que a reconstrução preserve o endereço, ou execute novamente o
  `Start-*ServiceVM.ps1` do serviço, que reconstrói a VM por meio de `New-VM.ps1`
  e incorpora o endereço atual.

Os próprios hospedeiros não precisam de nenhuma dessas ações: os consumidores do lado
do hospedeiro resolvem o proxy novamente a cada execução. A inscrição é separada — um
proxy reconstruído emite uma nova chave de autenticação interna; assim, cada hospedeiro
permanece *onsite* até que `Set-LabToken.ps1` o inscreva novamente
([control-routes.md](../control-routes.md#enabling-remote-control-on-a-host)).

<a id="42fffc2c-001d"></a>

## POST /api/v1/host-announce (pool-aggregator-service)

A contraparte de `/announce` no nível do hospedeiro: um **hospedeiro** envia por POST
`{"hostId":"<42-hex>","statusPort":<port>}` quando seu endereço muda,
quando seu serviço de status inicia e em um beacon periódico.

Essa rota existe porque a descoberta pelo log do Squid depende apenas da obtenção
de conteúdo e, por isso, atrasa justamente quando mais importa. Um hospedeiro só entra
no log quando ele ou seus convidados obtêm conteúdo pelo proxy; entre ciclos, a visão
fica desatualizada e mantém o endereço que o hospedeiro acabou de abandonar — e um convidado
que resolve por essa visão recebe uma resposta errada com aparência de certeza.
Essa rota atualiza o endereço do hospedeiro na visão lida por `pool-status`, pelos
redirecionamentos `/go/*` e pelo resolvedor do convidado. `/announce`, por sua vez,
representa a presença de *extensões* no escopo de uma área.

A contenção segue `/announce`, com uma verificação deliberadamente mais forte:

1. **Vínculo com a própria identidade.** O endereço vem da conexão, nunca do
   corpo; assim, um anunciante só pode anunciar a si próprio.
2. **Confirmado, não apenas aceito — pela identidade.** `/announce` verifica
   `/healthz`; esta rota obtém o `/runtime/status.json` do endereço anunciado e
   exige que o `hostId` ALI seja igual ao informado. A afirmação é uma identidade,
   portanto a identidade é o que se verifica: uma máquina que não consiga
   fornecer o `status.json` desse hospedeiro não pode assumir seu lugar apenas
   mudando o nome declarado.
3. **Limites definidos.** Os mesmos limites de corpo e conjunto de caracteres
   de hostId usados em `/announce`.
4. **Sem bearer**, pelo mesmo motivo de `/announce` — exigir a chave de
   autenticação interna impediria o beacon justamente nos laboratórios que
   precisam dele. A rota muda a localização de uma identidade existente e
   não concede nenhuma capacidade de plano de controle.

`400` cobre um corpo malformado, um hostId ou `statusPort` inválido, um endereço
para o qual o grupo não pode rotear, um endereço que não forneça `status.json`
e um endereço que forneça um hostId *diferente*. `503` quando `-announce-ttl`
é `0`. Como em `/announce`, um 2xx significa **registrado**, não apenas recebido.

<a id="42fffc2c-001e"></a>

## POST /api/v1/lab-token (pool-aggregator-service)

A troca de inscrição: um hospedeiro resgata o token do laboratório de
6 caracteres exibido no bloco "Lab token" do painel (corpo
`{"labToken":"<6 chars>"}`) e recebe a chave de autenticação interna —
`200 {"ok":true,"v":1,"salt":...,"nonce":...,"ciphertext":...,"tag":...}`;
`400` para corpo malformado, `403` para código desconhecido/expirado,
`429` para limitação por IP e `503` quando desativada. A rota é aberta — por
definição, o chamador é um hospedeiro que ainda não tem essa chave — e limitada pelo
código rotativo de curta duração (`-lab-token-rotate`, padrão `60s`; um código
exibido permanece resgatável por cerca de três rotações), pela limitação por
endereço e pela auditoria de cada tentativa (log do agregador + Loki, rótulo
`src="lab-token"`; o código nunca é registrado no log).

A resposta é **selada com o código resgatado**: AES-256-GCM com uma chave
PBKDF2-HMAC-SHA256 derivada desse código e um salt novo (dados associados
`yuruna-lab-token|v1`). Isso autentica o agregador perante um hospedeiro que não consegue
verificar seu certificado TLS final — assinado pela própria CA do proxy, em que
um hospedeiro em inscrição ainda não tem motivo para confiar — de modo que nenhum
outro participante no caminho possa responder à troca e inserir um token que o
hospedeiro depois aceitaria para provas de controle. Também impede que a chave trafegue
em claro quando o proxy usa HTTP simples (sem certificado TLS final).
`pwsh test/lab/Set-LabToken.ps1 -LabToken <code>` é o cliente
(`Unprotect-LabTokenEnvelope` abre o envelope; uma selagem que não se autentique
é recusada, nunca armazenada); `-lab-token-rotate 0` desativa a troca e o bloco
do painel. Veja [`pool-aggregator-service/README.md`](../../test/extension/pool-aggregator-service/README.md).

As rotas de serviço usam vários decodificadores JSON com limites. Rotas que usam
o auxiliar `jsonbody.Decode` do SDK impõem o limite completo de bytes e exatamente
um valor JSON; login, exclusão em lote do stash e rotas do agregador usam outros
decodificadores. Um `io.LimitReader` sozinho pode truncar um corpo sem informar
que ele excedia o tamanho permitido. MCP preserva os erros de análise JSON-RPC,
enquanto as rotas de serviço mantêm a política existente de erros HTTP/localizados.
Apenas endpoints que permitam explicitamente um corpo vazio o aceitam.
Os chamadores do status do grupo recebem um snapshot com cópia profunda,
incluindo slices aninhadas, mapas e status do hospedeiro; assim, alterações pelo chamador
não podem modificar uma resposta posterior do cache. As verificações de
autenticação eliminam entradas antigas da origem atual a cada tentativa e
percorrem todas as origens no máximo uma vez por janela de falha.

A implementação compartilhada de parada é `test/service/Stop-ExtensionService.ps1`,
que atende a implantações em VM e em processo no hospedeiro. Os comandos públicos
`Stop-*ServiceVM.ps1` continuam sendo pontos de entrada compatíveis.
O auxiliar `runCommandUnbounded` do proxy de cache mantém explicitamente seu
contrato existente de execução sem limite; seus clientes HTTP se chamam `httpClient`.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.10.18.1

Voltar a [Yuruna](../../README.md)