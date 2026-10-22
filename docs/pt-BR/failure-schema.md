<a id="42820e91-0001"></a>

<a id="failure-record-schema"></a>

# Esquema do registro de falha

Quando uma etapa de sequência falha (ou o mecanismo trava durante uma etapa), o executor
grava `$YURUNA_LOG_DIR/last_failure.json` e emite uma linha NDJSON `step_failure`
em `cycle.events.ndjson`. Ambos vêm de um único construtor --
[`New-SequenceFailureRecord`](../../test/modules/Test.SequenceFailureState.psm1)
no módulo que mantém os slots --, portanto o registro e o fluxo de eventos não podem
divergir na classificação ou nos campos. O
[despachante de remediação](#remediation-dispatcher) encaminha por `failureClass`; o
vocabulário de classe/severidade/recuperação vem do registro de cada verbo
(consulte o [contrato do manipulador](../test-sequences.md#handler-contract)).

Os slots que recebem esse registro são um **armazenamento compartilhado entre módulos**, não uma
variável `$script:` por módulo. Os manipuladores de verbos do mecanismo e os manipuladores SSH/OCR
de `Test.SequenceHandler` precisam ler e gravar os mesmos slots de falha, mas uma
variável `$script:` do PowerShell é resolvida no módulo que a
*definiu* -- um manipulador em `Test.SequenceHandler` que grava
`$script:WaitForTextMatchedFailurePattern` gravaria em um escopo que o mecanismo
(`Invoke-Sequence`) nunca lê, e o sinal desapareceria silenciosamente,
classificando então uma falha do instalador como um simples tempo limite. Ancorar os
slots em um único armazenamento baseado em `New-YurunaRegistry` (uma hashtable ordenada
`$global:` protegida contra descarte e que sobrevive a reimportações com `-Force`) permite que todos os
módulos compartilhem um objeto: cada um executa `$script:Fail = Get-SequenceFailureState`
uma vez e depois lê e grava `$script:Fail.<slot>`. Esse também é o
pré-requisito que permite migrar verbos como `retry` e `recoverFromSnapshot`
para fora do mecanismo sem perder seu vínculo com o estado de falha.

O registro é gravado na raiz compartilhada de logs, e cada início de sequência o limpa
nesse local para que a localização de uma etapa de uma sequência nunca seja relatada como se pertencesse à
seguinte. Por isso, cada gravador também o espelha na pasta do ciclo em execução
(`Copy-CycleFailureRecord`) assim que a falha é classificada: em um hospedeiro
que executa vários convidados por ciclo e não para na primeira falha,
essa limpeza ocorre entre o registro de um convidado que falhou e o fim do ciclo,
portanto a cópia na raiz normalmente já desapareceu quando o notificador, o
checkpoint de retomada a quente ou o despachante de remediação a lê.

São gravadas duas cópias. `<cycleFolder>/last_failure.json` descreve
o ciclo. `<cycleFolder>/<vmName>/last_failure.json` descreve um convidado e
é gravado sempre que o registro nomeia uma VM; a identidade do convidado vem do
próprio `vmName` do registro, portanto uma falha de bootstrap, planejador ou etapa do hospedeiro que não
nomeia um convidado grava apenas a cópia do ciclo. Dois convidados que falham no mesmo ciclo mantêm
registros separados, e um consumidor que nomeia seu convidado (`Get-FailureEventData
-VMName`) lê primeiro a cópia desse convidado e recusa uma cópia compartilhada que nomeia um
convidado diferente -- assim, um convidado cuja própria falha não produziu registro é relatado
como `unknown`, em vez de herdar a causa de seu antecessor. Um registro que não nomeia
convidado é do nível do hospedeiro e continua sendo oferecido a todos. O manifesto cataloga a
cópia do ciclo como tipo `failure` e cada cópia de convidado como `failure-guest`.

`Stop-LogFile` atualiza os espelhos a partir da raiz em um resultado diferente de aprovação -- a
raiz contém qualquer enriquecimento gravado depois que o registro foi criado -- e remove
todas as cópias em uma aprovação, pois um ciclo recuperado por retomada a quente não tem falha
própria. Uma cópia na raiz mais antiga que um espelho nunca é copiada sobre ele: ela pertence a
uma execução anterior.

<a id="42820e91-0002"></a>

<a id="last_failurejson-schema-v2"></a>

## `last_failure.json` (esquema v2)

Campos de nível superior, em ordem:

| Campo | Tipo | Observações |
|---|---|---|
| `schemaVersion` | int | `2`. Os leitores escolhem o caminho de leitura com base nesse valor. |
| `stepNumber` | int | Posição da etapa que falhou, começando em 1 (a etapa externa em uma falha por esgotamento de tentativas). `0` em uma falha do mecanismo antes de qualquer etapa. |
| `totalSteps` | int | Etapas da sequência. |
| `action` | string | Rótulo de falha para leitura humana. Para esgotamento de tentativas, já vem envolvido por `retry exhausted (N attempts): ...`; para uma falha do mecanismo sem rótulo, `engine crash: <message>`. |
| `description` | string | O `description:` da etapa. |
| `vmName` / `guestKey` | string | Identidade do convidado que falhou. |
| `timestamp` | string | UTC `yyyy-MM-dd HH:mm:ss`. |
| `failureClass` | enum | Classe que permite encaminhamento por máquina. O conjunto canônico está em [`Test.FailureTaxonomy`](../../test/modules/Test.FailureTaxonomy.psm1) (fonte única para o `ValidateSet` dos verbos e o validador do esquema de eventos). As classes de convidado/sequência vêm do registro do verbo que falhou; `unknown` quando o verbo não é resolvido; `pattern_matched_failure` quando `Wait-ForText` interrompeu a espera ao encontrar um padrão de bloqueio definitivo; as classes de infraestrutura do hospedeiro `provisioning_failure` / `bootstrap_sync` / `plan_invalid` / `network_timeout` / `hypervisor_unresponsive` vêm das etapas de infraestrutura do executor (consulte [Registros de etapas de infraestrutura](#infra-stage-records)). |
| `severity` | enum | `hard` / `soft` do verbo; `unknown` quando não resolvido. |
| `suggestedRecoveries` | string[] | `SuggestedRecoveries` do verbo (sempre um array JSON, nunca `null`). |
| `actionVerb` | string | Nome do verbo que falhou (`script_error` para uma falha do mecanismo sem atribuição; o nome da etapa para um registro de infraestrutura). |
| `reason` | enum | `step` (uma etapa falhou), `crash` (o mecanismo travou durante uma etapa), `infra` (uma etapa do hospedeiro falhou fora do mecanismo de sequências) ou `watchdog_kill` (o watchdog externo enviou SIGKILL a um processo interno travado; consulte [Registros sintéticos](#synthetic--infra-records)). |
| `classificationSource` | enum | Como `failureClass` foi derivada: `verb-registry`, `pattern-match` (um padrão OCR de bloqueio definitivo reclassificou a etapa), `unresolved-verb` (`unknown` apenas porque o verbo não tem registro -- registre-o, não escale), `crash`, `infra-stage` (uma etapa de infraestrutura do executor) ou `synthetic` (um registro sintetizado pelo watchdog). Permite que um consumidor diferencie uma causa realmente nova da falta de metadados. |
| `sequenceName` | string | Nome base da sequência que falhou (sem `.yml`) -- identidade de primeira classe para encaminhamento e reprodução (o caminho continua em `context.sequencePath`). |
| `stepInvocationId` / `sequenceInvocationId` | string | Identidades da invocação externa que falhou, compartilhadas com os eventos dessa etapa. Uma tentativa que falhou mantém os IDs de seu wrapper. Vazias quando uma falha do mecanismo ou da infraestrutura ocorreu antes de existir uma invocação. |
| `originatingStepInvocationId` / `originatingSequenceInvocationId` | string | Identidades da etapa interna que falhou quando uma nova tentativa propaga uma falha interna, vinculando suas evidências de fetch e seu parecer de progresso. Nos demais casos, os IDs da própria invocação que falhou, inclusive quando um handler externo lança um erro distinto. |
| `repro` | object | Reprodução pronta para executar; consulte [repro](#repro). |

<a id="42820e91-0003"></a>

### `repro`

Uma reprodução que um operador ou remediador autônomo pode executar sem reconstruir argumentos.

| Campo | Observações |
|---|---|
| `command` | `pwsh test/Debug-TestSequence.ps1 -SequenceName <name> [-GuestKey <k>] [-VMName <vm>] -logLevel Debug`. Executa novamente, de forma determinística, a sequência que falhou (e sua cadeia de baselines). Ele **omite** deliberadamente `-StartStep`: `stepNumber` / `resumeFromStep` são **locais ao arquivo** (começando em 1 dentro deste arquivo de sequência), mas `Debug-TestSequence -StartStep` é **global à cadeia**, portanto um `-StartStep` ingênuo apontaria para a etapa errada de uma sequência folha cujo baseline ainda não foi construído. |
| `runnerScript` / `entrypoint` | `test/Debug-TestSequence.ps1` / `Debug-TestSequence`. |
| `sequenceName` | Igual ao campo de nível superior. |
| `resumeFromStep` | A etapa que falhou, local ao arquivo. É seguro passá-la como `-StartStep` apenas quando a sequência não tem baseline ainda não construído (o caminho de retomada a quente / `requiresSnapshot`, ou uma sequência sem baseline). |

<a id="42820e91-0004"></a>

<a id="replay-boundary--inner-cause-fields"></a>

### Campos de limite de reexecução + causa interna

Eles aparecem em registros **tanto** de etapa quanto de falha do mecanismo (uma falha depois que a etapa N começou ainda tem um limite seguro de reexecução e, se passou por um `retry` esgotado, uma causa interna útil para encaminhamento):

| Campo | Tipo | Observações |
|---|---|---|
| `lastSucceededStepNumber` | int | Limite de reexecução -- a etapa N teve êxito; a falha ocorreu em N+1. Um marcador de "até onde é seguro avançar na reexecução", não um ponteiro de retomada automática. |
| `innerActionVerb` / `innerFailureClass` / `innerSeverity` / `innerSuggestedRecoveries` | string / string / string / string[] | Definidos apenas quando a falha passou por um `retry` esgotado; carregam a classificação do verbo interno mais profundo, para que um remediador encaminhe pela causa interna, em vez do `retry_exhausted` externo. O [despachante](#remediation-dispatcher) encaminha por `innerFailureClass` quando a classe externa é `retry_exhausted` e existe um manipulador interno. `null` (array vazio) nos demais casos. |

<a id="42820e91-0005"></a>

### `context`

| Campo | Observações |
|---|---|
| `hostType` | Por exemplo, `host.windows.hyper-v`. |
| `matchedFailurePattern` | O padrão de bloqueio definitivo que `Wait-ForText` encontrou, ou `null`. |
| `sequencePath` | Caminho do YAML da sequência que falhou. |
| `cycleFolder` | Identidade estável do ciclo (apenas falhas de etapa) -- o mesmo valor registrado pelo fluxo NDJSON, para que este arquivo possa ser associado ao fluxo de eventos e resolvido para a pasta no disco. |
| `failureScreenshotPath` / `failureOcrPath` | Nomes relativos ao diretório do ciclo das evidências de tela desta falha (apenas falhas de etapa). **Ausentes** a menos que o artefato exista e tenha sido gravado por último depois que a etapa que falhou começou: ambos são arquivos persistentes por VM que apenas os verbos de leitura de tela regravam, portanto uma falha em um verbo que não lê texto apontaria, de outra forma, para a tela de uma etapa anterior. Um leitor segue esses ponteiros; nada os audita, portanto um nome presente é uma afirmação que o registro precisa conseguir sustentar. |
| `staleEvidence` | Cada artefato removido dos dois ponteiros acima, identificado com quantos segundos antes da etapa que falhou ele foi gravado por último; `[]` quando não houve nenhum. O arquivo continua na pasta do ciclo com esse nome, portanto evidências de uma etapa anterior continuam localizáveis enquanto os ponteiros permanecem confiáveis -- e um ponteiro ausente nunca é interpretado como "não existe nenhuma evidência de tela", que é um fato diferente com uma próxima ação diferente. |
| `causeDetail` | Apenas registros de etapa: `{ ocrTail, patternsSought }` -- o texto OCR mais recente na tela (cauda limitada, <=1200 caracteres) e os padrões procurados pela espera no ponto de falha. Permite que um consumidor veja a causa em tempo de execução por trás de uma `failureClass` estática do verbo. Espelhado sem aninhamento no evento como `causeOcrTail` / `causePatternsSought`. `patternsSought` é registrado em toda espera que expira, inclusive quando o console nunca mostrou texto legível. Também contém `freshWindowNearMiss`, `closestOnScreen`, `consoleFlood`, `consoleStaticSeconds`, `blankScreenSeconds`, `guestLivelock`, `consoleSecondOpinion`, `installerStage`, `installerStageUnchangedSeconds`, `pauseBeforeStepSeconds`, `pauseReleasedAtUtc`, `vmState`, `vmStateWaitedSeconds`, `vmStateRequestedAtUtc`, `firstGuestSilenceUtc`, `firstGuestSilenceSource`, `launcherRejection` e `aptIndexMismatch` (abaixo). |
| `crash` | Apenas registros de falha do mecanismo: `{ error, origin, stack }`. |
| `dependencyFailures` | Evidências opcionais de infraestrutura para serviços do laboratório indisponíveis. As entradas da barreira de saúde do laboratório incluem a área, os endereços tentados e os últimos endereços conhecidos, o último êxito, detalhes e o resultado da descoberta no grupo. As entradas da verificação prévia do stash incluem a área, o endereço, o endpoint, a origem, o resultado, detalhes e a tentativa de repetição. As respostas HTTP de descoberta são preservadas para diferenciar um registro ausente de um serviço inacessível. Espelhado no evento como `dependencyFailures`. |
| `hostMemory` | Apenas registros de infraestrutura, e somente quando o driver do hospedeiro conseguiu medir a máquina: `{ availableMb, committedBytes, commitLimitBytes, commitAvailableBytes, source }`. A memória de inicialização de uma VM é cobrada do limite de confirmação do sistema -- memória física mais o tamanho atual do arquivo de paginação --, não da memória física livre; por isso, uma recusa de provisionamento é explicada pelos valores de confirmação enquanto a memória física livre pode estar em seu máximo nesse mesmo instante. **Ausente** quando nada foi medido, nunca preenchido com zeros: um bloco zerado indica uma máquina que foi medida e estava vazia, que é um fato diferente com uma próxima ação diferente. Espelhado sem aninhamento no evento como `hostAvailableMb` / `hostCommittedBytes` / `hostCommitLimitBytes` / `hostCommitAvailableBytes`. |
| `hostStorage` | Evidências opcionais de armazenamento da infraestrutura: `{ allowed, status, reason, timestamp, source, errorCode, volumes, vms }`. As linhas dos volumes preservam os bytes disponíveis para o usuário que executa a chamada e os bytes necessários nos volumes reais de estado de execução/configuração e de VHD. As linhas das VMs preservam os requisitos de inicialização, os bytes alocados dos arquivos de estado de execução, as reservas adicionais de disco e as evidências do espaço ocupado pelos VHDs e checkpoints, coletadas com limites de percurso. `status` pode ser `ready`, `insufficient` ou `unknown`. Leituras indisponíveis permanecem `null`, nunca zero; o bloco fica ausente quando nenhuma sondagem foi executada. O evento contém o mesmo objeto aninhado em `hostStorage`. |

<a id="42820e91-0006"></a>

<a id="causedetail-fields-that-describe-the-screen"></a>

#### Campos de `causeDetail` que descrevem a tela

| Campo | Observações |
|---|---|
| `freshWindowNearMiss` | Definido quando uma espera `freshMatch` atingiu o tempo limite para um texto que os mecanismos OCR LERAM, mas que havia rolado para acima da janela da cauda; identifica o mecanismo, o padrão e quantas linhas acima ele estava. `[]` cobre três telas sem relação entre si -- nenhuma janela estava em vigor, a janela cobria o quadro inteiro, ou o texto realmente não aparecia em nenhum lugar dele --, portanto, sozinho, nunca é evidência de que nada se parecia com o padrão. Leia-o junto com `closestOnScreen`. |
| `closestOnScreen` | Para cada mecanismo OCR e cada padrão procurado pela espera, a linha do quadro final que mais se aproximou e o grau de proximidade, como a porcentagem de caracteres normalizados do padrão que coincidiram (uma correspondência exige 85%, medidos na mesma forma canônica usada pelo comparador, portanto a confusão entre caracteres do OCR não reduz a pontuação). Uma porcentagem alta significa que o texto foi impresso e a leitura ficou aquém do necessário -- examine a captura ou a tolerância de correspondência; uma baixa significa que a tela mostrava outra coisa, portanto o convidado nunca imprimiu o texto. Três estados, seguindo a mesma disciplina de `consoleFlood`: as linhas, quando a varredura foi executada e encontrou algumas; `[]` quando foi executada e nada no quadro se parecia com o padrão; `null` quando nunca foi executada -- uma espera que termina em um padrão de falha retorna assim que o padrão corresponde, e uma falha fora de uma espera não tem quadro próprio. Uma lista vazia é uma leitura da tela; `null` é a ausência de uma leitura, e somente a primeira sustenta uma conclusão. |
| `consoleFlood` | Definido quando o console se encheu de uma linha repetida enquanto a espera procurava seu padrão; contém a linha dominante e sua proporção da tela. `''` quando a tela não era repetitiva. `null` quando a espera restringiu a correspondência à cauda do console (`freshMatch`): esse caminho lê os mesmos quadros, mas não verifica inundação, portanto o campo diz "não examinado", em vez de "não repetitivo". |
| `consoleStaticSeconds` | O maior período, em segundos, em que o CONTEÚDO do console não mudou durante a espera. A repetição é contada dentro de um único quadro; assim, uma parede de texto que rolou antes e depois parou é interpretada como inundação -- é isso que distingue os dois casos. Um valor alto indica um convidado esperando, não trabalhando, e muitas vezes é possível desbloquear um convidado que espera respondendo a ele. `0` quando a tela continuou mudando e `null` quando a espera restringiu a correspondência à cauda do console (`freshMatch`) e nunca fez a medição -- `0` é uma leitura, `null` é a ausência de uma leitura, e somente a primeira sustenta uma conclusão sobre o convidado. Em um tempo limite de `freshMatch`, as evidências de tela são `freshWindowNearMiss` e `ocrTail`. |
| `blankScreenSeconds` | Segundos em que o console estava em branco -- nenhum mecanismo de OCR encontrou texto -- quando a espera terminou; `0` quando o último quadro tinha texto. Um console em branco deixa `ocrTail` vazio e `consoleStaticSeconds` sem medição, pois ambos leem texto; por isso, este é o campo que diz que a tela ficou preta, e não que nada foi comparado. Espelhado no evento como `causeBlankScreenSeconds`. |
| `guestLivelock` | A visão do hipervisor sobre o convidado quando a espera terminou, a partir da gravação do amostrador do host: `{ verdict, livelockedSeconds, minimumSeconds, virtualProcessors, guestRunPercent, hypervisorRunPercent, interceptsPerSecond, dominantIntercept, interceptBreakdown, sampleCount, newestSampleUtc, reason }`. `verdict` é `livelocked` quando todo processador virtual ficou pelo menos 80% ocupado, com o hipervisor detendo pelo menos 88% desse tempo, por `minimumSeconds` (300); `not-livelocked` caso contrário; e `unavailable` quando a gravação não tinha leituras recentes da VM. `interceptBreakdown` faz a média das taxas de interceptação por causa ao longo do período, da maior para a menor, e `dominantIntercept` nomeia a primeira. `null` quando o host não mantém gravação (todo host que não é Windows, ou com amostragem desativada): não medido, o que não é a mesma leitura que medido e encontrado em execução. No macOS UTM, uma espera de login dentro de uma repetição com reinício a frio pode registrar, em vez disso, um veredito de tela com os mesmos campos: `livelocked` após 300 segundos de `Display output is not active.` do QEMU com uma sonda de console `guest-wedged`, sem leituras de processador e com um `reason` que nomeia essa evidência (veja [retry](../test-sequences.md#428e4df6-001c)). Espelhado no evento como `causeGuestLivelocked` / `causeGuestLivelockedSeconds`. |
| `consoleSecondOpinion` | A sondagem independente do console pelo host, feita após esgotar o reparo da captura: veredito, explicação e medições disponíveis. No UTM, inclui o estado da VM, o PID do QEMU e a porta VNC específicos da VM, dois hashes de quadros obtidos diretamente, amostras de CPU, intervalo e horário da observação. Leituras ausentes permanecem nulas. `guest-wedged` descreve saída inalterada com o emulador ocupado; não identifica um defeito no kernel ou no hipervisor, e atividade de CPU sem quadros legíveis não descarta uma falha no caminho de captura. O objeto é preservado quando as tentativas se esgotam e em falhas aninhadas, além de acompanhar as evidências de cada tentativa. Não autoriza reiniciar uma carga de trabalho arbitrária. |
| `installerStage` / `installerStageUnchangedSeconds` | O último marcador `start:` ou `finish:` de uma etapa substantiva de Install ou Mirror do Subiquity visível durante esta espera, e os segundos desde a mudança desse marcador. O tráfego de atualizações de rede é excluído. Registra o último marcador observado, não uma prova de que seu comando ainda está em execução. `''` / `0` quando nenhuma etapa foi vista. Espelhado no evento como `causeInstallerStage` / `causeInstallerStageUnchangedSeconds`. |
| `progressAdvisory` | Observações independentes: `outputStaticSeconds`, `heartbeatAgeSeconds`, capacidade de resposta SSH, `clockWarnings` e um veredito consultivo. `sshResponsiveness` é `unresponsive` quando o harness encerrou o cliente de evidências ou quando o próprio cliente relatou um caminho morto (saída 255 com tempo de conexão esgotado, sem rota, rede inalcançável, recusa ou um nome que não foi resolvido); é `unavailable` apenas quando nenhum transporte foi medido. `clockWarnings` lista os códigos levantados pela análise de relógio das amostras do gravador da etapa (por exemplo `cpu-idle-exceeds-boot-uptime`), e uma lista não vazia acrescenta o sinal `guest-clock-anomaly`, que é evidência sobre a base de tempo do convidado e nunca um sinal de travamento por si só. Pelo menos dois sinais de travamento sustentados produzem `progress-suspect`; medições ausentes continuam como null/unavailable. A saída também é observada em esperas restritas à cauda, sem habilitar seus sinais de recuperação desativados. `automaticRecoveryAllowed` é sempre false. |
| `pauseBeforeStepSeconds` | Segundos de uma suspensão solicitada pelo operador, quando uma delas foi liberada antes da etapa que falhou. A barreira de pausa suspende o executor, não o convidado, portanto um prompt que o convidado imprimiu uma vez durante a suspensão já saiu da tela que a etapa retomada precisa ler -- o que parece idêntico a um prompt que nunca foi impresso. `0` quando não houve suspensão. |
| `pauseReleasedAtUtc` | Quando essa suspensão terminou, para que possa ser comparada ao início da própria etapa. `''` quando não houve suspensão. |
| `vmState` / `vmStateWaitedSeconds` / `vmStateRequestedAtUtc` | Definidos por `stopVm` e `startVm` quando o convidado nunca chegou ao estado parado: o estado que o hospedeiro informou quando a espera desistiu, quanto tempo ela esperou e quando o desligamento foi solicitado. A classe passa a ser `wait_timeout`, e o evento carrega `causeVmState` e `causeVmStateWaitedSeconds`. `''` e `0` nos demais casos. |
| `firstGuestSilenceUtc` / `firstGuestSilenceSource` | O primeiro momento na sequência atual em que o convidado parou de responder, e o mecanismo que percebeu isso: um transporte SSH interrompido no meio de um comando, uma entrada digitada que o console nunca reconheceu, um diagnóstico que nenhum degrau conseguiu alcançar ou uma solicitação de desligamento que o convidado ignorou. Definido uma vez por sequência pelo primeiro observador e nunca limpo por uma etapa posterior, para que o registro nomeie o primeiro sintoma e não a etapa que finalmente desistiu. `''` quando nada observou um silêncio. |
| `launcherRejection` | Definido por `fetchAndExecute` quando o inicializador do convidado (`yfe --gui`) recusou o envelope compacto digitado, lido do registro que o inicializador deixa sob o digest do envelope: `{ code, attempt, receivedChars, expectedChars, receivedSha256, expectedSha256, payloadState }`. Toda recusa acontece antes de a carga útil executar, então a classe continua sendo o padrão de falha correspondido, enquanto este campo nomeia o que o teclado entregou: um caractere recebido a mais do que o digitado é uma tecla que se repetiu. Uma recusa `YFE_GUI_ENCODING` ou `YFE_GUI_DIGEST` com `payloadState` `NOT_PREPARED` é digitada mais uma vez dentro da etapa, e um evento `retry_attempt` com `stack` `gui-envelope` a registra; `attempt` nomeia a tentativa que esta recusa encerrou. `null` quando o inicializador não recusou nada ou é anterior ao registro. Espelhado no evento como `causeLauncherRejection` (o código, `''` quando não há). |
| `aptIndexMismatch` | Definido por `sshFetchAndExecute` quando o apt relatou um índice que diverge do seu `InRelease` (`File has unexpected size` ou `Hash Sum mismatch`): `{ kind, url, receivedBytes, expectedBytes, server, releaseFileCreated, occurrences, proxyCopy, proxyPurgeStatus }`, a partir da última linha desse tipo, que é a tentativa em que a etapa falhou. `server` é o endereço e a porta que o apt indicou, que é o proxy de cache quando a busca passou por ele; `proxyCopy` e `proxyPurgeStatus` são o que `apt_retry` relatou sobre a cópia armazenada no proxy e sobre o `PURGE` que enviou (veja [Recuperar um índice do apt](../network.md#4220a755-005e)). A classe continua sendo `script_error`, porque o script de fato falhou; este campo diz que a correção está no cache ou na origem. `null` quando o apt não relatou nenhuma linha desse tipo. Espelhado no evento como `causeAptIndexMismatch` (a URL, `''` quando não há). |

A gravação é atômica (arquivo temporário + renomeação por `Write-YurunaStateFile`), para que um
remediador ou o serviço de status nunca observe um registro truncado.

`guestLivelock.processorWindow` preserva os contadores individuais do processador
e sua disponibilidade mesmo quando o predicado de livelock de todos os
processadores não é atendido. O evento os inclui em `guestProcessorWindow`.
As médias de cada contador usam suas próprias contagens de amostras válidas;
leituras ausentes ou inválidas não se tornam zeros. Os resíduos exigem medições
pareadas de todos os contadores nomeados com suporte e continuam sendo
estimativas, pois as categorias podem se sobrepor. Cada processador também
traz `hypervisorShare` (seu tempo de hipervisor sobre seu tempo ocupado),
`stormed` (ocupado pelo menos 80% com o hipervisor detendo pelo menos 88%
disso, ou pelo menos um milhão de interceptações por segundo, ao longo da
janela) e `dominantIntercept`; a janela lista `stormedProcessors` e
`stormTransitions`, os instantes de amostra em que o conjunto de processadores
em tempestade mudou. O veredito é registrado em uma espera que expirou e em uma
espera encerrada por um padrão de falha, de modo que um script que desistiu no
console carrega o estado dos processadores naquele momento.

A idade do heartbeat descreve a atividade do gravador e da amostragem do
convidado; um heartbeat recente não comprova que a aplicação progrediu.

Os eventos de fim de etapa de fetch incluem `executionEvidence` com resultado
da captura, motivo, caminho do artefato e status preservado do gravador. A captura
nomeia o transporte que encontrou: `transport` é `responsive`, `timed-out`,
`unreachable` ou `unknown`, `transportDetail` guarda a linha do cliente que
decidiu o estado, e `transportFailed` é true para os dois estados mortos; um
transporte morto mantém seu código de motivo (`profile-ssh-timeout` ou
`profile-ssh-unreachable`) acima do veredito de identidade do log, porque um
caminho que nunca alcançou o convidado nada diz sobre qual log o convidado
guarda. `recorder.clockAnalysis` executa a análise consultiva de relógio sobre
as amostras preservadas do gravador, ordenadas no tempo. A limpeza
após uma falha emite um evento `failure_diagnostic` com os resultados independentes
dos snapshots do host e do convidado, incluindo exceções na captura, além de
`sshReadiness` (a causa, o alvo, as tentativas e a última linha do cliente que a
espera de prontidão registrou quando nenhum degrau alcançou o convidado) e
`networkCrossCheck` (o veredito da verificação de alcance feita pelo próprio
host, abaixo). O snapshot de relógio após o reinício acrescenta `sshProbe`: um
toque TCP limitado no endereço comprovado, com o banner que o sshd enviou, para
que um daemon ainda iniciando e um convidado fora da rede sejam lidos de forma
diferente sem espera. Quando as
tentativas se esgotam, o manifesto e o evento de diagnóstico usam os IDs da etapa
interna de origem para se vincular ao gravador de fetch; o evento de falha mantém
os IDs do wrapper externo e publica ambos os pares. Uma falha distinta do
mecanismo externo usa seus próprios IDs. Wrappers de tentativas com falha
preservam o parecer de progresso da etapa interna, sem substituir suas
observações de SSH e heartbeat por medições indisponíveis.

<a id="42820e91-0007"></a>

<a id="step_failure-ndjson-event"></a>

## Evento NDJSON `step_failure`

Emitido junto com o arquivo para que um consumidor do fluxo (serviço de status,
laço de remediação, hook de CI) veja a falha sem ler o arquivo.
Contém os mesmos valores, sem aninhamento (sem `context` aninhado), além de
`event` = `step_failure`, `ok` = `false` e `durationMs` = `null`
(espelha o formato de `step_end`, para que um consumidor possa associar os dois por um único
campo). Também contém `reason`, `classificationSource`, `sequenceName`,
`reproCommand` (a string `repro.command`) e `matchedFailurePattern`
(o campo do contexto aninhado trazido para o nível superior). Um evento de falha do mecanismo acrescenta `crashError`. Um
evento de infraestrutura cuja etapa mediu o hospedeiro acrescenta `hostAvailableMb`,
`hostCommittedBytes`, `hostCommitLimitBytes` e `hostCommitAvailableBytes`
(o bloco aninhado `context.hostMemory` trazido para o nível superior); os quatro estão presentes ou
ausentes juntos.

Quando uma sondagem de armazenamento foi executada, `hostStorage` no evento
preserva o objeto `context.hostStorage` completo, incluindo as evidências por
volume e as leituras desconhecidas.

`failureClass`, `severity` e `suggestedRecoveries` nesse evento são a
classificação da falha que ocorreu. Uma linha `step_end` com falha contém
o registro do verbo que falhou em `verbDefaultFailureClass`,
`verbDefaultSeverity` e `verbDefaultSuggestedRecoveries`: eles dizem como
o verbo CLASSIFICARIA uma falha própria, e um padrão de falha encontrado ou um
convidado inacessível afasta a classe real do registro -- portanto, uma associação
entre as duas linhas nunca compara uma medição com uma constante sob a mesma
chave.

<a id="42820e91-0008"></a>

<a id="last_remediationjson-the-dispatchers-decision-persisted"></a>

## `last_remediation.json` (a decisão persistida do despachante)

Quando o [despachante de remediação](#remediation-dispatcher) encaminha uma falha,
grava `$YURUNA_LOG_DIR/last_remediation.json` ao lado de `last_failure.json`.
Três sinais facilmente confundidos descrevem uma falha; este arquivo mantém
durável o que tem autoridade:

- `suggestedRecoveries` do verbo é uma **dica** (o que a ação que falhou
  considera que pode ajudar),
- o evento NDJSON `remediation_recommended` é um **rastro transitório**
  no fluxo, e
- `last_remediation.json` é a **decisão** do despachante -- a única
  recomendação que um consumidor deve seguir -- gravada como arquivo autossuficiente,
  para que um consumidor que consulta periodicamente o sistema de arquivos (dashboard, serviço pool-aggregator, um
  futuro laço autônomo) nunca precise acompanhar o fluxo de eventos ou executar novamente o
  despachante para recuperá-la.

Versionado por esquema (`schemaVersion` = `1`), gravado por meio da primitiva
atômica de arquivo de estado sem BOM. Campos: `timestamp`, `runId` (a execução que o produziu), `failureClass`,
`severity`, `recommendation` (do vocabulário canônico de recuperação),
`rationale`, `actions` (string[]), `handledBy`, `autoApply`, `source`, além de
`outerFailureClass` quando o despachante encaminhou além de um envoltório
`retry_exhausted`, e os campos de correlação (`vmName`, `guestKey`, `hostType`,
`stepNumber`, `actionVerb`, `sequenceName`) que a falha continha.

`autoApply` é **sempre `false` atualmente**: o despachante registra o que deve
acontecer; nunca executa a ação. Agir sobre a recomendação é uma
capacidade separada, desativada por padrão, controlada por um limite de tentativas por ciclo, uma
lista de classes permitidas e revisão humana suficiente desses registros primeiro -- é por isso que
a decisão é persistida antes de qualquer agente que a consuma.

`Stop-LogFile` arquiva o arquivo na pasta por ciclo em um resultado diferente de aprovação
(mesmo caminho de `last_failure.json`), `Write-CycleManifest` o cataloga
como `kind` = `remediation`, e a replicação do grupo copia a pasta inteira do
ciclo -- assim, a recomendação acompanha a falha até o grupo
sem um envio dedicado.

<a id="42820e91-0009"></a>

<a id="synthetic--infra-records"></a>

## Registros sintéticos e de infraestrutura

Duas variantes de registro reutilizam o formato do esquema v2 para falhas fora de uma
etapa normal:

<a id="42820e91-000a"></a>

<a id="infra-stage-records"></a>

### Registros de etapas de infraestrutura

Etapas do hospedeiro que falham fora do mecanismo de sequências (GitPull, ProjectClone,
Resolve-CyclePlan, capability gate, folder-check, GetImage, New-VM,
Start-VM, New-VM.Resource) gravam um `last_failure.json` do esquema v2 +
um evento `step_failure` por meio de `New-InfraFailureRecord`, para que o laço de
remediação possa encaminhá-los como qualquer outra falha. Contêm `reason` =
`infra`, `classificationSource` = `infra-stage`, `stepNumber` = `0` e
`actionVerb` = o nome da etapa. A classe mapeia a etapa para uma recuperação
que permite encaminhamento: `provisioning_failure` (New-VM/Start-VM -- `retry_with_backoff`),
`network_timeout` (GetImage, e uma falha do git cuja sondagem DNS/TCP falhou
-- `retry_with_backoff`), `bootstrap_sync` (ProjectClone, ou uma divergência
do git não relacionada à rede -- `operator_intervention_required`), `plan_invalid`
(Resolve-CyclePlan / capability gate / folder-check --
`operator_intervention_required`) e `pool_storage_full`
(PoolStorageSpaceCheck / PoolStorageMove -- `operator_intervention_required`;
gravado pelo laço EXTERNO, em vez do mecanismo de sequências, pois um compartilhamento que
não pode armazenar os resultados é identificado antes da criação do ciclo ou depois que ele
termina) e `hypervisor_unresponsive` (HypervisorControl, a sondagem pré-ciclo do
canal de controle do hipervisor, ou uma ação do hospedeiro cujo início de VM
relatou o canal travado -- `operator_intervention_required`). O executor nunca sobrescreve um registro mais rico
gravado pelo mecanismo, e a gravação é totalmente protegida para que a telemetria não possa
fazer o ciclo falhar.

Uma ação do hospedeiro (uma sequência `host:` de um projeto, como `initialize-lab`)
que termina com código diferente de zero é registrada sob o próprio nome, com a
classe que a própria ação gravou em `last_failure.json` durante a execução, ou
`unknown` quando não gravou nenhuma; a descrição é a última linha de erro que a
ação imprimiu ou, na ausência dela, a última linha de saída, para que a causa que
o script nomeou sobreviva fora da transcrição.

Uma etapa cujo driver do hospedeiro consegue medir a máquina também contém
[`context.hostMemory`](#context) -- a memória física disponível e a posição de
confirmação do sistema no instante da chamada que falhou. Apenas o driver que faz essa
chamada pode obter a leitura: quando o registro é arquivado, o convidado já foi
desmontado e os números que explicam a recusa desapareceram. Drivers que não conseguem
medir seu hospedeiro omitem o bloco, em vez de preenchê-lo com zeros, para que sua
presença sempre signifique uma medição real.

A inicialização no Hyper-V também contém `context.hostStorage` quando a sondagem
de armazenamento foi executada. Uma insuficiência medida ou um erro numérico de
disco cheio (`0x80070070` / `0x80070027`) exige intervenção do operador; a proposta
de remediação não recomenda novas tentativas sem corrigir a causa. Uma sondagem
que não conseguiu medir a capacidade preserva a política de novas tentativas
existente. A admissão de armazenamento antes de um ciclo usa o caminho de falha
da barreira de configuração (amarelo no painel do grupo); uma falha de
inicialização de VM durante um ciclo continua sendo uma falha de provisionamento,
com suas evidências originais.

<a id="42820e91-000b"></a>

<a id="synthetic-watchdog-kill-record"></a>

### Registro sintético (encerramento pelo watchdog)

Quando o watchdog externo envia SIGKILL a um processo interno travado, o caminho de falha do
processo interno não pode ser executado, portanto o externo sintetiza um registro do esquema v2: `reason` =
`watchdog_kill`, `classificationSource` = `synthetic`, `failureClass` =
`wait_timeout` (para que a repetição automática limitada por falhas consecutivas possa encerrar a pausa antecipadamente).
`stepNumber` (`0`) e `sequenceName` (`''`) são intencionalmente não resolvidos
-- o SIGKILL destruiu a única localização estruturada da etapa --, não omitidos,
para que o contrato continue atendido e um remediador continue seguro diante de valores nulos.

O mesmo encerramento também chega a `status.json`. `Complete-Run` é o que normalmente
acrescenta um ciclo a `history[]`, e um processo interno encerrado nunca chega lá, portanto o
externo grava a linha por conta própria: `overallStatus` = `fail`, um `finishedAt`
próprio (o ciclo nunca registrou um), e `cycleFolderUrl` ainda contendo seu
sufixo `.incomplete/`, pois apenas o caminho de conclusão renomeia essa pasta
e os resultados parciais estão sob o nome com sufixo. A linha é identificada por
`cycleStartUtc`, portanto o par `fault` -> `paused` produzido por um encerramento grava uma
linha, e um ciclo que chegou a `Complete-Run` mantém sua própria linha mais rica. A
`failureClass` do registro é copiada para o `lastFailure` ativo quando o processo interno
não deixou nenhuma, o que impede que um ciclo encerrado apareça como `unknown`
na discriminação por classe do dashboard do grupo.

<a id="42820e91-000c"></a>

<a id="degradation-event-non-failure-observability"></a>

## Evento `degradation` (observabilidade sem falha)

O mesmo fluxo `cycle.events.ndjson` também contém eventos `degradation` --
emitidos por `Send-YurunaDegradation` (`Test.Log.psm1`) quando a estrutura de testes recorre
de um mecanismo principal a uma alternativa inferior e **continua** o
ciclo degradado. Ele é deliberadamente distinto dos eventos `*_failed` /
`*_unavailable` (uma capacidade que deixou de funcionar): uma degradação relata uma
capacidade que estava indisponível e para a qual *foi encontrada uma alternativa*, para que um
ciclo degradado, mas aprovado, possa ser consultado, em vez de parecer uma aprovação sem ressalvas.
Campos:
`event` = `degradation`, `timestamp`, `dependency` (o subsistema, por exemplo,
`keystroke-mechanism`), `primary` (mecanismo preferencial), `fallback`
(alternativa adotada), `reason` e `severity` (`soft` por natureza). A emissão é
de melhor esforço (`Send-CycleEventSafely`) e nunca faz o ciclo falhar. Um consumidor do
fluxo que conta apenas falhas deve ignorar esse tipo de evento.

<a id="42820e91-0025"></a>

## Evento `network_cross_check` (a leitura de alcance feita pelo próprio host)

Emitido por `Invoke-GuestNetworkCrossCheck` (`Test.GuestNetworkCrossCheck.psm1`)
durante a limpeza após a falha, antes do diagnóstico do convidado, e gravado ao
lado dos artefatos da falha como `network-cross-check.json` e `.txt`. A partir
do host, ele sonda o registro do proxy de cache (`/v2/`) e sua página de saúde,
e o último endereço comprovado do convidado (TCP 22, ICMP, a tabela de
vizinhos). Sondagens TCP separadas verificam as portas de escuta HTTP e HTTPS
do proxy (normalmente 3128 e 3129, respeitando os valores de porta
configurados). As sondagens do registro, da página de saúde e do convidado
nomeiam a combinação: `proxy-reachable-guest-unreachable`,
`proxy-unreachable-guest-reachable`, `both-reachable`, `both-unreachable`,
uma leitura unilateral quando apenas um dos dois pôde ser sondado
(`guest-unreachable-proxy-unknown`, `guest-reachable-proxy-unknown`,
`proxy-reachable-guest-unknown`, `proxy-unreachable-guest-unknown`) ou
`unavailable` quando nem um host de cache nem um endereço de convidado era
conhecido. Campos: `event` = `network_cross_check`, `timestamp`, `vmName`,
`guestKey`, `verdict`, `cacheHost`, `cacheV2Status`, `cacheV2Ms`,
`cacheHealthOk`, `cacheHttpTcp`, `cacheHttpsTcp`, `guestAddress`,
`guestTcp22Ok`, `guestPingOk`, `neighborState`. Cada registro TCP do proxy
contém `address`, `port`, `open`, `ms` e `error`, ou é nulo quando nenhum
host de cache é conhecido. Leia esses registros mesmo quando o veredito for
`both-reachable`: o registro e a página de saúde podem responder enquanto uma
porta de escuta do proxy está indisponível. As sondagens descrevem o caminho
atual do host; elas não comprovam o caminho de saída do convidado, a
negociação TLS nem a conectividade durante um timeout anterior.
O evento existe porque o console de um convidado pode culpar um serviço que
o convidado não conseguiu alcançar por motivos próprios. Compare as
observações do host com as evidências do convidado e os logs do serviço
referentes ao intervalo da falha.

<a id="42820e91-001e"></a>

<a id="cycleeventsdeliveryjson-is-the-event-stream-complete"></a>

## `cycle.events.delivery.json` (o fluxo de eventos está completo?)

A emissão é de melhor esforço por projeto -- um ciclo nunca falha porque um evento não pôde
ser gravado --, e isso, sozinho, torna invisível um evento perdido. Um consumidor
que lê um fluxo silencioso não consegue distinguir "nada aconteceu" de "o gravador falhou",
e um gravador que nunca foi carregado não deixa qualquer rastro. Por isso, cada emissão é
contada, e cada perda é registrada com seu motivo ao lado do fluxo:

| Campo | Significado |
|---|---|
| `attempted` / `delivered` / `dropped` | Emissões desde a abertura do ciclo e como terminaram. |
| `lastDroppedEvent` | O nome de `event` da perda mais recente. |
| `lastDropReason` | `writer-unavailable` (o gravador não foi carregado nesse escopo), `writer-threw: <message>` ou `write-failed: <message>` (o acréscimo falhou: condição de corrida de identificador aberto, disco cheio). |
| `lastDropAtUtc` | Quando aconteceu. |

O arquivo é gravado quando um evento é perdido, não para cada evento, e um ciclo sem perdas
não tem esse arquivo; o manifesto o cataloga como tipo `ndjson-delivery`. A primeira perda em um
ciclo também gera um aviso, e as seguintes são contadas, em vez de repetidas.
`cycle.events.gaps` ainda contém uma linha por acréscimo que falhou (com o nome
e a ação do evento descartado), que é o detalhamento por evento resumido pelo livro de registros.

Um evento emitido quando nenhum ciclo está aberto é contado como descartado pelo motivo
`no-cycle-folder`, mas não gera aviso nem grava arquivo: sem ciclo, não
há fluxo que possa estar incompleto, e ferramentas e testes emitem nesse estado rotineiramente.
Nada disso muda o efeito de uma gravação que falhou sobre o ciclo -- a falha
relatada mantém sua própria classe e seu motivo; o livro de registros apenas informa quanto das
evidências ao redor dela chegou ao disco.

<a id="42820e91-000d"></a>

<a id="guest_quarantined-event-circuit-breaker"></a>

## Evento `guest_quarantined` (disjuntor)

O disjuntor de quarentena de convidados (`Test.GuestQuarantine.psm1`) acompanha uma
contagem de falhas consecutivas por convidado, identificada por `failureClass`, em
`runner.quarantine.json` (ao lado de `runner.gating.json` no diretório de execução,
sobrevivendo à recriação do processo interno de ciclo único). Depois de `failuresToQuarantine`
falhas da **mesma** classe (padrão 3), o convidado é ignorado por até
`skipCycles` ciclos (padrão 5), ou até que um commit do framework/projeto mude --
o que ocorrer primeiro --, para que um convidado com falha determinística deixe de custar um
provisionamento+implantação completo em cada ciclo, enquanto um convidado que falha de uma forma *diferente*
a cada vez nunca fique preso. Habilitado por padrão; defina
`testCycle.guestQuarantine.enabled: false` para desabilitar. Atingir o limiar
emite um evento `guest_quarantined`: `event` = `guest_quarantined`,
`timestamp`, `guestKey`, `failureClass`, `consecutiveFailures`, `skipCycles`,
`quarantinedUntilCommit` (e `vmName` / `hostType` /
`quarantinedUntilProjectCommit` quando conhecidos). O convidado ignorado também é
marcado em `status.json` (`guests[].quarantined` +
`quarantinedUntilCommit`), para que o dashboard mostre um indicador **em quarentena** -- a
omissão é explícita, nunca uma aprovação silenciosa. A emissão é de melhor esforço
(`Send-CycleEventSafely`) e nunca faz o ciclo falhar.

<a id="42820e91-000e"></a>

<a id="the-lab-health-gate-lab_health_-events"></a>

## A barreira de saúde do laboratório (eventos `lab_health_*`)

Uma etapa de ciclo precisa dos serviços do laboratório -- o stash para o qual envia binários, o
caching-proxy-service pelo qual seus convidados buscam conteúdo --, e um serviço em reconstrução fica indisponível por
minutos a dezenas de minutos. Tempo suficiente para que as janelas de nova tentativa da
verificação prévia, dimensionadas para uma renovação DHCP, não consigam cobrir a interrupção, mas curto o suficiente para que fazer o ciclo falhar descarte
uma aprovação por uma condição que se resolve sozinha.

Por isso, a barreira (`Test.LabHealth.psm1`) **suspende** a execução. Antes de cada entrada da cadeia
e de cada etapa de sequência, verifica os serviços declarados por este laboratório; quando um
que *estava* respondendo para, o ciclo fica suspenso exatamente como na
*Pausa após a próxima etapa* do operador -- repetindo as sondagens com o mesmo
backoff limitado a 59 s usado nas consultas do laço de pausa, e retomando sozinho quando o serviço
volta.

**O conjunto de sondagens é derivado, nunca configurado.** Cada área de extensão já
declara `healthPort`/`healthPath` em seu bloco `service:`
([extensions-api.md](../extensions-api.md)), portanto uma área lançada amanhã passa pela barreira
no dia em que chega. Uma área que exporta o verbo de contrato `Test-<Area>Host` é sondada
por meio dele: o `healthPort` do caching-proxy-service é a porta 3128 do Squid, enquanto seu
daemon responde a `/healthz` na porta 9310, e uma sondagem orientada pelo manifesto ali relataria
um daemon inativo em todos os proxies saudáveis do laboratório.

**Uma suspensão exige uma mudança de condição, não um serviço ausente.** Uma área é armada apenas
quando este hospedeiro conseguiu alcançá-la dentro de `testCycle.labHealth.armWindowHours` (padrão
24), e esse registro -- `runtime/lab-health.json` -- é lido **entre ciclos**. Um
serviço parado para reconstrução já está indisponível quando o próximo ciclo começa, portanto um
baseline capturado no início do ciclo nunca veria a transição que a barreira existe
para detectar. Um serviço que este hospedeiro *nunca* alcançou deliberadamente nunca causa uma suspensão:
suspender estacionaria um hospedeiro novo em seu primeiro ciclo, quando uma verificação prévia fornece um
"não há stash aqui" mais rápido e preciso.

**Custo.** Uma área armada é sondada primeiro em seu último endereço conhecido, sem
qualquer descoberta -- uma chamada HTTP por área armada, sem ida e volta ao grupo --, e seu
veredito é reutilizado por `minIntervalSeconds` (padrão 30). Uma área que a barreira não está
acompanhando só é consultada novamente a cada `discoveryIntervalSeconds` (padrão 600), pois
sua consulta é a mais cara e sua resposta quase nunca
muda.

**Encerrar uma suspensão.** A recuperação a limpa. `POST /control/lab-hold-release`
([control-routes.md](../control-routes.md)) significa que o operador considera a interrupção
permanente: a barreira remove a suspensão e deixa a etapa executar para que falhe por sua própria
causa. `/control/start-cycle` também a limpa. E, em `maxHoldAttempts` -- limitado
a **999** compilado, cerca de dezesseis horas no limite do backoff --, a barreira registra
`lab_dependency_down` e o ciclo termina como qualquer falha grave de infraestrutura.

As sondagens de saúde concluídas e as consultas durante a pausa do operador
atualizam `runner.stepHeartbeat`, permitindo que uma suspensão ativa ultrapasse
o tempo limite normal de uma etapa. Uma sondagem bloqueada ou uma suspensão
abandonada não atualiza esse arquivo e continua sujeita ao encerramento pelo
watchdog. Ao esgotar as tentativas, a barreira preserva os endereços e os detalhes
de descoberta do serviço indisponível em `context.dependencyFailures`; as falhas
da verificação prévia do stash em processos filhos usam as mesmas evidências
classificadas em vez de uma falha `unknown` sem explicação.

Três eventos seguem pelo fluxo NDJSON: `lab_health_change` (com `fromVerdict` /
`toVerdict` / `areas` / `armed`, e `attempts` + `heldSeconds` na recuperação),
`lab_health_released` e `lab_health_exhausted`. `status.json` contém
`labHold` e `labHoldAreas`, espelhados a partir do arquivo de sinalização em cada descarga,
que é o que o banner da página de status exibe.

O sinalizador da suspensão (`control.lab-hold`) deliberadamente **não** é o
`control.step-pause` do operador. A liberação automática exclui o sinalizador que ela criou; se ele fosse
o sinalizador do operador, o retorno de um serviço removeria a pausa de um ciclo que seu operador
havia suspendido antes de se afastar.

<a id="42820e91-000f"></a>

<a id="warm_resume-event-checkpoint-resume"></a>

## Evento `warm_resume` (retomada a partir de checkpoint)

O uso de checkpoints para retomada a quente (`Test.WarmResume.psm1`) transforma uma falha transitória
em uma etapa tardia em nova tentativa no mesmo local, em vez de refazer toda a instalação. Quando uma sequência de
carga de trabalho falha com uma classe **transitória** (`network_timeout`, `wait_timeout`,
`instrumentation_failure`, `host_io_blocked`, `ip_not_discovered`,
`payload_unavailable`, `input_lost` -- `Get-WarmResumeEligibleClass`), o executor executa novamente a
sequência que *falhou* a partir de `repro.resumeFromStep`
na **mesma VM ainda ativa** (a desmontagem ocorre apenas no resultado final),
até `testCycle.warmResume.maxAttempts` (padrão 2), e depois continua as
sequências de carga de trabalho restantes. Ao esgotar as tentativas ou encontrar uma classe não elegível, segue
para a desmontagem normal + novo provisionamento a frio, portanto a retomada a quente
permanece segura em caso de falha. Habilitada por padrão; defina `testCycle.warmResume.enabled: false`
para desabilitar. Cada tentativa emite um evento `warm_resume`: `event` = `warm_resume`,
`timestamp`, `guestKey`, `sequenceName`, `resumeFromStep`, `attempt`, além de
`failureClass` / `vmName` / `hostType` quando conhecidos -- para que uma execução que só foi aprovada
porque retomou continue consultável, nunca uma aprovação silenciosa.

<a id="42820e91-0010"></a>

<a id="rewind-to-a-restore-boundary"></a>

### Voltar a um limite de restauração

`repro.resumeFromStep` nomeia a etapa que **falhou**, e uma classe transitória informa
por que essa etapa parou, não quanto de seu trabalho foi realizado antes -- uma instalação que
descompactou arquivos antes que sua chamada de rede falhasse deixa o convidado alterado. Reiniciar ali
reexecutaria a etapa sobre seus próprios resíduos, o que não é a execução que a sequência
descreve. `loadDiskSnapshot` é a única ação que torna conhecido novamente o estado do convidado,
portanto o ponto de retomada é recuado até a mais próxima **no checkpoint ou antes dele**,
e cada etapa reexecutada passa a operar sobre o estado para o qual foi escrita.
O custo é refazer as etapas intermediárias -- a mesma troca que a retomada a quente
já faz em relação a uma reconstrução completa a frio.

Uma sequência sem `loadDiskSnapshot` no checkpoint ou antes dele não tem um ponto para o qual
restaurar. Nesse caso, a etapa do checkpoint só é reexecutada no mesmo local quando apenas
observa -- espera, lê a tela, captura evidências --, e isso é avaliado para
a etapa inteira: um bloco `retry` que começa com uma espera e depois digita é uma etapa
de digitação. Uma etapa que digita, clica ou altera o estado do convidado, do hospedeiro ou de algo externo seria
executada sobre seus próprios resíduos, portanto a retomada é recusada e a falha original
permanece. Cada verbo declara sua classe ao se registrar (`ReplaySafety`:
`observe`, `input`, `state-changing`, `restore-point` ou `composite`); um verbo que
não declarou nenhuma, um nome não registrado, uma sequência ilegível e uma verificação de segurança
ausente são todos considerados inseguros. Um ponto de restauração cujo snapshot definitivamente não
existe no hospedeiro é considerado ausência de limite, portanto não pode autorizar uma reexecução. Um checkpoint que já
está sobre o limite não é um recuo.

Uma retomada que era elegível e foi recusada informa isso por um evento
`warm_resume_declined`: `timestamp`, `event`, `guestKey`, `sequenceName`, `resumeFromStep` e um
token `reason` -- `no-restore-point`, `restore-point-missing` ou
`safety-check-unavailable` --, além de `replayClass` (o que tornou a etapa insegura),
`failureClass`, `vmName` e `hostType` quando conhecidos. Sem ele, uma recuperação recusada
fica invisível: o ciclo simplesmente falha com sua classe original.

Quando ocorre um recuo, o evento contém `checkpointStep` (a etapa que falhou)
e `rewoundSteps` (quantas foram reexecutadas), junto com `resumeFromStep` (onde a
execução realmente reiniciou); os três estão ausentes quando nada foi recuado, para que uma
reexecução nunca seja inferida de números de etapa que apenas discordam. A linha do console
diz o mesmo em palavras, identificando a contagem de etapas reexecutadas -- uma aprovação após retomada
que refez trabalho é explícita nos dois lugares.

Os números das etapas são posições na lista plana de etapas da sequência -- `component:` e depois
`workload:`, após a expansão de trechos --, que é a mesma lista usada na contagem de `-StartStep`.

A correção depende de o executor executar cada sequência de carga de trabalho como um **único
arquivo** (`Invoke-SequenceByName` -> `Invoke-Sequence`), para que `resumeFromStep`
(local ao arquivo) corresponda diretamente a `Invoke-Sequence -StartStep` (local ao arquivo). Esse é
o caso de "retomada a quente / nenhum baseline ainda não construído" destacado na observação de [`repro`](#repro) --
o executor de cadeias de Debug-TestSequence concatena baselines e *não* é esse
caso, por isso `repro.command` continua omitindo `-StartStep`.

<a id="42820e91-0011"></a>

<a id="retry_attempt--retry_exhausted-events-retry-telemetry"></a>

## Eventos `retry_attempt` / `retry_exhausted` (telemetria de novas tentativas)

As três pilhas de novas tentativas emitem um registro estruturado de tentativa para que uma repetição intermitente
possa ser consultada em `cycle.events.ndjson`, em vez de ficar apenas escondida no log para leitura humana:

- **`Yuruna.Retry`** (pwsh no hospedeiro: tofu init/plan/apply, buscas com helm/kubectl)
  emite `retry_attempt` antes de cada backoff e `retry_exhausted` na falha
  final -- em melhor esforço (`Send-CycleEventSafely` é protegido por Get-Command, portanto uma
  execução independente do tofu que nunca carregou `Test.Log` não é afetada).
- **O verbo `retry` da sequência** emite `retry_attempt` por passagem interna com falha e
  `retry_exhausted` ao esgotar as tentativas; o último contém a `failureClass`
  interna mais profunda (a classe externa se reduz a `retry_exhausted`). A proteção de inicialização do
  instalador ARM64 também emite `retry_suppressed` quando recusa uma
  reinicialização nativa ARM64 planejada, com `reason`, `attempt`, `maxAttempts`,
  `permittedMaxAttempts` e `configuredMaxAttempts`. Seu registro terminal contém
  `retrySuppressionReason`, para que a causa continue visível sem associar eventos.
  Cada `retry_attempt` da sequência também contém `guestLivelocked` e
  `guestLivelockedSeconds`, o veredito de livelock do host quando a tentativa falhou,
  para que as reinicializações justificadas por esse veredito possam ser contadas.
  Seu campo `installerRunning` registra se a cauda OCR da espera que falhou ainda
  mostrava as linhas de evento `subiquity/` do instalador em execução; com essa
  evidência, uma reinicialização durante a espera de login no Hyper-V ARM64 inicia
  pelo DVD do instalador em vez do disco de destino.
- **A biblioteca bash do convidado** (`automation/yuruna-retry.sh`) não consegue alcançar o fluxo do
  hospedeiro, portanto imprime um marcador `YURUNA_RETRY {stack,label,attempt,maxAttempts,rc,
  permanent}` em stderr; nos verbos SSH (`sshExec` /
  `sshFetchAndExecute`), o hospedeiro analisa esses marcadores e os transforma em eventos `retry_attempt`
  por meio de `Publish-GuestRetryMarker`. O caminho de busca por console/OCR mantém seu
  log no convidado, portanto esse caminho não é coberto.

Campos (todos aditivos; o esquema é aberto): `event`, `timestamp`, `stack`
(`pwsh` / `sequence` / `bash`), `attempt`, `maxAttempts`, `exitCode`,
`description` (o rótulo) e, opcionalmente, `transient` / `permanent` /
`sleepSeconds` / `failureClass` / `severity` / `guestKey` / `vmName` /
`evidencePath`.

`evidencePath` (pilha da sequência) é a pasta relativa ao ciclo que contém os
quadros de tela e o texto OCR produzidos pela tentativa que falhou, copiados para outro local antes que a próxima
tentativa os reutilize. Só está presente quando o verbo interno que falhou tem severidade
`hard` e havia algo para capturar. É o único registro durável de uma tentativa
recuperada por uma repetição posterior: esse ciclo termina em `pass`, e
todos os outros caminhos de coleta de artefatos são executados na falha do ciclo.

As novas tentativas de inicialização também salvam `vm-diagnostics.json` nessa
pasta, mesmo quando não há quadro disponível, e expõem `consoleSecondOpinion`
no evento da tentativa. O modo portátil `coldPowerCycle` funciona no Hyper-V,
KVM e UTM. `retry_vm_restart.recovery` registra `phase`, `reasonCode`,
`outcome`, `requiredCommand`, `initialState`, `stoppedState` e `runningState`.
O mesmo objeto de recuperação acompanha um evento `retry_suppressed` causado
por uma capacidade ausente. A falta de suporte à seleção da mídia de instalação
nunca desliga o convidado. As capturas nativas do UTM são feitas em melhor
esforço; seu resultado é registrado separadamente.

A sentinela de falha entre linguagens para busca e execução, `NONZERO SCRIPT EXIT:`
(a string que o wrapper do convidado imprime e que o verbo `fetchAndExecute` procura), é
uma constante declarada de cada lado (`Get-NonzeroScriptExitSentinel` + o produtor
bash), com um teste de proteção contra divergência, para que os dois lados não possam divergir silenciosamente.

<a id="42820e91-0012"></a>

<a id="sequence_paused--sequence_resumed-events-operator-holds"></a>

## Eventos `sequence_paused` / `sequence_resumed` (suspensões do operador)

As duas barreiras de pausa relatam as duas extremidades de uma suspensão, para que um ciclo que passou a maior parte de seu
tempo de relógio suspenso seja interpretado como suspenso, em vez de lento, e uma falha que
ocorre depois de uma suspensão possa ser interpretada em relação a ela.

| Campo | Observações |
|---|---|
| `pauseScope` | `step` (a barreira de sequência, de `control.step-pause`) ou `cycle` (a barreira no limite de ciclo, de `control.cycle-pause`). |
| `label` | Onde a barreira foi acionada: `[sequence start]`, `[3/9]` ou `[cycle boundary]`. |
| `requestedAtUtc` | Quando o operador armou a suspensão, lido do arquivo de sinalização marcado pelo serviço de status. `''` quando ilegível. |
| `heldSeconds` | Apenas o evento de liberação. Uma suspensão aberta ainda não tem duração, e um `sequence_paused` sem par é o único registro de que um executor morreu enquanto estava suspenso, e não enquanto estava travado. |
| `guestKey` / `vmName` / `sequenceName` | Apenas o escopo de etapa: o que foi suspenso. |

Os dois escopos diferem no custo de uma suspensão, e essa distinção é a razão
de o escopo estar no evento:

- **`cycle`** suspende depois da desmontagem, sem convidado em execução. Nada pode expirar
  durante a suspensão; o par serve para relatar a duração.
- **`step`** suspende o executor enquanto o convidado continua em execução. Um convidado imprime
  em seu próprio ritmo, portanto tudo o que imprime uma vez e não volta a imprimir -- principalmente um
  prompt de confirmação durante a inicialização -- pode rolar para fora da tela sem resposta durante a
  suspensão. A etapa que retoma lê então uma tela da qual o prompt já saiu, o que
  não pode ser distinguido de um prompt que nunca foi impresso. É por isso que uma suspensão liberada
  também é incluída no registro de falha como
  `causeDetail.pauseBeforeStepSeconds`.

<a id="42820e91-0013"></a>

<a id="statusjson-lastfailure-summary"></a>

## Resumo `lastFailure` de status.json

Para o dashboard ativo, `Set-LastFailureSummary` registra um objeto
`lastFailure` desnormalizado no nível superior de `status.json` no momento da falha:
`{ failureClass, severity, stepNumber, sequenceName, guestKey, stepName,
errorMessage, reproCommand, relPath, vmName, recordedAt }` -- `null` em um
ciclo aprovado. `relPath` aponta para o `last_failure.json` na pasta de ciclo
por convidado (o dashboard o resolve em relação à URL da pasta
por convidado). `Complete-Run` captura uma cópia dele na linha do histórico (junto com
`failureClass` / `errorMessage` por convidado em `guestSummary`), para que uma linha seja
autodescritiva. O próprio `schemaVersion` de `status.json` continua `1`; o campo
é aditivo (leitores antigos o ignoram).

<a id="42820e91-0014"></a>

<a id="remediation-dispatcher"></a>

## Despachante de remediação

O token `failureClass` no registro acima vem da enumeração em
[`Test.SequenceAction`](../../test/modules/Test.SequenceAction.psm1). O
despachante de remediação em
[`test/modules/Test.Remediation.psm1`](../../test/modules/Test.Remediation.psm1)
mapeia esse token para uma recomendação acionável. Sem ele, um operador
(ou um futuro laço autônomo) precisaria procurar na mensagem de erro em
texto livre e adivinhar; o despachante lê o registro de falha,
encaminha por `failureClass` e retorna o que o chamador deve fazer.

O despachante é **consultivo**: registra uma decisão e emite uma
recomendação, e aplicar essa recomendação é responsabilidade de outra parte. Nada
na árvore chama `Repair-Credential`, por exemplo. O único código que age sobre uma
falha é o conjunto de reparos limitados descritos em
[Resultado de recuperação e livro de registros](#recovery-result-and-ledger): eles estão desativados por
padrão, restritos a uma lista curta de opções permitidas e limitados por impressão digital da falha em um
livro de registros que sobrevive à reinicialização do executor, para que uma falha classificada incorretamente não possa
acionar um reparo em um laço.

Os links de classe de falha do painel abrem a entrada correspondente abaixo. Uma
classe descreve a operação que falhou ou a condição observada, não necessariamente
sua causa raiz; leia o motivo registrado, `causeDetail` e os artefatos do ciclo
antes de escolher uma recuperação. A lista canônica vem de
[`Test.FailureTaxonomy`](../../test/modules/Test.FailureTaxonomy.psm1).

| Classe de falha | Significado | Primeira verificação |
|---|---|---|
| <a id="failure-class-ocr_timeout"></a>`ocr_timeout` | O texto esperado do console não apareceu antes de expirar a espera por OCR. | Compare a captura de tela e o trecho final do OCR com o estado esperado da sequência. |
| <a id="failure-class-console_flooded"></a>`console_flooded` | A saída repetida do console impediu a leitura do texto esperado durante a espera. | Examine `causeDetail.consoleFlood`, a linha repetida e se o console estava estático ou mudando. |
| <a id="failure-class-network_timeout"></a>`network_timeout` | Uma operação de rede não ficou pronta nem terminou dentro do prazo. | Verifique o destino registrado, DNS, roteamento e disponibilidade do serviço antes de tentar novamente com espera progressiva. |
| <a id="failure-class-credential_expired"></a>`credential_expired` | O convidado rejeitou a credencial configurada. | Verifique se o valor no cofre corresponde à credencial atual do convidado. |
| <a id="failure-class-host_io_blocked"></a>`host_io_blocked` | O hospedeiro não conseguiu entregar entrada de teclado, texto ou ponteiro ao convidado. | Verifique a conexão de entrada VNC ou do hipervisor e reconecte-a se estiver obsoleta. |
| <a id="failure-class-pattern_matched_failure"></a>`pattern_matched_failure` | Um padrão de falha registrado ou marcador de término com falha apareceu no console. | Leia `matchedFailurePattern` e a saída ao redor dele para identificar o problema informado. |
| <a id="failure-class-retry_exhausted"></a>`retry_exhausted` | Um invólucro de repetição consumiu seu limite de tentativas sem sucesso. | Siga `innerFailureClass` e os artefatos da última tentativa até a falha subjacente. |
| <a id="failure-class-snapshot_restore_failed"></a>`snapshot_restore_failed` | A restauração do snapshot solicitado da VM falhou. | Verifique a existência do snapshot, o armazenamento e os diagnósticos de restauração do hipervisor. |
| <a id="failure-class-script_error"></a>`script_error` | Um comando ou script informou um erro de execução. | Leia o código de saída, a saída de erro e a transcrição antes de executá-lo novamente. |
| <a id="failure-class-wait_timeout"></a>`wait_timeout` | Uma espera ou um marcador de conclusão de script excedeu o prazo. | Verifique se o script do convidado ainda está em execução, bloqueado por uma dependência ou aguardando entrada. |
| <a id="failure-class-extension_error"></a>`extension_error` | Uma chamada de extensão falhou. | Examine o erro e a configuração da extensão. |
| <a id="failure-class-instrumentation_failure"></a>`instrumentation_failure` | A captura de uma tela ou de um artefato de diagnóstico falhou. | Verifique a ferramenta de captura e o caminho de saída; diferencie evidência ausente de falha do convidado. |
| <a id="failure-class-provisioning_failure"></a>`provisioning_failure` | A criação, a inicialização ou a transição de uma VM para o estado de execução exigido falhou. | Verifique os diagnósticos do hipervisor, os recursos disponíveis e a definição da VM. |
| <a id="failure-class-bootstrap_sync"></a>`bootstrap_sync` | A sincronização do framework ou do projeto falhou por um motivo não relacionado à rede. | Examine os diagnósticos do Git em busca de autenticação, divergência ou alterações locais. |
| <a id="failure-class-plan_invalid"></a>`plan_invalid` | O plano de ciclo configurado é ambíguo ou não pode ser executado neste hospedeiro. | Verifique sequências duplicadas, backends necessários e configurações de convidado ausentes. |
| <a id="failure-class-elevation_required"></a>`elevation_required` | Um comando privilegiado necessário exige autenticação do operador. | Resolva a exigência de elevação no console do hospedeiro. |
| <a id="failure-class-project_access_denied"></a>`project_access_denied` | A credencial do hospedeiro não pode ler o projeto atribuído pelo pool. | Peça ao administrador do pool que verifique a atribuição e o acesso ao repositório. |
| <a id="failure-class-host_network_degraded"></a>`host_network_degraded` | O caminho de rede que o hospedeiro fornece aos convidados está interrompido, afetando os convidados conectados a ele. | Examine o switch virtual ou a ponte, a associação ao uplink e o estado do enlace. |
| <a id="failure-class-ip_not_discovered"></a>`ip_not_discovered` | Nenhuma sondagem de descoberta no hospedeiro encontrou um endereço para o convidado. | Verifique o DHCP e os dados de descoberta de endereço do hipervisor antes de repetir a descoberta. |
| <a id="failure-class-payload_unavailable"></a>`payload_unavailable` | O invólucro de busca do convidado foi executado, mas nenhuma fonte forneceu seu script. | Verifique o endereço atual do hospedeiro, o endpoint que fornece o payload e o acesso à fonte alternativa. |
| <a id="failure-class-pool_storage_full"></a>`pool_storage_full` | O compartilhamento do pool não tem espaço para os resultados do ciclo. | Compare o espaço livre e o necessário informados; libere ou amplie o armazenamento antes de retomar. |
| <a id="failure-class-dhcp_identity_unbounded"></a>`dhcp_identity_unbounded` | Um convidado reconstruído recebeu outro endereço apesar de manter sua identidade prevista. | Compare os endereços antigo e novo registrados com as concessões DHCP e os identificadores do cliente. |
| <a id="failure-class-lab_dependency_down"></a>`lab_dependency_down` | Um serviço necessário do laboratório permaneceu indisponível durante a espera prolongada de recuperação do executor. | Verifique o serviço indicado e seu último endereço conhecido no hospedeiro que o executa. |
| <a id="failure-class-input_lost"></a>`input_lost` | A entrada digitada no shell não iniciou o payload; verificações no convidado confirmaram que ele nunca foi executado. | Examine o console e os diagnósticos de entrega de entrada antes de repetir a etapa. |
| <a id="failure-class-hypervisor_unresponsive"></a>`hypervisor_unresponsive` | O hipervisor responde a consultas de estado, mas suas solicitações de controle do ciclo de vida expiram. | Examine o snapshot de controle e os registros de processo ou de falha do aplicativo do hipervisor. |
| <a id="failure-class-source_integrity"></a>`source_integrity` | A assinatura da origem ou o conteúdo obtido falhou na verificação. Uma alternativa verificada na origem pode ter sucesso e preservar este aviso. | Confira o recibo, os identificadores das chaves cadastradas, o commit selecionado e as tentativas de transporte. Nunca ignore a verificação da assinatura ou do commit. |
| <a id="failure-class-unknown"></a>`unknown` | A falha não tem uma classificação utilizável. | Leia `classificationSource` e os artefatos; verifique se falta o registro do verbo antes de atribuir uma causa. |

<a id="42820e91-0015"></a>

<a id="why-each-infra-failure-class-exists"></a>

### Por que cada classe de falha de infraestrutura existe

Um token só ganha uma classe própria quando a política de novas tentativas ou a pessoa que pode
corrigi-lo difere de todas as classes já existentes na enumeração. As classes de infraestrutura são
onde é mais fácil definir esse limite incorretamente -- à distância, todas parecem "o ambiente
falhou" --, portanto a razão de cada uma está registrada aqui.

- **`elevation_required`** -- o hospedeiro pediu uma senha de sudo sem operador
  presente. Tem uma classe própria porque é a única falha comprovadamente
  impossível de corrigir fora do console: repetir a tentativa, neste ciclo ou em qualquer
  ciclo posterior, só pode reproduzi-la, portanto a remediação a encaminha diretamente para
  `operator_intervention_required`, em vez de consumir o backoff.
- **`project_access_denied`** -- um grupo atribuiu a este hospedeiro uma `projectUrl` que sua
  credencial não consegue ler. Distinta de `bootstrap_sync` (falha ao clonar o próprio
  projeto deste hospedeiro), pois a correção cabe a outra pessoa -- o
  administrador do grupo que fez a atribuição, não o proprietário do hospedeiro --, e distinta de
  `network_timeout`, pois nenhuma nova tentativa pode ter êxito.
- **`host_network_degraded`** -- o caminho de rede de convidados do próprio HOSPEDEIRO está interrompido,
  portanto todos os convidados que acessam a rede nele falham da mesma forma por uma causa que nenhuma
  nova tentativa no nível do convidado pode influenciar. Precisa de uma classe própria porque um
  objeto de switch virtual sobrevive à associação com seu uplink após uma reinicialização do hospedeiro: o
  switch continua existindo, mas não encaminha tráfego, e cada convidado relata
  apenas seu próprio sintoma (`network_timeout` / `provisioning_failure`). Está
  deliberadamente ausente das listas permitidas de repetição rápida transitória -- repetir
  contra uma ponte sem sinal de enlace só consome o orçamento do ciclo --,
  portanto é encaminhada ao operador da mesma forma que `elevation_required`.
- **`ip_not_discovered`** -- nenhuma sondagem no hospedeiro conseguiu identificar um endereço para o
  convidado, portanto a etapa nunca o alcançou. Distinta de `network_timeout`, que
  significa que um endereço real foi encontrado e o caminho até ele falhou, e de
  `host_network_degraded`, que não pode ser recuperada. Esta é a classe de
  atraso recuperável: a descoberta de endereços pelo hipervisor depende de caches que expiram e
  daemons que publicam com atraso, portanto a mesma chamada costuma responder segundos depois. Ela
  pertence, por isso, às listas permitidas de repetição rápida transitória e nunca deve ser
  relatada como `script_error` -- o script do convidado nunca foi executado, e encaminhar um leitor
  para depurá-lo desperdiça o ciclo.
- **`payload_unavailable`** -- o convidado foi alcançado e executou o wrapper de busca,
  mas nenhuma origem forneceu o script, portanto o payload nunca foi executado. Distinta de
  `ip_not_discovered`, em que o HOSPEDEIRO não conseguiu identificar o convidado: aqui o convidado
  está ativo e se comunicando, e é o hospedeiro que ele não consegue alcançar. Distinta de
  `script_error` pela razão mais importante -- nada foi executado, portanto não há
  script para depurar nem estado do convidado do qual desconfiar, o que torna correta a
  reexecução da etapa. A causa habitual é um hospedeiro cujo endereço mudou por DHCP enquanto o
  convidado ainda mantinha o endereço antigo; o convidado consulta novamente o diretório do grupo e
  normalmente se recupera, portanto essa classe pertence à lista permitida de retomada a quente, mas não à de correção automática. Ela
  permanece UMA classe, em vez de se dividir conforme o trecho que falhou: a chegada do payload
  na próxima tentativa depende de o hospedeiro voltar a ficar acessível, não da
  alternativa do GitHub, portanto um 404 terminal dessa alternativa não torna a
  falha permanente. Quando a alternativa É o caminho sem saída -- um repositório privado
  sem token --, o texto de recuperação a identifica.
- **`input_lost`** -- um fetch por GUI digitou o comando no shell do convidado, a espera
  chegou ao tempo limite com a subshell preparada ainda aberta na tela, e o convidado confirmou
  que a guarda nunca foi executada: não existe contexto preparado para o comando e nenhum
  processo de busca está em execução. Distinta de `wait_timeout`, em que um script estava em
  execução e travou, e de `script_error`, em que um script terminou com código diferente de
  zero: aqui nada foi executado, portanto não há script para depurar. Como nada foi executado, repetir a etapa não
  repete trabalho algum, e por isso a classe pertence às listas de reinício a quente e de
  remediação automática, e sua recuperação começa por `retry_with_backoff`.
- **`pool_storage_full`** -- o compartilhamento do grupo não tem espaço para os resultados deste ciclo.
  Assim como `elevation_required`, repetir é comprovadamente inútil: o executor não
  tem nada próprio para excluir, e nada no próximo ciclo deixa o compartilhamento
  mais vazio, portanto ela é encaminhada diretamente para `operator_intervention_required`, em vez de
  consumir o backoff. Deliberadamente ausente da lista transitória de remediação
  automática pelo mesmo motivo -- uma nova tentativa antecipada apenas voltaria a atingir o mesmo limite.
- **`dhcp_identity_unbounded`** -- um convidado foi reconstruído com a identidade que
  deveria manter por toda a vida, e o servidor DHCP lhe entregou um endereço *diferente*.
  Tem uma classe própria porque a solução não cabe a nenhum dos outros responsáveis: o convidado está saudável,
  o hospedeiro está saudável, e o que falhou é a propriedade que permite conviver com uma
  concessão longa -- o número de endereços que um cliente solicita deve ser limitado pela
  contagem de identidades, em vez do tempo decorrido. Cada endereço abandonado permanece
  alocado por toda a concessão, portanto o grupo se esgota a uma taxa determinada pelo tempo da concessão,
  em vez da contagem de máquinas, e o sintoma final são convidados que inicializam sem
  IPv4 -- chegando como `pattern_matched_failure` na primeira etapa que
  precisou da rede, em hospedeiros sem qualquer outra característica em comum. Ausente das
  listas permitidas de repetição transitória de propósito: a próxima construção faz a mesma pergunta
  e recebe outro endereço novo, portanto repetir consome mais do grupo. A primeira
  observação de uma identidade nunca recebe essa classe, e um convidado cujo endereço não pôde
  ser resolvido é registrado como não verificado, em vez de aprovado.
- **`lab_dependency_down`** -- um serviço do laboratório que este hospedeiro vinha alcançando parou
  de responder, e o ciclo já **ficou suspenso** por causa dele: a barreira de saúde do laboratório repetiu as sondagens
  com backoff por até dezesseis horas antes de registrar isso. Esse histórico é a
  razão de ela ter uma classe própria. A repetição automática comprovadamente já foi tentada na
  única escala que poderia ter funcionado, portanto a classe fica fora das listas permitidas de
  repetição rápida transitória e da lista transitória de remediação automática, e é encaminhada
  para `operator_intervention_required` -- o próximo ciclo gastaria as mesmas
  horas para chegar à mesma resposta. Distinta de `payload_unavailable`, em que um
  convidado ativo não consegue buscar conteúdo de seu hospedeiro: aqui nada está em execução ainda e não
  existe endereço para o serviço. Distinta de `network_timeout`, que
  significa que um endereço FOI encontrado e o caminho até ele falhou. E distinta de todas as
  classes com escopo de hospedeiro, pois o serviço não precisa estar neste hospedeiro -- em um
  grupo, normalmente é uma VM de outra pessoa; por isso, o texto de
  recuperação identifica o serviço e seu último endereço conhecido, em vez de encaminhar o
  leitor para a rede deste hospedeiro.
- **`hypervisor_unresponsive`** -- o canal de controle do hipervisor parou de
  atender às solicitações de ciclo de vida, embora continue respondendo a consultas
  de estado: no macOS, `utmctl list` e `status` retornam na hora, enquanto todo
  `start`, `stop` e `delete` espera até o fim do tempo limite do Apple Event. Tem
  uma classe própria porque a falha está no processo do próprio aplicativo do
  hipervisor, onde nem uma repetição nem uma reconstrução a alcançam -- cada
  repetição só acrescenta outro tempo limite, e as VMs ficam intactas --, portanto
  é encaminhada para `operator_intervention_required` e fica fora de todas as
  listas permitidas de repetição. Distinta de `provisioning_failure`, em que o
  hipervisor agiu e a VM não subiu, e de `unknown`, que é como a mesma indisponibilidade
  é registrada quando nada sonda o caminho de ciclo de vida. Reconhecida pela
  barreira de controle pré-ciclo, que envia um `stop` inócuo a uma VM já parada e
  faz o ciclo falhar em segundos quando esse verbo trava, ou pela repetição de
  início de um driver que relata dois tempos limite consecutivos do canal de
  controle. O driver grava um instantâneo de controle na pasta do ciclo (censo de
  processos com horários de início, a listagem bruta, relatórios de falha recentes,
  um trecho do log unificado) para que o leitor distinga uma falha com
  reinicialização de um travamento.
- **`console_flooded`** -- uma espera gastou todo o seu orçamento contra um console que
  se sobrescrevia com uma única linha repetida, portanto não era possível
  ler o padrão na tela, independentemente de ele ter sido impresso. Tem uma classe própria porque
  é a única falha de espera que uma reexecução não pode ajudar, que é exatamente o que
  `ocr_timeout` recomenda: essa classe presume que a tela divergiu do caminho
  registrado e que uma execução limpa voltará a segui-lo, enquanto aqui a tela
  nunca foi legível e uma reexecução a preenche novamente à mesma taxa. Ela também é invisível
  às duas autorrecuperações de captura -- o contador de ausência de texto vê uma tela cheia de texto e
  a verificação de quadro congelado vê um fluxo que muda em cada quadro, portanto o transporte está
  saudável e só o conteúdo é inútil. A linha dominante e sua proporção da
  superfície acompanham `causeDetail.consoleFlood`, pois o que se
  repete é o que identifica a causa. Ausente das listas permitidas de repetição transitória:
  um tempo limite maior não pode tornar legível uma superfície que se sobrescreve.

<a id="42820e91-0016"></a>

<a id="public-surface"></a>

### Interface pública

| Função | Assinatura | Usada por |
|---|---|---|
| `Register-RecoveryHandler` | `-FailureClass -Handler` | Módulos externos acrescentam ou substituem um manipulador |
| `Register-BuiltinRecoveryHandler` | (sem argumentos) | Instala o conjunto padrão de manipuladores ao carregar o módulo |
| `Get-RecoveryHandler` | `-FailureClass` | Despachante; introspecção |
| `Get-RegisteredFailureClass` | (sem argumentos) | Suítes que verificam a cobertura dos manipuladores; introspecção |
| `Get-RecoveryRecommendationName` | (sem argumentos) | Vocabulário canônico de recomendações (compartilhado com SuggestedRecoveries de cada verbo) |
| `Invoke-Remediation` | `-FailureRecord [-LastFailurePath]` | Operador / laço autônomo; retorna a hashtable de recomendação |
| `Clear-RecoveryHandler` | (sem argumentos) | Apenas testes |

<a id="42820e91-0017"></a>

<a id="recommendation-taxonomy"></a>

### Taxonomia de recomendações

Cada manipulador retorna uma hashtable cujo campo `Recommendation` DEVE ser
um dos valores canônicos abaixo, para que um consumidor do fluxo possa agrupar por
um conjunto finito pequeno, em vez de fazer correspondência de texto livre:

| Recomendação | Significado |
|---|---|
| `retry_immediately` | Transitória; execute novamente a etapa que falhou agora. |
| `retry_with_backoff` | Provavelmente transitória (interrupção breve de rede, limite de taxa); o chamador escolhe o backoff. |
| `restart_from_snapshot` | O estado do convidado se desviou; restaure o último snapshot válido e reexecute a partir dele. |
| `reconnect` | No nível de transporte (o VNC caiu, a sessão SSH terminou); refaça a conexão e continue. |
| `pause_and_inspect` | Repetir a etapa arrisca consumir recursos; apresente a condição e espere. |
| `operator_intervention_required` | O executor não consegue se recuperar sozinho (senha do cofre incorreta, imagem sem assinatura). |
| `escalate` | Reservada -- um manipulador externo pode retorná-la para sinalizar um caso novo que o framework deve aprender. Nenhum manipulador integrado a emite; a alternativa quando não há manipulador / ocorre erro no manipulador é `operator_intervention_required`. |

<a id="42820e91-0018"></a>

<a id="inner-cause-routing-past-retry_exhausted"></a>

### Encaminhamento pela causa interna além de `retry_exhausted`

Um `retry` esgotado relata a classe externa `retry_exhausted`, que
oculta a causa acionável do verbo mais profundo. O registro de falha preserva
essa causa em `innerFailureClass`; quando a classe externa é
`retry_exhausted` e a classe interna tem seu próprio manipulador registrado, o
despachante encaminha pela classe **interna**, para que a recomendação trate
a falha real, não o envoltório de novas tentativas. `severity` e
`suggestedRecoveries` seguem a classe encaminhada; a classe externa continua
visível como `RoutedFromFailureClass` no resultado e `outerFailureClass`
no evento `remediation_recommended`. Sem classe interna (ou sem manipulador
interno), o despachante encaminha pela classe externa sem alteração.

<a id="42820e91-0019"></a>

<a id="advisory-by-design"></a>

### Consultivo por projeto

Os manipuladores retornam **o que o chamador deve fazer**, não o que **fizeram**, e um
manipulador nunca age. Agir é responsabilidade do módulo de recuperação: um reparo registra uma
pré-condição, uma ação limitada, uma sondagem de pós-condição e uma reversão, e o
[livro de registros](#recovery-result-and-ledger) decide se ele pode executar novamente. Conectar
`Repair-VncConnection`, `Wait-SshReady` ou `Restore-VMDiskSnapshot` da mesma forma
é como a orientação de um manipulador se tornaria uma ação, um reparo de cada vez.

<a id="42820e91-001a"></a>

<a id="registry-shape"></a>

### Formato do registro

O registro usa a primitiva compartilhada
[`New-YurunaRegistry`](../../test/modules/Test.Registry.psm1),
portanto aparece em `Get-YurunaRegistryDirectory` junto com
`SequenceAction`, `HostIO`, `OcrProvider` e
[`HostCondition`](../test-harness.md#host-condition-registry) -- ferramentas
autônomas enumeram todas as interfaces de encaminhamento por uma única API.

<a id="42820e91-001b"></a>

<a id="event-emission"></a>

### Emissão de eventos

Cada despacho emite um evento NDJSON `remediation_recommended`
contendo `(failureClass, recommendation, severity, handledBy)`, para que um
consumidor do fluxo acompanhe a escolha do despachante sem analisar
o objeto de recomendação. O esquema está em
[`Test.EventSchema`](../../test/modules/Test.EventSchema.psm1) -- o mesmo
validador que controla o fluxo de eventos do ciclo.

<a id="42820e91-001c"></a>

<a id="adding-a-new-failure-class"></a>

### Adicionar uma nova classe de falha

1. Acrescente o novo valor à lista canônica `FailureClass` em
   [`Test.FailureTaxonomy`](../../test/modules/Test.FailureTaxonomy.psm1)
   E ao `ValidateSet` literal em
   [`Test.SequenceAction`](../../test/modules/Test.SequenceAction.psm1)
   (um argumento de atributo `ValidateSet` precisa ser uma expressão constante, portanto
   não pode ler o array compartilhado; uma chamada a `Assert-FailureTaxonomyInSync`
   ao carregar o módulo avisa se os dois divergirem). O validador do
   esquema de eventos deriva automaticamente sua enumeração do módulo de taxonomia.
   Classes de infraestrutura integradas já acrescentadas dessa forma: `provisioning_failure`,
   `bootstrap_sync`, `plan_invalid`, `hypervisor_unresponsive`.
2. Registre um manipulador no bloco integrado de
   [`Test.Remediation`](../../test/modules/Test.Remediation.psm1),
   ou a partir de um módulo externo por meio de
   `Register-RecoveryHandler`.
3. O manipulador é um scriptblock `param([hashtable]$c)` que lê
   `$c.Failure` (o last_failure.json analisado) e `$c.Context`
   (`vmName`, `guestKey`, `hostType`, `stepNumber`, `actionVerb`,
   `severity`, `suggestedRecoveries`, `failureClass`, além dos
   campos de acionabilidade `sequenceName`, `sequencePath`,
   `matchedFailurePattern`, `innerFailureClass`, `outerFailureClass`
   e `reproCommand` -- cada um é uma string vazia quando ausente, para que um manipulador
   teste strings sem uma proteção contra nulos -- e as leituras de `causeDetail`
   `consoleStaticSeconds`, `consoleStaticMeasured` e
   `pauseBeforeStepSeconds`, cujos valores são `0`, `true` e `0` quando ausentes),
   retornando `@{ Recommendation =
   '<enum>'; Rationale = '<short>' }` (`Actions`, `HandledBy` e
   `AutoApply` opcionais). O despachante anexa a severidade do registro de
   falha, não do manipulador.
4. `Test.Remediation.Tests.ps1` falha se faltar um manipulador para qualquer
   valor da enumeração; em tempo de execução, o despachante encaminha uma classe
   sem manipulador para o manipulador `unknown`.

<a id="42820e91-001f"></a>

<a id="recovery-result-and-ledger"></a>

## Resultado de recuperação e livro de registros

O executor, a execução do projeto e o executor de sequências antes descreviam o resultado de um ciclo
de três formas: um Boolean do mecanismo de sequências, um resultado de clonagem mais um código de
saída, um objeto de ciclo mais um arquivo auxiliar. Agora também registram um resultado tipado,
e um livro de registros durável limita o que o executor pode reparar por conta própria. Nada que
já existia mudou: cada código de saída, `status.json`, `last_failure.json`,
`last_remediation.json` e os campos obrigatórios de `runner.cycle.outcome.json`
continuam como antes. Os novos dados são acrescentados ao lado deles.

O código está em [`Test.RecoveryContract`](../../test/modules/Test.RecoveryContract.psm1)
(o resultado, as etapas compartilhadas), [`Test.RecoveryLedger`](../../test/modules/Test.RecoveryLedger.psm1)
(o livro de registros e o protocolo de reparo) e
[`Test.RecoveryActions`](../../test/modules/Test.RecoveryActions.psm1) (os reparos).

<a id="42820e91-0020"></a>

<a id="recoveryresultjson-the-typed-result"></a>

### `recovery.result.json` (o resultado tipado)

Gravado em `$YURUNA_RUNTIME_DIR` por cada ponto de entrada quando uma execução termina e
substituído a cada vez; `recovery.results.ndjson`, ao lado dele, mantém uma linha compacta por
resultado, reduzido aos 200 mais recentes. Uma gravação que falha gera um aviso e nunca muda
como a execução termina.

| Campo | Significado |
|---|---|
| `schemaVersion` | `1`. |
| `resultId` | Um GUID novo (formato N) por resultado. |
| `entryPoint` | `runner`, `project` ou `sequence`. |
| `cycleGeneration` | `<runnerInstanceId>:<cycle>` para o executor. Um ponto de entrada de execução única cria `<new guid>:1`, o exporta como `YURUNA_CYCLE_GENERATION`, e tudo o que inicia o compartilha. |
| `outcome` | `passed`; `failed` (os testes foram executados e falharam); `infrastructure-fault` (o mecanismo ao redor dos testes falhou); `cannot-run` (uma pré-condição, como a admissão de VM, recusou o ciclo); `aborted` (um processo filho morreu antes que pudesse executar um ciclo). |
| `exitCode` | O código de saída com que o ponto de entrada (ou, para o executor, o ciclo) terminou. |
| `failureClass` | Vazio, uma [classe de falha](#why-each-infra-failure-class-exists) da taxonomia compartilhada, ou uma classe de falha do executor (abaixo). |
| `fingerprint` | `fp1-` mais 16 caracteres hexadecimais: o SHA-256 da classe de falha, etapa, nome de sequência e verbo da ação, cada um sem espaços nas extremidades e convertido para minúsculas. Contagens, carimbos de data/hora, nomes de VM e endereços nunca são entradas, portanto a mesma falha tem a mesma impressão digital no próximo ciclo e depois de uma reinicialização. Vazio em uma aprovação ou em uma falha sem classe. |
| `stage` | A etapa de uma falha de infraestrutura (`ConfigGate`, `ProjectClone`, `FrameworkPull`, `VmAdmission`, `CycleOutcome`, `CycleStart`, `CycleSpawn`, `PoolStorage`), ou vazia. |
| `reason` | Texto curto, com informações sensíveis ocultadas (credenciais em URLs, pares no estilo `password=`, tokens opacos longos) e cortado em 300 caracteres. |
| `evidence` | Ponteiros: `{ kind: file\|record\|event\|command, ref, note }`, por exemplo, o caminho de `last_failure.json` ou o registro de resultado rejeitado. |
| `steps` | As etapas compartilhadas realizadas pela execução (`checkout`, `admission`, `replay`, `cycle`), cada uma `{ step, ok, failureClass, reason }`. |
| `recovery` | `{ state, action, attempt, ledgerId, advised }`; consulte os estados abaixo. |

`recovery.state`: `none` (nada para recuperar); `advised` (há reparos aplicáveis, mas
o reparo automático está desativado, e `advised` os identifica); `declined` (um reparo era aplicável
e sua pré-condição não foi atendida); `applied` (um reparo foi executado e sua pós-condição
foi atendida, e o próximo ciclo é a prova); `failed` (um reparo foi executado, sua pós-condição
falhou e a reversão foi executada); `exhausted` (o orçamento de tentativas para esta impressão digital
e este reparo se esgotou). `escalated` é reservado: o livro de registros registra a transferência
para o operador como uma linha `escalated` depois de uma tentativa que falhou, e o resultado relata
essa tentativa como `failed`. Depois de `failed` e de `exhausted`, o executor entra na
pausa normal de falha, quando o operador intervém.

<a id="42820e91-0021"></a>

<a id="runner-fault-classes"></a>

### Classes de falha do executor

Oito entradas de `RunnerFaultClassEnum` descrevem o executor, em vez de uma
etapa de sequência. Elas ficam fora da taxonomia compartilhada e não têm
manipulador do despachante:

| Classe | Significado |
|---|---|
| `config_gate_failed` | A validação da configuração recusou o início de um ciclo; uma validação que falhou é diferente de um validador bloqueado. |
| `inner_exited` | O processo interno terminou inesperadamente, sem evidências correspondentes da barreira de configuração ou do watchdog. |
| `outcome_unrecorded` | Um ciclo não deixou um registro de resultado utilizável. |
| `vm_admission_occupied` | A verificação de admissão no início do ciclo encontrou um hospedeiro ocupado. |
| `vm_admission_unknown` | A verificação de admissão no início do ciclo não conseguiu determinar se o hospedeiro estava disponível. |
| `preamble_stall` | O watchdog encerrou o processo interno depois que seu heartbeat expirou durante uma fase identificada do preâmbulo. |
| `cycle_killed` | A classificação legada para um ciclo interrompido abruptamente ou abortado, inclusive um processo de ciclo que terminou antes de informar um resultado. |
| `cycle_spawn_failed` | O processo do ciclo não pôde ser iniciado. |

Um encerramento pelo watchdog durante um ciclo ativo usa `wait_timeout` da
taxonomia compartilhada. `cycle_killed` não comprova que o watchdog encerrou um
processo; o watchdog registra sua própria decisão como `preamble_stall` ou
`wait_timeout`.

Para uma tentativa que ainda não concluiu um ciclo, a falha atual aparece em
`runnerFault.failureClass` de `status.json`, junto com a identidade da tentativa,
seus tempos, o commit do framework e os ponteiros de evidências. Uma falha de uma
nova tentativa preserva o veredito, o `lastFailure` e o histórico do ciclo
concluído anteriormente. Se a mesma tentativa iniciou um ciclo que ainda está
em execução, o executor marca esse ciclo como falho e preenche um `lastFailure`
e uma linha do histórico ausentes. As classes de falha do executor também podem
aparecer em `failureClass` de um resultado tipado.

<a id="42820e91-0022"></a>

<a id="the-shared-steps"></a>

### As etapas compartilhadas

As partes que decidem se um ciclo pode executar, ser reexecutado ou contar como uma aprovação são
funções de etapa no módulo de contrato, e os três pontos de entrada chamam as mesmas
funções. Cada uma retorna o mesmo formato: `Step`, `Ok`, `Skipped`, `FailureClass`,
`Reason`, `Evidence`, além de campos próprios.

| Etapa | Encapsula | Falha como |
|---|---|---|
| `Invoke-CycleCheckoutStep` | `Update-ProjectClone` (clona ao lado, verifica, troca) | `bootstrap_sync`, etapa `ProjectClone` |
| `Invoke-CycleAdmissionStep` | `Invoke-HostVmAdmission` | `vm_admission_occupied` (saída 1) ou `vm_admission_unknown` (saída 2) |
| `Resolve-CycleReplayStep` | `Resolve-WarmResumeReplayPlan` | não é uma falha: `Ok` é falso com um motivo (`no-restore-point`, `restore-point-missing`, `safety-check-unavailable`), e a falha original permanece |
| `Publish-CycleOutcomeRecord` / `Read-CycleOutcomeRecord` | o registro de resultado do ciclo | `outcome_unrecorded` |

O registro de resultado também pode conter `failureClass` e `detail` (com informações sensíveis ocultadas, no máximo
300 caracteres), gravados apenas quando o ciclo os conhece. Eles nunca determinam se
um registro é válido. A atualização do framework é o caso que precisa deles: ela é executada no
processo do ciclo, e o executor precisa distinguir um arquivo de bloqueio obsoleto do git de uma falha de rede.

<a id="42820e91-0023"></a>

<a id="recoveryledgerndjson-what-the-runner-may-repair-and-how-often"></a>

### `recovery.ledger.ndjson` (o que o executor pode reparar e com que frequência)

Um arquivo que só permite acréscimos em `$YURUNA_RUNTIME_DIR`, um objeto JSON por linha. O
orçamento de tentativas antes era um contador na memória do laço externo, reiniciado ao reiniciar o
executor; uma falha determinística que persistia depois de uma reinicialização era repetida sem
limite. O livro de registros mantém a contagem onde uma reinicialização não a apaga, e cada
decisão é derivada do arquivo, para que um processo novo que o leia chegue à mesma
resposta.

| `kind` | Linhas |
|---|---|
| `attempt` | `phase`: `started` (gravada e descarregada antes de a ação executar), seguida por uma de `succeeded`, `failed`, `declined`, `exhausted`, `rolled-back`, `rollback-failed`, `abandoned`, `escalated`. Contém `attemptId`, `fingerprint`, `failureClass`, `action`, `attempt`, `generation`, `reason`, `evidence`. |
| `resolved` | `scope` `all` ou `fingerprint`: um ciclo aprovado rearma todos os orçamentos. |

Regras:

1. **Sem registro durável, sem reparo.** Se a linha `started` não puder ser gravada, a
   ação não executa. Um livro de registros que existe, mas não pode ser lido, conta como um orçamento
   esgotado, não vazio.
2. **O orçamento** para uma impressão digital e um reparo é o número de linhas `started`
   depois da linha `resolved` mais recente que abrange o caso e dentro das últimas 24 horas. Ele se
   esgota quando esse número atinge o limite do reparo (`testCycle.autoRemediation.
   maxAttemptsPerCycle`, padrão 2; um reparo pode reduzi-lo).
3. **Uma falha do processo é uma tentativa.** Uma linha `started` sem linha terminal com menos de
   10 minutos indica outro processo ainda trabalhando: o reparo recusa
   (`attempt-in-progress`). Se for mais antiga, é abandonada: acrescenta-se uma linha
   `abandoned`, ela conta como usada e nunca é repetida silenciosamente.
4. As informações sensíveis do texto são ocultadas antes da gravação, e linhas que não podem ser analisadas (uma gravação
   interrompida) são ignoradas e contadas.
5. Dois processos executores podem acrescentar linhas no mesmo momento, e os acréscimos do .NET não
   são serializados entre processos: sem uma proteção, linhas eram perdidas silenciosamente. Por isso, cada
   acréscimo e cada compactação mantém bloqueado o arquivo complementar
   `recovery.ledger.guard`, aberto com exclusividade; o sistema operacional o libera
   quando seu detentor morre. Um gravador que não consegue obter a proteção em cerca de dois
   segundos trata a linha como não gravada, o que significa nenhum reparo.
6. O arquivo é compactado ao ultrapassar 256 KB, mantendo sete dias, cada tentativa inacabada
   e a linha `resolved` mais recente de cada escopo.

<a id="42820e91-0024"></a>

<a id="the-repairs"></a>

### Os reparos

O reparo automático está desativado por padrão (`testCycle.autoRemediation.enabled`, consulte
[test-config.md](../test-config.md#testcycleautoremediation)). Com ele desativado, nada
é gravado no livro de registros, e um resultado contém `recovery.state` `advised` com os
nomes dos reparos que seriam aplicáveis. Com ele ativado, o executor tenta os
reparos aplicáveis nesta ordem e para no primeiro que foi aplicado. Cada um é
idempotente, não realiza ações de hipervisor e executa, no máximo, um comando git limitado.
Nenhum foi exercitado em um hospedeiro real; os testes usam repositórios
temporários e funções substitutas.

| Reparo | Aplica-se a | Pré-condição | Ação | Pós-condição | Reversão |
|---|---|---|---|---|---|
| `clear_stale_git_lock` | uma falha `bootstrap_sync` na etapa `FrameworkPull` ou `ProjectClone` cujo motivo nomeia um arquivo `.lock` | um arquivo `*.lock` diretamente no `.git` de um repositório (ou em `.git/refs`, com três níveis de profundidade) tem mais de 10 minutos, e nenhum processo `git` está em execução na máquina (uma lista de processos que não pode ser lida conta como em execução, assim como um daemon residente de monitoramento do sistema de arquivos) | move cada bloqueio para `runtime/recovery.quarantine/<attemptId>/<framework or project>/<path inside the repository>` (nunca exclui; nada limpa a pasta depois) | `git --no-optional-locks status --porcelain` (somente leitura, portanto não pode recriar o bloqueio) termina com 0 em até 30 segundos em cada repositório afetado | move os bloqueios de volta, e nunca sobre um bloqueio que reapareceu |
| `reclone_project` | uma falha `bootstrap_sync` na etapa `ProjectClone` | uma URL de projeto é resolvida (uma atribuição do grupo em `project.access.json` que não seja `denied`, senão `repositories.projectUrl`), e o `project/` atual ainda não está saudável | `Update-ProjectClone`: clona ao lado, verifica, troca; o checkout anterior é mantido quando falha | o checkout passa na verificação de saúde | restaura uma troca interrompida |
| `end_failure_pause_early` | uma classe de falha que o despachante mapeia para uma repetição claramente segura (`wait_timeout`, `network_timeout`, `ip_not_discovered`, `input_lost`, `instrumentation_failure`, `host_io_blocked`) | a classe está nessa lista | nenhuma: o efeito é que a pausa termina | sempre | nenhuma |

`clear_stale_git_lock` e `reclone_project` executam antes da pausa por falha (e
`clear_stale_git_lock` também antes da suspensão que segue uma atualização do framework que falhou);
`end_failure_pause_early` executa dentro da pausa, depois do primeiro intervalo de consulta, como
sempre fez. Um reparo aplicado substitui a pausa, e o próximo ciclo é sua
prova: uma aprovação rearma todos os orçamentos, e uma repetição da mesma impressão digital os consome.
Quando um orçamento se esgota, o resultado informa `exhausted` e a pausa normal de falha
se aplica.

Cada linha do livro de registros também emite um evento `recovery_action` (`action`, `decision`,
`phase`, `fingerprint`, `failureClass`, `attempt`, `attemptId`, `generation`,
`reason`). `failureClass` é omitida quando o resultado não tem nenhuma e quando ela é uma
classe de falha do executor, pois o esquema de eventos verifica o campo em relação à taxonomia
compartilhada; a linha do livro de registros a mantém. O evento mais antigo `auto_remediation_applied`
continua sendo emitido para o encerramento antecipado da pausa, agora com `attemptId`.

<a id="42820e91-001d"></a>

<a id="related"></a>

## Relacionados

- [Contrato do manipulador](../test-sequences.md#handler-contract) -- onde o vocabulário de classe / severidade / recuperação é declarado.
- [Estrutura de testes](../test-harness.md) -- arquitetura geral.
- [Protocolo de watchdog e heartbeat](../runner-outer-loop.md#watchdog-and-heartbeat-protocol) -- a parte de encerramento da autorrecuperação.
- [Máquina de estados do executor](../runner-outer-loop.md#runner-state-machine) -- o ciclo de vida que apresenta uma transição de falha.
- [Log de desempenho por etapa](../test-perf.md) -- as linhas `step_end` com as quais este documento compartilha um formato de associação.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.10.22

Voltar para [Yuruna](../../README.md)
