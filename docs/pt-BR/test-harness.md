<a id="42d38664-0001"></a>

<a id="test-harness----architecture"></a>

# Infraestrutura de testes -- arquitetura

Como `test/` está organizado. Consulte [Arquitetura do Yuruna](../architecture.md) para a
arquitetura de todo o projeto e [Yuruna Test ...](../../test/README.md) para o uso pelo operador.

<a id="42d38664-0002"></a>

<a id="entry-points"></a>

## Pontos de entrada

| Script | Finalidade |
|--------|------------|
| `Start-TestRunner.ps1`                             | Laço contínuo de testes (o executor usado no dia a dia) |
| `New-LocalTestUser.ps1`                            | Criar um usuário local do sistema operacional (Windows / macOS / Ubuntu), opcionalmente com senha e direitos de administrador da máquina, e registrá-lo no `users.yml` da autenticação padrão |
| `Remove-TestVMFiles.ps1`                           | Eliminar VMs de teste e os artefatos de cada VM |
| `service/Repair-CachingProxyServiceForwarder.ps1`  | macOS/UTM: verificar se a VM do caching-proxy-service está acessível na LAN e atualizar o arquivo de estado `yuruna-caching-proxy-service` |
| `service/Start-CachingProxyServiceVM.ps1` / `service/Stop-CachingProxyServiceVM.ps1` | Expor a VM do Squid a clientes remotos |
| `service/Start-StatusService.ps1` / `service/Stop-StatusService.ps1` | Interface HTTP de status em processo independente |
| `Test-CachingProxyService.ps1`                            | Verificação prévia de um cache local ou remoto |
| `Test-Config.ps1`                                  | Validar `test.config.yml` + envio opcional de notificação |
| `Invoke-TestProject.ps1`                                 | Variante de execução única: verificar um clone novo, substituir `<RepoRoot>/project`, executar um único ciclo |
| `Debug-TestSequence.ps1`                                 | Auxiliar de desenvolvimento: uma única sequência, com qualquer etapa inicial ou final |
| `check/Test-TesseractOcr.ps1`                      | Verificação de OCR com Tesseract (código aberto; independente de WinRT) |
| `check/Test-WinRtOcr.ps1`                          | Verificação de OCR com WinRT -- também demonstra o problema de "acesso fechado" do pwsh moderno |

O próprio `test/` contém os sete pontos de entrada que o operador usa no dia a dia. Os
demais são agrupados pelo que controlam: `test/lab/` (montagem de um laboratório neste
hospedeiro -- os quatro pontos de entrada independentes do hospedeiro, criação do laboratório,
armazenamento local, registro de tokens, atualização do hospedeiro e suas credenciais
de atualização remota), `test/pool/` (a CLI de pool-admin e os arquivos de intenção de exemplo),
`test/service/` (ciclo de vida das VMs de serviços e dos serviços no hospedeiro, além das
operações do caching-proxy-service), `test/check/` (verificações independentes), `test/modules/`
(componentes internos da infraestrutura de testes, que não são chamados diretamente). A
verificação de codificação de todo o repositório fica em `tools/Test-AsciiNoBom.ps1`.

**O preâmbulo compartilhado.** `Initialize-YurunaEntryPoint`
(`test/modules/Test.Prelude.psm1`) retorna o conjunto canônico de caminhos
(`$TestRoot`, `$RepoRoot`, `$ModulesDir`, `$SequencesDir`, `$StatusDir`,
`$ConfigPath`) de que cada script de ponto de entrada precisa, para que `Start-TestRunner`,
`Invoke-TestRunnerInnerLoop`, `Debug-TestSequence` e `Invoke-TestProject`
tenham sempre os mesmos caminhos, e um futuro ponto de entrada não precise
copiar o código repetitivo de `$PSScriptRoot`/`Split-Path`/`Join-Path` para
calculá-los. **Contrato dos códigos de saída:** `0` significa sucesso; falhas na
verificação prévia usam `1`; `2` significa que uma barreira não conseguiu produzir
um veredito (a admissão de VMs não consegue determinar se há outros convidados em execução),
e `Invoke-TestProject` repassa o código de saída exato do ciclo interno.
Falhas distintas na verificação prévia aparecem no texto da faixa `Stop-WithReason`
-- o operador ou um analisador de CI lê "STOP (exit 1) at &lt;Step&gt;"
e o motivo para distingui-las.

<a id="42d38664-0003"></a>

<a id="cycle"></a>

## Ciclo

Cada iteração de `Start-TestRunner.ps1`:

1. Executa `git pull` e relê `test.config.yml`.
2. A cada 7 dias na configuração fornecida (configurável): atualiza as imagens
   base com `Get-Image.ps1`. Quando a configuração está ausente, o valor de fallback é 24h.
3. Para cada convidado do plano de ciclo resolvido a partir de `test/test.runner.yml` no
   repositório do projeto (`guestSequence` é o fallback, lido apenas quando esse
   arquivo não fornece um plano):
   - Verifica se `host/<short-host>/<guestKey>/` existe -- uma pasta ausente é uma
     falha desse convidado; os demais ainda são executados, exceto quando `testCycle.stopOnFailure` está ativo.
   - Limpa a VM de teste anterior.
   - `New-VM.ps1` -> `Start-VM` -> consulta até estar em execução -> pontos de
     captura de tela -> sequências YAML despachadas pelo planejador de ciclos.
4. Em caso de falha: limpa a VM de teste, exceto quando `testCycle.stopOnFailure` está ativo,
   continua com os demais convidados quando permitido e informa a falha do ciclo.
   O executor externo residente envia uma notificação após a sequência configurada
   de falhas em `failuresBeforeAlert` e entra na pausa por falha.

Antes de cada entrada de uma cadeia e de cada etapa de uma sequência, a
[verificação da saúde do laboratório](../failure-schema.md#the-lab-health-gate-lab_health_-events) verifica
os serviços declarados pelo laboratório e **retém** o ciclo -- o mesmo estado estacionado
produzido pelo botão *Pause* -- enquanto um serviço que antes respondia está ausente, retomando
quando ele retorna. Um serviço que este hospedeiro nunca alcançou nunca retém o ciclo; assim,
um hospedeiro sem stash ainda falha imediatamente, em vez de ficar estacionado.

<a id="42d38664-0004"></a>

<a id="modes"></a>

## Modos

Cada sequência declara seu próprio `keystrokeMechanism` (gui|ssh, padrão
gui), selecionando como a infraestrutura de testes controla o convidado:

- `gui` -- injeção de teclas (scancodes do Hyper-V, VNC/CGEvent do UTM).
- `ssh` -- encaminha cargas de trabalho por SSH usando uma chave por hospedeiro em
  `test/status/ssh/`, que o cloud-init injeta em cada convidado.

As sequências ficam diretamente em `sequences/<name>.yml`; uma variante SSH é um
`<name>.ssh.yml` distinto, selecionado por seu próprio nome.

<a id="42d38664-0005"></a>

<a id="module-responsibilities"></a>

## Responsabilidades dos módulos

Os módulos da infraestrutura de testes compartilhados entre hospedeiros ficam em `test/modules/`. Todo código específico
do hospedeiro (ciclo de vida de VM, busca de imagens, capturas de tela, mapas de portas, proxy do hospedeiro)
é delegado a um módulo de driver por hospedeiro -- consulte o [contrato
Yuruna.Host](#yurunahost-contract).

Todos os módulos de `test/modules/` aparecem abaixo, agrupados pela pergunta que
respondem, para que uma nova função possa ser colocada sem procurar na árvore. Quando uma
família tem um módulo irmão por hospedeiro ou plataforma, os irmãos compartilham uma linha: eles
não contêm lógica além de conectar sua plataforma ao registro da família, portanto
nunca são o local adequado para algo novo.

**Mecanismo de sequências e planejamento de ciclos** -- o que é uma etapa e quais etapas um
ciclo executa:

| Módulo | Finalidade |
|--------|---------|
| `Test.SequenceEngine`  | Controlador do mecanismo: o laço de etapas, `Wait-ForText` e callbacks de contexto para os manipuladores registrados -- consulte [Camadas do mecanismo de sequências](#sequence-engine-layering) |
| `Test.SequenceHandler` | Catálogo de scriptblocks Handler dos verbos integrados |
| `Test.SequenceAction`  | Registro de metadados por verbo (FailureLabel, requisitos de capacidade, sinalizadores de comportamento do mecanismo), consumido pelo mecanismo e pela barreira de capacidades |
| `Test.SequenceVariable`| Substituição de `${var}` e `${ext:area.Method(...)}` no texto das etapas |
| `Test.SequenceResolve` | Analisa o YAML de uma sequência e resolve um nome de sequência para um arquivo no caminho plano de busca |
| `Test.SequencePlanner` | Constrói o plano por ciclo a partir de `test.runner.yml` e da cadeia de `resource` de cada sequência |
| `Test.SequenceRunner`  | Auxiliares de planejamento + execução de cadeias para `Debug-TestSequence.ps1` |
| `Test.SequenceFailureState` | O armazenamento único de slots de falha ancorado em `$global:`, lido e gravado tanto pelo mecanismo quanto pelo catálogo de manipuladores |
| `Test.Orchestrator`    | Executa as sequências internas de uma sequência de orquestração no mesmo processo, sob um único ciclo de `status.json` |
| `Test.Start-GuestOS` / `Test.Start-GuestWorkload` | Os dois blocos do executor: o planejador percorre cada cadeia de recursos de nível superior, envia as sequências `start.*` para o primeiro e todas as demais para o segundo |
| `Test.Capability`      | [Matriz de capacidades](#capability-matrix-and-cycle-plan-gate) e barreira do plano de ciclo (recusa ciclos cujas sequências precisam de um backend de E/S do hospedeiro não conectado) |
| `Test.WarmResume`      | Para quais classes de falha uma retomada no mesmo local é correta, além do checkpoint que indica em qual etapa retomar |
| `Test.Backoff`         | Cálculo compartilhado de atraso entre consultas (exponencial, com variação aleatória) para todos os laços que esperam por estado no sistema de arquivos |

Os módulos despachantes usam a convenção de nome de arquivo `Test.<exported-cmdlet>.psm1`, para que
buscas no código e links da interface de status cheguem ao ponto de entrada exportado.

**Controlar e observar o convidado** -- teclado, mouse, tela, OCR, SSH:

| Módulo | Finalidade |
|--------|---------|
| `Test.HostIO`          | Registro de provedores de E/S por hospedeiro para `Send-Key` / `Send-Text` / `Send-Click` -- consulte [Registro de E/S do hospedeiro](../host-io.md) |
| `Test.HostIO.{HyperV,Kvm,Utm}` | Conexão apenas por registro: associa cada tipo de hospedeiro a seus backends. Sem lógica |
| `Test.Transport`       | As implementações dos backends -- scancodes PS/2, VNC/RFB, AppleScript/CGEvent -- e as janelas de estabilização de que precisam |
| `Test.KeyCodeRegistry` | Tabelas de códigos de tecla e caracteres por transporte, consultadas pelos transportes |
| `Test.VncProvider`     | Registro de conexões VNC + `Repair-VncConnection`, que obriga a próxima chamada a refazer o handshake depois que um identificador em cache fica obsoleto |
| `Test.ScreenshotProvider` | Registro de provedores de captura de tela + `Repair-ScreenshotRing` |
| `Test.OcrEngine` / `Test.Tesseract` | [Provedores OCR](../ocr.md) intercambiáveis e os auxiliares para localizar / instalar / chamar o Tesseract |
| `Test.OcrMatch`        | Normalização e correspondência tolerantes ao OCR (grupos de confusão) + o combinador de múltiplos mecanismos |
| `Test.Ssh`             | Chaves SSH por convidado, as opções obrigatórias de chave do hospedeiro e os auxiliares `ssh` / `scp` |

**Plataforma do hospedeiro** -- o que esta máquina é e quais condições precisa atender para um ciclo executar:

| Módulo | Finalidade |
|--------|---------|
| `Test.HostContract`    | Fachada fina que reexporta os quatro módulos irmãos `Test.Host*`; código novo importa o módulo irmão diretamente |
| `Test.HostDetection`   | Descoberta do tipo de hospedeiro, mapeamento de pastas de hospedeiro, derivação de nomes de VM de teste, verificações de requisitos mínimos |
| `Test.HostBootstrap`   | `Initialize-YurunaHost` -- importa o driver `Yuruna.Host` correspondente para a sessão do executor |
| `Test.HostCondition` (+ `.Mac`, `.Windows`, `.Linux`) | Fachada + trios Set/Assert/AssertMinimum por plataforma -- consulte [Registro de condições do hospedeiro](#host-condition-registry) |
| `Test.HostGit`         | Atualização do framework no início do ciclo (`Invoke-GitPull`), hashes curtos de HEAD, substituição verificada do clone do projeto, diagnóstico de PIDs que bloqueiam arquivos no Windows após falhas de `Remove-Item` (Restart Manager / scanner de diretório atual da PEB), respostas de acesso ao repositório para interfaces do grupo (`Get-HostRepositoryAccess`) e instalações sob demanda da PSGallery (`powershell-yaml`, `PSScriptAnalyzer`), que o PowerShell 7 não inclui |
| `Test.HostAutomationState` | Registra o valor anterior de cada ajuste do hospedeiro antes de `Enable-TestAutomation` gravá-lo, para que `Disable` possa restaurar, em vez de adivinhar |
| `Test.HostFacts`       | Os dados de hardware da própria máquina no formato servido por `/control/host-facts`, incluindo as regras de contagem de armazenamento |
| `Test.HostIdentity`    | Impressão digital do hardware + recuperação de uuid confirmada pelo operador, que impede que o histórico no grupo de um hospedeiro reinstalado se bifurque |
| `Test.HostAddressBeacon` | Parte de envio da descoberta de endereços: anuncia novamente este hospedeiro quando seu endereço muda, em vez de esperar pela consulta do agregador |
| `Test.VMUtility`       | Auxiliares de VM entre hospedeiros, compartilhados por todos os drivers Yuruna.Host |
| `Test.ServiceVm`       | Relação de VMs de serviço e a sondagem de acessibilidade que as traz de volta após uma reinicialização do hospedeiro; a política Preserve/Repair que decide o significado de um estado desconhecido (`Test-YurunaServiceVmRunning`), e a restauração que contém o motivo de cada sondagem, ignora um serviço parado pelo operador e verifica o endpoint do consumidor dentro de um prazo compartilhado |
| `Test.ServiceCensus`   | Inventário passivo de VMs de serviço gravado pelo sinalizador de endereço sem nenhuma chamada a Apple Events, as intenções de parada/início publicadas pelos scripts de serviço, bloqueios de operação por chave de serviço e as linhas de identidade capturadas pela atualização do hospedeiro antes de interromper qualquer coisa |
| `Test.SingleFlightLock` | Bloqueio exclusivo entre processos baseado em um bloqueio de arquivo do sistema operacional mantido aberto durante toda a operação, não apenas na gravação de seus metadados: esperas limitadas, ordem de bloqueios (HostOperation, depois ServiceKey e depois um de Admission, CensusMerge ou Gate), exclusão verificada pelo próprio mecanismo e verificações de qualificação do estado, propriedade e sistema de arquivos |
| `Test.HostRefresh`     | Worker de reparo de atualização do hospedeiro e suas partes independentes de hospedeiro: a declaração de nível de reparo (`Get-VirtualizationRepairRung`, disponível apenas onde existe executor e a plataforma é qualificada), o orçamento de 915 segundos e suas fases, a tabela de vereditos e códigos de saída, a projeção pública `host-refresh.state.json` e seu publicador de heartbeat, o resumo de capacidades e o vetor de argumentos do worker. Não importa drivers, para que o status service possa carregá-lo |
| `Test.HostRefreshIntent` | O diário de solicitações de atualização do hospedeiro (um registro crítico na raiz privada): admissão sob seu próprio bloqueio, reivindicação, nova tentativa e abandono, registros de recuperação e as obrigações que um reparo precisa cumprir, a reserva para início de ciclo e os sujeitos registrados da concessão de automação |
| `Test.HostRefreshAuth` | Autorização de atualização remota do hospedeiro: criação e verificação de provas versionadas com relógio e tolerância de desvio explícitos, armazenamento e verificações da chave verificadora por hospedeiro (apenas proprietário, sem links, correspondência do hospedeiro), a camada `Test-YurunaHostRefreshAuthorization` do listener, o resumo do estado remoto e as primitivas de provisionamento por trás de `test/lab/Set-HostRefreshCredential.ps1`, incluindo `ConvertTo-YurunaHostRefreshHostKeyLine`, que formata uma chave verificadora do hospedeiro como seu segredo de uma linha. Importa apenas `Yuruna.Globalization`; sua suíte fixa os vetores compartilhados com o verificador Go |
| `Test.StatusFirewall`  | Regra de permissão por sistema operacional que torna a porta do status-service acessível pela LAN |
| `Test.RootArtifact`    | Encontra e limpa o estado pertencente ao root deixado por uma execução de um ponto de entrada com `sudo` (apenas Unix) |

**Ciclo de vida do executor** -- iniciar, supervisionar e recuperar o laço:

| Módulo | Finalidade |
|--------|---------|
| `Test.Prelude`         | O conjunto canônico de caminhos, inicialização do conjunto de módulos e contrato dos códigos de saída usados por todo ponto de entrada |
| `Test.RunnerOuterLoop` | O laço permanente -- consulte [Laço externo do executor](../runner-outer-loop.md) |
| `Test.RunnerInnerLoop` | Auxiliares por ciclo conduzidos ao longo de um ciclo pelo executor interno |
| `Test.RunnerWatchdog`  | Watchdog de heartbeat de etapas em processo separado; encerra um processo interno travado |
| `Test.RunnerHeartbeat` | Heartbeat do processo por temporizador de threadpool, que continua avançando enquanto o runspace está bloqueado |
| `Test.RunnerState`     | Máquina de estados explícita do executor externo, com estado persistido + eventos de transição NDJSON |
| `Test.RunnerElevation` | Contrato de elevação no lançamento: resolvê-la uma vez enquanto um operador está presente, ou recusar o início |
| `Test.SingleInstance`  | Proteção por pidfile compartilhada pelo trio de executores (`Get-RunnerInstanceState`, `Stop-StaleRunner`); o construtor da tabela de processos e o classificador de identidades que decidem quais processos executores um reparo pode parar, a barreira de atualização que suspende novas criações durante um reparo, o token de transferência e a confirmação de prontidão que trazem o executor de volta, e o registro persistido de lançamento do qual parte um executor retomado |
| `Test.InnerSpawn`      | `New-InnerRunnerArgList` -- construtor de argv para `pwsh -Command` que preserva tipos na criação do processo externo->interno e em `Invoke-TestProject`; `Start-YurunaDetachedProcess`, que inicia um worker que sobrevive ao processo que o lançou e o confirma com um handshake |
| `Test.Recovery`        | Varredura na inicialização que detecta e arquiva cada classe de estado obsoleto deixada por um ciclo que travou; seu modo de preservação durante atualização mantém os controles do operador e os registros do executor recuperado quando um reparo reinicia o executor |
| `Test.HostRefreshTrigger` | Política de atualização automática do hospedeiro: evidências de tempo limite do hipervisor por ciclo, a contagem persistida, o orçamento de tentativas por dia UTC e a decisão de reparo pós-ciclo do executor residente -- consulte [testCycle.autoRefreshAfterStalls](../test-config.md) |
| `Test.OuterLog`        | Gravador de `outer.log` com carimbo de data/hora, compartilhado pelo laço externo e pelo worker de atualização do hospedeiro; nunca lança exceção quando o diretório de execução não está definido |

**Configuração**:

| Módulo | Finalidade |
|--------|---------|
| `Test.Config`          | Leitor YAML com cache (`Read-TestConfig`, `Get-TestConfigValue`), usado por todos os executores / pontos de entrada |
| `Test.ConfigValidator` | `Test-AgainstSchema`, `Test-IsSet`, `Test-RepoFreshness` -- a camada de regras, reutilizável por qualquer script de verificação |
| `Test.ConfigPreflight` | `Invoke-ConfigGate` -- barreira de `Test-Config.ps1` antes do ciclo, compartilhada por todos os pontos de entrada |
| `Test.ConfigSync`      | Reconciliação de `test.config.yml` ativo <-> modelo fornecido no início do ciclo |
| `Test.ConfigNaming`    | A tabela de chaves aposentadas: caminho pontuado antigo -> novo caminho + fator de unidade, compartilhada pelo validador e pelo regravador |
| `Test.ConfigServiceSync` | Copia a configuração de um hospedeiro de referência do grupo para este hospedeiro, convertendo os valores específicos do tipo de hospedeiro |
| `Test.ConfigServiceCA` | CA de configuração por hospedeiro (mTLS) que sustenta o serviço de configuração: um certificado de servidor, um certificado de cliente por VM |
| `Test.LogLevel`        | Cascata canônica de níveis de log (`Resolve-LogLevel`, `Use-LogLevelFromEnv`) -- consulte [Cascata de níveis de log](../loglevels.md) |

**Logs, status e telemetria**:

| Módulo | Finalidade |
|--------|---------|
| `Test.Log`             | Responsável pelo sistema de arquivos do ciclo: pasta do ciclo, subpastas por convidado, `cycle.events.ndjson`, `manifest.json` |
| `Test.Output`          | Contagem PASS/FAIL/WARN por script + faixa `Write-Summary`, reutilizada em `Test-Config` e nos scripts de verificação |
| `Test.LogRotation`     | Rotação de N arquivos limitada por bytes para arquivos que só recebem acréscimos e não dependem do ciclo |
| `Test.YurunaDir`       | Resolve e cria `$env:YURUNA_LOG_DIR` / `$env:YURUNA_RUNTIME_DIR` |
| `Test.Status`          | Ciclo de vida de `status.json`, incluindo o bloqueio de ciclos aninhados |
| `Test.EventSchema`     | Valida cada registro NDJSON no ponto de emissão, para que um erro de digitação de campo seja detectado antes de chegar ao disco |
| `Test.Perf`            | Uma linha JSONL de desempenho por execução de etapa, um arquivo por ciclo |
| `Test.Provenance`      | Lê o arquivo auxiliar de proveniência da imagem base gravado por `Get-Image.ps1` |
| `Test.FrameworkSource` | De qual snapshot do framework uma VM de serviço foi construída e se o convidado recorreu ao espelho público |
| `Test.PortOwner`       | `Get-PortListenerPid` (HTTP.sys do Windows + lsof do Unix) + `Resolve-PortOrphan` para a porta do status-service |
| `Test.Notify`          | Despachante fino para as extensões de notificação ativas (`Send-Notification -EventCode -EventMessage -EventNote`); a extensão padrão entrega e-mails pelo Resend |
| `Test.StatusControlRoute` | Auxiliares sem driver por trás das rotas de atualização do hospedeiro, início de ciclo e diagnóstico do hospedeiro do status service: leitor limitado do corpo da solicitação, validação da solicitação, respostas de admissão e o resumo `refresh` em `/control/control-status` |
| `Invoke-StartCycleWorker.ps1` / `Invoke-HostDiagnosticWorker.ps1` | Workers independentes que o status service lança para *Save and start cycle* e para o diagnóstico do hospedeiro, para que uma limpeza lenta ou uma sondagem travada nunca bloqueie o listener |

**Classificação de falhas e recuperação**:

| Módulo | Finalidade |
|--------|---------|
| `Test.FailureTaxonomy` | Arrays canônicos `FailureClass` / `Severity`; um módulo folha lido por todos os outros consumidores |
| `Test.Remediation`     | Despachante de classe de falha -> recuperação (`Register-RecoveryHandler`) -- consulte [Esquema de falha](../failure-schema.md) |
| `Test.GuestQuarantine` | Disjuntor por convidado: N falhas da mesma classe colocam esse convidado em quarentena, excluindo classes com escopo de hospedeiro |
| `Test.Diagnostic`      | Captura do convidado após falha e sua cadeia de estratégias -- consulte [Captura de diagnóstico por ciclo](#per-cycle-diagnostic-capture) |
| `Test.SnapshotManifest`| Arquivos auxiliares de snapshots, para que uma restauração possa recusar um snapshot que não reconhece |
| `Test.CredentialProvider` | Auxiliares de inspeção / reparo apenas para testes sobre o [registro de login de componentes](../authentication.md#component-registry-login) |

**Grupo e laboratório** -- tudo o que só faz sentido com mais de uma máquina:

| Módulo | Finalidade |
|--------|---------|
| `Test.PoolSync`        | Obtém a intenção do grupo (associação + desiredState) e a reconcilia no laço externo |
| `Test.PoolPlanner`     | Lê o manifesto do grupo -- os repositórios de framework e projeto do grupo -- para o executor |
| `Test.PoolAdmin`       | Auxiliares por trás da CLI pool-admin; cada alteração é validada por esquema antes de ser confirmada |
| `Test.PoolStorage`     | Compartilhamento SMB3 opcional como camada durável para a saída dos ciclos, além da drenagem que confirma e recupera espaço |
| `Test.PoolPush`        | Envia o NDJSON de um ciclo para o agregador por HTTPS com CA fixada, fechando a lacuna entre consultas |
| `Test.PoolNotifier`    | Entrega os alertas de degradação do grupo do agregador pela extensão de notificação, com fila no compartilhamento |
| `Test.PoolWorker`      | Conversão de um hospedeiro independente em worker do grupo e desativação dos serviços locais que, caso contrário, ganhariam a consulta |
| `Test.Lab`             | Formato do cofre do laboratório e consulta de credenciais da máquina; somente leitura, nunca cria uma credencial |
| `Test.LocalLabStorage` | Transforma uma máquina em seu próprio servidor SMB de grupo/stash, para que um laboratório com um único hospedeiro exercite o caminho de rede |

**Extensões e VMs de serviço**:

| Módulo | Finalidade |
|--------|---------|
| `Test.Extension`       | Carregador das áreas de extensão intercambiáveis em `test/extension/<area>/`, além de `Get-ExtensionHostAddress` -- onde uma área de serviço é acessível para este hospedeiro -- consulte [API de extensões](../extensions-api.md) |
| `Test.ExtensionService`| O manifesto `service:` declarado por uma área sobre si mesma e o marcador em tempo de execução que indica que este hospedeiro a executa |
| `Test.DownloadAgentService` | Ciclo de vida do download-agent no hospedeiro: o marcador, a sondagem de prontidão, o endereço publicado |
| `Test.CachingProxyService` | Estado da VM caching-proxy-service entre ciclos (senha de administrador + IP) -- consulte [Cache](../caching.md) |
| `Test.CachingProxyServiceLock` | Bloqueio de serialização ao redor de reconstrução do caching-proxy-service / gravações de mapas de portas e a decisão de adotar se saudável |

**Primitivas compartilhadas** -- módulos folha sem dependências da infraestrutura de testes:

| Módulo | Finalidade |
|--------|---------|
| `Test.Registry`        | `New-YurunaRegistry` -- a primitiva de conjunto de closures + âncora global sobre a qual todos os registros acima são construídos |
| `Test.StateFile`       | Gravador atômico de arquivos auxiliares -- consulte [Arquivos auxiliares de estado](#state-sidecars) |
| `Test.CriticalRecord`  | Registros privados com checksum e número de geração, uma geração anterior mantida e gravações limitadas e descarregadas (durabilidade diante de falha do processo), para estado que autoriza uma alteração |
| `Test.Hash`            | Array de bytes -> hexadecimal em minúsculas, para que todos os chamadores de hash compartilhem uma codificação |
| `Test.Assert`          | O vocabulário de asserções das suítes e as estruturas de apoio dos testes -- consulte [Um único vocabulário de asserções](#one-assertion-vocabulary). Importado apenas por suítes, nunca pelo código da infraestrutura de testes |
| `Test.MacUtmFakeHost`  | Suporte a testes: um hospedeiro macOS/UTM substituto (`utmctl`, `osascript`, `pgrep` e outros simulados) para as suítes do driver macOS `Test.MacVirtualizationResponsive`, `Test.MacUtmLifecycle` e `Test.MacUtmBoundedNative`. Importado apenas por suítes |

<a id="42d38664-0006"></a>

<a id="testconfig-role-pyramid"></a>

### Pirâmide de funções de Test.Config*

Três dos módulos `Test.Config*` da tabela se dividem por função:
`Test.Config` é o leitor YAML com cache baseado em mtime (a camada de dados);
`Test.ConfigValidator` contém as primitivas de esquema + atualidade (a
camada de regras), reutilizáveis entre chamadores; `Test.ConfigPreflight` é a
barreira antes do ciclo que inicia `Test-Config.ps1` e recusa o ciclo diante de
itens FAIL (a camada de política).

<a id="42d38664-0007"></a>

<a id="yurunahost-contract"></a>

### Contrato Yuruna.Host

`Initialize-YurunaHost` (em `Test.HostContract`) importa o driver correspondente
com base no tipo de hospedeiro:

| Tipo de hospedeiro | Driver |
|-----------|--------|
| `host.windows.hyper-v` | [`host/windows.hyper-v/modules/Yuruna.Host.psm1`](../../host/windows.hyper-v/modules/Yuruna.Host.psm1) (real) |
| `host.macos.utm`       | [`host/macos.utm/modules/Yuruna.Host.psm1`](../../host/macos.utm/modules/Yuruna.Host.psm1) (real) |
| `host.ubuntu.kvm`      | [`host/ubuntu.kvm/modules/Yuruna.Host.psm1`](../../host/ubuntu.kvm/modules/Yuruna.Host.psm1) (real) |

O driver exporta um conjunto fixo de funções de contrato que cobre o ciclo de
vida de VMs (`New-VM`, `Start-VM`, `Stop-VM`, `Stop-VMForce`, `Remove-VM`,
`Rename-VM`, `Get-VMState`), inventário de VMs (`Get-VMName`), gerenciamento de
snapshots (`Save-VMDiskSnapshot`, `Restore-VMDiskSnapshot`, `Test-VMDiskSnapshot`),
console de VM (`Test-VMConsoleOpen`, `Restart-VMConsole`), busca de imagens
(`Get-Image`, `Get-ImagePath`), E/S de VM (`Send-Text`, `Send-Key`, `Send-Click`,
`Get-VMScreenshot`, `Get-VMConsoleHandle`), descoberta (`Wait-VMIp`, `Get-VMIp`,
`Get-VMMac`, `Update-GuestNeighborCache`), rede (`Get-ExternalNetwork`,
`New-ExternalNetwork`, `Test-CacheVMOnExternalNetwork`), mapas de portas e
endereços do hospedeiro (`Add-PortMap`, `Remove-PortMap`, `Get-BestHostIp`,
`Get-GuestReachableHostIp`), caching-proxy-service (`Test-CachingProxyServiceAvailable`,
`Get-CachingProxyServiceVmIp`), proxy no hospedeiro (`Set-HostProxy`,
`Clear-HostProxy`, `Remove-HostProxy`, `Get-HostProxyBackupPath`), verificações de virtualização
(`Assert-Virtualization`) e reparo de virtualização
(`Test-VirtualizationResponsive`, uma sondagem limitada e somente de leitura do
canal de controle do hipervisor, e `Start-VirtualizationServiceIfStopped`, que
inicia um serviço de hipervisor apenas diante de evidência positiva de que está parado).
`Test.HostDriverContractParity` verifica se os três drivers definem, exportam e
declaram todos os verbos do contrato, e `Test.KvmStartIfStopped` e
`Test.HyperVVirtualizationResponsive` cobrem os dois verbos em KVM e Hyper-V.
Observações por hospedeiro para os contratos que
divergem de formas operacionalmente significativas (snapshot + renomeação, E/S
de tela):
[Ações de sequência e contratos de hospedeiro](../test-sequences.md#yurunahost-contract).

O despacho por ciclo é orientado por YAML: cada ciclo lê
`project/test/test.runner.yml` para obter os nomes das sequências de carga de trabalho de
nível superior, percorre o campo `resource` de cada sequência (objeto identificado por sistema
operacional convidado; a grafia antiga `baseline` é recusada com um erro de migração)
para derivar uma cadeia ordenada por dependências e despacha cada entrada da
cadeia por [`modules/Test.SequenceEngine.psm1`](../../test/modules/Test.SequenceEngine.psm1).
Sequências cujo nome começa com `start.` executam durante a etapa
Start-GuestOS do executor; as demais executam durante Start-GuestWorkload. O planejador de
ciclos as reúne percorrendo cada cadeia de recursos de nível superior; nenhum código de integração
`.ps1` por sistema operacional é necessário. Arquitetura completa:
[Módulos de teste](../../test/modules/README.md).

<a id="42d38664-0008"></a>

<a id="runtime-directories"></a>

## Diretórios de execução

```
test/
+-- sequences/
|   +-- actions.yml             Action catalog (YAML, machine-readable)
|   +-- _snippets.yml           Shared step snippets
|   +-- <name>[.ssh].yml        Flat sequence files (SSH variant = .ssh.yml suffix)
+-- schemas/                    JSON Schema files (YAML-encoded) for extension/* configs + vault
+-- extension/                  Pluggable extension areas (Test.Extension loader; committed code only)
|   +-- authentication/         default.psm1, authentication.config.yml
|   +-- notification/           default.psm1, notification.config.yml, transports.yml.template
|   +-- ...                       9 areas total -- see [extensions-api.md](extensions-api.md)
+-- screenshots/<guestKey>/     [Optional -- operator-populated; absent by default]
|   +-- schedule.json           Capture checkpoints + thresholds (create if using screenshot validation)
|   +-- reference/*.png         Trained reference screenshots (commit manually per checkpoint)
+-- status/                     Status dashboard + ALL harness runtime state
    +-- index.html, diagnostics.html, config.html, yuruna.common.{css,js},
    |                           status.json.template     (committed UI)
    +-- runtime/                $env:YURUNA_RUNTIME_DIR -- pids,
    |                           status.json, control flags, ipaddresses.txt,
    |                           caching-proxy-service.txt, server.err, host.uuid,
    |                           yuruna-caching-proxy-service.yml, .status-service.ps1
    +-- log/                    $env:YURUNA_LOG_DIR -- HTML transcripts,
    |                           OCR debug, failure screenshots
    +-- perf/                   JSONL perf rows + content-addressed
    |                           host/guest dumps
    +-- extension/
    |   +-- authentication/     vault.yml, vault.lock, events.log (plaintext by design -- ephemeral test-VM credentials only; threat model: docs/authentication.md)
    |   +-- notification/       transports.yml (Resend API key)
    +-- captures/
    |   +-- sequences/          takeScreenshot debug PNGs
    |   +-- training/           per-cycle training captures, guest-prefixed
    +-- ssh/                    yuruna_ed25519(.pub) -- generated per host
```

A referência por ação (comportamento de cada verbo e observações dos contratos
por hospedeiro) está em [Sequências de teste](../test-sequences.md).

<a id="42d38664-0009"></a>

<a id="extension-areas"></a>

### Áreas de extensão

Cada área em `test/extension/<area>/` inclui um
`<area>.config.yml` versionado que nomeia os módulos `<name>.psm1` ativos
(authentication usa exatamente `active[0]`; notification percorre a
lista). Para substituir, coloque um `<name>.psm1` irmão ao lado de
`default.psm1` e edite o `<area>.config.yml` da área.

- **authentication** -- cofre de credenciais que simula um provedor externo
  de autenticação. O vault.yml da extensão padrão persiste entre ciclos
  (Initialize-VaultConnection não faz nada quando o arquivo já
  existe); o comportamento "simulado" é o ramo de criação sob demanda de
  Get-Password (a primeira referência a um nome de usuário gera+armazena uma
  senha; todas as chamadas posteriores retornam o mesmo valor armazenado). As etapas de
  sequência obtêm valores ativos por substituições
  `${ext:authentication.GetPassword(${username})}` /
  `${ext:authentication.NewRandomPassword()}`; as confirmações passam
  pelo verbo de ação `callExtension` (`authentication.SetPassword`). Um
  mutex de sistema nomeado serializa leitura-modificação-gravação entre convidados em paralelo.
- **notification** -- despacho por código de evento (`cycle.failure`,
  `config.smoke`). Assinantes e credenciais de transporte ficam em
  `test/status/extension/notification/transports.yml` (estado de execução
  ignorado pelo git); o modelo (`transports.yml.template`) é incluído na árvore
  em `test/extension/notification/`.

Substitua os diretórios de execução e de logs por `$env:YURUNA_RUNTIME_DIR` e
`$env:YURUNA_LOG_DIR` antes do lançamento; o status service remapeia os
prefixos de URL.

<a id="42d38664-000a"></a>

<a id="pester-discovery-and-file-scope-variables"></a>

## Descoberta do Pester e variáveis no escopo do arquivo

Uma suíte que cria um `$env:YURUNA_RUNTIME_DIR` temporário deriva seu nome de
`$PID` e mantém esse nome em uma variável de escopo de arquivo NÃO QUALIFICADA
(sem o qualificador `$script:`). Os dois detalhes são essenciais, e as duas falhas são
silenciosas:

- O corpo do arquivo é executado durante a passagem de DESCOBERTA do Pester -- e, quando o
  arquivo é executado como script de entrada, mais uma vez antes dela.
  `$env:YURUNA_RUNTIME_DIR` é global ao processo, portanto a última execução do corpo prevalece,
  enquanto os blocos `It` leem o nome capturado pela primeira. Um GUID por execução
  apontaria, por isso, o módulo em teste para um diretório e as
  asserções para outro; um nome derivado de `$PID` é idêntico em todas as passagens, portanto
  os dois não podem divergir.
- Um bloco `It` executa em um escopo de script novo. Uma leitura qualificada com `$script:` em um
  teste é resolvida NESSE escopo e retorna `$null`, mesmo que o arquivo
  tenha atribuído o nome. Apenas um nome não qualificado percorre a cadeia de escopos até as
  variáveis do próprio arquivo.

A limpeza pertence a `AfterAll` pelo mesmo motivo, nunca ao final do arquivo:
código no nível do arquivo executa durante a descoberta, ANTES de qualquer `It`, portanto um
`Remove-Item` ao final exclui o diretório no qual os testes vão criar estado, em vez de
limpar depois deles.

Fixtures e funções auxiliares pertencem a um `BeforeAll` -- o escopo que o Pester compartilha
com cada `It`. Uma atribuição no escopo do arquivo é resolvida em `pwsh -File <suite>` e
é vinculada como VAZIA em `Invoke-Pester -Path <suite>`, portanto uma suíte escrita assim
relata aprovação de uma forma e falha da outra. Consulte
[Fixtures do Pester no escopo do arquivo](../memory.md#pester-file-scope-fixtures) para a regra
completa, incluindo os três posicionamentos que parecem a armadilha e estão corretos.
`Test.SuiteHelperAdoption.Tests.ps1` faz falhar qualquer suíte que não declara
`BeforeAll`.

<a id="42d38664-000b"></a>

<a id="running-the-suites"></a>

## Executar as suítes

O executor das suítes requer Pester 5.x (a versão 5.9.1 é a versão de instalação
indicada na documentação). As suítes usam `BeforeAll`/`AfterAll` para preparar e
limpar o ambiente de execução entre as fases de descoberta e execução. Pester 4
não é compatível com o executor.

As suítes **não** fazem parte de um ciclo de testes. Elas executam ao lado da infraestrutura de testes:

```
pwsh -NoProfile -File tools/Invoke-TestSuite.ps1            # everything
pwsh -NoProfile -File tools/Invoke-TestSuite.ps1 -Filter 'Test.Pool*'
pwsh -NoProfile -File tools/Invoke-TestSuite.ps1 -ListOnly  # discovery only
```

Um processo por suíte, para que as importações, o estado global ou uma falha de uma suíte não possam
influenciar o resultado de outra. Cada processo filho define uma `PesterConfiguration` e depois chama
a suíte pelo operador de chamada, em vez de `Invoke-Pester -Path`, que é o
que mantém as suítes com fixtures no escopo do arquivo funcionando enquanto ainda emitem XML NUnit.

**No Windows, execute as suítes em um PowerShell elevado que tenha o `usr\bin`
do Git for Windows em `PATH`.** Elevação: algumas suítes criam links simbólicos ou regravam o
proprietário de um arquivo, e um token não elevado não tem os privilégios para as duas ações (o
privilégio de link simbólico e `SeSecurityPrivilege`), portanto esses casos falham nessa condição; um
hospedeiro de ciclos de teste Windows também executa elevado. Ferramentas Git: várias suítes executam
`bash`, `chmod` e `openssl`. Em um PowerShell comum, `bash` é o lançador WSL em
`System32`, que não interpreta um caminho Windows, como `C:\x`, como arquivo, e
`chmod` e `openssl` não são encontrados; o Git for Windows inclui os três em
`usr\bin`. As suítes privadas em `dev-only/test` seguem a mesma regra.

**Planeje o tempo.** Até oito processos de suíte executam ao mesmo tempo (`-ThrottleLimit`),
e uma execução completa das suítes versionadas leva cerca de 8 minutos no hospedeiro Ubuntu KVM
em que o baseline é registrado, cerca de 7 minutos no macOS e de 17 a 20 minutos no
Windows. Uma suíte executa ao lado de outras sete, portanto um limite de tempo dentro de uma
suíte precisa ser atendido em uma máquina ocupada, e um teste que precisa de uma porta livre não deve
presumir que uma porta que acabou de liberar continuará livre.

**O código de saída de uma suíte isolada não indica aprovação/falha.** O caminho
independente do Pester não propaga uma execução com falha pelo operador de chamada: uma
suíte cujos testes falham ainda retorna 0, e uma que não descobre nada retorna 0
com zero testes. Por isso, o executor lê o arquivo de resultados e falha em cinco
condições -- nenhum arquivo de resultados (falha de processo, erro de análise, tempo limite), falhas ou erros,
zero testes, uma suíte do baseline ausente da execução ou uma contagem de testes de
suíte abaixo do baseline. As duas últimas detectam a perda SILENCIOSA de testes: uma
suíte excluída e um `Describe` que deixou de descobrir metade de seus casos sem avisar.

`test/modules/suite-baseline.json` é essa referência e é versionado. Registre novamente
todas as linhas com `-UpdateBaseline` apenas a partir de uma execução completa aprovada, como uma alteração
deliberada e revisada. A atualização recusa suítes perdidas, contagens de teste menores e novas
omissões; remoções deliberadas ou permissões para omitir exigem uma edição separada e revisada.

Uma linha do baseline contém `total`, `skipped` e `seconds` do hospedeiro que a registrou,
além de dois campos opcionais editados manualmente em uma alteração revisada e mantidos por uma
atualização. `platformTotal` (por exemplo, `{ "macos": 6 }`) é a contagem de testes que
uma plataforma precisa alcançar quando difere de `total`: uma suíte que define
alguns de seus blocos `Describe` apenas no Windows ou apenas no Linux tem menos testes
em outras plataformas, e uma única contagem fixa faria todas as execuções completas falharem na plataforma com
menos testes. Uma plataforma sem entrada precisa atingir `total`, e uma atualização em outra
plataforma nunca reduz o `total` dessa linha. `timeoutSeconds` dá a uma suíte um
limite próprio, quando ela leva várias vezes mais tempo em um hospedeiro lento do que seu
custo registrado mais a margem de 300 s permite; ele só pode elevar o limite.
`tools/Test-SuiteBaseline.ps1` recusa um valor malformado em qualquer um dos campos.

Para registrar suítes recém-adicionadas sem atualizar linhas históricas, execute:

```powershell
pwsh -NoProfile -File tools/Invoke-TestSuite.ps1 -RegisterNewSuites
```

O registro executa **todas** as suítes descobertas ausentes do baseline e
exige evidências NUnit de aprovação sem testes omitidos. Preserva todas as linhas existentes,
permissões de omissão e o carimbo de data/hora histórico da execução completa, e registra separadamente o
carimbo de data/hora do registro e os hashes dos arquivos-fonte das novas suítes. Recusa
suítes removidas e alterações na descoberta, nos arquivos-fonte das novas suítes ou no baseline
durante a execução. Filtros e `-UpdateBaseline` não podem ser combinados com esse
modo. Revise e coloque em staging o baseline resultante junto com as novas suítes.

O registro não afirma que houve aprovação de uma execução completa: as suítes existentes não são executadas novamente,
e suas falhas ou perdas de testes ainda fazem uma execução completa normal falhar.

`tools/Invoke-GoTest.ps1` aplica a mesma ideia aos serviços de extensão: `go
build`, `go vet` e `go test` por módulo, descobertos pela busca de `go.mod`.

<a id="42d38664-000c"></a>

<a id="one-assertion-vocabulary"></a>

## Um único vocabulário de asserções

As suítes importam [`Test.Assert.psm1`](../../test/modules/Test.Assert.psm1), em vez de
declarar seus próprios auxiliares -- `Assert-True/False/Equal/StringEqual/NotEqual/
Null/NotNull/Match/Throw/NoFinding`, além de `Get-YurunaTestRepoRoot`,
`New-YurunaTestTempDir` e os carregadores AST. `Test.SuiteHelperAdoption.Tests.ps1`
faz falhar uma suíte que redeclara qualquer um deles; sem essa proteção, a contagem cresceu de
234 para 296 definições feitas manualmente, com três significados mutuamente incompatíveis para
`Assert-Equal`.

`Assert-Equal` compara **por valor**; `Assert-StringEqual` compara representações
em string. São exportações separadas porque de fato diferem -- em zeros
à esquerda, espaços em branco, representação de números de ponto flutuante, `$null` em relação a uma string vazia e, de forma mais
acentuada, em arrays, em que `-ne` filtra elemento por elemento, em vez de comparar, e por isso
RECUSA dois arrays idênticos. Eles NÃO se distinguem pelo rigor de tipo:
`1 -ne '1'` é falso nos dois.

<a id="42d38664-000d"></a>

<a id="self-healing-extension-points"></a>

## Pontos de extensão de autorrecuperação

A infraestrutura de testes expõe cinco registros que o operador, um projeto
ou um futuro laço de recuperação pode estender sem criar um fork do framework.
Cada um é enumerado na inicialização pela [matriz de capacidades](#capability-matrix-and-cycle-plan-gate);
quatro dos cinco compartilham a primitiva
[`New-YurunaRegistry`](../../test/modules/Test.Registry.psm1)
e são expostos por `Get-YurunaRegistryDirectory`.
`New-YurunaRegistry -Name '<DomainName>'` retorna uma
hashtable de conjunto de closures (scriptblocks `Register` / `Get` / `Has` / `GetMatrix` / `Clear`
) que fecha sobre um armazenamento compartilhado ancorado em
`$global:__YurunaRegistry__<DomainName>`, para que uma reimportação com `-Force` do
módulo chamador não descarte entradas já registradas. Os módulos de domínio
envolvem o conjunto com seus próprios nomes `Register-*`/`Get-*`; a
primitiva permanece genérica, para que registros futuros por ciclo possam
reutilizá-la. A exceção é o registro de provedores de credenciais
para login de componentes, que usa o mesmo
padrão de âncora global protegido contra descarte, mas é implementado manualmente em
[`automation/Yuruna.CredentialProvider.psm1`](../../automation/Yuruna.CredentialProvider.psm1)
(para permanecer fora de `test/` e não estar em `Get-YurunaRegistryDirectory`):

- [Provedores OCR](../ocr.md) -- `Register-OcrProvider`
- [Registro de E/S do hospedeiro](../host-io.md) -- `Register-HostIOProvider`
- Ações de sequência -- `Register-SequenceAction` (consulte
  [`Test.SequenceAction.psm1`](../../test/modules/Test.SequenceAction.psm1))
- [Login de registro de componentes](../authentication.md#component-registry-login) -- `Register-CredentialProvider`
- [Registro de condições do hospedeiro](#host-condition-registry) -- `Register-HostConditionProvider`

Além do [despachante de remediação](../failure-schema.md#remediation-dispatcher) (`Register-RecoveryHandler`,
classe de falha para recomendação) e da
[API de extensões](../extensions-api.md) baseada em arquivos em
`test/extension/<area>/` para autenticação, transportes de notificação
e análise de logs do caching-proxy-service.

A disponibilidade do laboratório é, na prática, seu próprio ponto de extensão, embora não registre
nada: [`Test.LabHealth.psm1`](../../test/modules/Test.LabHealth.psm1) deriva o que
sondar dos manifestos `service:` em `test/extension/<area>/`, portanto uma área
que declara `healthPort` passa pela barreira sem qualquer edição do framework.

O ciclo de vida do executor é observável pela
[máquina de estados do executor](../runner-outer-loop.md#runner-state-machine) (`Set-RunnerState` em cada
limite de ciclo; eventos NDJSON `runner_state_transition`). O
laço do executor externo e seu watchdog de heartbeat estão divididos
em [Test.RunnerOuterLoop](../runner-outer-loop.md) e
[Test.RunnerWatchdog](../runner-outer-loop.md#module-testrunnerwatchdog), para que os dois possam ser testados unitariamente
independentemente do script de ponto de entrada.

A renderização de seeds do cloud-init passa pelo
[pipeline de modelos cloud-init](../vmconfig.md#how-user-data-is-rendered) -- base compartilhada
+ sobreposição por hospedeiro + proteção de placeholders.

<a id="42d38664-000e"></a>

<a id="sequence-engine-layering"></a>

## Camadas do motor de sequências

Três módulos compartilham a interface do motor de sequências:

- `Test.SequenceAction.psm1` -- a primitiva de registro
  (`Register-SequenceAction`, FailureLabel + metadados de capacidade por verbo).
- `Test.SequenceHandler.psm1` -- o catálogo de scriptblocks Handler dos verbos
  integrados. Adicionar um verbo exige uma edição local aqui, sem concentrar
  conflitos de mesclagem no motor. Cada handler deste módulo se comunica com o
  motor pela hashtable `$Context`, pelo armazenamento compartilhado
  `Test.SequenceFailureState` e pelas exportações padrão de `Yuruna.Host` /
  `Test.Ssh` / `Test.Extension` / `Test.Log`. Esse catálogo inclui os manipuladores
  com estado `retry` e `recoverFromSnapshot`.
- `Test.SequenceEngine.psm1` -- o controlador do motor. Ele executa o laço de
  etapas e fornece o callback recursivo `InvokeStepBlock` por `$Context`.
  Ambos os módulos leem e gravam um único armazenamento compartilhado de slots
  de falha, permitindo que os manipuladores coordenem novas tentativas e
  recuperação sem ramificações por verbo no motor.

<a id="42d38664-000f"></a>

<a id="capability-matrix-and-cycle-plan-gate"></a>

## Matriz de capacidades e barreira do plano de ciclo

No início de cada ciclo, o executor interno publica um único banner que informa
o que o ambiente de testes pode fazer no hospedeiro atual -- quais motores OCR
estão disponíveis, quais ações de E/S do hospedeiro estão conectadas e quais
extensões estão ativas em cada área. A mesma matriz é cruzada com o plano de
sequências de cada ciclo: ciclos que referenciam uma ação de E/S do hospedeiro
não implementada falham antes que qualquer VM seja acessada, com uma mensagem
que identifica o backend ausente, em vez de falhar mais tarde dentro de uma
etapa com "Unknown host: ...".

Implementação:
[`test/modules/Test.Capability.psm1`](../../test/modules/Test.Capability.psm1).
Expõe três registros subjacentes:
[provedores OCR](../ocr.md),
[provedores de E/S do hospedeiro](../host-io.md) e
[áreas de extensão](../extensions-api.md).

<a id="42d38664-0010"></a>

<a id="the-banner"></a>

### O banner

```
---------------------------------------------------------
Yuruna capability matrix (host.windows.hyper-v)
---------------------------------------------------------
  Host I/O:   Send-Click, Send-Key, Send-Text
  OCR:        winrt, tesseract
  Recovery:   VNC reconnect (built-in (clear cached handle)), screenshot (legacy capture)
  Extensions:
    authentication         default
    caching-proxy-parser-service   default
    notification           default
---------------------------------------------------------
```

É impresso uma vez por ciclo, logo após o sucesso de `Resolve-CyclePlan`. Entra
no log HTML de cada ciclo pelo fluxo Information, para que quem analisa uma
falha veja o que estava conectado no início do ciclo sem precisar executá-lo novamente.

<a id="42d38664-0011"></a>

<a id="the-cycle-plan-gate"></a>

### A barreira do plano de ciclo

Depois de imprimir o banner, o executor interno chama
`Test-CyclePlanCapabilityFromPlan`, que:

1. Percorre cada sequência do plano de ciclo (incluindo blocos `retry`
   aninhados) e coleta os verbos de ação usados.
2. Para cada verbo, consulta seus requisitos por meio de
   [`Test.SequenceAction\Get-SequenceActionRequirementMap`](../../test/modules/Test.SequenceAction.psm1) --
   cada verbo declara quais ações de E/S do hospedeiro precisa e se OCR é necessário.
3. Cruza os requisitos com as matrizes ativas de
   `Test.HostIO`/`Test.OcrEngine`.

Quando uma ação de E/S do hospedeiro exigida está ausente, o ciclo é abortado com:

```
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  CAPABILITY GATE FAILED -- cycle aborted on 'host.ubuntu.kvm'.
  Sequences reference host I/O actions this host has no backend for:
    - Send-Click
  Wire a backend via Register-HostIOProvider in Test.SequenceEngine.psm1,
  or drop the requiring action from the cycle's sequence YAMLs.
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
```

Se um motor OCR é exigido, mas nenhum provedor está habilitado+disponível,
é produzida a mensagem correspondente:

```
  Sequences require OCR but no OCR provider is enabled+available.
  Install tesseract or wire a per-host provider via Register-OcrProvider.
```

O ciclo NÃO inicia uma VM após uma falha na barreira de capacidades;
`$GuestList` é esvaziado para que o laço por convidado execute zero iterações,
e o ciclo é finalizado com `$OverallPassed=false`. Isso incrementa
`ConsecutiveFailures` e dispara notificações no mesmo limite usado
para qualquer outra falha.

<a id="42d38664-0012"></a>

<a id="unknown-verbs-are-warnings-not-failures"></a>

### Verbos desconhecidos geram avisos, não falhas

Quando uma sequência referencia um verbo não registrado em
`Test.SequenceAction`, a barreira emite um `Write-Warning` que lista os
verbos desconhecidos, mas NÃO aborta o ciclo. O switch de ações do motor em
[`Test.SequenceEngine.psm1`](../../test/modules/Test.SequenceEngine.psm1)
lança uma exceção em tempo de execução; o aviso revela o erro de digitação /
novo verbo em desenvolvimento antes do caminho lento.

<a id="42d38664-0013"></a>

<a id="whats-in-the-requirements-table"></a>

### Conteúdo da tabela de requisitos

Atualmente (consulte as chamadas a `Register-SequenceAction` em
[`Test.SequenceHandler.psm1`](../../test/modules/Test.SequenceHandler.psm1)):

| Verbo                    | HostIO exigido            | OCR exigido  |
|--------------------------|---------------------------|--------------|
| `pressKey`               | `Send-Key`                | não          |
| `inputText`              | `Send-Text`               | não          |
| `inputTextAndEnter`      | `Send-Text`, `Send-Key`   | não          |
| `tapOn`                  | `Send-Click`              | sim          |
| `waitForText`            | _(nenhum)_                | sim          |
| `waitForTextWithNudge`   | `Send-Key`                | sim          |
| `waitForAndEnter`        | `Send-Text`, `Send-Key`   | sim          |
| `passwdPrompt`           | `Send-Text`, `Send-Key`   | sim          |
| `fetchAndExecute`        | `Send-Text`, `Send-Key`   | sim          |
| `networkRelease`         | `Send-Text`, `Send-Key`   | não          |
| `sshExec` / `sshFetchAndExecute` / `sshWaitReady` | _(nenhum)_ | não |
| `startVm` / `saveDiskSnapshot` / `loadDiskSnapshot` / `saveGuestClockSnapshot` / `saveSystemDiagnostic` / `takeScreenshot` / `break` / `callExtension` / `recoverFromSnapshot` / `retry` / `waitForSeconds` | _(nenhum)_ | não |

Adicionar um novo verbo exige uma chamada a `Register-SequenceAction` que
declare suas capacidades -- a barreira o reconhece no próximo ciclo.

<a id="42d38664-0014"></a>

<a id="guest-coverage-caveats"></a>

### Ressalvas sobre a cobertura de convidados

Uma exceção de licenciamento da Apple quebra a premissa do ambiente de testes
de que todo convidado pode ser executado em todo hospedeiro: **macOS 26** só
pode ser virtualizado em um hospedeiro macOS. `host/windows.hyper-v/guest.macos.26/`
e `host/ubuntu.kvm/guest.macos.26/` não existem por decisão de projeto;
`host/macos.utm/guest.macos.26/` é o único caminho. Planos de ciclo que
visam `guest.macos.26` em um hospedeiro não macOS falham no planejamento,
quando a pasta do convidado não pode ser descoberta, e não no meio de uma etapa.

<a id="42d38664-0015"></a>

<a id="calling-the-matrix-outside-a-cycle"></a>

### Consulta da matriz fora de um ciclo

A matriz pode ser consultada programaticamente:

```
Import-Module test/modules/Test.Capability.psm1 -Global -Force
Import-Module test/modules/Test.SequenceEngine.psm1 -Global -Force   # populates the registries

$matrix = Get-HostCapabilityMatrix -HostType 'host.windows.hyper-v'
$matrix.hostIO        # @('Send-Key','Send-Text','Send-Click')
$matrix.ocr           # @('winrt','tesseract')
$matrix.extensions    # ordered dict: area -> [active...]
```

Usada por futuras verificações de saúde, testes básicos de CI e pelo futuro
endpoint `/control/capability` no status service.

<a id="42d38664-0016"></a>

<a id="host-condition-registry"></a>

## Registro de condições do hospedeiro

Cada plataforma de hospedeiro compatível (Windows Hyper-V, macOS UTM, Ubuntu KVM)
expõe o mesmo contrato de três métodos:

- `Set-<Platform>HostConditionSet` -- aplica as configurações de que o
  executor não supervisionado precisa (tempo limite da tela, bloqueio de tela,
  cache do sudo, associação ao grupo libvirt, ...). Chamado por `Enable-TestAutomation.ps1`.
- `Assert-<Platform>HostConditionSet` -- condiciona cada ciclo de testes à
  permanência dessas configurações em vigor.
- `Test-<Platform>HostMinimum` -- verificação rápida para auxiliares pontuais
  do operador (`Remove-TestVMFiles.ps1`, `Remove-OrphanedVMFiles.ps1`,
  ...) em que o Assert completo indicaria um falso positivo durante
  a manutenção interativa.

A fachada
[`test/modules/Test.HostCondition.psm1`](../../test/modules/Test.HostCondition.psm1)
contém o registro; cada módulo irmão de plataforma
([`.Mac`](../../test/modules/Test.HostCondition.Mac.psm1),
[`.Windows`](../../test/modules/Test.HostCondition.Windows.psm1),
[`.Linux`](../../test/modules/Test.HostCondition.Linux.psm1))
é importado com `-Global -Force` para que a fachada possa reexportar seus
nomes de funções, e exporta o trio correspondente mais alguns auxiliares
específicos da plataforma (concessões TCC no macOS, regras de firewall no
Windows, diagnósticos de libvirt no Linux). A detecção pura / derivação de
nomes de VM fica em `Test.HostDetection.psm1`.

O registro substitui cadeias paralelas de despacho por hospedeiro: o despacho
inline exige duas edições em dois arquivos para cada novo hospedeiro; o registro
exige uma chamada a `Register-HostConditionProvider`. Os chamadores mantêm
`Import-Module Test.HostCondition` e resolvem os nomes como antes.

<a id="42d38664-0017"></a>

<a id="public-surface"></a>

### Interface pública

| Função | Usada por |
|---|---|
| `Register-HostConditionProvider -HostType -Assert -AssertMinimum [-RequiresElevation] [-Display] [-DisplayTeardown] [-ClockSync] [-NetworkHealth] [-MetricsExporter]` | Carregador da fachada; plugins externos de hospedeiro |
| `Get-HostConditionProvider -HostType` | Despachadores; introspecção |
| `Get-HostConditionProviderMatrix` | Matriz de capacidades na inicialização |
| `Clear-HostConditionProvider` | Somente testes |
| `Assert-HostConditionSet -HostType` | Barreira por ciclo do executor externo |
| `Get-HostClockSkew` / `Get-HostClockSkewLimit` | Medição do relógio do hospedeiro (NTP direto por UDP) |
| `Write-HostClockDriftWarning -HostType` | `Assert` de cada plataforma -- mede uma vez por processo e avisa |
| `Reset-HostClockReport` | Somente testes (rearma a trava que permite uma execução por processo) |
| `Sync-HostClock -HostType` | Oferta de correção de `Test-Config`; `Enable-TestAutomation.ps1` -- nunca um ciclo em execução |
| `Test-ElevationRequired -HostType` | Auxiliares de limpeza ([`Test.HostDetection`](../../test/modules/Test.HostDetection.psm1)) |
| `Test-HostRequirement -HostType [-Quiet]` | Auxiliares pontuais do operador ([`Test.HostDetection`](../../test/modules/Test.HostDetection.psm1)) |

<a id="42d38664-0018"></a>

<a id="provider-record-shape"></a>

### Estrutura do registro de provedor

Cada registro contém um dicionário ordenado de nove campos:

```
@{
    HostType          = 'host.windows.hyper-v'
    Assert            = { param([string]$HostType) ... [bool] }
    AssertMinimum     = { param() ... [bool] }
    RequiresElevation = $true   # consumed by Test-ElevationRequired
    Display           = { param() ... }   # optional: per-cycle display-surface ensure (e.g. attach a virtual monitor on headless Hyper-V); $null when unneeded. Invoked by Initialize-HostDisplay.
    DisplayTeardown   = { param() ... }   # optional inverse: tear the surface down; $null when unneeded. Invoked by Remove-HostDisplay.
    ClockSync         = { param() ... @{ Succeeded; Message } }   # optional: put this host's clock back under NTP discipline. Invoked by Sync-HostClock from the operator-facing paths only -- it needs privileges an unattended cycle cannot obtain.
    NetworkHealth     = { param([string]$HostType) ... }   # optional: can this host still put a guest on a working network? $null for a host with no way to answer. Invoked by Test-HostGuestNetworkHealth.
    MetricsExporter   = { param() ... @{ Status; Reason } }   # optional: per-cycle convergence of this host's metrics exporter; $null for a host where that repair would have to ask for its privilege. Invoked by Initialize-HostMetricsExporter.
}
```

`Assert` recebe `-HostType` e pode ser chamado várias vezes por ciclo. `AssertMinimum` é mais leve que
`Assert` (sem verificações de tempo limite da tela / bloqueio de tela /
concessões TCC), para auxiliares de limpeza que legitimamente são executados
durante a manutenção interativa.

<a id="42d38664-0019"></a>

<a id="three-platforms-today"></a>

### As três plataformas atuais

| HostType | RequiresElevation | Condições exigidas por `Assert` | `ClockSync` |
|---|---|---|---|
| `host.windows.hyper-v` | `$true` | Elevação de Administrador, serviço vmms, tempo limite da tela, tela de bloqueio | W32Time -> Automático + iniciado + `w32tm /resync /force` |
| `host.macos.utm` | `$false` | Concessões TCC de Acessibilidade + Gravação de Tela, repouso da tela, bloqueio de tela | `systemsetup -setusingnetworktime on` + `sntp -sS` |
| `host.ubuntu.kvm` | `$false` | `/dev/kvm` presente, libvirtd ativo, ida e volta de virsh, conjunto de grupos do shell atual inclui `libvirt` | `timedatectl set-ntp true` + ajuste imediato do daemon ativo |

Todo `Assert` também informa o relógio do hospedeiro, mas nunca o usa como
condição para prosseguir -- veja abaixo.

O diagnóstico do `Assert` do Linux distingue "kvm missing" de
"libvirtd down", de "stale group set" e de "not in libvirt group at
all", para que o operador receba etapas que possa executar, em vez de uma
mensagem genérica "permission denied".

<a id="42d38664-001a"></a>

<a id="the-host-clock"></a>

### O relógio do hospedeiro

Cada hipervisor aqui inicializa o relógio do convidado a partir do hospedeiro
ao ligá-lo; portanto, um hospedeiro cujo relógio se desviou inicia todas as VMs
com o mesmo erro -- e o cliente NTP do próprio convidado o ajusta para a hora
real segundos após a inicialização, em meio ao que esse convidado estiver
iniciando. Um convidado Kubernetes sobrevive a esse ajuste parecendo saudável
em todos os aspectos, exceto naquele que importa: pods `Running`, mas nunca
`Ready` (seus timestamps de status ficam no futuro, então `kubectl` mostra a
idade como `<invalid>`), Services sem endpoints, todos os NodePort recusando
conexões, enquanto um `curl` direto ao IP do pod responde `200`. Nada nesse
cenário aponta para um relógio.

Um ciclo informa o relógio; somente um operador o corrige. A correção de cada
plataforma é uma chamada privilegiada -- Administrador ou uma credencial sudo
que ninguém está presente para digitar --, portanto um laço não supervisionado
não pode executá-la nem parar para perguntar, e um hospedeiro que recusasse
ciclos por causa do relógio não executaria nenhum até alguém perceber.

| Nível | O que acontece |
|-------|--------------|
| `Write-HostClockDriftWarning`, no `Assert` de cada plataforma | Mede **uma vez por processo** (um processo novo executa cada ciclo, portanto uma vez por ciclo) e avisa quando ultrapassa `Get-HostClockSkewLimit` (120s), explicando o sintoma. O ciclo continua. Um relógio **impossível de medir** não gera mensagem -- um laboratório isolado não tem rota para um servidor de horário e é uma implantação normal. |
| `Test-Config.ps1` | Informa o desvio e oferece a correção -- somente a um console que pode responder. A aceitação prepara o cache de credenciais sudo (`Initialize-SudoCache`) antes de `Sync-HostClock`, porque a sincronização de todas as plataformas usa `sudo -n` e, sem isso, falharia mesmo após a resposta recém-dada. |
| `Set-*HostConditionSet` / `Enable-TestAutomation.ps1` | A correção duradoura: habilitar o serviço de horário da plataforma para mantê-lo sincronizado. |

`Get-HostClockSkew` fala NTP diretamente por UDP em vez de invocar o cliente de
horário da plataforma: em um hospedeiro com desvio, esse cliente geralmente está
quebrado ou ausente, sua saída é localizada e seus tempos limite não podem ser
escolhidos por nós. Retorna `$null` -- nunca `0` -- quando nada responde, para
que "unreachable network" nunca seja confundido com "disciplined clock".

<a id="42d38664-001b"></a>

<a id="registry-shape"></a>

### Estrutura do registro

A fachada chama
[`New-YurunaRegistry -Name 'HostCondition' -AnchorVar
'YurunaHostConditionProviders'`](../../test/modules/Test.Registry.psm1)
e expõe wrappers finos em torno de `Register` / `Get` / `GetMatrix` /
`Clear`. As entradas de provedores sobrevivem às reimportações da fachada
com `-Force` porque o armazenamento subjacente fica ancorado em
`$global:YurunaHostConditionProviders` -- o mesmo padrão de proteção contra
remoção usado por `Test.HostIO`, `Test.SequenceAction` e `Test.CredentialProvider`.
Portanto, `Assert-HostConditionSet`, `Test-ElevationRequired` e
`Test-HostRequirement` são consultas puras ao registro.

<a id="42d38664-001c"></a>

<a id="adding-a-new-host"></a>

### Adição de um novo hospedeiro

1. Implemente as três funções para sua plataforma:
   - `Set-<Platform>HostConditionSet -HostType <id>`
   - `Assert-<Platform>HostConditionSet -HostType <id>`
   - `Test-<Platform>HostMinimum`
2. Adicione um módulo irmão em `test/modules/Test.HostCondition.<Platform>.psm1`
   e exporte o trio.
3. Adicione o módulo irmão ao bloco `Import-Module` da fachada; adicione a linha
   `Register-IfAvailable` que lista o novo HostType + nomes de funções +
   `RequiresElevation`. Adicione `-ClockSyncFn` apontando para um
   `Sync-<Platform>HostClock` que retorne `@{ Succeeded; Message }`
   -- sem ele, a plataforma informa um relógio com desvio, mas não oferece ao
   operador uma forma de corrigi-lo.
4. Adicione o token `HostType` correspondente à descoberta `Get-HostType` de
   [`Test.HostDetection`](../../test/modules/Test.HostDetection.psm1)
   para que a nova plataforma possa ser detectada.
5. Forneça um driver de hospedeiro em
   `host/<short>/modules/Yuruna.Host.psm1`
   que corresponda ao contrato de `Yuruna.Host` (`New-VM`, `Start-VM`,
   `Stop-VM`, `Remove-VM`, `Get-VMState`, ...).
6. A matriz de capacidades da inicialização reconhece a nova entrada
   automaticamente.

Registros relacionados: [Login no registro de componentes](../authentication.md#component-registry-login)
-- o mesmo padrão de âncora global protegido contra remoção, implementado
manualmente em vez de usar `New-YurunaRegistry`; [Registro de E/S do hospedeiro](../host-io.md)
-- o registro mais antigo de dois níveis que estabeleceu o padrão. Análises
detalhadas por plataforma: [Hospedeiro macOS](../host-macos.md), [Hospedeiro Hyper-V](../host-hyperv.md).

<a id="42d38664-001d"></a>

<a id="state-sidecars"></a>

## Arquivos auxiliares de estado

Todo arquivo auxiliar de estado do ambiente de testes (pidfile, arquivo JSON
auxiliar, marcador de runtime) passa pelo gravador atômico em
[`modules/Test.StateFile.psm1`](../../test/modules/Test.StateFile.psm1)
(`Write-YurunaStateFile`, `Write-YurunaStateFileJson`). O contrato:

1. Grave o conteúdo em `<Path>.<PID>-<GUID>.tmp` como UTF-8 (sem BOM por
   padrão; `-WithBom` para scripts PowerShell que precisam atender a
   `PSUseBOMForUnicodeEncodedFile`).
2. Use `[System.IO.File]::Move(<tmp>, <Path>, $true)` -- operação atômica em
   NTFS / ext4 / APFS no mesmo volume, uma única chamada de sistema de renomeação.
3. Retorne `$true` em caso de sucesso, `$false` em caso de falha. O próprio
   auxiliar é silencioso -- chamadores de alta frequência não inundam `Verbose`.
   Os chamadores registram a razão específica no ponto de chamada, se necessário.

Um leitor concorrente vê o arquivo anterior (se existir) ou o novo arquivo
completo -- nunca uma gravação parcial; portanto, a varredura de recuperação
na inicialização pode confiar em cada arquivo auxiliar que encontra no disco.

**Nome temporário exclusivo por gravador.** Um `$Path.tmp` fixo permite que
dois processos que gravam no mesmo destino (por exemplo, o executor e o status service, ambos descarregando `status.json`) renomeiem o arquivo temporário
parcialmente gravado do outro. `PID + GUID` mantém privado o arquivo temporário
de cada gravador; a renomeação para o caminho final permanece atômica. O sufixo
`.tmp` é preservado para que as regras de limpeza/ignorar `*.tmp` continuem correspondendo.

<a id="42d38664-001e"></a>

<a id="single-instance-locks"></a>

## Bloqueios de instância única

Vários processos do ambiente de testes devem ter no máximo uma instância por
diretório de runtime -- o beacon de endereço do hospedeiro, o encaminhador de
push do grupo e a drenagem do armazenamento de grupos. São usados dois formatos
de bloqueio, e cada detalhe de ambos impede uma falha que, de outro modo, seria silenciosa.

**Um handle mantido pelo SO, quando o kernel pode ser o bloqueio.** O beacon
abre seu arquivo de bloqueio com `FileShare::None` e mantém o handle aberto
durante toda a execução: um segundo beacon não pode abri-lo, e o kernel o libera
quando o processo morre -- inclusive quando é encerrado à força, sem executar
código de limpeza. Nada analisa o arquivo; seu conteúdo serve apenas para diagnóstico.

**Um registro de PID, quando um bloqueio obsoleto precisa poder ser retomado.**
O encaminhador e a drenagem criam o arquivo com `[System.IO.File]::Open` no modo
`CreateNew` -- uma criação pelo SO somente se não existir -- e registram o PID
do detentor junto com a hora de início do processo. A aquisição atômica é o que
torna seguros os iniciadores concorrentes: verificar e depois gravar falha
diante de um iniciador que lê o arquivo de zero bytes criado pelo vencedor,
mas ainda não preenchido, não consegue analisá-lo, conclui que o bloqueio está
obsoleto e o retoma.

**A identidade é PID E hora de início.** A verificação de atividade exige tanto
um PID ativo quanto uma hora de início correspondente, para que a reutilização
de PID pelo SO após uma falha não permita que um bloqueio obsoleto se passe por
um detentor em execução -- o que impediria para sempre o trabalho protegido,
sem nunca informar isso.

**A hora de início é registrada como ticks, nunca como timestamp formatado.**
`ConvertFrom-Json` materializa um campo ISO-8601 como `[datetime]`, e sua
renderização de volta para uma string produz um valor formatado pela cultura
(`08/11/2026 19:07:24`) que nunca pode ser igual ao formato de ida e volta `'o'`
em que foi gravado. Toda comparação diverge, toda inicialização considera
obsoleto um bloqueio ATIVO e o retoma, e a garantia de instância única desaparece
sem nada no log. Um número sobrevive à ida e volta sem alterações.

**Ocupe a posição antes do trabalho dispendioso.** O beacon adquire seu bloqueio
antes das importações de módulos que vêm a seguir: elas carregam o driver do
hospedeiro e levam segundos, e dois beacons iniciados com segundos de diferença
passariam pela verificação antes que qualquer um tivesse gravado algo.

**O local do bloqueio faz parte do projeto.** O bloqueio do armazenamento de
grupos é mantido pelo orquestrador, e não pelo script wrapper desacoplado,
porque o modo de movimentação chama a função diretamente e no mesmo processo
-- um bloqueio mantido apenas pelo script permitiria que o movimentador síncrono
disputasse com uma drenagem desacoplada que ainda processa uma fila anterior,
com um deles excluindo pastas locais de onde o outro ainda está copiando.

<a id="42d38664-001f"></a>

<a id="statusjson-history-schema"></a>

## Esquema do histórico de status.json

O `guestSummary` de cada entrada do histórico é um `[ordered]@{}`, para que o
JSON preserve a ordem de `guestSequence`. Um `@{}` simples é uma `[hashtable]`
cuja enumeração é agrupada em buckets e arbitrária, o que embaralharia a ordem
dos indicadores na tabela "Recent Cycles" do painel, mesmo que o ciclo tenha
sido executado na ordem correta.

Estrutura do valor por convidado (compatível com versões anteriores):

| Estrutura | Significado |
|-------|---------|
| `"pass"` / `"fail"` (string simples) | Linhas antigas do histórico, anteriores a `stepDurationsSeconds` / `failureArtifacts`. Painéis mais antigos ainda as renderizam. |
| `{ status, stepDurationsSeconds, [failureArtifacts], [errorMessage], [failureClass] }` | Forma atual. |

- `stepDurationsSeconds` é um mapa de segundos de tempo real por etapa, com
  uma entrada para cada etapa na lista de etapas do convidado (`New-VM`, `Start-VM`,
  `Start-GuestOS`, `New-VM.Resource` e, opcionalmente, `Screenshots` /
  `Start-GuestWorkload`). Permite analisar tendências p50/p95 no histórico
  sem pesquisar os logs com grep.
- `failureArtifacts` está presente somente quando existe uma pasta de
  depuração, para manter compacto o conteúdo dos ciclos em que tudo passou.

O painel lê `.status` na forma de objeto e, como alternativa, usa o valor
inteiro como string, para que ambas as estruturas continuem sendo renderizadas.

Cada entrada do histórico também contém um array `sequenceSummary` --
`[{ name, status, folderUrl }]`, um elemento por sequência de test.runner.yml
executada pelo ciclo, na ordem da lista do executor. A tabela "Recent
Cycles" do painel renderiza um botão por elemento, vinculando `folderUrl` à
pasta de resultados dessa sequência (a pasta por VM do convidado controlado
para uma sequência 1:1; a pasta do ciclo quando uma sequência abrange mais de
um convidado). `status` é o pior resultado entre os convidados da sequência
(`fail > running > pass > skipped > pending`). O campo é `[]` no caminho
legado de `guestSequence` (sem sequências) e está ausente das linhas gravadas
antes de sua existência; em ambos os casos, o painel recorre aos indicadores
por convidado de `guestSummary`.

Cada entrada do histórico também contém seu próprio snapshot de `gitCommits`,
para que uma linha gravada meses atrás ainda aponte para os commits corretos
do framework + projeto, mesmo que o executor tenha passado a usar uma nova URL
de repositório ou adicionado/removido um clone de projeto.

O evento NDJSON de abertura do ciclo contém o mesmo array `gitCommits`, para
que um consumidor que lê apenas o fluxo de eventos possa identificar as
revisões do framework e do projeto usadas por um ciclo sem buscar o status.json
do hospedeiro -- que, no momento da leitura do fluxo, descreve o ciclo em
execução naquele instante, e não aquele a que os eventos pertencem. Entrada do
framework primeiro, entrada do projeto em segundo, SHAs curtos, e a chave fica
totalmente ausente de um ciclo cujos commits não puderam ser resolvidos.

<a id="42d38664-0020"></a>

<a id="status-service-port-orphan-resolution"></a>

## Resolução de processos órfãos na porta do Status-service

As verificações de pidfile em `Start-StatusService.ps1` conhecem apenas o
último servidor que *nós* iniciamos. Um `pwsh` desacoplado anterior ainda pode
manter o HttpListener na porta configurada se uma execução anterior sobreviveu
ao fechamento do terminal ou se uma inicialização malsucedida sobrescreveu
`server.pid` com um PID que nunca chegou a funcionar. As novas inicializações
então terminam com:

```
Failed to listen on prefix 'http://*:<port>/' because it conflicts
with an existing registration on the machine.
```

O processo filho desacoplado registra isso em `$RuntimeDir/server.stderr` e sai,
então o script externo *parece* iniciar sem problemas enquanto nada atende;
e qualquer órfão associado a um diretório obsoleto de arquivos de controle
(`$StatusDir` ou `$StatusDir/track`, em vez de `$RuntimeDir`) continua gravando
ali, interrompendo silenciosamente os botões Pause / Cycle do painel.

Os erros explícitos do listener são gravados em `server.err`, separados da
saída stderr nativa do processo. Antes de uma inicialização autorizada, a
rotina de inicialização preserva três gerações de cada arquivo de erros
(`.previous.1` a `.previous.3`), mantendo no máximo o último 1 MiB por geração.
Uma inicialização rejeitada ou simultânea mantém os logs atuais intactos.

Os uploads de diagnósticos e logs do instalador são lidos de forma assíncrona,
em paralelo com as solicitações de verificação de saúde. Eles compartilham
um limite de quatro solicitações, têm um prazo de 30 segundos para a leitura
do corpo e mantêm os limites de tamanho de 5 MiB para diagnósticos e 4 MiB
para logs do instalador. Os uploads concluídos substituem os artefatos de
forma atômica; uploads com falha ou paralisados preservam o artefato existente.

`Resolve-PortOrphan` (em `test/modules/Test.PortOwner.psm1`) faz uma sondagem
com um `HttpListener` descartável. Se ela funcionar, a inicialização desacoplada
também funcionará. Caso contrário, identifica o proprietário real por meio
das ferramentas do SO (`netstat`/`Get-NetTCPConnection` no HTTP.sys do Windows,
`lsof` no Unix) e o encerra -- **somente** se for um processo `pwsh`
plausivelmente nosso. Proprietários desconhecidos (servidor de desenvolvimento,
outra ferramenta) recebem um erro claro, e a inicialização é interrompida.
Manter o auxiliar em `Test.PortOwner.psm1` torna o despacho reutilizável por
futuros chamadores (verificação de saúde, `Stop-StatusService`,
`Test-CachingProxyService`) sem carregar o módulo completo do status service.

<a id="42d38664-0021"></a>

<a id="status-service-port-and-the-host-firewall"></a>

## Porta do Status-service e firewall do hospedeiro

`Start-StatusService` se associa a `http://*:<port>/` (todas as interfaces), mas
o firewall do hospedeiro descarta silenciosamente TCP de entrada nas interfaces
que não são de loopback, a menos que exista uma regra de permissão -- portanto,
localhost responde enquanto um cliente da LAN (o serviço pool-aggregator, o
navegador de um operador) esgota o tempo limite. Um hospedeiro com essa lacuna
desaparece do painel de grupos e perde seu link direto para o extension-host.
`Test.StatusFirewall.psm1` centraliza a lógica de regras de permissão por SO,
usada TANTO na configuração elevada do hospedeiro feita uma única vez
(`Set-WindowsHostConditionSet` / `host/ubuntu.kvm/Enable-TestAutomation.ps1`)
quanto na autocorreção de melhor esforço em cada início do status-service.
Gerenciados: Windows Defender Firewall (`New-NetFirewallRule`) e Linux ufw.
Informados, mas nunca alterados: nftables/iptables sem ufw e o firewall de
aplicativos do macOS (com escopo por aplicativo, não por porta -- a porta não
é bloqueada por padrão).

<a id="42d38664-0022"></a>

<a id="per-cycle-diagnostic-capture"></a>

## Captura de diagnóstico por ciclo

`Save-GuestDiagnostic` (Test.Diagnostic.psm1) é executado no fim do ciclo para
trazer um snapshot do convidado para o hospedeiro. Usa uma cadeia de estratégias
com três níveis: **SSH com chave -> SSH com senha -> console**. SSH é o padrão
porque funciona da mesma forma em todo hospedeiro (Linux / macOS / Windows),
sem um injetor de teclado específico do hospedeiro, um status service
acessível pelo convidado ou um shell interativo em `tty1`. O nível de console
é a alternativa de emergência quando o próprio SSH é o problema (sshd inativo,
chave de hospedeiro divergente, falha de autenticação); quando SSH está saudável,
o diagnóstico é enviado imediatamente, sem a latência da digitação no console
e a corrupção de teclas (ausências na tabela de caracteres, tratamento de Shift
específico do hospedeiro).

Nenhum nível pode substituir as evidências deixadas por outro. Um nível que
falha após capturar saída mantém essa saída em seu próprio arquivo ao lado da
captura principal, `<stamp>.system.diagnostic.<Id>.key-ssh.txt` ou
`.password-ssh.txt`, e o manifesto lista cada um desses arquivos em
`rungEvidence`, com seu código de saída e seus indicadores de tempo limite
e truncamento. O nível de console faz o convidado enviar para
`<stamp>.system.diagnostic.<Id>.console.txt`: um envio que chega a tempo é
renomeado para a captura principal, e um que chega depois que o nível desistiu
permanece com seu próprio nome. Quando todos os níveis falham, a captura
principal contém a saída malsucedida mais informativa -- `$lastResult`
mantém a mais completa das capturas SSH.

Cada nível SSH retém até 16,777,216 caracteres por fluxo. Um relatório maior
que o limite é informado como truncado e o nível como malsucedido, transferindo
a captura para o próximo nível; por isso, o limite fica muito acima de um
relatório real: um convidado que executa Kubernetes com um projeto implantado
já produz cerca de 600 KB.

O nível de console baixa apenas `automation/Get-SystemDiagnostic.ps1`
para `/tmp` do convidado, portanto esse script não importa nenhum módulo.
Ele contém sua própria cascata de níveis de log, renderizador de mensagens
e o texto en-US de cada mensagem que imprime; dentro de um checkout, renderiza
por meio dos catálogos compilados no idioma configurado. Depois de alterar
uma mensagem impressa pelo script, compile os catálogos e execute
`pwsh -NoProfile -File tools/Update-SystemDiagnosticText.ps1`;
`Test.SystemDiagnosticSelfContained.Tests.ps1` falha até que a cópia incorporada
corresponda ao catálogo.

Toda a captura é executada em `Invoke-GuestDiagnosticWorker.ps1`, supervisionada
por um **prazo monotônico de 300 segundos**. Isso inclui a inicialização do
processo, amostras do hospedeiro e do convidado, chamadas ao driver do hospedeiro,
consulta de credenciais, SSH, entrada no console e limpeza. Cada tentativa SSH
tem um **limite de 60 segundos**; drenagem de fluxos, encerramento da árvore de
processos e liberação de recursos compartilham esse limite. A limpeza bloqueante
é executada fora do runspace PowerShell do chamador.

O worker restaura o nome de usuário SSH e o endereço comprovado do convidado
atual, o driver do hospedeiro e a localidade resolvida do operador. Importa-os
em um processo separado para preservar o estado do driver do executor ativo.
SSH com senha passa `SSHPASS` somente no ambiente do cliente filho.

Checkpoints atômicos e específicos da invocação preservam as amostras concluídas
e a saída SSH parcial antes de iniciar outra alternativa. O supervisor grava
o `.manifest.json` final, incluindo `diagnosticOutcome`, `timedOut`,
`budgetExceeded`, `elapsedSeconds` e o status de limpeza do worker. Um worker
cujo prazo expirou produz `reasonCode: diagnostic-deadline-exceeded`; o idioma
de exibição não determina o resultado. A falha de diagnóstico continua sendo
não fatal para a sequência, e o watchdog do ciclo continua independente.

O wrapper Linux de fetch também ativa um gravador de diagnóstico no convidado
antes de iniciar uma invocação não sensível. Ele funciona independentemente do
pipeline do console e do SSH. A cada 30 segundos, registra UTC, ID de boot e
uptime, IDs da invocação, CPU/estado por thread e uma quantidade limitada de
pilhas de threads executáveis, que consomem muita CPU ou estão bloqueadas,
pressão, interrupções, estatísticas de disco, atributos dos canais VMBus e
mensagens recentes do kernel. Os inventários de processos usam nomes de
comandos sem argumentos nem ambiente. Pilhas ausentes ou sem permissão ficam
explícitas na amostra. Credenciais conhecidas do ambiente, atribuições de
segredos, cabeçalhos de autorização e blocos de chaves privadas são filtrados
antes da retenção local ou do envio; etapas sensíveis desativam o gravador e o
trace.

Cada coleta tem limite de 8 segundos e mais 1 segundo para encerramento. O
gravador mantém oito amostras de até 128 KiB cada, para após 240 amostras ou duas
horas e verifica o shell que o invocou a cada segundo durante a espera. Coletas e
envios em andamento mantêm seus próprios limites quando esse shell termina. O
campo `sampleDurationSeconds` e os limites de bytes tornam visível o custo da
coleta. Os valores manuais opcionais `EXEC_RECORDER_INTERVAL_SECONDS` (1-300) e
`EXEC_RECORDER_MAX_SAMPLES` (1-240) alteram o intervalo e a quantidade de
amostras; `EXEC_RECORDER=0` desativa a gravação. Esses controles não alteram o
prazo de execução da carga de trabalho. Em um host Linux de validação local,
uma coleta levou 24 ms e produziu aproximadamente 19 KiB; meça separadamente o
convidado ARM64.

O runner fornece um caminho relativo `E_RECORDER_PATH` vinculado à integridade
e direcionado à pasta existente do convidado no ciclo. O wrapper reutiliza a
origem resolvida do host ou as coordenadas confiáveis do seed; preparar a
captura não faz outra chamada ao driver do host. Cada amostra substitui
`execution.system.diagnostic.<stepInvocationId>.txt` pelo handler de upload
existente `/diagnostics/<cycle>/<guest>/<file>`, cuja gravação atômica e limite
de 5 MiB também se aplicam aqui. Cada POST tem limite de 6 segundos, além do
prazo de encerramento; falhas no envio aparecem na próxima amostra e no arquivo
local `status`. O envio final marca o gravador como parado. As amostras locais
permanecem no diretório privado `/tmp/yuruna-fae-recorder.*` indicado no log de
execução até a limpeza do convidado. Sem um endpoint de status, a gravação local
continua funcionando.

Após uma invocação lenta ou com falha, `fetch-and-execute.<id>.evidence.json` e o
registro de evidências de execução de `step_end` distinguem timeout do SSH,
trace ausente, divergência de invocação, saída parcial e captura completa. Um
envio anterior do gravador continua vinculado quando o SSH não responde, com o
UTC e a idade do heartbeat. Assim, a duração de uma tentativa de captura não
oculta a ausência de um artefato.

**Verificação prévia de Wait-SshReady.** Sequências frequentemente terminam com
"Reboot the
VM", portanto o convidado pode estar reiniciando quando `Save-GuestDiagnostic`
é executado. Sem uma barreira que exija um handshake real, a chamada seria
interrompida em `Get-GuestAddress` (pasta por convidado vazia) ou gravaria um
arquivo quase inútil cujo conteúdo seria apenas o erro de conexão SSH (uma
condição de corrida "half-up sshd", com a porta 22 aberta, mas o sshd ainda
estabelecendo o vínculo -- consulte `feedback_save_diag_post_reboot.md`).
`Wait-SshReady` consulta um handshake real `echo yuruna-ssh-ready` e resolve
novamente `Get-GuestAddress` a cada iteração, para que uma entrada KVP que se
estabelece tarde no vSwitch External do Hyper-V seja reconhecida automaticamente.
Ao esgotar o tempo limite, os níveis SSH são ignorados, e a alternativa de
console pode usar o orçamento restante.

O orçamento de espera é limitado por `min(180, remaining-of-total-budget)`,
para que uma chamada próxima do prazo não leve o ciclo além do limite de
`$SaveGuestDiagnosticTotalTimeoutSeconds`. 180 s cobrem a sondagem ARP
(~5 s) + a inicialização típica do Linux após uma reinicialização (60-120 s) + margem.

<a id="42d38664-0023"></a>

<a id="watchdog-and-per-cycle-resilience"></a>

## Watchdog e resiliência por ciclo

O trabalho do executor externo é manter o interno em execução para sempre.
A detecção de heartbeat obsoleto, a proteção de instância única e o protocolo
de espera progressiva após pausa por falha ficam em
[Watchdog](../runner-outer-loop.md#watchdog-and-heartbeat-protocol). A visibilidade
do fluxo de logs por etapa é controlada por [Níveis de log](../loglevels.md).

<a id="42d38664-0024"></a>

<a id="exit-codes"></a>

## Códigos de saída

| Código | Significado |
|------|---------|
| `0` | Todos os convidados passaram (o executor foi interrompido ou concluiu) |
| `1` | Um ou mais convidados falharam, ou houve erro na verificação prévia |
| `2` | Uma verificação não pôde emitir um veredito (a admissão de VM não conseguiu comprovar que o hospedeiro está livre de outros convidados) |

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.10.11

Voltar para [Yuruna](../../README.md)
