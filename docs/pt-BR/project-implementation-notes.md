<a id="42010605-0001"></a>

<a id="project-and-test-implementation-notes"></a>

# Notas de implementação de projetos e testes

Estas notas explicam restrições compartilhadas pelos pontos de entrada dos
testes do workspace, pelas ferramentas do laboratório, pelos projetos de exemplo
e pelas cargas de trabalho de convidados do AmisAd. Use os mesmos nomes de fase
para a mesma operação; mantenha as diferenças entre hospedeiros, aplicações e
transportes exigidas pela restrição descrita abaixo.
Veja [consistência do código-fonte](https://yuruna.link/42e220c4-0001).

<a id="42010605-0002"></a>

<a id="runner-entrypoints"></a>

## Pontos de entrada do executor

<a id="42010605-0303"></a>

<a id="pass-the-planners-listobject-straight-through----do-not-wrap-in--resolve-testsequenceplan-alw"></a>

### Passe List[object] do planejador diretamente — NÃO envolva em @(). Resolve-TestSequencePlan sempre

`yuruna/test/Debug-TestSequence.ps1`

Passe List[object] do planejador diretamente — NÃO envolva em @().
Resolve-TestSequencePlan sempre retorna chainEntries como uma List (uma IList),
que é vinculada diretamente ao parâmetro IList. Envolver uma List genérica em @()
produz um array que um parâmetro Mandatory [IList]/[object[]] rejeita com
"Argument types do not match" (uma particularidade da vinculação @() sobre List
no PowerShell); portanto, esse envolvimento quebraria justamente o caminho
com estado já preparado e uma única entrada que parece proteger.

<a id="42010605-0304"></a>

<a id="run-each-chain-entry-that-overlaps-the-requested-step-range"></a>

### Execute cada entrada da cadeia que se sobreponha ao intervalo de etapas solicitado

`yuruna/test/Debug-TestSequence.ps1`

A execução da janela de etapas de cada entrada e a detecção de renomeação no meio
da cadeia ficam em Test.SequenceRunner.psm1 (Invoke-TestSequenceChain); ele executa
o arquivo real de cada entrada por Invoke-Sequence -StartStep/-StopStep, sem
arquivos temporários de recortes a limpar. Uma renomeação por saveDiskSnapshot
no meio da cadeia aparece no finishedVmName retornado, para que o $VMName externo
deste script acompanhe a renomeação na mensagem final.
O rastreador de resultado de finally{} tem escopo de script, para que uma saída
no meio de try capture a disposição correta antes de Stop-LogFile emitir cycle_end.
'unknown' é o padrão seguro caso o controle saia antes que um dos ramos de
sucesso/falha atribua o resultado.

<a id="42010605-0305"></a>

<a id="register-this-run-as-a-cycle-in-statusjson"></a>

### Registre esta execução como um ciclo em status.json

`yuruna/test/Debug-TestSequence.ps1`

Sem esse bloco, uma execução de Debug-TestSequence fica no ciclo "000000", sem
linha na tabela de histórico do painel, e break-active.json não tem um ciclo
ativo ao qual vincular o botão Continue. O formato segue
Invoke-TestRunnerInnerLoop, mas usa uma única etapa 'Sequence': os indicadores
fixos de fase do executor interno — New-VM / Start-VM / Start-GuestOS / ... —
exibiriam quatro marcadores "pending" que nunca mudam, pois Debug-TestSequence
ignora essas fronteiras de fase.
$nestedNodeId é o ID do nó desta execução no mapa `nested` do proprietário;
ele permanece $null em uma execução proprietária e é lido novamente em finally{}
para finalizar o nó; por isso deve estar no escopo do script ANTES do ramo.

<a id="42010605-0306"></a>

<a id="ensure-vm-is-running"></a>

### Garanta que a VM esteja em execução

`yuruna/test/Debug-TestSequence.ps1`

Ignorado quando a primeira etapa EXECUTADA (respeitando -StartStep e percorrendo
um invólucro como `retry` até a etapa interna efetivamente executada) é
`loadDiskSnapshot`: esse manipulador aceita uma VM parada como entrada (seu driver
do hospedeiro condiciona o Stop-VM anterior à restauração a `if running`),
restaura o disco offline e inicia a própria VM ao retornar. Inicializá-la antes
aqui apenas obrigaria o manipulador a executar Stop-VM imediatamente outra vez —
um ciclo Start+Wait desperdiçado (~15-20s de atraso de inicialização mais a
consulta de parada a frio do Hyper-V) em cada execução com estado já preparado.

<a id="42010605-0307"></a>

<a id="forward--username---hostname-when-the-sequence-declares-them-mirrors-invoke-testrunnerinnerloops"></a>

### Encaminhe -Username / -Hostname quando a sequência os declarar. Segue Invoke-TestRunnerInnerLoop

`yuruna/test/Debug-TestSequence.ps1`

Encaminhe -Username / -Hostname planejados para New-VM. Resolve-TestSequencePlan
percorre a cadeia de baselines e retorna o nome de usuário e o nome de hospedeiro
efetivos, usando a mesma cascata de variáveis do executor recorrente. Valores
vazios usam os padrões de New-VM de cada hospedeiro (o padrão da conta e o nome
da VM, respectivamente).

<a id="42010605-0308"></a>

<a id="reuse-skips-the-entire-new-vm-path-so-the-switch-selection-that-runs-there-never-runs-the-vm-keeps"></a>

### A reutilização ignora todo o caminho de New-VM; a seleção de switch desse caminho não ocorre e a VM mantém

`yuruna/test/Debug-TestSequence.ps1`

A reutilização ignora todo o caminho de New-VM; assim, a seleção de switch feita
nele nunca ocorre: a VM mantém a conexão vNIC com que foi criada, e nenhuma
alteração de rede no hospedeiro chega até ela. Um objeto vSwitch do Hyper-V
sobrevive à sua vinculação com o uplink após uma reinicialização do hospedeiro;
portanto, a mera existência do switch não comprova que ele ainda faça a ponte —
revalide a conexão antes que o mecanismo de sequência gaste o orçamento de etapas
em um convidado que nunca alcançará a rede. Apenas relate: este script não limpa
arquivos de VM, portanto recriá-la cabe à iteração por convidado do executor.
As verificações Get-Command deixam todo o bloco inativo em host.ubuntu.kvm e
host.macos.utm.

<a id="42010605-0309"></a>

<a id="resolve-caching-proxy-service-url"></a>

### Resolva a URL do serviço caching-proxy

`yuruna/test/Debug-TestSequence.ps1`

Siga Invoke-TestRunnerInnerLoop: resolva uma vez com Test-CachingProxyServiceAvailable
(respeita $Env:YURUNA_CACHING_PROXY_SERVICE_IP para caches remotos e usa como
alternativa o estado registrado localmente) e encaminhe a New-VM, para que o
user-data do cloud-init do convidado receba a URL do proxy no template.
Sem esse encaminhamento, New-VM.ps1 de cada convidado recorre à descoberta local
por Get-VM yuruna-caching-proxy-service e avisa "no cache", mesmo quando o
operador tem um cache remoto saudável.

<a id="42010605-000a"></a>

<a id="resolve-the-caching-proxy-service-endpoint-from-config--env"></a>

### Resolva o endpoint de caching-proxy-service a partir da configuração e do ambiente

`yuruna/test/Debug-TestSequence.ps1`

Invoke-TestRunnerInnerLoop lê TANTO $Config.vmStart.cachingProxyIp (a chave
persistente editada pela interface, verificada primeiro) QUANTO
$env:YURUNA_CACHING_PROXY_SERVICE_IP (alternativa com escopo de sessão, verificada
apenas quando o candidato da configuração está ausente ou falha), mantém o
primeiro cuja porta HTTP do proxy seja acessível e limpa a variável de ambiente
quando nenhum responde. Debug-TestSequence executa o MESMO
Resolve-CachingProxyServiceEndpoint; assim, um IP sintaticamente válido, mas
inativo, configurado pela página Edit-config do status service também não pode
persistir no cidata do convidado aqui. Quando nenhuma das origens está definida,
o resolvedor não faz nada, e o caminho de descoberta local em
Test-CachingProxyServiceAvailable abaixo continua inalterado.

<a id="42010605-000b"></a>

<a id="ssh-user-override"></a>

### Substituição do usuário SSH

`yuruna/test/Debug-TestSequence.ps1`

O mesmo registro em cascata de Invoke-TestRunnerInnerLoop: Get-GuestSshUser de
Test.Ssh é o ponto de consulta para Save-GuestDiagnostic e para Send-Text /
fetchAndExecute SSH em modo SSH do driver do hospedeiro. Uma execução independente
de Debug-TestSequence usa a mesma cadeia uma única vez; portanto, registre a
mesma substituição aqui. Um $effectiveUser vazio continua usando o padrão fixo
de cada convidado por Get-GuestSshUser, sem alterações.

<a id="42010605-000c"></a>

<a id="concurrent-vm-admission"></a>

### Admissão diante de VMs simultâneas

`yuruna/test/Debug-TestSequence.ps1`

Dois ciclos sobre um mesmo conjunto de VMs corrompem um ao outro; por isso, a
execução só inicia em um hospedeiro no qual tenha confirmado a ausência de outros
convidados. Em algumas versões do macOS, vmnet-shared também atribui uma ponte
separada no hospedeiro a cada "session" de vmnet (bridge100, bridge101, ...),
sem roteamento entre elas; assim, uma VM externa simultânea pode colocar os
convidados de teste em uma ponte diferente daquela do gateway vmnet do hospedeiro
e quebrar a URL do proxy do hospedeiro, usada pelo cloud-init e incorporada a seed.iso.
As VMs de serviço e o destino do operador ($VMName) são isentos; o destino pode
permanecer ativo para outra iteração da mesma sequência de depuração.
A admissão primeiro para e depois recusa: um convidado remanescente é parado em
vez de deixar o hospedeiro sem saída, e a recusa cobre apenas o que não pôde ser
parado — ou um hospedeiro que não consegue informar o que está em execução.

<a id="42010605-000d"></a>

<a id="build-chain-plan"></a>

### Construa o plano da cadeia

`yuruna/test/Debug-TestSequence.ps1`

O planejamento da cadeia e a verificação requiresSnapshot para o caminho com
estado já preparado ficam em Test.SequenceRunner.psm1, para permitir testes
unitários com dados de fixture. O comportamento é percorrer a cadeia de baseline,
construir (name,path,sequence,stepCount,globalStart) para cada entrada e — quando
o nível superior declara requiresSnapshot.id e o snapshot já está no disco —
excluir todos os pré-requisitos e executar apenas o nível superior sobre a VM
persistida. effectiveUsername deve ser conhecido ANTES de New-VM abaixo,
acompanhando o mesmo encaminhamento do executor.

<a id="42010605-000e"></a>

<a id="derive-guestkey-from-the-sequences-baseline-map"></a>

### Derive GuestKey do mapa de baseline da sequência

`yuruna/test/Debug-TestSequence.ps1`

A fonte de verdade é o campo `baseline:` da sequência — as chaves de SO nele
listadas informam qual VM de convidado a sequência tem como destino. O nome do
arquivo NÃO é a autoridade: caso contrário, um erro de digitação ou uma
renomeação poderia desviar silenciosamente toda a cadeia (e uma sequência de
projeto como `ch01.website.example.yml` sequer contém um token de convidado no
nome). É a mesma consulta que o planejador de ciclo usa em Resolve-CyclePlan
(Test.SequencePlanner.psm1) para Start-TestRunner / Invoke-TestProject,
mantida simétrica para que Debug-TestSequence se comporte da mesma forma
quando executado de modo independente.

<a id="42010605-000f"></a>

<a id="same-hazard-the-guest-path-guards-against-further-down-a-foreign-running-vm-can-share-the-host-with"></a>

### O mesmo risco verificado adiante no caminho do convidado: uma VM externa em execução pode compartilhar o hospedeiro com

`yuruna/test/Debug-TestSequence.ps1`

O mesmo risco verificado adiante no caminho do convidado: uma VM externa em
execução pode compartilhar o hospedeiro com esta execução (e, no macOS, colocar
seus convidados em uma segunda ponte no hospedeiro que não tem rota para o
gateway vmnet dele, quebrando a URL do proxy do hospedeiro incorporada a seed.iso
para o cloud-init). Este caminho retorna antes de chegar àquela verificação, e
Test.Orchestrator não tem uma própria; portanto, a admissão também deve ocorrer
aqui. Ela primeiro para e depois recusa, para que um convidado remanescente seja
parado em vez de deixar o hospedeiro sem saída. Sem -ExceptVmName: uma execução de
orquestração cria uma VM por sequência interna, em vez de ter um único convidado
nomeado como destino; portanto, não há nada a isentar.

<a id="42010605-0010"></a>

<a id="orchestration-sequence-dispatch-invoketestsequence-steps"></a>

### Despacho de sequência de orquestração (etapas InvokeTestSequence)

`yuruna/test/Debug-TestSequence.ps1`

Uma sequência de orquestração não tem `baseline:`, e suas etapas invocam
sequências internas (de convidado ou de ação no hospedeiro) em ordem. Ela é
detectada aqui — depois de preparar o driver do hospedeiro, os diretórios de
runtime, a proteção de instância única e o OCR, mas antes do caminho GuestKey + VM
exclusivo de convidados — e entregue a Test.Orchestrator, que gerencia seu próprio
ciclo de status e log e retorna um código de saída.

<a id="42010605-0011"></a>

<a id="sweep-the-stale-inter-cycle-control-state-a-freshly-typed-debug-testsequence-command-line-must-not-i"></a>

### Limpe o estado de controle antigo entre ciclos que uma nova linha de comando Debug-TestSequence não deve herdar

`yuruna/test/Debug-TestSequence.ps1`

Limpe o estado de controle antigo entre ciclos que uma nova linha de comando
Debug-TestSequence não deve herdar. -Scope Startup consome control.cycle-
restart (para que a verificação nº 1 de Invoke-Sequence não lance YurunaCycleRestart
na primeira etapa e dê a impressão de que a SEQUÊNCIA falhou), arquiva um
break-active.json remanescente e limpa sinalizadores de pausa antigos (para que
a interface de status não mostre Continue pendente e a execução não comece
pausada por causa de uma sessão anterior que o operador nunca retomou).
O operador digitou ESTA linha de comando, portanto a intenção de executar tem
prioridade sobre os sinalizadores antigos. Execuções aninhadas NÃO devem limpar
o estado de controle: os sinalizadores de pausa / cycle-restart pertencem ao
ciclo ativo do proprietário, e limpá-los em um filho descartaria um Continue
preparado pelo operador no pai. Apenas o proprietário faz essa limpeza.

<a id="42010605-0012"></a>

<a id="ctrlc-handler"></a>

### Manipulador de Ctrl+C

`yuruna/test/Debug-TestSequence.ps1`

Registre um manipulador de CancelKeyPress que altere $script:CancelState['Requested'],
em vez de permitir que Ctrl+C encerre o runspace no meio de uma etapa. O bloco
finally{} abaixo consulta o sinalizador e para a VM, para que um convidado
incompleto (interrompido durante New-VM / Start-VM / uma etapa longa de sequência)
não permaneça consumindo CPU e memória do hospedeiro. O disco é mantido
intencionalmente, para permitir a inspeção após a falha por virsh / vmconnect / utmctl.

<a id="42010605-0013"></a>

<a id="single-instance-guard"></a>

### Proteção de instância única

`yuruna/test/Debug-TestSequence.ps1`

Recuse a inicialização quando um Start-TestRunner já for proprietário do diretório
de runtime. Debug-TestSequence é um ponto de entrada de desenvolvimento: ele não
coordena a máquina de estados do executor; assim, uma execução simultânea
concorreria com o pidfile do executor, com os registros de status.json e com as
operações de VM. Get-RunnerInstanceState (Test.SingleInstance) faz a leitura;
Assert-NoOtherRunner o envolve com a semântica de recusa e mensagem necessária
a este ponto de entrada — o caminho de tomada de controle de Start-TestRunner
faz o oposto (Stop-StaleRunner).
Execuções aninhadas ignoram a proteção: elas não são proprietárias do diretório
de runtime (o proprietário do ciclo externo é), e ele já passou pela mesma
verificação. Impô-la aqui faria toda etapa aninhada recusar a inicialização assim
que o proprietário se registrasse.

<a id="42010605-0014"></a>

<a id="tolerate-operator-typing-the-ymlyaml-extension-on-the-name-form-eg-via-shell-tab-completion-ag"></a>

### Aceite a extensão .yml/.yaml digitada pelo operador na forma de nome (por exemplo, pela conclusão de tabulação do shell)

`yuruna/test/Debug-TestSequence.ps1`

Aceite a extensão .yml/.yaml digitada pelo operador na forma de nome (por exemplo,
pela conclusão de tabulação do shell em uma árvore de trabalho de projeto irmã,
cujo caminho o ramo Resolve-Path não conseguiu resolver a partir deste cwd).
Resolve-SequencePath acrescenta .yml incondicionalmente; assim, uma extensão no
final faria a busca procurar `Name.yml.yml` e não encontrar o arquivo. É a mesma
remoção que Test.SequencePlanner já faz ao ler entradas de baseline do YAML,
mantida simétrica para que chamadores pela CLI e pelo YAML se comportem da mesma forma.

<a id="42010605-0015"></a>

<a id="resolve-sequence-file"></a>

### Resolva o arquivo da sequência

`yuruna/test/Debug-TestSequence.ps1`

As sequências ficam diretamente em test/sequences/ no framework e em
project/<...>/test/ no clone de cada ciclo; uma variante ssh é uma sequência
<name>.ssh própria. Resolve-SequencePath verifica primeiro a árvore do projeto,
depois o framework, e a variante específica do hospedeiro antes do arquivo simples.
Se nada corresponder, liste tudo o que estiver disponível nas duas árvores.

Por conveniência, quando $SequenceName é o caminho de um arquivo .yml existente
(a conclusão de tabulação do shell produz isso naturalmente), use-o literalmente
e reduza o nome ao basename para o planejamento posterior. GuestKey vem do mapa
de baselines da sequência, a menos que seja fornecido explicitamente. O operador
indicou um arquivo específico — respeite essa escolha, sem substituí-la por uma
variante do hospedeiro obtida na busca por níveis.

<a id="42010605-0016"></a>

<a id="pre-cycle-config-gate"></a>

### Verificação de configuração antes do ciclo

`yuruna/test/Debug-TestSequence.ps1`

Siga Start-TestRunner: recuse iniciar uma VM quando test.config.yml / vault.yml /
users.yml / transports.yml estiverem em um estado que Test-Config.ps1 rejeitaria.
Sem essa verificação, uma sequência pode "passar" em Debug-TestSequence (o modo
de compatibilidade das extensões encobre a configuração incorreta), enquanto o
executor se recusa até a iniciar o ciclo com a mesma configuração — justamente
a surpresa confusa contra a qual essa verificação protege. Ignore-a com
-NoConfigGate para alterações ad hoc ou em andamento.
Inicie um pwsh novo, para que uma saída antecipada Out-Of-Order ::Stop em
Test-Config não desfaça este script. -SkipSend impede que o email de teste de
smoke sobrecarregue subscribers["config.smoke"] a cada chamada de Debug-TestSequence.
Test.ConfigPreflight foi importado por Initialize-YurunaEntryPointModuleSet acima.

Uma execução ANINHADA herda a decisão do proprietário, em vez de repetir a
verificação. O proprietário aprovou esse mesmo hospedeiro e configuração ao abrir
o ciclo; uma execução aninhada é uma etapa desse ciclo, portanto revalidar a cada
etapa não traz benefício e tem um custo real. A verificação acessa github.com,
e o estado remoto não é uma propriedade da configuração verificada: uma credencial
que expire entre duas etapas transforma uma checagem prévia em uma interrupção
no meio da execução, encerrando um ciclo por algo de que nenhum trabalho restante
depende e descartando todas as etapas já construídas. A checagem prévia pertence
ao início da execução. Uma execução independente (sem contexto de ciclo herdado)
não é afetada e continua fazendo sua própria verificação.

<a id="42010605-0017"></a>

<a id="pre-flight-elevation"></a>

### Checagem prévia: elevação

`yuruna/test/Debug-TestSequence.ps1`

Antes da substituição do checkout do projeto abaixo. Assert-HostConditionSet faz
a mesma verificação muito depois, e com -NoConfigGate nada a detecta antes que
<RepoRoot>/project já tenha sido atualizado. A própria verificação limita sua
aplicação: Assert-Elevation retorna true imediatamente sempre que
Test-ElevationRequired é false, e apenas host.windows.hyper-v registra
RequiresElevation — portanto, isso não faz nada no macOS e no Linux e não pode
introduzir uma exigência de UAC ou sudo.

<a id="42010605-0018"></a>

<a id="nested-cycle-detection"></a>

### Detecção de ciclo aninhado

`yuruna/test/Debug-TestSequence.ps1`

Quando este Debug-TestSequence inicia na árvore de processos de outra execução —
uma etapa de ação no hospedeiro que nos chama novamente em um pwsh filho (por
exemplo, Set-Resource.ps1 distribuindo construções de convidados por etapa) —,
ele herda o identificador do contexto de ciclo do proprietário
($env:YURUNA_CYCLE_CONTEXT). Sua presença indica que ESTA execução é ANINHADA:
ela anexa um nó ao ÚNICO ciclo de status.json do proprietário, em vez de criar
um próprio. Uma execução aninhada NÃO deve redefinir status.json, reiniciar o
status service, obter a trava de instância única, limpar os sinalizadores de
controle do proprietário, alocar um número de ciclo de nível superior nem
finalizar o ciclo — ações exclusivas do proprietário. A ausência do identificador
significa proprietário independente, o comportamento clássico inalterado.
Veja "Nested-cycle support" em Test.Status.psm1 para o modelo de propriedade.

<a id="42010605-0019"></a>

<a id="canonical-module-set-for-the-sequence-entry-point"></a>

### Conjunto canônico de módulos para o ponto de entrada Sequence

`yuruna/test/Debug-TestSequence.ps1`

Inclui Test.LogLevel + Test.Config + Test.SequenceAction + Test.HostIO +
Test.HostContract + Test.Log + Test.SequenceEngine + Test.SequencePlanner +
Test.YurunaDir + Test.OcrEngine + Test.Tesseract +
Test.ConfigPreflight. A ordem importa: o planejador DEPOIS do mecanismo, para que
a reimportação com -Force do mecanismo dentro do planejador não remova o mecanismo
que acabou de ser importado.

<a id="42010605-001a"></a>

<a id="build-the-parameter-set-invoke-testproject-must-pass-to-the-inner--nogitpull-and--noprojectclone-ar"></a>

### Construa o conjunto de parâmetros que Invoke-TestProject deve passar ao executor interno. -NoGitPull e -NoProjectClone

`yuruna/test/Invoke-TestProject.ps1`

Construa o conjunto de parâmetros que Invoke-TestProject deve passar ao executor
interno. -NoGitPull e -NoProjectClone são *sempre* impostos aqui — Invoke-TestProject
faz seu próprio clone novo e testa a árvore local como está; uma atualização do
framework no meio do teste misturaria os sinais. logLevel só é encaminhado se o
operador o passou na linha de comando deste script (PSBoundParameters); caso
contrário, o executor interno usa o padrão do arquivo de configuração.
-NoConfigGate também é imposto: a verificação acima já aprovou essa mesma
configuração segundos antes, precedendo a substituição do checkout novo realizada
por este ponto de entrada. Verificá-la novamente no executor interno repetiria
a consulta a todas as origens remotas para obter uma decisão que nada teve tempo
de invalidar.

<a id="42010605-001b"></a>

<a id="step-3-spawn-one-inner-cycle"></a>

### Etapa 3: inicie um ciclo interno

`yuruna/test/Invoke-TestProject.ps1`

Invoke-TestProject usa o construtor compartilhado de argumentos tipados para
invocar diretamente um novo processo interno; o executor recorrente o inicia
a partir de um worker de ciclo:
  * operador de chamada (não Start-Process) — o executor interno deste ponto de
    entrada de execução única herda seu ambiente, stdio e contexto de sinais
  * -Command (não -File) — pwsh -File converte cada argv em [string],
    o que quebraria parâmetros [switch] / [int]
  * -NoProfile — $PROFILE não pode sobrescrever variáveis de ambiente YURUNA_*
  * YURUNA_RUNNER_RELAUNCH=1 — o executor interno ignora sua própria proteção
    de tomada do pidfile (não pode tomar nosso controle com segurança;
    somos o pai legítimo)
  * -NoProjectClone — as etapas 1+2 já produziram uma árvore nova; o executor
    interno confia nela e ignora Update-ProjectClone
  * -NoGitPull — Invoke-TestProject é um teste do projeto, não do framework;
    uma atualização do framework no meio do teste misturaria os sinais

<a id="42010605-001c"></a>

<a id="step-12-wipe--re-clone-project"></a>

<a id="step-12-clone-verify-and-swap-the-project-checkout"></a>

### Etapas 1+2: clone, verifique e substitua o checkout do projeto

`yuruna/test/Invoke-TestProject.ps1`

Update-ProjectClone é o mesmo auxiliar que Invoke-TestRunnerInnerLoop usa a cada
ciclo — ao chamá-lo aqui, uma regressão na substituição do checkout, no próprio
git clone ou na verificação de segurança (recusar a exclusão fora de RepoRoot)
aparece em Invoke-TestProject antes de afetar Start-TestRunner. A função clona ao
lado do checkout atual, verifica o clone e então o coloca em seu lugar; um clone
malsucedido mantém o checkout anterior. Separar essas operações em Invoke-TestProject
duplicaria a verificação de segurança sem acrescentar valor.
Test.HostContract foi importado por Initialize-YurunaEntryPointModuleSet acima.

<a id="42010605-001d"></a>

<a id="sweep-the-parked-interactive-control-state-before-handing-off-to-the-inner--scope-prespawn-archives"></a>

### Limpe o estado de controle interativo estacionado antes de entregar ao executor interno. -Scope PreSpawn arquiva

`yuruna/test/Invoke-TestProject.ps1`

Limpe o estado de controle interativo estacionado antes de entregar ao executor
interno. -Scope PreSpawn arquiva um break-active.json remanescente e limpa
sinalizadores de pausa antigos (control.step-pause / .cycle-pause), para que o
processo interno iniciado não herde o estado de interrupção estacionado — caso
contrário, a interface de status manteria ativo o botão Continue da execução
anterior. Invoke-TestProject inicia Invoke-TestRunnerInnerLoop diretamente
(sem passar pelo Start-TestRunner externo que normalmente hospeda
Invoke-YurunaBootRecovery), portanto essa limpeza deve ocorrer aqui.
PreSpawn deixa deliberadamente control.cycle-restart para que o executor interno
filho o consuma como SUA própria reinicialização.

<a id="42010605-001e"></a>

<a id="refuse-to-start-when-a-start-testrunner-already-owns-the-runtime-dir-invoke-testproject-spawns-its"></a>

### Recuse a inicialização quando um Start-TestRunner já for proprietário do diretório de runtime. Invoke-TestProject inicia seu

`yuruna/test/Invoke-TestProject.ps1`

Recuse a inicialização quando um Start-TestRunner já for proprietário do diretório
de runtime. Invoke-TestProject inicia abaixo seu próprio executor interno com
YURUNA_RUNNER_RELAUNCH=1, o que lhe diz para ignorar sua proteção de tomada do
pidfile — seguro apenas quando o próprio Invoke-TestProject é o pai legítimo.
Se um Start-TestRunner real já estiver ativo, esse contrato permitiria que nosso
executor interno concorresse com as atualizações de runner.pid + status.json do
ciclo ativo. Assert-NoOtherRunner (Test.Prelude, apoiado por Test.SingleInstance)
lê runner.pid + runner.start e recusa; o caminho de tomada de controle de
Start-TestRunner faz o oposto (Stop-StaleRunner) e permanece no executor externo.

<a id="42010605-001f"></a>

<a id="pre-flight-elevation-1"></a>

### Checagem prévia: elevação

`yuruna/test/Invoke-TestProject.ps1`

Antes da substituição do checkout. Sem isso, um operador que tenha esquecido o
shell elevado recebe <RepoRoot>/project atualizado e só depois encontra a
verificação no ciclo interno iniciado. A própria verificação limita sua aplicação:
Assert-Elevation retorna true sempre que Test-ElevationRequired é false, e apenas
host.windows.hyper-v registra RequiresElevation — portanto, isso não faz nada
no macOS e no Linux e não pode introduzir uma exigência de UAC ou sudo em um
caminho que nunca precisou deles.

<a id="42010605-0020"></a>

<a id="exit-code-contract-0--success-1--anything-else-a-binary-code-is-what-passfail-consumers-want"></a>

<a id="exit-code-contract-setup-failure-is-1-completed-cycles-forward-the-inner-exit-code"></a>

### Contrato de código de saída: falha de preparação é 1; ciclos concluídos encaminham o código de saída interno

`yuruna/test/Invoke-TestProject.ps1`

Falhas na checagem prévia, no clone e na criação do processo interno encerram com 1;
um ciclo interno concluído encaminha seu código de saída exato, em que 0 indica
sucesso. Um consumidor de CI que precise distinguir entre "preflight" /
"clone failed" / "inner spawn failed" lê a mensagem Stop-WithReason
("STOP (exit 1) at <Step>"). O $Step + $Reason da mensagem fornecem o motivo.

<a id="42010605-0021"></a>

<a id="one-shot-project-test-wipe-reporootproject-re-clone-from-repositories"></a>

<a id="one-shot-project-test-prepare-the-project-clone-and-invoke-the-inner-runner"></a>

### Teste único do projeto: prepare o clone do projeto e invoque o executor interno

`yuruna/test/Invoke-TestProject.ps1`

Cada etapa é verificada e informa seu próprio motivo em caso de falha:

  As etapas 1+2 verificam um clone novo e substituem <RepoRoot>/project pelo mesmo
            auxiliar Test.HostContract\Update-ProjectClone que
            Invoke-TestRunnerInnerLoop chama a cada ciclo. Uma falha aqui
            interrompe com uma linha clara de "o quê + por quê"; o executor
            interno nunca é iniciado.

  A etapa 3 inicia Invoke-TestRunnerInnerLoop.ps1 em um pwsh novo usando o
            construtor compartilhado de argumentos tipados de Test.InnerSpawn,
            com -NoProjectClone (o clone já é novo) e -NoGitPull
            (Invoke-TestProject testa o projeto como está localmente; uma
            atualização do framework no meio do teste confundiria o sinal).
            O executor interno realiza o ciclo completo, registra-o como um
            ciclo regular em status.json e encerra.

  A etapa 4 expõe o código de saída do executor interno como o nosso e para.
            Sem retomada; o operador (ou CI) chama Invoke-TestProject novamente
            de modo explícito se quiser outra execução.

Ao chamar Update-ProjectClone + Invoke-TestRunnerInnerLoop diretamente,
Invoke-TestProject exercita os mesmos caminhos de código que Start-TestRunner —
uma regressão em qualquer um deles aparece aqui primeiro.

<a id="42010605-0022"></a>

<a id="register-in-the-runtime-usersyml"></a>

### Registre em users.yml do runtime

`yuruna/test/New-LocalTestUser.ps1`

O literal YAML preserva a formatação exata usada pelas entradas versionadas de
users.yml.template (recuo de 2 espaços em `users:`, formato flow inline
`corporate: { domain: "", sam: "", upn: "" }`, chaves preenchidas para vaultKey /
localOsPasswordRef). Acrescentar texto, em vez de converter e serializar novamente
por ConvertTo-Yaml, mantém intactos os comentários existentes e a formatação
das entradas do arquivo.

<a id="42010605-0023"></a>

<a id="-windowstyle-not--nonewwindow--credential-belongs-to-a-parameter-set-that-has-no--nonewwindow--wo"></a>

### -WindowStyle em vez de -NoNewWindow: -Credential pertence a um conjunto de parâmetros sem -NoNewWindow. -Wo

`yuruna/test/New-LocalTestUser.ps1`

-WindowStyle em vez de -NoNewWindow: -Credential pertence a um conjunto de
parâmetros sem -NoNewWindow.
-WorkingDirectory: sem ele, o filho herda o diretório do chamador, e o diretório
de um operador elevado costuma ser inacessível para a nova conta — o que faz
a própria inicialização falhar antes que qualquer comando seja executado.

<a id="42010605-0024"></a>

<a id="let-the-new-windows-account-run-scripts"></a>

### Permita que a nova conta do Windows execute scripts

`yuruna/test/New-LocalTestUser.ps1`

Uma nova conta do Windows começa com o padrão do shell — Restricted nas SKUs
cliente —, portanto o primeiro .ps1 executado interativamente pelo operador
nessa conta é recusado. A política CurrentUser fica no próprio perfil da conta
(o PowerShell 7 a mantém em Documents\PowerShell\powershell.config.json;
o Windows PowerShell 5.1, em HKCU), e nenhum desses armazenamentos existe até que a
conta entre uma vez: defini-la nesta sessão elevada alteraria apenas a política
do operador que executa o script. Por isso, ela é definida em uma sessão realmente
executada como a nova conta — um logon único aqui quando a conta tem uma senha
utilizável e uma tarefa agendada no primeiro login quando não tem.

Essa política se aplica às sessões interativas de scripts da própria conta.
Um processo filho iniciado com -ExecutionPolicy Bypass usa essa substituição
explícita; nem todos os pontos de entrada do framework a fornecem.

<a id="42010605-0025"></a>

<a id="get-localgroupmember-fails-to-enumerate-a-group-that-still-holds-a-sid-no-longer-resolvable-to-a-pri"></a>

### Get-LocalGroupMember não consegue enumerar um grupo que ainda contém um SID não resolvível para uma entidade de segurança

`yuruna/test/New-LocalTestUser.ps1`

Get-LocalGroupMember não consegue enumerar um grupo que ainda contém um SID
não resolvível para uma entidade de segurança (uma conta de domínio excluída,
um usuário local removido). Add-LocalGroupMember acima já lança uma exceção
em uma falha real; portanto, um grupo ilegível é uma lacuna de verificação,
não uma concessão malsucedida — informe isso em vez de interromper uma execução
bem-sucedida. $null significa "não foi possível enumerar", diferente de $false
("enumerou, e a conta não está lá") — apenas o segundo caso é uma concessão
realmente malsucedida.

<a id="42010605-0026"></a>

<a id="recreating-is-the-whole-point-of-running-this-against-a-name-that-already-exists-so-the-run-offers"></a>

### Recriar é a finalidade de executar contra um nome que já existe; por isso, a execução oferece

`yuruna/test/New-LocalTestUser.ps1`

Recriar é a finalidade de executar contra um nome que já existe; por isso, a
execução oferece essa opção, em vez de recusar e dizer ao operador qual switch
acrescentar. Ela não pode decidir em nome dele: a conta pode ser uma conta de
teste antiga ou uma conta em uso, e apenas o operador distingue os casos.
-Force é essa resposta dada antecipadamente, permitindo a recriação sem intervenção.

<a id="42010605-0027"></a>

<a id="a-path-at-or-beside-the-filesystem-root-is-a-damaged-account-record-rather-than-a-home-directory---"></a>

### Um caminho na raiz do sistema de arquivos ou junto dela indica um registro de conta danificado, não um diretório pessoal —

`yuruna/test/New-LocalTestUser.ps1`

Um caminho na raiz do sistema de arquivos ou junto dela indica um registro de
conta danificado, não um diretório pessoal — '/', '/home' e C:\Users contêm os
arquivos de todas as outras contas, e excluir recursivamente um desses caminhos
não permite recuperação. Use DirectoryInfo em vez de Split-Path: Split-Path gera
erro em um caminho raiz, em vez de retornar nada, e esse erro abandona a instrução
que deveria fornecer a proteção. Pelo mesmo motivo, qualquer caminho que a
verificação não consiga resolver é recusado.

<a id="42010605-0028"></a>

<a id="an-account-with-a-password-is-the-point-of-the-tool-so-a-run-that-names-no-password-asks-for-one-ra"></a>

### Uma conta com senha é a finalidade da ferramenta; por isso, uma execução sem senha informada a solicita

`yuruna/test/New-LocalTestUser.ps1`

Uma conta com senha é a finalidade da ferramenta; por isso, uma execução que não
informe senha a solicita, em vez de produzir uma conta bloqueada em que ninguém
consiga entrar. -NoPassword é a opção explícita para dispensá-la.

A própria solicitação deliberadamente NÃO fica aqui. No Windows, uma execução
sem elevação se inicia novamente por UAC, e a senha nunca é encaminhada pela
linha de comando; solicitá-la agora exigiria solicitá-la outra vez na janela
elevada. Ela é solicitada uma vez, depois da verificação de elevação e das
checagens prévias — não há motivo para coletar um segredo para uma conta
que já existe.

<a id="42010605-0029"></a>

<a id="re-create-the-default-test-account-without-stopping-to-ask-an-existing-yurunatest-os-account-and"></a>

### Recrie a conta padrão de teste sem parar para perguntar: uma conta de SO `yurunatest` existente e

`yuruna/test/New-LocalTestUser.ps1`

Recrie a conta padrão de teste sem parar para perguntar: uma conta de SO
`yurunatest` existente e seu diretório pessoal são excluídos primeiro, enquanto
a entrada de users.yml do Yuruna e qualquer senha do vault para a qual ela
aponte são reutilizadas. A mesma execução sem -Force faz o mesmo depois de
confirmar a exclusão com o operador. Acrescente -WhatIf na primeira vez para
ver exatamente o que seria removido.

<a id="42010605-002a"></a>

<a id="one-entry-per-host----the-currentuser-policy-is-stored-per-host-so-setting-one-leaves-the-other-at"></a>

### Uma entrada por host do PowerShell — a política CurrentUser é armazenada por host do PowerShell; definir uma deixa a outra no

`yuruna/test/New-LocalTestUser.ps1`

Uma entrada por host do PowerShell — a política CurrentUser é armazenada por host do PowerShell;
definir uma deixa a outra no padrão — e se a nova conta consegue executá-la.

Um PowerShell instalado para um único usuário fica no perfil desse usuário:
um MSI por usuário em AppData\Local\Programs ou um alias de execução da Store
em AppData\Local\Microsoft\WindowsApps. Nenhuma outra conta pode executá-lo.
Passar esse caminho a um logon como a nova conta falha com "Access is denied"
antes de o comando iniciar, e uma tarefa agendada para o mesmo caminho falha da
mesma forma no login da própria conta — por isso, um caminho sob um perfil é
informado ao operador e nunca usado.

<a id="42010605-002b"></a>

<a id="second-pass-over-the-home-directory-because-every-platforms-account-delete-has-a-way-of-leaving-it"></a>

### Segunda passagem pelo diretório pessoal, pois a exclusão de conta em cada plataforma pode deixá-lo

`yuruna/test/New-LocalTestUser.ps1`

Segunda passagem pelo diretório pessoal, pois a exclusão de conta em cada
plataforma pode deixá-lo para trás: um perfil do Windows cuja entrada ProfileList
é ilegível, `userdel` relatando saída 12, um diretório pessoal do macOS com
arquivos ainda abertos. O que permanece não é apenas aparência — a conta recriada
não consegue ler arquivos pertencentes a um ID que já não resolve, e no Windows
recebe um segundo diretório de perfil com sufixo `.000`, ao lado do antigo.

O caminho vem do próprio SO (Win32_UserProfile.LocalPath, o registro passwd,
dscl), nunca do nome da conta; assim, a remoção atinge o diretório que a conta
realmente tinha.

<a id="42010605-002c"></a>

<a id="create-a-local-os-account-on-the-host-optionally-with-a-password-and-local-machine-administrator-ri"></a>

### Crie uma conta local de SO no hospedeiro, opcionalmente com senha e direitos de administrador da máquina local

`yuruna/test/New-LocalTestUser.ps1`

Cria um usuário local de SO com o nome de exibição e o nome de conta fornecidos.
O nome de conta padrão é `yurunatest`; assim, o caso comum exige apenas um switch:
`.\New-LocalTestUser.ps1 -Admin`.

A senha é definida na criação e pode ser usada imediatamente, para que um
hospedeiro de teste sem intervenção possa entrar sem que uma troca interativa
no primeiro login impeça isso. Há três formas:

  * Padrão: a senha é solicitada interativamente (duas vezes, com confirmação)
    no lado elevado; assim, nunca chega ao histórico do shell nem ao vetor
    de argumentos de um processo.

  * Com -Password: a senha fornecida é usada em vez de ser solicitada.

  * Com -NoPassword: a conta é criada SEM uma senha utilizável.
    Ela existe, mas não pode entrar até que o operador defina uma senha
    por outro meio.

Quando o vault de autenticação já guarda uma senha local de SO para esse nome
de conta, ela é reutilizada em vez de solicitada; assim, uma conta recriada
continua correspondendo à credencial fornecida pelo Yuruna.
-Password substitui a senha armazenada; -PromptForPassword solicita uma mesmo
assim e avisa que a cópia armazenada deixará de corresponder.

-ForcePasswordChange torna a senha uma credencial inicial de uso único e exige
sua troca no primeiro login interativo. É opcional — sem ele, a conta entra
sem intervenção.

-Admin também torna a conta administradora da máquina local: o grupo interno
Administrators no Windows (resolvido por SID, para funcionar em instalações
em outros idiomas), o grupo `admin` no macOS e o grupo `sudo` no Ubuntu.

No Windows, a conta também fica apta a executar scripts: sua política de execução
CurrentUser é definida como RemoteSigned. Essa política fica no próprio perfil
da conta; por isso é definida em uma sessão que executa como a nova conta — um
logon único aqui quando a senha é utilizável e uma tarefa agendada no primeiro
login quando -NoPassword ou -ForcePasswordChange impede esse logon.

O mesmo nome lógico de conta é registrado no mapeamento de autenticação do runtime,
status/extension/authentication/users.yml, com os campos corporate / vault vazios,
para que a entrada se comporte como um usuário Yuruna puramente local (compare
test/extension/authentication/users.yml.template). Um hospedeiro cujo arquivo de
runtime ainda não exista recebe primeiro uma cópia inicial do template versionado;
o próprio template nunca é gravado, portanto registrar uma conta local da máquina
nunca altera um arquivo rastreado.

Um nome já declarado em users.yml é reutilizado, não recusado: a entrada permanece
exatamente como está, assim como qualquer credencial de vault para a qual aponte,
e a execução continua. Uma conta de SO já existente também não interrompe a
execução: ela informa o que será removido com a exclusão e solicita confirmação;
depois exclui a conta — seu diretório pessoal e tudo nele — e a cria novamente
do zero. -Force responde a essa confirmação antecipadamente, permitindo que
uma execução sem intervenção recrie a conta em uma chamada. Três casos são
recusados de imediato, inclusive com -Force: uma conta do sistema, a conta
que executa o script e uma conta com sessão de login aberta.

A elevação é solicitada antes de qualquer alteração. No Windows, uma execução
sem elevação pede consentimento e se inicia novamente por UAC; a janela elevada
solicita a senha, em vez de recebê-la pela linha de comando, para que o segredo
nunca apareça na lista de processos. No macOS / Ubuntu, o script autentica sudo
previamente, de modo que haja uma única solicitação claramente identificada.

<a id="42010605-002d"></a>

<a id="always-run-the-orphan-file-sweep----even-if-some-vms-survived-the-registry-removal-step-their-on-di"></a>

### Sempre execute a limpeza de arquivos órfãos — mesmo que algumas VMs sobrevivam à remoção do registro. Seus arquivos em disco

`yuruna/test/Remove-TestVMFiles.ps1`

Sempre execute a limpeza de arquivos órfãos — mesmo que algumas VMs sobrevivam
à remoção do registro. Seus arquivos em disco continuam associados ao registro
que sobreviveu, portanto o script de órfãos os ignora; mas arquivos remanescentes
de falhas anteriores (o sintoma real em hospedeiros de longa duração) são
recuperados. A linha "Running orphaned VM file cleanup: <path>" permanece em
Write-Output (incondicional), para que um chamador automatizado com -Quiet ainda
veja uma linha comprovando a tentativa de limpeza; -Quiet é propagado, de modo
que Remove-OrphanedVMFiles não produza mensagens adicionais.

<a id="42010605-002e"></a>

<a id="release-the-per-cycle-display-surface-this-host-attaches-for-screen-capture-the-hyper-v-usbmmidd-vi"></a>

### Libere a superfície de exibição por ciclo anexada pelo hospedeiro para capturas de tela (a tela virtual usbmmidd do Hyper-V

`yuruna/test/Remove-TestVMFiles.ps1`

Libere a superfície de exibição por ciclo que este hospedeiro anexa para capturas
de tela (a tela virtual usbmmidd do Hyper-V). O caminho de início do ciclo a anexa
por Initialize-HostDisplay; removê-la aqui limpa um monitor antigo/duplicado
deixado por uma troca de KVM no meio do ciclo, para que não permaneça quando a
máquina parar de executar testes. O despachante não faz nada em hospedeiros que
não anexam uma tela (macOS/Linux) e nunca lança uma exceção.

<a id="42010605-002f"></a>

<a id="track-every-vm-we-attempted-with-a-final-disposition-per-vm-ops-must-not-abort-the-whole-loop-on"></a>

### Registre cada VM sobre a qual houve uma tentativa, com a disposição final. Operações por VM NÃO DEVEM interromper todo o laço: em

`yuruna/test/Remove-TestVMFiles.ps1`

Registre cada VM sobre a qual houve uma tentativa, com a disposição final.
Operações por VM NÃO DEVEM interromper todo o laço: em um hospedeiro de longa
duração, uma única VM presa (.vhdx bloqueado, vmms travado, auxiliar do UTM
mantendo um identificador de arquivo) poderia lançar uma exceção sob
$ErrorActionPreference='Stop' e ignorar todas as VMs correspondentes seguintes,
acumulando sobreviventes ciclo após ciclo. Cada VM é envolvida em try/catch com
seu próprio caminho de continuação após falha; as sobreviventes são relatadas no
fim, e a limpeza de arquivos órfãos continua para recuperar espaço em disco
mesmo quando uma VM resiste à exclusão.

<a id="42010605-0030"></a>

<a id="resolve-prefix-explicit--prefix-wins-then-testconfigymls-vmstartcleanupvmnameprefixes-then-v"></a>

### Resolva $Prefix: -Prefix explícito tem precedência, depois vmStart.cleanupVmNamePrefixes de test.config.yml, depois v

`yuruna/test/Remove-TestVMFiles.ps1`

Resolva $Prefix: -Prefix explícito tem precedência, depois
vmStart.cleanupVmNamePrefixes de test.config.yml, depois vmStart.testVmNamePrefix
e finalmente o padrão "test-". Ler a configuração importa quando o operador
executa este script diretamente após parar o executor — o executor passa -Prefix
da mesma configuração; uma chamada manual que usasse "test-" deixaria VMs de
fora sempre que o operador tivesse personalizado os prefixos.

<a id="42010605-0031"></a>

<a id="eternal-loop"></a>

### Laço contínuo

`yuruna/test/Start-TestRunner.ps1`

O corpo do ciclo fica em Test.RunnerOuterLoop.psm1, permitindo testes unitários
sem iniciar um pwsh interno real. A hashtable State transporta tudo de que o
laço precisa (caminhos, parâmetros ajustáveis, referência ShutdownState, argv do
operador de chamada), para que a função não leia implicitamente variáveis do
escopo do chamador. ShutdownState é compartilhado por referência com o manipulador
de Ctrl+C acima; alterar ['Requested'] lá encerra o laço aqui.

<a id="42010605-0032"></a>

<a id="pre-flight-elevation-2"></a>

### Checagem prévia: elevação

`yuruna/test/Start-TestRunner.ps1`

Resolva a elevação UMA VEZ, aqui, enquanto o operador ainda estiver no console —
o único momento em que pode responder com uma senha. Cada ciclo posterior executa
em um pwsh novo, sem um timestamp sudo válido, e o executor interno herda este
terminal; portanto, uma solicitação no meio do ciclo deixaria o hospedeiro
parado com o painel ainda verde. Assert-RunnerElevation só retorna $false depois
de imprimir os comandos exatos de /etc/sudoers.d a executar; recusar iniciar é o
resultado correto, pois um hospedeiro que exige uma senha digitada precisa de
intervenção local, assim como um hospedeiro com rede quebrada. Não faz nada no
Windows/macOS nem quando um drop-in já cobre a necessidade; nesse caso, nada
é impresso nem solicitado. A proteção por Get-Command permite que um executor
cujo clone do framework seja anterior ao módulo use o comportamento anterior,
em vez de falhar ao iniciar.

<a id="42010605-0033"></a>

<a id="helpers"></a>

### Auxiliares

`yuruna/test/Start-TestRunner.ps1`

Os auxiliares git / config / watchdog / Sync-ForwardEnv / Write-OuterLog ficam
em módulos irmãos, para que o ponto de entrada permaneça pequeno e o watchdog de
heartbeat e o despachante de ciclos possam ser testados independentemente deste
arquivo. Veja modules/Test.RunnerWatchdog.psm1, modules/Test.RunnerOuterLoop.psm1
e modules/Test.OuterLog.psm1; os três foram carregados com -Global -Force por
Initialize-YurunaEntryPointModuleSet -For Outer acima.

<a id="42010605-0034"></a>

<a id="every-switch-here-forwards--noconfiggate-included-the-inner-gates-each-cycle-it-runs-so-an-operat"></a>

### Todos os switches aqui são encaminhados, inclusive -NoConfigGate: o executor interno verifica cada ciclo; assim, um operador

`yuruna/test/Start-TestRunner.ps1`

Todos os switches aqui são encaminhados, inclusive -NoConfigGate: o executor
interno verifica cada ciclo que executa; caso contrário, um operador que ignorou
a verificação inicial durante uma edição seria parado pela mesma verificação
uma camada abaixo, justamente na execução em que pediu para ignorá-la.
Os parâmetros do transporte de atualização pertencem a este script e nunca chegam
ao executor interno, cuja vinculação estrita os recusaria.

<a id="42010605-0035"></a>

<a id="ctrlc-handler-1"></a>

### Manipulador de Ctrl+C

`yuruna/test/Start-TestRunner.ps1`

O registro compartilhado fica em Test.Prelude (Register-EntryPointCancelHandler):
uma assinatura Register-ObjectEvent CancelKeyPress altera o sinalizador 'Requested'
da hashtable retornada na thread do pipeline (um delegate .NET direto seria
acionado em uma thread do pool sem Runspace). Durante um ciclo iniciado em outro
processo, o executor externo consulta $script:ShutdownState['Requested'] entre
esperas de um segundo pelo processo filho e interrompe toda a árvore de processos
do ciclo quando há uma solicitação de cancelamento. O laço contínuo e o laço de
pausa por falha também consultam o sinalizador antes de continuar.

<a id="42010605-0036"></a>

<a id="sync-forwardenv-lives-in-testrunnerouterloop-and-write-outerlo"></a>

### Sync-ForwardEnv fica em [Test.RunnerOuterLoop](../../test/modules/Test.RunnerOuterLoop.psm1) e Write-OuterLo

`yuruna/test/Start-TestRunner.ps1`

Sync-ForwardEnv fica em [Test.RunnerOuterLoop](../../test/modules/Test.RunnerOuterLoop.psm1)
e Write-OuterLog em [Test.OuterLog](../../test/modules/Test.OuterLog.psm1), que o laço
externo reexporta; assim, o corpo do laço e o script de entrada usam as mesmas
implementações. Sync-ForwardEnv recebe o snapshot como parâmetro (sem leitura do
escopo de script); Write-OuterLog lê YURUNA_RUNTIME_DIR do ambiente no momento
da chamada (resolvido por Initialize-YurunaRuntimeDir acima).

<a id="42010605-0037"></a>

<a id="host-refresh-gate-at-startup"></a>

### Verificação de atualização do hospedeiro na inicialização

`yuruna/test/Start-TestRunner.ps1`

Uma inicialização normal é recusada enquanto uma atualização do hospedeiro mantém
seu executor retido: haveria concorrência com o reparo, e o próprio reparo reinicia
o executor ao terminar. Uma inicialização retomada (iniciada pelo worker de
atualização) deve apresentar um token de transferência válido para este runtime;
um token recusado grava a confirmação de falha que o worker aguarda, quando a
verificação ainda mantém esse token.

<a id="42010605-0038"></a>

<a id="auto-relaunch-under-sg-libvirt--c--on-hostubuntukvm-when-this-shells-running-supplementary"></a>

### Reinicialização automática sob `sg libvirt -c "..."` em host.ubuntu.kvm quando os grupos suplementares deste shell

`yuruna/test/Start-TestRunner.ps1`

Reinicie automaticamente sob `sg libvirt -c "..."` em host.ubuntu.kvm quando o
conjunto de grupos suplementares em execução deste shell não incluir libvirt.
Isso ocorre ANTES de iniciar qualquer pwsh interno — ele herda os grupos do
executor externo; corrigir aqui permite que cada chamada virt-install / virsh
no executor interno acesse /var/run/libvirt/libvirt-sock corretamente.
Não faz nada no macOS/Windows nem em shells que já tenham libvirt no conjunto
efetivo. Veja Invoke-LibvirtGroupReExecIfNeeded para a justificativa completa
(sg + initgroups, por que $env: vazaria etc.).

<a id="42010605-0039"></a>

<a id="publish-the-resolved-config-path-so-every-cross-module-reload-site-sync-runtimeconfig-in-the-inner"></a>

### Publique o caminho resolvido da configuração para que todo ponto de recarga entre módulos (Sync-RuntimeConfig no executor interno

`yuruna/test/Start-TestRunner.ps1`

Publique o caminho resolvido da configuração para que todo ponto de recarga entre
módulos (Sync-RuntimeConfig no executor interno, Update-TransportDefault em
Test.Transport e futuros chamadores semelhantes) leia o MESMO arquivo quando o
operador passar -ConfigPath <elsewhere>. Sem isso, Test.Transport usa como
alternativa o template da árvore, e as edições de vmCommunication.* feitas pelo
operador no painel nunca têm efeito.

<a id="42010605-003a"></a>

<a id="resilient-outer-runner"></a>

### Executor externo resiliente

`yuruna/test/Start-TestRunner.ps1`

O caminho normal usa um executor externo residente (este arquivo), um novo
worker por ciclo (modules/Invoke-TestCycleRunner.ps1) e o executor interno
(modules/Invoke-TestRunnerInnerLoop.ps1). O worker executa a orquestração do
ciclo e invoca o executor interno; o externo mantém o estado entre os ciclos.
Se o script do worker de ciclo estiver ausente, o externo executa a orquestração
do ciclo em seu próprio processo como alternativa.
Motivos da separação:
  * pwsh novo a cada ciclo em todo hospedeiro — a lógica do ciclo e seus módulos
    são recarregados sem reiniciar o executor externo residente
  * memória residente O(1); o externo é o único processo mantido entre os ciclos
    e espera pelo worker de ciclo em intervalos de um segundo
  * espera progressiva com consulta de commits impede consumo contínuo
    por falhas infinitas

Veja test/README.md para o fluxo do ciclo, a configuração, as notificações e a
opção YURUNA_CACHING_PROXY_SERVICE_IP; veja docs/test-harness.md para a arquitetura
do ambiente de testes.

<a id="42010605-003b"></a>

<a id="optional-promote-to-machine-wide-host-proxy"></a>

### Opcional: promova a proxy do hospedeiro para toda a máquina

`yuruna/test/Test-CachingProxyService.ps1`

Só executa quando todas as verificações de nível FAIL passam — o nível WARN
(ausência de :80 / certificado da CA) é compatível com um proxy HTTP funcional;
por isso não impede a promoção.

Limpeza automática antes da promoção: Remove-HostProxy limpa incondicionalmente
qualquer string WinINet ProxyServer remanescente e as variáveis de ambiente
HTTP_PROXY/HTTPS_PROXY/NO_PROXY ANTES de Set-HostProxy gravar as novas.
A alternativa de snapshot e restauração preserva o estado de proxy do hospedeiro
na PRIMEIRA execução de Set-HostProxy — se o hospedeiro já tinha uma variável
HTTP_PROXY (preexistente ou de um ciclo antigo), Stop-CachingProxyServiceVM a
restaura fielmente, propagando um IP antigo para toda verificação posterior de
Test-CachingProxyService. Limpar primeiro garante uma base limpa para cada
promoção; Stop-CachingProxyServiceVM também limpa definitivamente em vez de
restaurar. Não exige uma ação do usuário com -ClearHostProxy.

<a id="42010605-003c"></a>

<a id="effective-proxy-for-outbound-calls"></a>

### Proxy efetivo para chamadas de saída

`yuruna/test/Test-CachingProxyService.ps1`

Leia as variáveis de ambiente do processo DIRETAMENTE, em vez de consultar
[System.Net.WebRequest]::DefaultWebProxy.GetProxy(). DefaultWebProxy é um singleton
por AppDomain — HttpEnvironmentProxy é construído a partir das variáveis de
ambiente na PRIMEIRA chamada HTTP do .NET e então mantido em cache pela vida do
processo, sem caminho de atualização. Assim, depois que Test-CachingProxyService.ps1
(ou um script anterior no mesmo pwsh) usa HTTP do .NET, o singleton fica preso
ao valor de HTTP_PROXY daquele momento, mesmo após Set-WindowsHostProxy atualizar
$env:HTTP_PROXY na mesma sessão. Por isso, duas execuções consecutivas de
-SetHostProxy em um pwsh continuavam avisando apesar de o estado subjacente
estar correto.

Ler as variáveis de ambiente diretamente reflete o que NOVOS processos filhos
herdarão (Start-TestRunner inicia um pwsh novo a cada ciclo no Windows;
o filho recebe o bloco de ambiente do processo pai no momento da criação e
constrói seu próprio DefaultWebProxy com ESSES valores). $env: acessa o bloco
de ambiente ativo do processo a cada leitura.

<a id="42010605-003d"></a>

<a id="host-system-proxy-check"></a>

### Verificação do proxy de sistema do hospedeiro

`yuruna/test/Test-CachingProxyService.ps1`

Um proxy de sistema antigo (por exemplo, uma promoção anterior com -SetHostProxy
para um IP que mudou) redireciona silenciosamente todo Invoke-WebRequest / curl
em Start-TestRunner. No macOS, o .NET lê networksetup; no Windows, lê WinINet por
usuário (gravado pelo Set-WindowsHostProxy do driver) e WinHTTP para toda a máquina.
As variáveis de ambiente só são consultadas como alternativa; por isso, exibir
apenas essas variáveis não revela uma configuração de sistema antiga.

<a id="42010605-003e"></a>

<a id="port-probes--ca-cert-fetch"></a>

### Verificações de portas e obtenção do certificado da CA

`yuruna/test/Test-CachingProxyService.ps1`

Compartilhado com a verificação de início de ciclo em Invoke-TestRunnerInnerLoop.ps1
por Invoke-CachingProxyServiceProbe em Test.CachingProxyService.psm1 — ambos os
chamadores veem a mesma classificação PASS/WARN/FAIL:
  :3128 / :3129 / :3000 — FAIL quando inacessíveis (requisitos obrigatórios)
  :80, certificado da CA — WARN (cache HTTPS desativado nos convidados,
                           mas HTTP ainda funciona)
Linhas e contadores são incorporados novamente ao estado $script:* deste script,
para que a linha Summary e o código de saída correspondam à classificação
PASS/WARN/FAIL da verificação inicial do ciclo (fonte única de verdade em
Invoke-CachingProxyServiceProbe).

<a id="42010605-003f"></a>

<a id="-sethostproxy-ends-this-script-with-remove-hostproxy-then-set-hostproxy-both-of-which-reach-invoke-"></a>

### -SetHostProxy encerra este script com Remove-HostProxy e depois Set-HostProxy; ambos chegam a Invoke-

`yuruna/test/Test-CachingProxyService.ps1`

-SetHostProxy encerra este script com Remove-HostProxy e depois Set-HostProxy;
ambos chegam a Invoke-MacElevationIfNeeded e solicitam uma senha — depois que as
verificações de portas e a obtenção da CA já consumiram um minuto ou mais.
O requisito é conhecido apenas pela vinculação de parâmetros; portanto,
apresente-o aqui. É idempotente e silencioso quando já é root (sudo -E),
quando o timestamp sudo ainda é válido ou no Windows, onde Set-HostProxy grava
WinINet por usuário e não precisa de elevação. Uma execução sem -SetHostProxy
é uma verificação somente de leitura e nunca solicita uma senha.

<a id="42010605-0040"></a>

<a id="resolve-the-cache-ip"></a>

### Resolva o IP do cache

`yuruna/test/Test-CachingProxyService.ps1`

A prioridade segue a resolução de início de ciclo de Start-TestRunner:
  parâmetro -CacheIp                  (substituição explícita, só neste script)
  vmStart.cachingProxyIp              (test/test.config.yml, verificado primeiro)
  $Env:YURUNA_CACHING_PROXY_SERVICE_IP (verificado se a configuração estiver ausente/inacessível)
  descoberta local por Test-CachingProxyServiceAvailable
Os caminhos de configuração e ambiente passam por Resolve-CachingProxyServiceEndpoint
— o MESMO resolvedor de Invoke-TestRunnerInnerLoop.ps1 e Debug-TestSequence.ps1 —,
para que a política de aceitação (primeira origem cuja porta HTTP do proxy
responda) não se desvie da política do executor. Duas diferenças são deliberadas:
este diagnóstico nunca publica o vencedor em $env:YURUNA_CACHING_PROXY_SERVICE_IP
(verificação somente de leitura, sem alteração da sessão), e uma origem recusada
é apresentada como WARN antes de recorrer à descoberta local, exatamente como
o executor faria.

<a id="42010605-0041"></a>

<a id="canonical-path-bundle--cachingproxyservice-module-kind-loads-the-trio-testvmutility-testcachin"></a>

<a id="conjunto-canônico-de-caminhos-e-tipo-de-módulo-cachingproxyservice-carrega-o-trio-testvmutility-testcachin"></a>

<a id="canonical-path-bundle-and-caching-proxy-service-module-imports"></a>

### Conjunto canônico de caminhos e importações dos módulos do caching-proxy-service

`yuruna/test/Test-CachingProxyService.ps1`

Conjunto canônico de caminhos e tipo de módulo CachingProxyService. Carrega o
trio (Test.VMUtility, Test.CachingProxyService, Test.HostContract) compartilhado
pelos quatro scripts de caching-proxy-service:
  * Test.VMUtility — Get-CachingProxyServicePort / Test-IpAddress, usados pelo
    bloco de verificação de portas abaixo e pelos ramos de variável de ambiente /
    -CacheIp que não passam pelas importações transitivas de
    Test-CachingProxyServiceAvailable.
  * Test.CachingProxyService — Invoke-CachingProxyServiceProbe (compartilhado com
    a verificação de início de ciclo em Invoke-TestRunnerInnerLoop.ps1).
  * Test.HostContract — Invoke-LibvirtGroupReExecIfNeeded + Initialize-YurunaHost.

<a id="42010605-0042"></a>

<a id="summary"></a>

### Resumo

`yuruna/test/Test-Config.ps1`

Exit-WithSummary imprime a contagem PASS/WARN/FAIL E o bloco FAILURES repetido
(a mensagem de cada Write-Fail e seu caminho completo, agrupados por seção).
A centralização garante que todo ponto anterior de saída antecipada (arquivo de
configuração ausente, erro de análise YAML, falha de verificação de rede,
interrupção antes das verificações de rede) termine no mesmo formato — o operador
nunca precisa rolar para cima para encontrar o que falhou.

<a id="42010605-0043"></a>

<a id="-bootstrap-not-the-gates-default-the-default-is-deliberately-wider----every-file-type-that-is-asc"></a>

### -Bootstrap em vez do padrão da verificação. O padrão é deliberadamente mais amplo — todo tipo de arquivo que é ASCII

`yuruna/test/Test-Config.ps1`

-Bootstrap em vez do padrão da verificação. O padrão é deliberadamente mais amplo
— todo tipo de arquivo que deve ser ASCII pela política —, pois um desenvolvedor
ou uma verificação de merge precisa detectar desvios onde quer que apareçam.
Esta chamada é diferente: decide se um executor pode INICIAR; por isso, seu escopo
permanece no conjunto em que um byte inesperado realmente quebra a primeira
instalação em um hospedeiro novo. Ampliá-lo aqui permitiria que um caractere em
qualquer folha de estilo ou arquivo YAML parasse todos os executores do grupo,
um impacto que o defeito não justifica.

<a id="42010605-0044"></a>

<a id="section-13-bootstrap-script-encoding-ascii-no-bom"></a>

### Seção 13: codificação dos scripts de bootstrap (ASCII, sem BOM)

`yuruna/test/Test-Config.ps1`

O instalador PS 5.1 `irm | iex` e os scripts guest/windows.11 que o convidado
Windows novo executa da mesma forma são analisados byte a byte antes que exista
qualquer shell tolerante a BOM; portanto, um BOM UTF-8 ou um byte não ASCII os
interrompe na linha 1. Incorpore a proteção compartilhada Test-AsciiNoBom a esta
verificação anterior ao ciclo, para que uma recodificação acidental bloqueie o
ciclo aqui, em vez de quebrar a primeira instalação no convidado.
Veja feedback_bootstrap_installer_no_bom.md.

<a id="42010605-0045"></a>

<a id="section-9d-pool-configuration-sync"></a>

### Seção 9d: grupo (sincronização de configuração)

`yuruna/test/Test-Config.ps1`

Valide a obtenção opcional de configuração do grupo quando configurada: enabled exige
configurationGitUrl não vazio, e o repositório de configuração na LAN responde a um git
ls-remote com limite. A acessibilidade é WARN (o executor passa a operar com um
único hospedeiro quando o repositório está fora do ar), para que um proxy
momentaneamente offline nunca bloqueie um ciclo saudável. O CONTEÚDO do
repositório de configuração (estrutura de pools.yml) é validado por Test-PoolConfiguration.ps1;
esta verificação cobre apenas o bloco LOCAL da configuração e a acessibilidade.

<a id="42010605-0046"></a>

<a id="probe-from-here-too-the-pool-answering-for-an-address-only-says-the-aggregator-can-reach-it-and-th"></a>

### Verifique também DAQUI: a resposta do grupo para um endereço só informa que o agregador o alcança, e este

`yuruna/test/Test-Config.ps1`

Verifique também DAQUI: a resposta do grupo para um endereço só informa que o
agregador o alcança, e este hospedeiro é quem precisa alcançá-lo. 'host' é o
endereço simples já extraído pelo agregador; uma versão antiga que não o envia
deixa a URL para ser analisada aqui, e um valor que não possa ser analisado
é ignorado, em vez de lançar uma exceção para fora da seção.

<a id="42010605-0047"></a>

<a id="section-9c2-extension-services-registered-with-the-pool"></a>

### Seção 9c2: serviços de extensão registrados no grupo

`yuruna/test/Test-Config.ps1`

As verificações de armazenamento do stash acima comprovam que este hospedeiro
poderia CONSTRUIR um stash service. Esta faz a pergunta oposta, da qual um ciclo
realmente depende: para qual stash service este hospedeiro será encaminhado,
e ele responde?

Um ciclo resolve esse endereço pelo grupo; assim, um registro inacessível para
o ciclo no aquecimento — depois de a verificação de configuração informar que
estava tudo bem. Dois hospedeiros anunciando a mesma área é normal (cada um pode
executar a própria); um endereço anunciado ao qual nada responde não é, e fica
invisível para este hospedeiro até o momento em que um ciclo precise dele.

Toda esta seção é consultiva. Esta verificação recusa INICIAR o laço do executor
em um FAIL; portanto, um serviço fora do ar em outra máquina travaria um
laboratório que poderia continuar executando ciclos e se recuperar. Além disso,
a necessidade de stash cabe ao projeto, não ao framework. O objetivo é dar
visibilidade: o operador lê isso antes que um ciclo gaste seu orçamento
descobrindo a mesma coisa.

<a id="42010605-0048"></a>

<a id="active-write-path-pre-flight-the-stash-share-is-configured-as-a-subfolder-servershareyurunas"></a>

### Checagem prévia ATIVA de escrita: o compartilhamento do stash é uma SUBPASTA ('\\server\share\yuruna.s

`yuruna/test/Test-Config.ps1`

Checagem prévia ATIVA de escrita: o compartilhamento do stash é configurado como
uma SUBPASTA ('\\server\share\yuruna.stash'); New-SmbMapping para uma subpasta
inexistente falha com o vago "network name cannot be found". Portanto, garanta
que a pasta de destino exista (crie-a pelo compartilhamento pai se faltar) e
verifique sua montagem real. Tudo é consultivo — o stash é opcional e
Start-StashServiceVM falha obrigatoriamente na construção —, mas isso detecta o
caso "NAS acessível, credencial armazenada, porém a montagem ainda falha porque
a pasta nunca foi criada", invisível às verificações passivas acima.
Só se tenta quando há uma credencial armazenada E o servidor respondeu; assim,
um NAS apenas offline permanece como WARN acima.

<a id="42010605-0049"></a>

<a id="free-space-checked-only-behind-a-succeeded-pre-flight-on-linuxmacos-df-against-an-existing-but-"></a>

### Espaço livre, verificado APENAS após uma checagem prévia bem-sucedida. No Linux/macOS, `df` em um localPath existente, mas

`yuruna/test/Test-Config.ps1`

Espaço livre, verificado APENAS após uma checagem prévia bem-sucedida.
No Linux/macOS, `df` em um localPath existente, mas não montado, tem sucesso e
informa o sistema de arquivos PAI; executá-lo em qualquer caminho cuja montagem
foi ignorada ou falhou mediria o disco local e aprovaria ou reprovaria a
verificação usando um número inteiramente errado.

<a id="42010605-004a"></a>

<a id="active-write-path-pre-flight-actually-mount-localpath-and-create-the-per-host-folder-"></a>

### Checagem prévia ATIVA de escrita: monte localPath e crie a pasta de cada hospedeiro '<localPath>/<

`yuruna/test/Test-Config.ps1`

Checagem prévia ATIVA de escrita: monte localPath e crie a pasta de cada hospedeiro
'<localPath>/hosts/<hostId>'. É a verificação que detecta o caso "NAS acessível,
caminhos configurados, mas a replicação silenciosamente nunca ocorre" — senha SMB
errada, erro no nome do compartilhamento, sudo sem senha ausente no Linux ou
compartilhamento somente de leitura —, invisível à verificação passiva de
acessibilidade acima (a drenagem no hospedeiro executa separada e apenas registra
a falha no ledger, onde nenhum operador a vê). Só se tenta quando há uma
credencial configurada E o servidor está acessível; assim, um NAS apenas offline
permanece como o WARN transitório acima. FAIL (bloqueia o ciclo) quando moveLogsToPoolStorage
está ativado; WARN consultivo quando está desativado.

<a id="42010605-004b"></a>

<a id="mount8-execs-the-external-mountcifs-helper-from-cifs-utils-which-nothing-else-in-the-harness-pul"></a>

### mount(8) executa o auxiliar externo mount.cifs de cifs-utils, que nenhuma outra parte do ambiente de testes instala

`yuruna/test/Test-Config.ps1`

mount(8) executa o auxiliar externo mount.cifs de cifs-utils, que nenhuma outra
parte do ambiente de testes instala. Garanta sua presença ANTES da checagem prévia ativa:
sem ele, toda montagem falha com o mesmo código de saída de uma rejeição de
credencial; informar o pacote ausente é, portanto, o diagnóstico correto e o
único que permite uma ação. A tentativa de montagem destinada a falhar é então
ignorada, em vez de gerar um segundo diagnóstico da mesma causa.

<a id="42010605-004c"></a>

<a id="an-absent-or-unpopulated-pool-tier-is-only-optional-to-someone-who-never-asked-for-shared-storage"></a>

### Uma camada de grupo ausente ou não preenchida só é "opcional" para quem nunca solicitou armazenamento compartilhado

`yuruna/test/Test-Config.ps1`

Uma camada de grupo ausente ou não preenchida só é "opcional" para quem nunca
solicitou armazenamento compartilhado. -ExpectStorageConfigured indica que o
chamador acabou de tentar preparar o armazenamento; nesse caso, a mesma ausência
comprova que nada foi instalado — o script de compartilhamentos locais grava
essas três chaves ao construí-los, e uma montagem NAS se recusa a iniciar sem
elas. Portanto, uma execução que chegue aqui sem as chaves não tem armazenamento
algum, embora todas as etapas seguintes se comportem como se tivesse.

<a id="42010605-004d"></a>

<a id="section-9c-networkstorage-pool-ypool-nas-archiving"></a>

### Seção 9c: arquivamento no grupo networkStorage (ypool-nas)

`yuruna/test/Test-Config.ps1`

Valide a camada opcional de arquivamento NAS: os três caminhos definidos, uma
credencial utilizável no vault (para que a montagem não gere automaticamente uma
senha SMB inútil), a resposta do servidor SMB em :445 e — quando ambos passam —
uma montagem ATIVA de localPath e a criação da pasta de cada hospedeiro
'<localPath>/hosts/<hostId>', seguidas do espaço livre necessário ao próximo ciclo
dessa pasta. A etapa ativa comprova que o arquivamento funcionará (credenciais,
nome do compartilhamento, sudo do Linux, permissão de escrita), em vez de falhar
silenciosamente depois; no modo MOVE, uma falha produz FAIL (parando o ciclo),
pois a cópia local está prestes a ser excluída, enquanto no modo de cópia ela é
consultiva. A verificação de acessibilidade permanece WARN em ambos os casos;
assim, um NAS apenas offline — que o laço tenta novamente a cada ciclo — nunca
bloqueia uma execução saudável.

A verificação de espaço só ocorre após uma montagem bem-sucedida: no Linux/macOS,
`df` em um localPath existente, mas não montado, tem sucesso e informa o sistema
de arquivos PAI; verificar qualquer outro caminho avaliaria o compartilhamento
pelo espaço livre do disco local.

<a id="42010605-004e"></a>

### Show-NetworkStorageFieldSwapWarning

`yuruna/test/Test-Config.ps1`

Uma letra de unidade simples (por exemplo, 'z:') é um valor de localPath, nunca
um nome de usuário SMB válido — encontrá-la em <prefix>NetworkUser significa que
<prefix>NetworkUser e <prefix>LocalPath foram trocados em test.config.yml.
A troca mantém o esquema válido (ambos são strings), portanto nada mais a aponta;
o único sintoma visível é o aviso enganoso "no stored vault credential"
associado à letra de unidade, enquanto a senha da conta real fica sem uso no vault.

<a id="42010605-004f"></a>

### Invoke-PoolStorageVaultCredentialOffer

`yuruna/test/Test-Config.ps1`

Apenas interativamente: colete a senha NAS ausente do grupo e armazene-a no vault,
para que um operador com o segredo disponível termine com uma credencial
funcional, em vez de uma falha que aponte para um documento e um segundo comando.
A senha é o único valor que o ambiente de testes nunca deve inventar — a conta SMB já
existe no NAS, portanto uma senha gerada automaticamente sempre é inútil e
rejeitada (cifs mount error(13)). Retorna $true APENAS quando uma credencial foi
armazenada; o chamador repete a checagem prévia somente de leitura, em vez de
confiar na gravação. Onde não é possível perguntar a ninguém — na verificação
anterior ao ciclo e no executor sem intervenção —, retorna $false imediatamente
e mantém as instruções impressas, que indicam o equivalente manual.

<a id="42010605-0050"></a>

### Invoke-LinuxSudoInstallOffer

`yuruna/test/Test-Config.ps1`

Apenas no Linux e interativamente: ofereça instalar agora o drop-in de sudo sem
senha necessário à montagem, solicitando sudo uma vez. Retorna $true APENAS quando
o drop-in foi realmente instalado (para que o chamador repita a montagem);
recusa, sessão em que não é possível perguntar a ninguém ou qualquer resultado
sem instalação retorna $false, e o chamador segue para Show-LinuxSudoHintOnce.
O executor sem intervenção nunca chega à oferta e não deve elevar a si próprio.

<a id="42010605-0051"></a>

<a id="linux-only-print-the-exact-one-time-passwordless-sudo-setup-the-mount-path-needs-resolved-to-this"></a>

### Apenas Linux: imprima a configuração EXATA e única de sudo sem senha exigida pela montagem (resolvida para esta

`yuruna/test/Test-Config.ps1`

Apenas Linux: imprima a configuração EXATA e única de sudo sem senha exigida pelo
caminho de montagem (resolvida para esta conta e caminhos de binários) na primeira
falha de uma checagem prévia na etapa de montagem. Uma vez por execução — os
compartilhamentos do grupo e do stash usam um drop-in comum. O EXECUTOR sem
intervenção não consegue aplicá-lo sozinho (`sudo -n` nunca solicita uma senha
e /etc/sudoers.d exige root); por isso, essa orientação é sua alternativa.
A um operador INTERATIVO, Invoke-LinuxSudoInstallOffer oferece a instalação diretamente.

<a id="42010605-0052"></a>

<a id="section-9b3-stale-smb-alias-mappings-windows"></a>

### Seção 9b3: mapeamentos antigos de aliases SMB (Windows)

`yuruna/test/Test-Config.ps1`

Um mapeamento persistente de unidade do Windows pode sobreviver ao alias do
arquivo hosts para o qual aponta: após a renomeação/remoção de um alias NAS,
o mapeamento ainda mostra Status OK pela conexão em cache, mas a sessão com
nome inexistente que mantém BLOQUEIA uma nova montagem do mesmo NAS físico sob
um alias atual (o redirecionador recusa uma segunda sessão com credenciais para
um servidor ao qual já mantém uma conexão antiga). Mapear dois aliases de UM
NAS para o MESMO IP é intencional e válido — um alias NÃO RESOLVÍVEL é o verdadeiro
bloqueio. Liste-os e, apenas com um operador ao teclado, ofereça desmontar cada
um, para que as montagens de grupo/stash abaixo não sejam impedidas antes de
começar. Execuções sem interface nunca perguntam: WARN consultivo e o reparo
manual em uma linha.

<a id="42010605-0053"></a>

<a id="section-9b2-sequence-files-parse--snippet-expansion"></a>

### Seção 9b2: arquivos de sequência (análise e expansão de snippets)

`yuruna/test/Test-Config.ps1`

Leia toda sequência no framework E no projeto padrão de teste pelo mesmo
carregador usado pelo executor (Read-SequenceFile, que insere referências
`snippet:` das bibliotecas _snippets.yml). Um erro YAML, nome de snippet
desconhecido ou duplicado, ou ciclo de snippets produz FAIL aqui — antes do
início de um ciclo —, em vez de descartar etapas ou interromper no meio do
convidado. A estrutura das bibliotecas de snippets também é verificada diretamente,
para que uma biblioteca quebrada, mas não referenciada, não fique oculta até o primeiro uso.

<a id="42010605-0054"></a>

<a id="strict-mode-completeness-every-logical-username-referenced-by-an-active-sequence-must-be-declared"></a>

### Completude no modo estrito: todo nome lógico de usuário referenciado por uma sequência ativa deve estar declarado.

`yuruna/test/Test-Config.ps1`

Completude no modo estrito: todo nome lógico de usuário referenciado por uma
sequência ativa deve estar declarado. Examine sequências do framework em
test/sequences/ E sequências da árvore do projeto, que a estrutura plana mantém
diretamente em qualquer diretório chamado 'test' sob <repoRoot>/project/
(por exemplo, `project/example/website/test/*.yml`) — a mesma estrutura percorrida
por Get-ProjectFlatTestSearchDir no runtime, reproduzida aqui para que Test-Config
permaneça independente e não precise importar o módulo do mecanismo de sequências.

<a id="42010605-0055"></a>

<a id="githubcom-answered-and-it-rejected-the-credential----so-the-url-is-very-likely-fine-and-the-generi"></a>

### github.com respondeu e rejeitou a credencial — portanto, a URL provavelmente está correta e as causas genéricas

`yuruna/test/Test-Config.ps1`

github.com respondeu e rejeitou a credencial — portanto, a URL provavelmente
está correta, e as causas genéricas abaixo levariam a uma investigação errada.
Informe isso e inclua a solução DENTRO de FAIL: a verificação anterior ao ciclo
reexibe apenas o bloco FAILURES no console; qualquer coisa escrita fora dele
nunca chega ao operador que examina um ciclo recusado.

<a id="42010605-0056"></a>

<a id="no-git----could-be-the-in-tree-project-layout-files-committed-to-the-framework-repo-or-the-post-f"></a>

<a id="ausência-de-git--pode-ser-o-projeto-dentro-da-árvore-arquivos-versionados-no-repositório-do-framework-ou-o-pós-f"></a>

<a id="missing-git-in-tree-project-layout-or-emptydamaged-project-directory"></a>

### Ausência de .git: projeto dentro da árvore ou diretório de projeto vazio/danificado

`yuruna/test/Test-Config.ps1`

Ausência de .git — pode ser o projeto dentro da árvore (arquivos versionados no
repositório do framework) OU um diretório de projeto vazio ou danificado.
Update-ProjectClone agora clona ao lado do checkout anterior e verifica a
substituição; assim, um clone malsucedido mantém o checkout anterior.
Quando nenhum arquivo compactado pode ser servido, o status server responde 404
a /yuruna-project-archive.tar.gz, e os convidados recorrem ao próprio clone,
que pode falhar pelo mesmo problema de acesso ao repositório.

<a id="42010605-0057"></a>

<a id="section-5d-storage-filter-stack-guest-throughput"></a>

### Seção 5d: pilha de filtros de armazenamento (vazão do convidado)

`yuruna/test/Test-Config.ps1`

Uma instalação de convidado realiza dezenas de milhares de pequenas escritas,
cada uma seguida de um flush, e todas passam pelo que o hospedeiro tiver anexado
ao volume que contém o VHDX. Esse custo é invisível dentro do convidado e nos
próprios logs do ambiente de testes: o que aparece é uma etapa de pacote demorada e um
orçamento de etapa esgotado, ambos identificando o convidado. Aumentar o orçamento
trata então o sintoma na máquina errada.

É relatado, nunca imposto, e relatado mesmo quando está correto. O hospedeiro do
laboratório também costuma ser a estação de trabalho de alguém; assim, um scanner
nesse volume é uma configuração legítima, não um defeito — mas deve ser conhecido,
pois altera silenciosamente todas as durações registradas pelo ambiente de testes e todos
os orçamentos derivados delas.

É específico do Windows por natureza: minifiltros do sistema de arquivos e cópias
de sombra de volume são recursos do Windows, e o qcow2 de um hospedeiro KVM ou UTM
não tem nada equivalente no caminho.

<a id="42010605-0058"></a>

<a id="section-5c-display-scaling-ocr"></a>

### Seção 5c: escala de exibição (OCR)

`yuruna/test/Test-Config.ps1`

Um desktop do hospedeiro com escala acima de 100% compõe a janela do console da
VM por um compositor escalado; assim, os glifos enviados ao OCR por uma captura
de janela chegam reamostrados, em vez de na resolução nativa. Nada gera erro
quando isso afeta a execução: a etapa gasta todo o timeoutSeconds e informa
'pattern not found', enquanto o frame salvo parece perfeitamente legível a uma
pessoa — a forma mais cara de descobrir o problema.

O escopo é definido por família de hospedeiro porque a exposição não é uniforme.
O laço de espera do OCR lê diretamente o framebuffer do convidado — WMI no
Hyper-V, VNC no UTM, virsh no KVM —, e a escala do hospedeiro não alcança nenhum
deles. Ela só afeta o OCR pelos caminhos de captura de janela: o laço tapOn,
que sempre solicita uma janela, e as alternativas usadas por cada família
quando a leitura do framebuffer falha. No KVM, não há esse caminho; portanto,
a resposta correta é que a configuração não se aplica, em vez de que foi aprovada.

WARN, nunca FAIL, e deliberadamente diferente da Seção 5a2 acima: nenhuma
asserção por ciclo recusa um ciclo por causa da escala; um relatório que o
reprovasse aqui inventaria uma verificação que o ambiente de testes não tem — e os operadores
deixam de executar um relatório de saúde que possa fazer uma execução falhar.

<a id="42010605-0059"></a>

<a id="apply-the-pin-rather-than-print-it-the-remedy-is-set-at-bridge-build-time-and-nobody-rebuilds-a-wor"></a>

### Aplique a fixação em vez de imprimi-la. A solução é definida na criação da ponte, e ninguém reconstrói uma ponte funcional

`yuruna/test/Test-Config.ps1`

Aplique a fixação em vez de imprimi-la. A solução é definida na criação da ponte,
e ninguém reconstrói uma ponte funcional; assim, um comando impresso só chega ao
operador que executa este relatório manualmente, enquanto esta verificação roda
em todo hospedeiro a cada início do executor, e sua transcrição é descartada
quando passa. É seguro sem intervenção porque a chamada grava o perfil
armazenado sem reativá-lo: o endereço em uso não muda e nenhuma conexão cai.
Só o backend NetworkManager é alterado; veja Set-HostBridgeDhcpIdentity para
entender por que netplan é apenas relatado.

<a id="42010605-005a"></a>

<a id="section-5b-host-address-stability"></a>

### Seção 5b: estabilidade do endereço do hospedeiro

`yuruna/test/Test-Config.ps1`

Um hospedeiro que obtém uma nova concessão a cada renovação consome endereços à
taxa definida pelo tempo de concessão, não pelo número de máquinas — por isso,
a mesma falha é suportável com uma concessão curta e esgota o conjunto de
endereços em poucos dias com uma longa. Os convidados privados de endereços
relatam "no IPv4 address", dando a impressão de uma falha própria. A verificação
combina o que o log de endereços observou com o que a ponte solicitou, porque
uma fixação ignorada pelo servidor DHCP parece funcionar pela configuração e
parece inexistente pelo log. É relatado, nunca fatal: quando isso executa, o
desvio já causou seu custo, e os operadores deixam de executar um relatório
de saúde que possa fazer uma execução falhar.

<a id="42010605-005b"></a>

<a id="section-5a3-utm-app-lifetime"></a>

### Seção 5a3: tempo de vida do aplicativo UTM

`yuruna/test/Test-Config.ps1`

Uma seção própria, em vez de um complemento aos diagnósticos de bloqueio de tela
acima: nenhuma dessas configurações é de tela nem precisa de sudo; colocá-las
sob um título sobre repouso da tela — ao lado de uma solução que avisa que
pedirá senha — leva o operador a procurar em System Settings um painel sem essa
opção. Elas são lidas de Get-MacUtmLifetimeIssue, também usado pela asserção por
ciclo; assim, o relatório e a verificação não podem descrever o mesmo hospedeiro
de formas diferentes.

FAIL, como em 5a2: cada linha retornada é uma condição que a verificação recusa
na inicialização.

<a id="42010605-005c"></a>

<a id="section-5a2-macos-screen-lock--display-sleep"></a>

### Seção 5a2: bloqueio de tela e repouso da tela no macOS

`yuruna/test/Test-Config.ps1`

Verificado aqui pelo mesmo motivo das permissões concedidas pelo operador acima:
este script É a verificação anterior ao ciclo, e a asserção por ciclo recusa um
ciclo exatamente por essas configurações. Um hospedeiro aprovado neste relatório
e depois parado pelo executor não ensina nada ao operador — ele encontra a
recusa um ponto de entrada depois, com o executor já esperando, em um aviso
que este relatório nunca mostrou.

Os diagnósticos vêm de Get-MacScreenLockIssue, também usado pela asserção por
ciclo; assim, o relatório e a verificação não podem descrever o mesmo hospedeiro
de formas diferentes. FAIL em vez de WARN: cada linha retornada é uma condição
que a verificação recusa ao iniciar um ciclo.

<a id="42010605-005d"></a>

<a id="section-5a-macos-permissions-only-a-person-can-give"></a>

### Seção 5a: permissões do macOS que apenas uma pessoa pode conceder

`yuruna/test/Test-Config.ps1`

Verificado AQUI, não apenas dentro do ciclo. Este script É a verificação anterior
ao ciclo; um hospedeiro que ele aprova e que Assert-HostConditionSet depois recusa
não recebeu informação útil da verificação: o operador descobre o problema um
ponto de entrada depois, com o executor já esperando, por uma mensagem que a
verificação nunca mostrou.

A detecção e todo o texto do reparo vêm do registro de permissões do operador
usado pela asserção por ciclo; assim, os dois não podem descrever a mesma
permissão de formas diferentes — a falha mais cara para um operador, pois seguir
um conjunto de instruções e ser recusado pelo outro não permite saber qual
está desatualizado.

Nenhuma dessas permissões pode ser concedida por um script, com ou sem senha:
o macOS as mantém em bancos TCC protegidos por SIP, e apenas um perfil PPPC
entregue por MDM pode pré-autorizá-las. A verificação faz o que resta — informa
a permissão exata, o painel exato e o aplicativo exato a habilitar.

<a id="42010605-005e"></a>

<a id="utm-installs-correctly-and-still-leaves-this-failing-the-cli-lives-inside-the-app-bundle-and-nothin"></a>

<a id="o-utm-é-instalado-corretamente-e-ainda-deixa-esta-falha-a-cli-fica-dentro-do-pacote-do-aplicativo-e-nada"></a>

<a id="utm-cli-in-the-app-bundle-is-not-automatically-on-path"></a>

### A CLI do UTM no pacote do aplicativo não entra automaticamente no PATH

`yuruna/test/Test-Config.ps1`

O UTM é instalado corretamente e ainda deixa esta falha: a CLI fica dentro do
pacote do aplicativo, e nada coloca esse diretório no PATH. Os dois reparos são
impressos porque não são intercambiáveis — o primeiro também aplica as demais
configurações do hospedeiro e exige sudo interativo; o segundo é uma linha que
o operador pode colar em uma sessão cujo timestamp sudo ainda seja válido.

<a id="42010605-005f"></a>

<a id="section-3c-host-setup-freshness"></a>

### Seção 3c: atualidade da configuração do hospedeiro

`yuruna/test/Test-Config.ps1`

As configurações aplicadas por Enable-TestAutomation sobrevivem a uma
reinicialização, mas não de forma confiável a uma atualização principal do SO:
os domínios de preferências de aplicativos são reconstruídos com os padrões,
e as permissões de privacidade são solicitadas novamente. O hospedeiro então
parece nunca ter sido configurado — várias opções aparentemente sem relação
desaparecem ao mesmo tempo, cada uma relatada em uma seção abaixo, sem identificar
o evento comum. Informar isso uma vez aqui, antes das seções que relatam as
consequências, faz o conjunto ser entendido como um problema com uma solução.

WARN, nunca FAIL: um hospedeiro atualizado cujas configurações sobreviveram
continua executando; as que não sobreviveram são recusadas pelos próprios critérios
abaixo. Uma segunda recusa pelo mesmo estado do hospedeiro só dificultaria
encontrar a primeira.

<a id="42010605-0060"></a>

### Invoke-HostClockSyncOffer

`yuruna/test/Test-Config.ps1`

Apenas interativamente: ofereça sincronizar o relógio novamente agora.
Retorna $true apenas quando uma sincronização realmente tiver sucesso (o chamador
então mede novamente, em vez de confiar na tentativa). Onde não é possível
perguntar a ninguém — na verificação anterior ao ciclo e em um executor sem
intervenção —, retorna $false imediatamente e mantém as instruções impressas,
pois não oferecer a ação é um resultado completo aqui, enquanto bloquear
aguardando uma resposta não é.

Este é o único ponto em que se tenta reparar o relógio com um operador presente;
portanto, também é o único que pode solicitar uma credencial. Um ciclo em
execução nunca sincroniza — apenas mede e avisa (Write-HostClockDriftWarning).

<a id="42010605-0061"></a>

<a id="section-3b-host-clock"></a>

### Seção 3b: relógio do hospedeiro

`yuruna/test/Test-Config.ps1`

Todo hipervisor aqui inicializa o relógio do convidado a partir do hospedeiro
quando ele liga; assim, um hospedeiro com desvio inicia todas as VMs igualmente
erradas, e o cliente NTP do próprio convidado salta para a hora real alguns
segundos após a inicialização — no meio da partida dos serviços desse convidado.
Em um convidado Kubernetes, isso deixa pods Running, mas nunca Ready, e todos os
NodePort recusando, sem nada que aponte para um relógio. É barato medir aqui;
caro diagnosticar depois.

<a id="42010605-0062"></a>

<a id="capture-test-hostrequirements-write-warning-lines-via--warningvariable-and-re-emit-them-through-wri"></a>

### Capture as linhas Write-Warning de Test-HostRequirement por -WarningVariable e reemita-as por Wri

`yuruna/test/Test-Config.ps1`

Capture as linhas Write-Warning de Test-HostRequirement por -WarningVariable
e reemita-as por Write-Warn, para que fiquem sob a seção atual no estado de
Test.Output. Sem isso, os avisos chegam diretamente ao fluxo Warning do
hospedeiro e nunca entram no bloco de resumo FAILURES, deixando o operador
apenas com "see warnings above" apontando para conteúdo que já saiu da tela.

<a id="42010605-0063"></a>

<a id="section-3-host-requirements-quick"></a>

### Seção 3: requisitos do hospedeiro (rápidos)

`yuruna/test/Test-Config.ps1`

Importa Test.HostContract.psm1 e executa a mesma checagem prévia rápida chamada
pelos auxiliares voltados ao operador (Remove-TestVMFiles.ps1, ...): detecta o
tipo de hospedeiro e verifica o mínimo absoluto (Administrator + vmms no Hyper-V,
virsh + /dev/kvm no Ubuntu, UTM.app + utmctl no macOS). A indicação Write-Information
dentro de Test-HostRequirement é suprimida aqui porque ESTE script É a verificação
mais profunda que ela anunciaria.

<a id="42010605-0064"></a>

<a id="helpers-1"></a>

### Auxiliares

`yuruna/test/Test-Config.ps1`

Write-Pass / Write-Fail / Write-Warn / Write-Info / Write-Section /
Write-Summary / Exit-WithSummary são exportados por Test.Output.psm1.
Test-IsSet / Test-AgainstSchema / Test-RepoFreshness são exportados por
Test.ConfigValidator.psm1. Ambos os módulos compartilham uma âncora $global: de
contadores, para que todo Write-Fail / Write-Pass de qualquer um deles apareça
no mesmo resumo final.

<a id="42010605-0065"></a>

<a id="alternative-ocr-option-using-tesseract-open-source-independent-of-winrt"></a>

### Opção alternativa de OCR com Tesseract (código aberto), independente de WinRT

`yuruna/test/check/Test-TesseractOcr.ps1`

Test-WinRtOcr.ps1 demonstra o mecanismo WinRT Windows.Media.Ocr, que exige
executar PowerShell 5.1 externamente, pois o .NET 6+ deixou de oferecer suporte a WinRT.

Este script demonstra uma abordagem completamente diferente: Tesseract OCR,
um mecanismo de código aberto executado como programa independente. Funciona
diretamente em pwsh (sem um intermediário powershell.exe), executa no
Windows/macOS/Linux e não depende de nenhuma API do Windows Runtime.

Instale Tesseract por qualquer uma destas opções:
  winget install UB-Mannheim.TesseractOCR
  choco install tesseract
  scoop install tesseract
  brew install tesseract          (macOS)
  sudo apt install tesseract-ocr  (Linux)

<a id="42010605-0066"></a>

<a id="demonstrates-the-closed-access-problem-with-microsoft-aiocr-on-modern-powershell"></a>

### Demonstra o problema de "acesso fechado" ao Microsoft AI/OCR no PowerShell moderno

`yuruna/test/check/Test-WinRtOcr.ps1`

O Windows inclui um mecanismo de OCR capaz (Windows.Media.Ocr) como parte do
Windows Runtime (WinRT). Porém, o .NET 6+ removeu o suporte integrado à projeção
WinRT; por isso, o PowerShell 7+ (pwsh) não consegue carregar tipos WinRT diretamente.

As únicas duas formas de usar Windows.Media.Ocr são:

1. Executar Windows PowerShell 5.1 (powershell.exe) externamente, pois ele ainda
   tem interoperabilidade WinRT nativa. É o que faz Test.OcrEngine.psm1 do Yuruna
   (veja o bloco do provedor WinRT).

2. Acrescentar o pacote NuGet Microsoft.Windows.SDK.NET.Ref a um projeto C#
   e compilar com ele. Esse pacote não é redistribuível e exige uma instalação
   do Windows SDK.

Nenhuma opção funciona como um simples "Add-Type" ou "Import-Module" em pwsh.
Os tipos existem em toda máquina Windows, mas a ponte do runtime deixou de existir.

Este script demonstra o problema: tenta carregar o mecanismo de OCR em pwsh
(o que falha) e depois recorre a powershell.exe (o que funciona). Se um caminho
de imagem for fornecido, também executa OCR nessa imagem por powershell.exe
e exibe o texto extraído.

<a id="42010605-0003"></a>

<a id="lab-storage-and-enrollment"></a>

## Armazenamento e inscrição no laboratório

<a id="42010605-0068"></a>

<a id="loopback-exemption-and-aliases"></a>

### Exceção de loopback e aliases

`yuruna/test/lab/Clear-LocalLabStorage.ps1`

Os aliases só são removidos quando ainda apontam para ESTA máquina. Após uma
conversão, a sincronização normalmente os redirecionou para o NAS do laboratório
— mesmo nome, outro endereço —; removê-los então deixaria a montagem com um nome
que nada resolve. Get-PoolWorkerAliasPlan define essa regra; aqui, a lista de
servidores configurados fica vazia intencionalmente, para que um nome resolvido
fora da máquina seja informado como pertencente a outra e mantido em qualquer caso.

<a id="42010605-0069"></a>

<a id="the-probes-ask-questions-and-change-nothing-so--whatif-is-suppressed-across-them-it-has-to-be-supp"></a>

### As verificações consultam sem alterar nada; por isso, -WhatIf é suprimido nelas. Deve ser suprimido

`yuruna/test/lab/Clear-LocalLabStorage.ps1`

As verificações consultam sem alterar nada; por isso, -WhatIf é suprimido nelas.
Isso deve ocorrer AQUI, não dentro do módulo: a propagação de preferências segue
a cadeia de chamadas, não a cadeia de escopos do módulo; assim, uma atribuição
na função chamada é invisível ao cmdlet que ela envolve. Sem isso, o primeiro
Get-SmbShare carrega automaticamente o módulo SmbShare, e suas chamadas New-Alias
inserem cinco linhas "What if: Set Alias" no meio do relatório.

<a id="42010605-006a"></a>

<a id="what-this-machine-still-serves"></a>

### O que esta máquina ainda compartilha

`yuruna/test/lab/Clear-LocalLabStorage.ps1`

A consulta é feita à tabela de compartilhamentos do SO, não a test.config.yml,
pelo motivo de existir Get-LocalLabStorageServedPath: a configuração que uma
máquina carrega para um NAS é idêntica, em todas as chaves, à configuração de
compartilhamentos servidos aqui; só a tabela os distingue. Após uma conversão,
a configuração identifica o NAS, o que faria uma resposta baseada nela dizer
"nada local" em uma máquina que ainda compartilha as duas pastas.

<a id="42010605-006b"></a>

<a id="stop-this-machine-from-serving-its-own-pool-and-stash-shares-withdraw-the-smb-shares-delete-the-st"></a>

### Pare de compartilhar as pastas locais do grupo e do stash nesta máquina: remova os compartilhamentos SMB e exclua as

`yuruna/test/lab/Clear-LocalLabStorage.ps1`

O inverso de New-LocalLabStorage.ps1, para uma máquina que ingressou em um
laboratório e agora monta o armazenamento dele em vez do próprio. Tudo que fazia
desta máquina um SERVIDOR de armazenamento é removido; nada que ela armazenou é.

Essa separação é deliberada e constitui todo o projeto deste script. As pastas
sob a raiz de armazenamento contêm arquivos compactados de ciclos concluídos,
artefatos do stash, o vault do laboratório e o repositório de configuração do grupo —
conteúdo cuja única cópia pode estar aqui e que nenhuma regra automatizada pode
avaliar. Por isso, os bytes são relatados, nunca excluídos: tamanho por pasta,
conteúdo de cada uma e comando exato para o operador executar depois de decidir.
Todo o resto — definições de compartilhamentos, contas específicas deles,
exceção de loopback do Windows, aliases do arquivo hosts — é configuração da
máquina que se torna incorreta quando este hospedeiro para de compartilhar,
e é removida sem perguntas além de uma confirmação.

Deixar as contas não é a opção segura que parece. O NAS do laboratório tem
contas com os MESMOS nomes (yuruna-pool, yuruna-stash), e o vault agora guarda
as senhas do NAS para elas; uma conta local desse nome que já não corresponda
é uma credencial que o operador pode passar muito tempo acreditando ser a
que está sendo recusada.

Idempotente. Uma máquina que nunca serviu armazenamento próprio, ou que já foi
limpa, informa 'absent' em cada etapa e não altera nada.

Execute APÓS a conversão, não antes: test/pool/Convert-ToPoolWorker.ps1 precisa
das montagens do laboratório funcionando, e o escopo de remoção de aliases deste
script é definido pela configuração após a conversão. Convert-ToPoolWorker
imprime o convite para executá-lo como etapa final.

<a id="42010605-006c"></a>

<a id="put-this-hosts-settings-back-the-way-enable-testautomation-found-them"></a>

### Restaure as configurações deste hospedeiro ao estado encontrado por Enable-TestAutomation

`yuruna/test/lab/Disable-TestAutomation.ps1`

Ponto de entrada independente do tipo de hospedeiro, seguindo Enable-TestAutomation.ps1.
Detecta o tipo de hospedeiro e executa seu Disable-TestAutomation.ps1 em um pwsh
filho com diretório de trabalho na própria pasta; os argumentos são encaminhados
literalmente, e o código de saída do filho é retornado.

O que é restaurado vem da captura gravada por Enable antes de qualquer alteração
(status/runtime/host.pre-automation.json). Em um hospedeiro habilitado antes de
existir essa captura, só se reverte o que foi acrescentado E comprovadamente é
nosso — a regra de firewall da porta de status e a regra ICMP do Yuruna.
Todo o resto é impresso como comando para execução manual, sem adivinhações.

Deliberadamente NÃO revertidos, apenas relatados: pacotes instalados, módulos
PSGallery, permissões TCC do macOS, vault de credenciais, repositórios clonados /
imagens de VM / histórico, serviço vmms e tudo gravado pelo questionário
networkStorage (chaves de configuração, credencial no vault, montagens).
Desativar armazenamento ao "desabilitar configurações" seria uma surpresa;
por isso, a ação é oferecida por comandos explícitos.

    host/windows.hyper-v/Disable-TestAutomation.ps1   (exige Administrator)
    host/macos.utm/Disable-TestAutomation.ps1         (solicita sudo)
    host/ubuntu.kvm/Disable-TestAutomation.ps1        (solicita sudo)

Idempotente: pode ser executado novamente com segurança.

<a id="42010605-006d"></a>

<a id="common-parameter-relay"></a>

### Encaminhamento de parâmetros comuns

`yuruna/test/lab/Enable-TestAutomation.ps1`

Enable-TestAutomation.ps1 específico de cada hospedeiro é um script avançado e
explica cada decisão sob -Verbose; portanto, encaminhe o switch quando solicitado.
Ele é vinculado a este redirecionador como parâmetro comum e, sem encaminhamento,
pararia aqui. Um nível Verbose ou Debug solicita a mesma explicação por outro
nome, e o filho vincula o switch — a variável de ambiente sozinha alcançaria
apenas as preferências do próprio script específico, não sua saída condicionada
a -Verbose.

<a id="42010605-006e"></a>

<a id="prepare-this-host-to-run-yuruna-automated-vm-tests-whatever-host-it-is"></a>

### Prepare ESTE hospedeiro para executar testes automatizados de VM do Yuruna, qualquer que seja seu tipo

`yuruna/test/lab/Enable-TestAutomation.ps1`

Ponto de entrada independente do tipo de hospedeiro. Detecta o tipo e executa
seu Enable-TestAutomation.ps1 em um pwsh filho com diretório de trabalho na própria
pasta; este shell permanece em test/. Os argumentos são encaminhados literalmente,
e o código de saída do filho é retornado.

O que realmente é configurado — repouso da tela, bloqueio de tela, serviço do
hipervisor, regras de firewall do hospedeiro — varia conforme o hospedeiro e é
documentado e gerenciado pelo script específico:

    host/windows.hyper-v/Enable-TestAutomation.ps1   (exige Administrator)
    host/macos.utm/Enable-TestAutomation.ps1         (solicita sudo)
    host/ubuntu.kvm/Enable-TestAutomation.ps1        (solicita sudo)

Idempotente, pois os scripts chamados também são: pode ser executado novamente
com segurança.

<a id="42010605-006f"></a>

<a id="force-this-hosts-bridge-to-take-a-fresh-dhcp-lease-on-an-interval-so-a-cycle-can-be-shown-to-survi"></a>

### Force a ponte deste hospedeiro a obter uma nova concessão DHCP periodicamente, para demonstrar que um ciclo sobrevive

`yuruna/test/lab/Invoke-HostAddressChurn.ps1`

Um hospedeiro de teste de resistência não comprova nada em uma rede sem mudanças.
Esperar que o roteador do ambiente mude o endereço torna a evidência uma questão
de sorte: a concessão é a que existe, as mudanças ocorrem quando ocorrerem, e um
ciclo aprovado pode simplesmente ter atravessado meia hora tranquila. Este script
provoca a mudança, para que "o ciclo passou por N mudanças de endereço" descreva
o ambiente de testes, não o comportamento ocasional do roteador.

Cada intervalo solicita ao NetworkManager que refaça DHCP na ponte. A mudança
real do endereço ainda cabe ao servidor — o script não pode fabricar um novo
endereço, apenas provocar uma nova negociação de concessão —; por isso relata
o que observou, não o que pretendia. Um servidor que devolva o mesmo endereço
produz uma linha honesta de "no change", em vez de sucesso silencioso.

--- REGION: https://yuruna.link/4220a755-0048

<a id="42010605-0070"></a>

<a id="repair-a-wedged-local-hypervisor-and-leave-the-runner-its-services-and-the-listener-running-again--"></a>

### Repare um hipervisor local travado e deixe o executor, seus serviços e o listener novamente ativos —

`yuruna/test/lab/Invoke-HostRefresh.ps1`

Uma tentativa de reparo com limites, com a mesma implementação usada por todos
os canais: shell do operador, despacho de atualização do bootstrap do macOS,
listener de status, solicitação pool-control e acionamento automático do executor
externo. Ela sobe uma escada de ações (verificar, recuperar, iniciar se parado,
reiniciar se travado, ...), até o teto solicitado, executando apenas ações que
este checkout suporta nesta plataforma e verificando novamente após cada uma.
Depois converge os serviços, o listener e o executor com uma reserva de tempo
separada.

Propriedades de segurança:
  * Um reparo por conta de hospedeiro de cada vez (trava mantida aberta durante
    a operação), um journal durável de solicitações e um registro de recuperação
    em $HOME/.yuruna/host-refresh, fora de qualquer diretório servido.
  * Nada solicita resposta: sem pergunta no console, diálogo de consentimento
    ou sudo interativo. Toda chamada nativa é limitada pelo orçamento de
    915 segundos da invocação (60 s para iniciar, 600 s para a escada,
    240 s para convergência, 15 s para relatório).
  * Apenas processos do executor comprovadamente próprios recebem sinais;
    o listener de status, seu beacon e processos de outra conta nunca recebem.
    Pausas, retenções e pedidos de reinicialização do operador sobrevivem ao reparo.
  * Reiniciar UTM pode suspender convidados ativos, e uma parada forçada pode
    desligá-los sem encerramento correto; ela só ocorre com -AllowHardStop
    em uma solicitação local.
  * -WhatIf é um plano somente de leitura: nada é criado, travado, gravado,
    sinalizado nem iniciado.

Tudo que uma tentativa interrompeu permanece como obrigação pendente até ser
verificado ou resolvido; -Resume tenta novamente a única solicitação não
resolvida, e -DisposeObligation registra, com auditoria, que uma obrigação
foi tratada manualmente.

<a id="42010605-0071"></a>

<a id="show-step-by-step-where-a-lab-token-exchange-stops"></a>

### Mostre, etapa por etapa, onde uma troca de token do laboratório para

`yuruna/test/lab/Lab-Diag.ps1`

Set-LabToken informa uma frase quando a troca falha, e no caso mais comum essa
frase é enganosa: atribui o problema a um código antigo ou ao proxy errado,
justamente os dois casos que produzem um 403 claro, não a mensagem impressa.
Quando o agregador SELOU a resposta e o cliente não conseguiu abri-la, a causa
está no cliente, e nenhuma dessas orientações se aplica.

Este script imprime cada etapa entre o código e o token recuperado, para que
a etapa que falhou se identifique:

  - qual runtime e SO estão solicitando, pois o cliente é a parte que varia
    entre os hospedeiros de um laboratório;
  - o status HTTP, que distingue uma recusa (403 — o código realmente estava
    errado ou expirado) de uma resposta selada que o cliente não conseguiu
    abrir (200);
  - a resposta bruta e como este PowerShell a analisou, pois o envelope é lido
    por chave, e um parser que retorne outro tipo de dicionário é uma diferença
    que só aparece em um hospedeiro;
  - os quatro campos do envelope com seus comprimentos, pois
    Unprotect-LabTokenEnvelope retorna SILENCIOSAMENTE uma string vazia quando
    qualquer um falta, indistinguível de uma falha de decifragem na mensagem
    vista pelo operador;
  - a própria decifragem, com a exceção real em vez da suprimida.

Somente leitura. Resgata um código, que o agregador contabiliza como troca `ok`
e audita como qualquer outra, mas não armazena nada: nenhuma gravação no vault,
alteração de configuração nem token mantido. O código permanece resgatável até
rotacionar; executar isso não custa ao operador a inscrição que estava prestes
a realizar.

<a id="42010605-0072"></a>

<a id="pool-configuration-repository"></a>

### Repositório de configuração do grupo

`yuruna/test/lab/New-Lab.ps1`

'pool-configuration.git' é o nome já resolvido por todo consumidor e que ele não pode
descobrir: o Alias do apache publicado pelo proxy de cache, o caminho de montagem
do convidado no qual pool-control service faz commits e o caminho gravável
passado por setup.ps1 a New-Pool. Um nome derivado do nome do laboratório não
seria acessível por nenhum deles; o repositório existiria e nada o abriria.
O nome do laboratório não precisa estar no nome — cada laboratório tem seu
próprio -Root, portanto a pasta do grupo já tem escopo de laboratório.

<a id="42010605-0073"></a>

<a id="create-a-lab-its-storage-folders-its-credential-vault-and-its-pool-configuration-repository"></a>

### Crie um laboratório: suas pastas de armazenamento, seu vault de credenciais e seu repositório de configuração do grupo

`yuruna/test/lab/New-Lab.ps1`

Um laboratório é um conjunto de hospedeiros fisicamente locais, depois
organizados em grupos; cada grupo pode definir os repositórios de framework e
projeto executados por seus hospedeiros. Prepará-lo manualmente — criar duas
pastas, compartilhá-las, definir ACLs, colocar senhas em um vault — não deixa
nada para verificar o resultado. Este script cria os três itens de forma
consistente e pode ser executado novamente com segurança.

O que cria em -Root:
  <Root>/yuruna.pool          replicação da saída de ciclos + repositório de configuração
  <Root>/yuruna.stash         armazenamento durável do próprio stash service
  <Root>/yuruna.pool/pool-configuration.git
                              repositório bare de configuração do grupo, inicialmente válido pelo esquema.
                              a VM caching-proxy-service o serve por HTTP; essa URL
                              se torna configurationGitUrl do laboratório.

O vault gravado é YAML simples protegido por permissões do sistema de arquivos.
Isso é deliberado e é o motivo de existir este script em vez de reutilizar
Export-Clixml: um vault do laboratório deve ser COPIÁVEL para seus outros
hospedeiros, e arquivos vinculados por DPAPI não podem ser decifrados na máquina
para a qual são copiados. Veja test/schemas/lab.vault.schema.yml.

Compartilhar as pastas por SMB cabe ao operador: é específico da plataforma,
exige elevação, e a conta autorizada é uma decisão que este script não deve tomar.
O guia cobre isso. Em uma máquina que serve o próprio armazenamento,
test/lab/New-LocalLabStorage.ps1 faz essa parte e chama este script para a outra.

ACRESCENTAR UM LABORATÓRIO A UMA MÁQUINA QUE JÁ TEM ARMAZENAMENTO. As contas de
compartilhamento têm escopo de máquina, não de laboratório: uma única conta de
SO `yuruna-pool` atende todos os laboratórios cujo armazenamento está aqui.
Por isso, uma credencial que esta máquina já tenha é REUTILIZADA, não regenerada
— uma senha aleatória nova seria registrada no vault do novo laboratório enquanto
a conta de SO, o servidor SMB e as outras máquinas ainda guardariam a antiga;
toda montagem com o novo vault falharia em um compartilhamento que nunca teve
aquela senha.

A reutilização lê o vault do hospedeiro (o repositório lido pelo próprio ambiente de testes)
pela mesma indireção vaultKey usada por Get-Password. É estritamente somente de
leitura: um usuário sem credencial armazenada recebe uma nova gerada, e nenhum
valor existente é sobrescrito. -Force regenera o arquivo de vault do laboratório,
mas ainda reutiliza as credenciais da máquina; trocar uma senha é uma ação
separada e deliberada (Set-Password) que também deve alcançar a conta de SO
e o compartilhamento.

-Root pode ser omitido depois que houver armazenamento aqui: a raiz é lida do
vault de um laboratório já existente nesta máquina, para que um segundo
laboratório não precise informar novamente onde o primeiro colocou suas pastas.

<a id="42010605-0074"></a>

<a id="clear-what-would-otherwise-serve-this-mount-from-the-wrong-place-two-kinds-and-the-second-is-the-o"></a>

### Limpe o que atenderia esta montagem a partir do lugar errado. São dois tipos; o segundo é

`yuruna/test/lab/New-LocalLabStorage.ps1`

Limpe o que atenderia esta montagem a partir do lugar errado. São dois tipos,
e o segundo é invisível: um cliente SMB mantém UMA sessão por nome de servidor
e a reutiliza; enquanto algum compartilhamento do NAS antigo continuar montado
como 'ypool-nas', uma montagem do 'ypool-nas' redirecionado será atendida pela
sessão ANTIGA — ela procura nosso compartilhamento no NAS, não o encontra, e
mount_smbfs informa "No such file or directory". Redirecionar o alias na etapa 5
não desfaz isso; só encerrar a sessão resolve, e ela termina quando suas montagens
são removidas.

<a id="42010605-0075"></a>

<a id="the-cifs-mount-runs-sudo--n-which-never-prompts-without-the-drop-in-it-fails-and-the-runner-buff"></a>

### A montagem cifs executa `sudo -n`, que nunca solicita senha; sem o drop-in, falha e o executor armazena

`yuruna/test/lab/New-LocalLabStorage.ps1`

A montagem cifs executa `sudo -n`, que nunca solicita senha; sem o drop-in,
ela falha e o executor armazena localmente em vez de arquivar.

-NonInteractive é vinculado a partir do mesmo predicado usado por todas as outras
perguntas deste script, pois instalar o drop-in grava /etc/sudoers.d por um simples
`sudo tee`. sudo lê a senha de /dev/tty; assim, sob um chamador que tomou o console
— stdin fechado, stdout capturado —, essa gravação gera uma solicitação que nada
exibe nem responde, e a execução para ali depois de já ter criado contas e
compartilhamentos. Se recusada, a chamada retorna os comandos exatos para instalar
o drop-in manualmente.

<a id="42010605-0076"></a>

<a id="step-8----mount"></a>

### Etapa 8 — montagem

`yuruna/test/lab/New-LocalLabStorage.ps1`

A montagem usa Connect-YurunaPoolStorage, em vez de uma chamada própria:
é o mesmo código usado pelo ciclo sem intervenção; um compartilhamento montado
aqui é um que o ciclo consegue montar, e uma falha aqui é a que ele encontraria
mais tarde sem ninguém observando.

Os registros das camadas são relidos da configuração gravada pelos próprios
leitores do ambiente de testes, que também aplicam a expansão de '~' necessária ao ponto
de montagem do macOS — passado sem expansão, mount_smbfs criaria um diretório
literalmente chamado '~', e a verificação de montagem nunca voltaria a reconhecê-lo.

<a id="42010605-0077"></a>

<a id="step-3-writes-the-credential-verifies-it-and-rebuilds-the-account-when-it-cannot----so-reaching-he"></a>

### A etapa 3 grava a credencial, verifica-a e reconstrói a conta quando não consegue — chegar aqui

`yuruna/test/lab/New-LocalLabStorage.ps1`

A etapa 3 grava a credencial, verifica-a e reconstrói a conta quando não consegue;
chegar aqui significa que a conta tem o registro e smbd ainda a recusa, algo
que o operador não pode corrigir repetindo o que o script já fez.
Pare em vez de continuar: a montagem na etapa 8 falharia com
"No such file or directory", uma mensagem sobre compartilhamento ausente
para uma credencial que nunca foi aceita.

<a id="42010605-0078"></a>

<a id="step-progress"></a>

### Progresso das etapas

`yuruna/test/lab/New-LocalLabStorage.ps1`

Quase todo segundo gasto por este script está dentro de uma ferramenta nativa
que não imprime nada até terminar: `sysadminctl -addUser`, `pwpolicy`, `apt-get
install`, um `sudo pwsh` aninhado para o arquivo hosts e duas montagens SMB,
cada uma limitada por um tempo de vários segundos. Anunciar o trabalho ANTES
de começar e cronometrá-lo distingue uma etapa lenta de uma travada para o
operador que a observa — o mesmo motivo pelo qual as chamadas de SO do módulo
explicam o próprio andamento.

<a id="42010605-0079"></a>

<a id="honor-the-callers-loglevel-published-as-envyuruna_log_level-by-whatever-entry-point-started-this"></a>

### Respeite logLevel do chamador, publicado como $env:YURUNA_LOG_LEVEL pelo ponto de entrada que iniciou este

`yuruna/test/lab/New-LocalLabStorage.ps1`

Respeite logLevel do chamador, publicado como $env:YURUNA_LOG_LEVEL pelo ponto
de entrada que iniciou este script (install/setup.ps1, um ciclo do executor).
Isso fica depois da linha acima intencionalmente: um nível explícito é escolha
do operador e substitui o padrão do próprio script. $InformationPreference é
então relido da variável global gravada pela cascata, pois a atribuição em escopo
de script acima a oculta no restante deste arquivo. Veja docs/loglevels.md.

<a id="42010605-007a"></a>

<a id="turn-this-machine-into-its-own-pool-and-stash-storage-server-create-the-folders-the-two-storage-ac"></a>

### Torne ESTA máquina seu próprio servidor de armazenamento do grupo e do stash: crie as pastas e as duas contas de armazenamento

`yuruna/test/lab/New-LocalLabStorage.ps1`

Um laboratório sem NAS ainda precisa das camadas de grupo e stash. Prepará-las
manualmente envolve uma dúzia de etapas elevadas específicas da plataforma —
criar duas pastas, criar duas contas, habilitar um servidor de arquivos, publicar
dois compartilhamentos, definir ACLs, acrescentar aliases do hospedeiro, guardar
duas senhas em um vault, montar dois compartilhamentos e editar seis chaves de
configuração — sem nada para verificar o resultado. Este script faz tudo isso
no Windows, macOS e Ubuntu e pode ser executado novamente com segurança.

APENAS PARA MÁQUINAS LOCAIS. As contas e permissões criadas são locais a esta
máquina. Um NAS real ou servidor de arquivos separado tem suas próprias contas
e controle de acesso, que não podem ser configurados daqui: neles, crie os
usuários e conceda as permissões de compartilhamento NO DISPOSITIVO REMOTO;
depois aponte networkStorage.* para ele (docs/test-config.md). O script informa
isso e pede confirmação antes de alterar qualquer coisa.

Os compartilhamentos são LOCAIS, mas consumidos como se fossem REMOTOS.
Cada camada recebe um alias de hospedeiro (ypool-nas, ystash-nas) resolvido para
loopback, e o compartilhamento é montado por SMB usando esse nome pelo mesmo
Connect-YurunaPoolStorage usado no ciclo sem intervenção. O benefício é a
uniformidade: o executor, a verificação de configuração, a drenagem de replicação
e as seeds de convidados usam um único caminho de rede; assim, um laboratório
de uma máquina exercita o mesmo código de um laboratório com NAS — e migrar
para hardware real depois altera apenas o alias.

A raiz de armazenamento é resolvida primeiro (solicitada, com a convenção da
plataforma oferecida como padrão: /srv/yuruna no Ubuntu, /Users/Shared/yuruna
no macOS e <drive>\Shares\yuruna no Windows — a primeira unidade fixa que não
seja a unidade do sistema). As oito etapas numeradas seguem esta ordem:

  1. Pastas, vault do laboratório e repositório de configuração do grupo, por
     New-Lab.ps1. As duas senhas dos compartilhamentos são as que ele gera;
     um laboratório existente mantém suas senhas, para que uma nova execução
     não troque as credenciais usadas por suas outras máquinas.
  2. Servidor SMB. Iniciado (Windows), habilitado (macOS File Sharing) ou
     instalado e configurado (Ubuntu: samba + cifs-utils). Antes das contas,
     para que a etapa 4 publique e verifique na mesma execução.
  3. Contas de armazenamento. Uma conta local por camada, restrita ao próprio
     compartilhamento: sem direitos de administrador nem shell interativo;
     no Ubuntu, a senha de SO permanece bloqueada (a credencial SMB fica no
     passdb do Samba). No macOS, o tipo de hash SMB-NT é habilitado e a senha
     redefinida, a única forma de tornar a conta utilizável por SMB.
  4. Compartilhamentos. Um por camada, autorizando apenas a conta dessa camada;
     no macOS, cada credencial é então verificada no servidor SMB em execução.
  5. Loopback. Aliases de hospedeiro para ambos os servidores e, no Windows,
     a exceção de loopback NTLM e EnableLinkedConnections.
  6. Vault. Cada senha é mapeada para uma vaultKey em users.yml e armazenada,
     para que o ambiente de testes nunca gere uma senha que o compartilhamento recusaria.
  7. Configuração. As seis chaves networkStorage em test/test.config.yml.
  8. Montagem. Ambos os compartilhamentos nos pontos convencionais da plataforma
     — depois da configuração, para que se monte o que o executor depois lerá.
     Um compartilhamento já presente em um desses pontos é desmontado primeiro,
     para que o montado corresponda à resolução atual do alias da etapa 5.

Os nomes de conta deliberadamente NÃO são parâmetros — são as duas variáveis
de script abaixo. Devem corresponder às contas de um NAS caso este laboratório
migre para um; por isso são uma constante de todo o laboratório a editar uma
vez, não uma escolha por execução que possa variar entre máquinas.

<a id="42010605-007b"></a>

<a id="delete-vm-files-on-this-host-that-no-longer-belong-to-a-registered-vm"></a>

### Exclua arquivos de VM NESTE hospedeiro que já não pertencem a uma VM registrada

`yuruna/test/lab/Remove-OrphanedVMFiles.ps1`

Ponto de entrada independente do tipo de hospedeiro. Detecta o tipo e executa
seu Remove-OrphanedVMFiles.ps1 em um pwsh filho com diretório de trabalho na própria
pasta; este shell permanece em test/. Os argumentos são encaminhados literalmente,
e o código de saída do filho é retornado.

A definição de órfão varia por hospedeiro e é gerenciada pelo script específico:

    host/windows.hyper-v/Remove-OrphanedVMFiles.ps1  (exige Administrator)
    host/macos.utm/Remove-OrphanedVMFiles.ps1
    host/ubuntu.kvm/Remove-OrphanedVMFiles.ps1

DESTRUTIVO; solicita confirmação, a menos que -Force seja fornecido.

Isso limpa apenas ARQUIVOS deixados por VMs que já não existem. Para remover as
próprias VMs de teste e depois limpar, use Remove-TestVMFiles.ps1 nesta pasta —
ele para e remove do registro todas as VMs com o prefixo de teste e chama
este mesmo script específico do hospedeiro em seguida.

<a id="42010605-007c"></a>

<a id="provision-the-secrets-remote-host-refresh-needs-the-signing-authority-and-operator-credential-for-p"></a>

### Provisione os segredos necessários à atualização remota do hospedeiro: a autoridade de assinatura e a credencial do operador para p

`yuruna/test/lab/Set-HostRefreshCredential.ps1`

A atualização remota é autorizada por segredos próprios, nunca pelo token do
laboratório, por uma sessão do laboratório nem pela chave de autenticação interna,
todos acessíveis pelo caminho de inscrição do painel. Este script os cria e
transporta sem solicitar respostas:

  1. -NewAuthority, na máquina do operador: cria authority.key (a autoridade
     de assinatura) e operator.credential (o que os chamadores enviam em
     X-Yuruna-Refresh-Credential), acessíveis apenas ao proprietário, no
     diretório authority da raiz privada. Copie ambos para
     /etc/yuruna/host-refresh/ de pool-control, com permissões exclusivas do
     proprietário; nunca os copie para um hospedeiro do grupo.
  2. -ExportHostKey -HostId <id> -OutputPath <file>, na mesma máquina:
     deriva a chave de verificação de um hospedeiro e a grava para transporte.
  3. -InstallHostKey -KeyPath <file>, nesse hospedeiro: instala a chave na
     raiz privada dele. Um hospedeiro que também seja a máquina da autoridade
     pode usar -InstallHostKey -AuthorityDirectory <dir>.
  4. -RemoveHostKey em um hospedeiro retira sua participação na atualização remota.

Sem um switch, o script informa o estado da chave do hospedeiro e da autoridade.
Segredos nunca chegam à saída: apenas tags (nomes não secretos) e caminhos.
O ID do hospedeiro é lido de runtime/host.uuid e nunca criado aqui.
Código de saída 0 no sucesso, 1 em uma recusa.

<a id="42010605-007d"></a>

<a id="an-existing-value-is-normally-the-operators-and-is-never-touched-the-exception-is-a-value-this-blo"></a>

### Um valor existente normalmente pertence ao operador e nunca é alterado. A exceção é um valor que ESTE blo

`yuruna/test/lab/Set-LabToken.ps1`

Um valor existente normalmente pertence ao operador e nunca é alterado.
A exceção é um valor gravado por ESTE bloco em uma execução anterior:
o endereço do proxy vem de uma concessão DHCP e muda; uma URL fixada no endereço
anterior aponta para nada — ou, pior, para o convidado que agora tem aquela
concessão. Isso não é uma decisão do operador a preservar e, se não for alterado,
nunca se recupera: toda execução posterior vê um valor não vazio e ignora.
Reconheça apenas o formato exato emitido pelo bloco (esquema, hospedeiro, nome do
repositório), para que qualquer escolha real do operador continue tendo precedência.

<a id="42010605-007e"></a>

<a id="seed-the-pool-configuration-store-binding"></a>

### Inicialize a vinculação ao repositório de configuração do grupo

`yuruna/test/lab/Set-LabToken.ps1`

Um hospedeiro que acabou de inscrever seu token do laboratório é um hospedeiro
que o operador pretende gerenciar pelo laboratório. O repositório de configuração
que deve consultar é servido pelo próprio proxy recém-informado; vincule-o agora:
a inscrição é o único momento em que um operador está presente, autenticado e
já forneceu o endereço.

Executa para TODO endereço resolvido, não apenas para um fornecido pelo operador
— um hospedeiro cujo cachingProxyIp já esteja na configuração ainda precisa da
vinculação ao grupo, o caso comum em uma nova inscrição.

Um configurationGitUrl existente e não vazio é mantido, a menos que corresponda ao
formato http://<host>/pool-configuration.git inicializado automaticamente e seja diferente
da URL do proxy resolvido. Esse formato é atualizado para o endereço atual do
proxy; outras URLs selecionadas pelo operador permanecem inalteradas. Toda a ação é de melhor esforço
— o token já está armazenado, e uma falha ao inicializar uma vinculação opcional
não deve fazer a inscrição falhar.

<a id="42010605-007f"></a>

<a id="resolve-the-aggregator-base-url"></a>

### Resolva a URL base do agregador

`yuruna/test/lab/Set-LabToken.ps1`

-CachingProxyService explícito tem precedência; depois vem a configuração do
próprio hospedeiro (a resolução de verificar e descartar de
Get-PoolAggregatorServiceSeedUrl, que só confia em um endereço armazenado depois
que ele responde); por último, pergunta-se ao operador. $addressSource registra
a origem do endereço, para que apenas um fornecido pelo operador seja persistido
abaixo.

O orçamento de espera distingue este chamador de uma renderização de seed:
um operador tem um código resgatável por cerca de três minutos; esperar uma
indisponibilidade momentânea custa um tempo que ele gastaria de qualquer forma,
enquanto resolver para '' custa a inscrição e uma volta ao painel para obter
um código novo.

<a id="42010605-0080"></a>

<a id="enroll-this-host-in-the-lab-redeem-the-dashboards-lab-token-for-the-internal-authentication-key-an"></a>

### Inscreva ESTE hospedeiro no laboratório: resgate Lab token do painel pela chave de autenticação interna e

`yuruna/test/lab/Set-LabToken.ps1`

O painel Yuruna hosts (Grafana no caching-proxy service) mostra um bloco
"Lab token" com um código de 6 caracteres que muda aproximadamente a cada minuto.
Este script resgata esse código em POST /api/v1/lab-token do pool-aggregator service,
recebe a chave de autenticação interna e a armazena no vault deste hospedeiro —
habilitando as rotas de controle de status-service (as provas de controle dos
links diretos do Grafana) e config-sync entre hospedeiros. O operador nunca
precisa ler o segredo no proxy nem digitá-lo.

A resposta é selada com o código digitado, para que apenas este hospedeiro possa
abri-la: um hospedeiro em inscrição ainda não consegue verificar o certificado
TLS final do agregador (assinado pela própria CA do proxy), e a selagem impede
que qualquer outro participante da rede responda à troca e insira um token.

O caching-proxy service é localizado pela configuração deste hospedeiro
(o estado persistido de caching-proxy-service, $env:YURUNA_CACHING_PROXY_SERVICE_IP
ou vmStart.cachingProxyIp em test.config.yml). Cada origem é verificada na porta
do agregador, e a primeira que responde é usada; assim, um endereço deixado por
um proxy que mudou é ignorado, em vez de impedir a inscrição. Quando nenhum
responde, as verificações continuam por até dois minutos antes de desistir,
para que uma indisponibilidade momentânea não custe um código ao operador.
Se nenhum endereço responder, passe -CachingProxyService ou responda à solicitação.
Esse endereço é gravado em vmStart.cachingProxyIp quando test.config.yml existe,
vinculando o hospedeiro ao proxy deste laboratório nas próximas execuções;
em uma máquina ainda sem configuração, atende apenas a esta inscrição,
e Sync-HostConfiguration.ps1 transfere a configuração que faz a vinculação.

Pode ser executado novamente a qualquer momento com segurança: token perdido
ou trocado, proxy reconstruído ou estado duvidoso do hospedeiro é resolvido
lendo o código atual no painel e executando novamente.

<a id="42010605-0081"></a>

<a id="internal-authentication-key"></a>

### Chave de autenticação interna

`yuruna/test/lab/Sync-HostConfiguration.ps1`

-PersistInternalAuthKey é independente do tipo de hospedeiro: armazenar a chave
de autenticação interna no vault deste hospedeiro é a mesma operação em todas
as plataformas (ao contrário da conversão de configuração gerenciada pelo script
específico); por isso, executa aqui no redirecionador — antes de config-sync
específico, que também pode ler o token no vault local. A ação usa
Set-InternalAuthKey do módulo no próprio processo (test/lab/Set-LabToken.ps1
aceita apenas o código de 6 caracteres do painel, nunca o token bruto);
os switches de persistência são excluídos dos argumentos encaminhados
(o script específico não tem esse parâmetro).
Persistir é o PADRÃO quando um token é fornecido e o hospedeiro ingressa no grupo:
um hospedeiro que sincronize a configuração do grupo, mas não armazene token,
aceita controle apenas de loopback; assim, o link direto do próprio painel falha
com um 403 que parece um defeito, em vez de configuração incompleta.
-NoPersistInternalAuthKey mantém o token transitório em um hospedeiro que deve
permanecer controlado localmente; -NoPool já significa "não ingressar", portanto
também não persiste.

<a id="42010605-0082"></a>

<a id="common-parameter-relay-1"></a>

### Encaminhamento de parâmetros comuns

`yuruna/test/lab/Sync-HostConfiguration.ps1`

Sync-HostConfiguration.ps1 específico de cada hospedeiro é um script avançado e
explica cada decisão (caminho local mantido, alias acrescentado, credencial
armazenada) sob -Verbose; encaminhe o switch quando solicitado, pois ele é
vinculado a este redirecionador como parâmetro comum e, sem encaminhamento,
pararia aqui. -WhatIf segue pelo mesmo motivo e precisa do mesmo encaminhamento
explícito: ConvertTo-HostScriptArgument descarta deliberadamente parâmetros
comuns opcionais; assim, um -WhatIf vinculado pararia neste shell enquanto o
script específico — que o suporta — executaria de verdade. Um nível Verbose ou
Debug solicita a mesma explicação por outro nome, e o filho vincula o switch —
a variável de ambiente sozinha alcançaria apenas as preferências do próprio
script específico, não sua saída condicionada a -Verbose.

<a id="42010605-0083"></a>

<a id="elevation-gate"></a>

### Verificação de elevação

`yuruna/test/lab/Sync-HostConfiguration.ps1`

Elevação antes de qualquer ação. Invoke-YurunaHostScript faz a mesma verificação,
mas só no momento da delegação — até lá, este redirecionador já regravou
internal-auth-key do vault e reiniciou o status service (uma espera de até três
minutos); assim, um operador do Windows sem elevação paga por trabalho que não
pode terminar. Test-IsAdministrator fica em Yuruna.Common: Yuruna.HostRedirect o
importa apenas no próprio escopo, portanto este ponto de entrada também o importa.
Apenas Windows, exatamente como no redirecionador — '#requires -RunAsAdministrator'
existe somente no script específico do Hyper-V; as variantes macOS e Ubuntu
solicitam sudo por operação, com um motivo.

<a id="42010605-0084"></a>

<a id="supportsshouldprocess-is-load-bearing-not-decoration-this-script-performs-a-state-change-of-its-ow"></a>

### SupportsShouldProcess é essencial, não decorativo: este script realiza uma alteração de estado própria

`yuruna/test/lab/Sync-HostConfiguration.ps1`

SupportsShouldProcess é essencial, não decorativo: este script realiza uma
alteração de estado própria (armazenar internal-auth-key no vault e reiniciar
o status service) antes de delegar. Sem isso, -WhatIf é vinculado a
-RemainingArguments como uma string simples, em vez de parâmetro comum; o ensaio
alcança apenas o script específico — e a gravação do vault que deveria ensaiar
acontece de verdade.

<a id="42010605-0085"></a>

<a id="copy-another-pool-hosts-test"></a>

### Copie o teste de outro hospedeiro do grupo

`yuruna/test/lab/Sync-HostConfiguration.ps1`

Ponto de entrada independente do tipo de hospedeiro. Detecta o tipo e executa
seu Sync-HostConfiguration.ps1 em um pwsh filho com diretório de trabalho na própria
pasta; este shell permanece em test/. Os argumentos são encaminhados literalmente,
e o código de saída do filho é retornado.

A conversão é o que varia por hospedeiro — caminhos de compartilhamentos,
convenções de pontos de montagem locais e local de gravação de um alias —,
e é gerenciada pelo script específico:

    host/windows.hyper-v/Sync-HostConfiguration.ps1  (exige Administrator)
    host/macos.utm/Sync-HostConfiguration.ps1        (sudo para /etc/hosts)
    host/ubuntu.kvm/Sync-HostConfiguration.ps1       (sudo para /etc/hosts)

Idempotente, pois os scripts chamados também são: uma repetição sem alterações
a fazer não grava nada.

<a id="42010605-0004"></a>

<a id="pool-transitions"></a>

## Transições de grupo

O leitor compartilhado `ConvertTo-PoolConfigurationSchemaV4` normaliza as versões
2 e 3 em memória. Move as declarações de repositórios da versão 2 para
`repositories` e renomeia `desiredState` para `configuredState`, preservando o valor.
Valores duplicados iguais são unificados apenas em documentos legados; valores
conflitantes são recusados antes de qualquer alteração. A versão 4 rejeita o campo
antigo. A leitura por si só nunca grava o documento armazenado.

<a id="42010605-0087"></a>

<a id="re-asked-in-process-rather-than-read-off-the-sync-the-sync-ran-the-same-convergence-but-behind-the"></a>

### Consulte novamente no próprio processo em vez de ler o resultado da sincronização. Ela fez a mesma convergência, mas pelo

`yuruna/test/pool/Convert-ToPoolWorker.ps1`

Consulte novamente no próprio processo em vez de ler o resultado da sincronização.
Ela fez a mesma convergência, mas no pwsh filho do redirecionador; seus registros
por usuário não voltaram aqui — apenas um código de saída, que é 0 para uma
sincronização que relatou uma credencial não convergida como aviso. Consultar
novamente é idempotente (uma entrada já correspondente não faz nada nem grava),
e é a única forma de este script nomear os usuários não convergidos na sua decisão.

<a id="42010605-0088"></a>

<a id="order-is-load-bearing-and-each-step-is-the-precondition-of-the-next-release-first-this-hosts-mou"></a>

### A ordem é essencial, e cada etapa é pré-condição da seguinte. LIBERE primeiro: as montagens deste hospedeiro

`yuruna/test/pool/Convert-ToPoolWorker.ps1`

A ordem é essencial, e cada etapa é pré-condição da seguinte.

LIBERE primeiro: as montagens deste hospedeiro de seus próprios compartilhamentos
ocupam os mesmos pontos indicados pela configuração sincronizada, e suas sessões
mantêm os nomes de servidor usados na resolução. Nada mais pode montar até que
sejam removidas. Libere-as enquanto o servidor ainda estiver ativo — desmontar
um compartilhamento cujo ponto acabou de ser retirado pode travar em operações
de E/S que nunca terminam.

<a id="42010605-0089"></a>

<a id="the-sync-runs-in-this-session-and-re-imports-testconfigservicesync-with--force-which-unloads-the-t"></a>

### A sincronização executa NESTA sessão e reimporta Test.ConfigServiceSync com -Force, descarregando T

`yuruna/test/pool/Convert-ToPoolWorker.ps1`

A sincronização executa NESTA sessão e reimporta Test.ConfigServiceSync com
-Force, descarregando a instância de Test.HostDetection para a qual apontam as
reexportações de Test.HostContract — Get-HostType deixa, então, de resolver daqui
em diante. O contrato é reimportado pelo mesmo motivo de ser importado por último
acima: depois de tudo que carrega suas dependências aninhadas. A supressão de
-WhatIf também é necessária pelo mesmo motivo, pois New-YurunaRegistry constrói
o estado de módulo do contrato sob ShouldProcess.

<a id="42010605-008a"></a>

<a id="by-name-hashtable-splatting-is-required-here-array-splatting-binds-every-element-positionally---"></a>

### O splatting por nome (hashtable) é OBRIGATÓRIO aqui. O splatting de array vincula cada elemento POR POSIÇÃO —

`yuruna/test/pool/Convert-ToPoolWorker.ps1`

O splatting por nome (hashtable) é OBRIGATÓRIO aqui. O splatting de array vincula
cada elemento POR POSIÇÃO — um elemento string literal '-ReferenceHost' nunca
é reinterpretado como nome de parâmetro; ele fica em $ReferenceHost, e o endereço
real, a porta e o token acabam todos no coletor ValueFromRemainingArguments da
sincronização. Esse coletor torna o erro silencioso neste caminho: a sincronização
vincula e executa, e apenas seu próprio filho rejeita o duplicado
'-ReferenceHost -ReferenceHost' com um erro de vinculação que identifica um
script que o operador nunca digitou.

-SkipValidation é passado INCONDICIONALMENTE; este script faz a validação no final.
As verificações de armazenamento de Test-Config montam os compartilhamentos do
laboratório, e neste ponto da conversão ainda não conseguem: esta máquina
continua servindo os próprios compartilhamentos sob os mesmos nomes e mantém
as sessões SMB que determinam aonde esses nomes levam. Validar aqui informa
uma FAILURE que as próximas duas etapas existem para remover, o pior momento
possível para mostrá-la — o operador lê uma falha definitiva em uma execução
que ainda não terminou.

<a id="42010605-008b"></a>

<a id="2-sync-configuration-from-the-reference-host"></a>

### 2. Sincronize a configuração a partir do hospedeiro de referência

`yuruna/test/pool/Convert-ToPoolWorker.ps1`

Pelo redirecionador documentado, em vez da função do módulo, para que esta
conversão receba a conversão específica do hospedeiro, as verificações de elevação
e a verificação de atualidade exatamente como um operador executando a
sincronização manualmente.

-InternalAuthKey é passado explicitamente mesmo quando veio do vault deste
hospedeiro: a sincronização o encontraria novamente, mas passá-lo faz com que o
valor verificado previamente por este script seja o valor usado por ela, sem
divergência sobre o token que sustenta a execução. Fornecê-lo também faz a
sincronização armazená-lo no vault deste hospedeiro e reiniciar o status service,
necessário a um hospedeiro em conversão: um worker que sincronize a configuração
do grupo, mas não tenha token, aceita controle apenas de loopback, e o link
direto do painel responde 403.

<a id="42010605-008c"></a>

<a id="read-from-the-config-this-host-carries-now-the-synced-one-names-the-same-share-leaf-for-each-tier--"></a>

### Leia a configuração que este hospedeiro tem AGORA. A sincronizada identifica a mesma pasta final de compartilhamento para cada camada —

`yuruna/test/pool/Convert-ToPoolWorker.ps1`

Leia a configuração que este hospedeiro tem AGORA. A sincronizada identifica
a mesma pasta final de compartilhamento para cada camada —
'//ypool-nas/work/yuruna.pool' e '//ypool-nas/yuruna.pool', publicado na preparação
local, terminam ambos em 'yuruna.pool' —; assim, a resposta da checagem prévia
também vale para a configuração após a sincronização.

A importação YAML suprime $WhatIfPreference: powershell-yaml registra dois aliases
ao carregar, New-Alias suporta ShouldProcess, e um ensaio inseriria duas mensagens
"What if: New Alias" no meio de um relatório que apenas LÊ. Ler uma configuração
não altera nada sob nenhuma das preferências.

<a id="42010605-008d"></a>

<a id="same-whatifpreference-suppression-and-for-the-same-reason-as-the-imports-above-the-host-drivers"></a>

### A mesma supressão de $WhatIfPreference das importações acima, pelo mesmo motivo: o estado do módulo do driver do hospedeiro

`yuruna/test/pool/Convert-ToPoolWorker.ps1`

A mesma supressão de $WhatIfPreference das importações acima, pelo mesmo motivo:
o estado de módulo do driver do hospedeiro é construído por Set-Variable sob
ShouldProcess; um -WhatIf herdado torna a criação da âncora inativa, e a primeira
leitura desse estado lança "Cannot find a variable" — um ensaio falha no estado
necessário para OLHAR o plano antes de ensaiar qualquer coisa. Carregar um driver
não altera nada no hospedeiro; as verificações que alteram ficam todas abaixo.

<a id="42010605-008e"></a>

<a id="elevation-is-asserted-before-anything-happens-rather-than-at-the-line-that-needs-it-the-sync-rewrit"></a>

### A elevação é verificada antes de qualquer ação, em vez de na linha que precisa dela: a sincronização regrava

`yuruna/test/pool/Convert-ToPoolWorker.ps1`

A elevação é verificada antes de qualquer ação, em vez de na linha que precisa
dela: a sincronização regrava o arquivo hosts e a remoção exclui VMs; sem isso,
um operador sem elevação pagaria pela busca da referência, pelas verificações de
credenciais e pela substituição da configuração antes da primeira ação incapaz
de terminar.

Um ensaio é isento. -WhatIf não grava nada, e exigir um shell Administrator para
OLHAR o plano é o que faz um operador ignorar a prévia e executar a ação real primeiro.

<a id="42010605-008f"></a>

<a id="last-and-that-ordering-is-load-bearing-testhostcontract-re-exports-testhostdetections-get-hostt"></a>

### POR ÚLTIMO, pois a ordem é essencial. Test.HostContract reexporta Get-HostT de Test.HostDetection

`yuruna/test/pool/Convert-ToPoolWorker.ps1`

POR ÚLTIMO, pois a ordem é essencial. Test.HostContract reexporta Get-HostType /
Initialize-YurunaHost de Test.HostDetection; uma importação posterior com
`-Force` de Test.HostDetection por qualquer outro módulo — como faz
Test.ConfigServiceSync acima — descarrega a instância para a qual essas
exportações apontam, deixando Get-HostType sem resolução. Importar o contrato
depois de todo módulo que carrega suas dependências aninhadas mantém no escopo
as funções de hospedeiro necessárias a este script para verificar o estado
dos serviços.

<a id="42010605-0090"></a>

<a id="whatifpreference-is-suppressed-across-the-imports-and-restored-immediately-after-the-host-contract"></a>

### $WhatIfPreference é suprimido nas importações e restaurado logo depois. O contrato do hospedeiro

`yuruna/test/pool/Convert-ToPoolWorker.ps1`

$WhatIfPreference é suprimido nas importações e restaurado logo depois.
O estado de módulo do contrato do hospedeiro é construído por New-YurunaRegistry,
cujo Set-Variable está sob ShouldProcess; um -WhatIf herdado torna a criação da
âncora inativa, e a linha seguinte indexa um array nulo — um ensaio falha ao
carregar o módulo, três etapas antes da primeira ação que deveria ensaiar.
Só as importações são abrangidas; toda verificação ShouldProcess gerenciada
por este script continua respeitando o switch do operador.

<a id="42010605-0091"></a>

<a id="convert-a-standalone-machine-into-a-pool-worker-sync-the-labs-configuration-onto-it-retire-the-lo"></a>

### Converta uma máquina independente em worker de grupo: sincronize a configuração do laboratório e retire os serviços lo

`yuruna/test/pool/Convert-ToPoolWorker.ps1`

Sync-HostConfiguration copia a configuração de um hospedeiro de referência e
reconcilia os dois canais auxiliares dos quais depende. É a operação correta
para uma máquina que ingressa em um laboratório, mas insuficiente para uma que
DEIXA a operação independente, pois ela executa versões locais de tudo que a
nova configuração agora identifica em outro lugar — e uma delas vence silenciosamente.

As áreas de extensão resolvem nesta ordem: fixação do operador, VM NESTE
hospedeiro e registro do grupo (Get-ExtensionHostAddress). Um hospedeiro convertido
que ainda tenha sua própria VM stash continua usando-a indefinidamente, e seus
ciclos produzem PASS assim. O stash do grupo nunca é consultado, nenhum aviso é
emitido, e os artefatos que o laboratório espera coletar vão para um
compartilhamento que apenas esta máquina lê. Parar a VM também não resolve:
Restore-YurunaServiceVM inicia toda VM de serviço registrada, mas parada, no
início de cada ciclo, por projeto; o serviço retorna no ciclo seguinte.

Por isso, este script segue esta ordem:

  1. Checagem prévia — hospedeiro de referência acessível, chave de autenticação interna disponível.
  2. Sincronização — test/lab/Sync-HostConfiguration.ps1, com convergência
                     obrigatória das credenciais.
  3. Remoção       — cada VM de serviço local retirada por seu próprio
                     Stop-*ServiceVM.ps1, que limpa o marcador do serviço
                     e exclui os arquivos da VM.
  4. Anúncio       — cada marcador de runtime AINDA declarado após a etapa 3
                     é retirado, e host.registration.json é regenerado para
                     que este hospedeiro saia do painel. Isso é guiado pelos
                     marcadores, não pela remoção, pois um marcador sobrevive
                     à VM que descreve: um hospedeiro cujas VMs de serviço já
                     não existem não tem script de parada a executar e
                     continuaria anunciando-as indefinidamente.
  5. Armazenamento — liberação das montagens dos PRÓPRIOS compartilhamentos da
                     máquina, retirada desses compartilhamentos e contas,
                     e montagem do armazenamento do laboratório no lugar.
  6. Aliases       — entradas do arquivo hosts que identificavam um serviço local retirado.
  7. Verificação   — test/Test-Config.ps1 e depois a pergunta que ele não
                     responde: o estado final é realmente um worker?

A chave de autenticação interna é OBRIGATÓRIA. Sem ela, nada pode ser obtido da
referência, e as entradas do vault criadas por esta máquina para os
compartilhamentos que antes servia sobreviveriam à conversão — uma senha que o
NAS do laboratório nunca viu, em um hospedeiro cuja configuração agora aponta
para esse NAS. Essa falha aparece mais tarde como um erro de montagem que ninguém
associa a esta etapa. Inscreva primeiro com test/lab/Set-LabToken.ps1 ou passe
-InternalAuthKey.

A necessidade da etapa 5 é a menos visível. Uma máquina independente monta os
próprios compartilhamentos exatamente nos pontos que a configuração sincronizada
agora associa ao armazenamento do laboratório, e um cliente SMB mantém UMA sessão
por nome de servidor. Enquanto essas montagens existirem, uma montagem do
'ypool-nas' redirecionado será atendida pela sessão para ESTA máquina, não encontrará
ali o compartilhamento do laboratório e falhará com "No such file or directory",
embora alias, caminho do compartilhamento, conta e ponto de montagem estejam corretos.

DADOS nunca são excluídos. A etapa 5 retira definições de compartilhamentos e suas
contas específicas — configuração que se torna incorreta quando este hospedeiro
para de compartilhar — e preserva todo byte sob a raiz de armazenamento:
arquivos compactados de ciclos, artefatos do stash, vault do laboratório e
repositório de configuração do grupo ficam ali, e nenhuma regra automatizada pode
julgar qual é a única cópia. A saída final mostra o que permanece e o único
comando que recupera o espaço. Passe -KeepLocalShares em uma máquina cujos
compartilhamentos ainda são montados por outros hospedeiros.

Idempotente. Uma segunda execução encontra todos os serviços ausentes, nenhum
anúncio, nada próprio desta máquina impedindo o armazenamento do laboratório,
todos os aliases já removidos e todas as credenciais já convergidas, e não altera nada.

<a id="42010605-0092"></a>

<a id="autoenrollment-is-projected-alongside-pools-because-this-cli-is-the-only-read-path-the-pool-control"></a>

### autoEnrollment é exposto junto dos grupos porque esta CLI é o ÚNICO caminho de leitura de configuração para pool-control

`yuruna/test/pool/Get-PoolConfiguration.ps1`

autoEnrollment é exposto junto dos grupos porque esta CLI é o ÚNICO caminho de
leitura de configuração disponível a pool-control service. Sem isso, a varredura não
vê `excluded[]` — a lista que impede reincluir um hospedeiro removido
intencionalmente pelo operador —, e o operador e um timer de 60 segundos
entrariam em conflito indefinidamente. Quando ausente, é emitido como objeto
vazio, para que um consumidor nunca precise distinguir "ausente" de "não definido".

<a id="42010605-0093"></a>

<a id="evict-from-the-live-dashboard-view-aggregator-forget-host-best-effort"></a>

### Remova da visão ativa do painel (forget-host do agregador, melhor esforço)

`yuruna/test/pool/Remove-PoolHost.ps1`

O painel "Yuruna hosts" é a visão em memória de pool-aggregator-service
(Prometheus yuruna_pool_host_info), NÃO os registros NAS acima — um hospedeiro
descoberto por CONSULTAS periódicas aos status services permanece ali pelo TTL
de hospedeiro do agregador (-host-ttl, padrão 24h) após o último contato;
as exclusões feitas até aqui não o removem. Quando uma chave de autenticação
interna e caching-proxy-service estão configurados, peça ao agregador para
esquecer o hospedeiro AGORA. Opcional e de melhor esforço: token ausente,
proxy desconhecido ou agregador inacessível fazem a ação ser ignorada
silenciosamente (obtenção de dados e TTL ainda convergem), sem fazer a limpeza
falhar nem lançar exceção.

<a id="42010605-0094"></a>

<a id="purge-a-stale-host-from-the-pool-delete-its-nas-records-identity--replicated-cycles-and-strip-it"></a>

### Remova um hospedeiro antigo do grupo: exclua seus registros NAS (identidade e ciclos replicados) e retire-o

`yuruna/test/pool/Remove-PoolHost.ps1`

CLI de coleta de registros obsoletos do grupo. Com um hostId estável, remove
todos os registros do hospedeiro para que deixe de aparecer no conjunto
"Yuruna hosts" / Extension-hosts:

  1. ARMAZENAMENTO. Exclui, sob networkStorage.poolStorageLocalPath (lido de
     test.config.yml):
       * <poolStorageLocalPath>/hosts/info.<hostId>.yml — registro de identidade
         pelo qual o agregador lista um hospedeiro.
       * <poolStorageLocalPath>/hosts/<hostId>/ — arquivos compactados dos ciclos
         atuais do hospedeiro e a raiz antiga <poolStorageLocalPath>/<hostId>/,
         quando presente (recupera espaço no NAS).
  2. ASSOCIAÇÃO. Retira hostId de members[] de TODO grupo no repositório de
     intenção (pools.yml); depois faz commit e push.

Hospedeiros efêmeros (um ciclo descartável de hospedeiro aninhado, uma máquina
com imagem refeita) criam um hostId novo a cada reconstrução; sem limpeza,
cada execução deixa uma entrada inativa.

Proteções: recusa remover o uuid DESTE hospedeiro (runtime/host.uuid) ou um
registro visto pela última vez há < 24h (pode ainda estar ativo), a menos que
-Force seja usado. Idempotente; SupportsShouldProcess (-WhatIf / -Confirm).
Diferente de Remove-HostFromPool, que só edita a associação de UM grupo nomeado
e nunca altera armazenamento.

<a id="42010605-0095"></a>

<a id="the-auto-enrollment-target-pool-can-never-carry-repositories-hosts-arrive-there-automatically-with"></a>

### O grupo de destino da inscrição automática NUNCA pode definir repositórios. Os hospedeiros chegam automaticamente, sem

`yuruna/test/pool/Set-PoolRepository.ps1`

O grupo de destino da inscrição automática NUNCA pode definir repositórios.
Os hospedeiros chegam automaticamente, sem uma escolha feita por alguém;
um projeto definido aqui redirecionaria silenciosamente todo hospedeiro
inscrito automaticamente no laboratório no ciclo seguinte — o maior impacto
possível em toda a camada de grupos.

Vinculado a autoEnrollment.targetPoolId, não ao literal 'default', para que
renomear o destino mantenha a proteção. Isso fica no código por ser uma
restrição entre campos que JSON Schema não expressa; Test-PoolConfiguration.ps1 a
verifica novamente como validador autoritativo. O ID comparado é o armazenado
no grupo encontrado acima, não -PoolId como digitado: a busca ignora
maiúsculas/minúsculas, portanto um ID com outra capitalização não pode escapar.

<a id="42010605-0096"></a>

<a id="set-or-clear-the-framework-and-project-repositories-a-pools-hosts-run"></a>

### Defina ou limpe os repositórios de framework e projeto executados pelos hospedeiros de um grupo

`yuruna/test/pool/Set-PoolRepository.ps1`

CLI de administração de grupos. Com -FrameworkUrl e -ProjectUrl, define
`repositories` do grupo em pools.yml, substituindo qualquer par anterior;
com -Clear, remove-os. Um executor associado a um grupo substitui seus próprios
repositories.frameworkUrl / repositories.projectUrl pelo par do grupo durante
o ciclo e executa o test.runner.yml desse projeto. Um grupo sem repositórios
mantém cada hospedeiro em seus próprios repositórios configurados.
GH_TOKEN nunca faz parte da configuração do grupo — permanece local ao hospedeiro.

As duas URLs têm espaços nas extremidades removidos, devem ser não vazias,
livres de espaços em branco e caracteres de controle, e não podem começar com '-'.
O grupo de destino da inscrição automática (autoEnrollment.targetPoolId) nunca
pode definir repositórios, portanto defini-los nele é recusado; limpá-los nele
é permitido, pois é assim que se repara um repositório de configuração que viole a regra.

<a id="42010605-0097"></a>

<a id="push-the-repos-canonical-yuruna-hosts-dashboard-onto-a-running-caching-proxy-service-vm-so-a-dashb"></a>

### Transfira o painel canônico Yuruna hosts do repositório para uma VM caching-proxy service EM EXECUÇÃO, para que um painel

`yuruna/test/pool/Sync-PoolDashboardOnProxy.ps1`

test/extension/pool-aggregator-service/grafana-pool-dashboard.json é o painel
canônico. A VM do proxy não o lê: cloud-init contém uma cópia inline idêntica
em bytes e a grava uma vez, na construção, em
/var/lib/grafana/dashboards/pool.json. Assim, uma correção no arquivo canônico
só chega a um proxy ativo reconstruindo a VM — o que custa cerca de um quarto
de hora e derruba cache, agregador, Grafana, Loki e Prometheus juntos, apenas
para substituir um arquivo JSON.

Isso executa a partir do HOSPEDEIRO, não do proxy: o hospedeiro já tem a chave
SSH do ambiente de testes, enquanto um convidado contém apenas uma chave PÚBLICA autorizada.
Fazer pelo convidado exigiria incorporar uma chave privada com acesso a sudo
no proxy dentro da própria VM que ela administra.

A transferência deve acertar três coisas, porque a cópia incorporada as acerta
e um simples `scp` não:

  * O painel inclui o literal AGGREGATOR_BASE_PLACEHOLDER na variável
    `aggregator`. Cloud-init o substitui por http://<vm-ip>:9400 depois que
    a VM obtém um endereço. A mesma substituição ocorre aqui, no convidado,
    a partir do próprio `hostname -I` — o endereço é o que a VM realmente
    tem, não um que este hospedeiro presumiu.
  * O provedor de arquivos do Grafana relê o diretório de painéis a cada 30 s
    (updateIntervalSeconds); um arquivo substituído é adotado automaticamente.
    Nada é reiniciado: reiniciar deixaria todos os painéis vazios durante a
    partida do Grafana para obter o que uma consulta do provisionador já obtém.
  * yuruna-fit-pool-dashboard.timer gerencia gridPos.h dos três painéis por
    hospedeiro no proxy — ajusta-os à contagem ativa de hospedeiros, e as alturas
    do arquivo canônico são apenas padrões anteriores ao coletor.
    Sobrescrevê-los redefine os valores, e o timer pode levar até 5 minutos
    para corrigi-los. Por isso, o ajustador executa uma vez imediatamente
    após a transferência.

Idempotente: o candidato é comparado com o que o proxy já serve, usando a
geometria gerenciada pelo ajustador (os três painéis por hospedeiro e os painéis
de linha) do arquivo ativo. Um proxy já atualizado permanece intocado, em vez
de ser regravado e reajustado a cada execução.

Pode ser executado novamente com segurança e não é destrutivo em caso de falha:
o novo arquivo é gravado em um caminho temporário no diretório de painéis e só
movido ao destino depois de ser analisado como JSON no convidado; assim, uma
transferência truncada nunca substitui um painel funcional.

<a id="42010605-0098"></a>

<a id="the-auto-enrollment-target-pool-must-carry-no-repositories-this-is-the-authoritative-check-the-cli"></a>

### O grupo de destino da inscrição automática NÃO deve definir repositórios. Esta é a verificação AUTORITATIVA: a CLI

`yuruna/test/pool/Test-PoolConfiguration.ps1`

O grupo de destino da inscrição automática NÃO deve definir repositórios.
Esta é a verificação AUTORITATIVA: a CLI recusa e a interface desabilita,
mas só esta detecta um arquivo editado manualmente ou um repositório gravado
por uma versão antiga. É uma restrição entre campos (um grupo identificado
por OUTRO campo), que JSON Schema não expressa. É definida para a estrutura v3;
portanto, executa apenas em um repositório com schemaVersion 4.

Uma violação produz FAIL, em vez de ser removida silenciosamente:
removê-la alteraria o que um laboratório executa sem decisão de ninguém.

<a id="42010605-0099"></a>

<a id="validate-every-file-in-the-pool-configuration-store-against-its-schema"></a>

### Valide cada arquivo do repositório de configuração do grupo pelo seu esquema

`yuruna/test/pool/Test-PoolConfiguration.ps1`

CLI de administração de grupos / verificação de CI. Clona/atualiza o repositório
de configuração e valida pools.yml (esquema v4) e guests.compatibility.yml
(quando presente) contra test/schemas/*; impõe a regra entre grupos de que um
hospedeiro pertence a no máximo um grupo e verifica que o destino da inscrição
automática não define repositórios. pools.yml é avaliado como armazenado:
um repositório abaixo de schemaVersion 4 recebe um diagnóstico de versão de
esquema indicando test/pool/Update-PoolConfigurationSchema.ps1. Saída 0 se tudo for
válido, 1 em qualquer erro. Nunca grava. Execute antes de depender de intenção
recém-criada (os executores obtêm o que está versionado, portanto um arquivo
malformado configuraria incorretamente todo o grupo sem aviso).

<a id="42010605-009a"></a>

<a id="migrate-the-pool-configuration-store-to-pools"></a>

### Migre o repositório de configuração do grupo para grupos

`yuruna/test/pool/Update-PoolConfigurationSchema.ps1`

A migração preserva `run`, `paused` e `drain` ao renomear `desiredState` para
`configuredState`. Valores duplicados conflitantes são recusados; a versão 4
aceita apenas o novo campo. Atualize também todos os executores antes de
migrar o repositório compartilhado.


CLI de administração de grupos. Clona/atualiza o repositório de configuração GRAVÁVEL
e lê pools.yml como armazenado. Abaixo de schemaVersion 4, atualiza o documento
com ConvertTo-PoolConfigurationSchemaV4: as URLs de framework e projeto de testSet de
cada grupo se tornam `repositories`, e o nome e as sequências de testSet são
removidos. Também exclui um test-sets.yml remanescente, que nada lê.
Depois valida pools.yml contra test/schemas/pools.schema.yml, faz commit e push.
O título do commit identifica a alteração: "Migrate pool configuration to schemaVersion 4"
quando a versão armazenada muda, ou "pool: remove test-sets.yml" quando ela
já é schemaVersion 4 e apenas aquele arquivo remanescente é removido.

Idempotente: um repositório já em schemaVersion 4 e sem test-sets.yml é informado
como atual e permanece intocado. Uma versão MAIS NOVA é recusada — atualize
primeiro este checkout. A migração mantém todo valor encontrado, inclusive
repositórios no destino da inscrição automática; execute Test-PoolConfiguration.ps1
depois, que informa isso como violação a limpar com Set-PoolRepository.ps1 -Clear.

Toda outra CLI administrativa faz a mesma atualização em memória e a persiste
na próxima gravação; este script torna a migração um commit próprio, explícito
e revisável. Execute depois que todo checkout que grava o repositório
(inclusive a VM pool-control-service) usar o código de schemaVersion 4:
um checkout que ainda valida schemaVersion 2 se recusa a gravar um repositório v4.

<a id="42010605-009b"></a>

<a id="example-pool-configuration-schema-v3-validates-against-testschemaspoolsschemayml-this-is-the-file"></a>

###  Exemplo de configuração de grupo (esquema v4). Valida contra test/schemas/pools.schema.yml. Este é o arquivo

`yuruna/test/pool/examples/pools.yml`

Exemplo de configuração de grupo (esquema v4). Valida contra test/schemas/pools.schema.yml.
Este é o arquivo criado pela CLI de administração de grupos e obtido por cada
executor do repositório git bare em caching-proxy-service. `members[]` é a fonte
única de verdade da associação (um hospedeiro pertence a no máximo um grupo):
substitua os hostIds de exemplo pelos valores reais de runtime/host.uuid dos
seus hospedeiros (com prefixo 42 e 32 caracteres hexadecimais).
`poolGuid` é o GUID estável do grupo. `repositories` contém as URLs de
repositórios de framework e projeto executados por cada hospedeiro do grupo;
omita-o para que cada um use seus próprios repositórios configurados
(GH_TOKEN fica local ao hospedeiro, nunca aqui). `configuredState` controla
execução/pausa/drenagem; `config` substitui opções do ciclo, e `gating` define
os limites consultivos dos alertas de grupo.

<a id="42010605-0005"></a>

<a id="example-workload-execution"></a>

## Execução de carga de trabalho de exemplo

<a id="42010605-009d"></a>

<a id="acquire-base-images"></a>

### Obtenha as imagens base

`yuruna-project/tools/example-workload.sh`

Obtenha as imagens ausentes no armazenamento local. Candidatos, em ordem de
prioridade: o cache pull-through zot (LAN, absorve oscilações TLS da origem) e
depois mcr.microsoft.com, como alternativa quando a VM do cache estiver ausente
ou não conseguir fornecer a tag. Cada candidato é verificado primeiro;
a própria obtenção tem limite de inatividade (PULL_STALL, definido acima),
como proteção contra travamentos no meio da transferência.

<a id="42010605-009e"></a>

<a id="every-attempt-warms-before-it-pulls-the-warm-up-is-what-holds-the-request-open-past-dockerds-fixed"></a>

### Toda tentativa aquece o cache antes de obter a imagem. O aquecimento mantém a solicitação aberta além da espera fixa do dockerd

`yuruna-project/tools/example-workload.sh`

Toda tentativa aquece o cache antes de obter a imagem. O aquecimento mantém a
solicitação aberta além da espera fixa do dockerd por cabeçalhos de resposta
enquanto o cache conclui a sincronização; uma tentativa que o ignore não pode
aproveitar o progresso da sincronização em segundo plano da tentativa anterior:
fica limitada apenas àquela espera, dentro da qual um cache ainda sincronizando
não consegue responder.

<a id="42010605-009f"></a>

<a id="no-http-status-at-all-has-several-causes-that-send-the-operator-to-different-places-and-curls-exit"></a>

### A ausência de status HTTP tem várias causas que levam o operador a lugares diferentes, e o código de saída de curl

`yuruna-project/tools/example-workload.sh`

A ausência de status HTTP tem várias causas que levam o operador a lugares
diferentes, e o código de saída de curl é a única forma de distingui-las.
Relatar todas com o texto de tempo limite faz todos procurarem uma sincronização
ainda em andamento — o lugar errado para investigar um cache que recusou a
conexão em milissegundos porque nada está escutando na porta ainda.

<a id="42010605-00a0"></a>

<a id="the-container-image-carries-no-certificate-and-no-password-kestrel-reads-the-pfx-from-a-kubernetes"></a>

### A imagem de contêiner não contém certificado nem senha. Kestrel lê o PFX de um volume de Secret do Kubernetes

`yuruna-project/tools/Example.Build.psm1`

A imagem de contêiner não contém certificado nem senha. Kestrel lê o PFX de um
volume de Secret do Kubernetes e a senha do mesmo Secret por secretKeyRef.
O Secret é criado para cada implantação, com uma senha nova gerada por
Invoke-ExampleCertificateSecret.

A senha do próprio PFX do desenvolvedor chega na variável lida pelo Kestrel.
Reutilizar esse nome permite que `docker run -e <name>` passe o valor pelo nome,
sem que ele apareça em uma linha de comando ou arquivo batch exibido.
Quando a variável não está definida ou está vazia, o arquivo auxiliar ao lado do PFX
(<pfx>.password, uma linha) a fornece: os scripts de provisionamento de convidados
exportam o PFX com uma senha aleatória e a guardam ali; uma execução no convidado
não precisa de variável.

<a id="42010605-00a1"></a>

<a id="create-the-kubernetes-secret-that-carries-a-pods-https-certificate-protected-by-a-new-random-passw"></a>

### Crie o Secret do Kubernetes que contém o certificado HTTPS do pod, protegido por uma nova senha aleatória

`yuruna-project/tools/Example.Build.psm1`

O Secret contém duas chaves: aspnetapp.pfx e password. A carga de trabalho monta
a primeira como arquivo e lê a segunda por secretKeyRef.

O certificado é o PFX do desenvolvedor reexportado com a senha gerada ou,
quando -SelfSigned é fornecido ou YURUNA_EXAMPLE_SELF_SIGNED_CERT=1, um certificado
autoassinado descartável nunca gravado em disco. O PFX do desenvolvedor é aberto
com a senha de ASPNETCORE_Kestrel__Certificates__Default__Password ou, se não
estiver definida ou estiver vazia, do arquivo auxiliar '<CertificatePath>.password'. A senha gerada
existe apenas em memória e no Secret: não é colocada em linha de comando,
arquivo, variável que o mecanismo de implantação registre nem qualquer saída.
O manifesto chega a kubectl pela entrada padrão.

As falhas são gravadas no fluxo de erro, registrado pelo mecanismo de implantação
em todo nível de log, e informadas pelo código de saída retornado.

<a id="42010605-00a2"></a>

<a id="run-by-the-workloads-configuration-immediately-before-the-chart-is-installed-like-create-cert-secre"></a>

### Executado pela configuração de cargas de trabalho imediatamente antes de instalar o chart, como create-cert-secre

`yuruna-project/example/text-to-sql/components/frontend/text-to-sql-ui/create-db-secret.ps1`

Executado pela configuração de cargas de trabalho imediatamente antes de instalar
o chart, como create-cert-secret.ps1. A etapa de preparação do banco gera a senha
do papel somente de leitura para cada implantação e a deixa em um arquivo
acessível apenas ao proprietário; este script leva a senha ao cluster como um
Secret lido pelo pod por secretKeyRef. A forma de script (em vez de chamada a
módulo na configuração) permite que uma falha chegue ao mecanismo de implantação
como código de saída. A senha não é colocada em linha de comando, saída nem
variável registrada pelo mecanismo: o manifesto chega a kubectl pela entrada padrão.

<a id="42010605-00a3"></a>

<a id="notice-that-the-registryname-variable-is-used-to-find-the-name-of-another-variable-requiring-the"></a>

### Observe que a variável 'registryName' localiza o nome de outra variável, exigindo a

`yuruna-project/example/text-to-sql/workloads/frontend/text-to-sql-ui/templates/01-text-to-sql-ui.yml`

Observe que a variável 'registryName' localiza o nome de outra variável,
exigindo dupla indireção.
`required` é uma proteção deliberada contra renderizar
"/text-to-sql-ui/text-to-sql-ui:latest" (barra inicial, registry vazio) quando
o bloco componentsRegistry de resources.output.yml está ausente ou não chega
a values.yaml, produzindo um pod InvalidImageName.

<a id="42010605-00a4"></a>

<a id="the-registry-provisioned-here-is-ecr-whose-repository-url-is-dkrecramazonawsc"></a>

### O registry provisionado aqui é ECR, cuja URL de repositório é <account>.dkr.ecr.<region>.amazonaws.c

`yuruna-project/example/website/config/aws/workloads.yml`

O registry provisionado aqui é ECR, cuja URL de repositório é
<account>.dkr.ecr.<region>.amazonaws.com/<repository>. O Secret de obtenção da
imagem autentica no hospedeiro do registry, portanto o caminho do repositório
é removido, e a região — o quarto segmento separado por pontos desse hospedeiro —
deve ser especificada na solicitação do token. ECR não tem senha estática:
o token é de curta duração e sempre acompanha o nome fixo de usuário 'AWS'.

<a id="42010605-00a5"></a>

<a id="notice-that-the-registryname-variable-is-used-to-find-the-name-of-another-variable-requiring-the-1"></a>

### Observe que a variável 'registryName' localiza o nome de outra variável, exigindo a

`yuruna-project/example/website/workloads/frontend/website/templates/01-website.yml`

Observe que a variável 'registryName' localiza o nome de outra variável,
exigindo dupla indireção.
`required` é uma proteção deliberada contra renderizar
"/website/website:latest" (barra inicial, registry vazio) quando o bloco
componentsRegistry de resources.output.yml está ausente ou não chega a
values.yaml, produzindo um pod InvalidImageName.

<a id="42010605-00a6"></a>

<a id="to-set-deploy-your-components-a-helm-chart-under-workloads-eg---chart-frontendyourcompon"></a>

### TO-SET: implante seus componentes. Um chart Helm em workloads/, por exemplo: - chart: "frontend/yourcompon

`yuruna-project/template/config/localhost/workloads.yml`

TO-SET: implante seus componentes. Um chart Helm em workloads/, por exemplo:
  - chart: "frontend/yourcomponent"
    variables:
      installName: "yourcomponent-${env:runId}"
ou um manifesto / comando direto:
  - kubectl: "apply -f workloads/yourcomponent/manifest.yml"

<a id="42010605-0006"></a>

<a id="amisad-host-orchestration"></a>

## Orquestração de hospedeiros AmisAd

`Initialize-Lab.ps1` prepara uma topologia para um ciclo de orquestração externo;
`run-tests.ps1` primeiro limpa o laboratório independente e depois executa sua
lista de cenários. As etapas compartilhadas usam o mesmo contrato de hospedeiro,
nomes de fase e regras de admissão. Ambos chamam `Start-AmisAdEdge`: iniciam as
duas bordas antes de esperar, descartam relatórios de inicializações anteriores,
exigem um endereço IP novo e válido para cada borda e param antes dos cenários
se qualquer uma falhar. Os motivos da falha permanecem associados à borda.
A transferência da chave pública usa esses endereços verificados, sem reler um
relatório não confirmado. `-WhatIf` mantém intocados os relatórios e as VMs.

<a id="42010605-00a8"></a>

<a id="locate-the-yuruna-framework-checkout-without-hard-coding-a-path"></a>

### Localize o checkout do framework Yuruna sem fixar um caminho no código

`amisad.dev/test/AmisAd.HostCommon.ps1`

Testados em ordem; vence o primeiro que realmente pareça um checkout:

  1. -Explicit (-YurunaRoot do chamador), para que uma substituição do operador
     sempre tenha precedência sobre a descoberta.
  2. $env:YURUNA_ROOT, para um hospedeiro cuja estrutura não corresponda às opções abaixo.
  3. $env:YURUNA_CONFIG_PATH — o executor publica o caminho resolvido
     '<root>/test/test.config.yml' antes de cada etapa, e a ação no hospedeiro
     o herda, tornando esta opção exata dentro do ciclo.
  4. <this file>/../.. — o ciclo clona o projeto em '<root>/project';
     o diretório test/ do projeto fica dois níveis abaixo da raiz do framework.
  5. $HOME/git/yuruna, para uma execução independente fora de qualquer ciclo
     (um operador chamando a remoção manualmente). É onde os instaladores de
     bootstrap clonam em toda plataforma, inclusive Windows; assim, um
     candidato cobre os três hospedeiros, sem gravar uma letra de unidade.

Um candidato só é válido se test/modules/Test.HostContract.psm1 estiver presente:
é o módulo importado pelas duas ações no hospedeiro; validá-lo garante que uma
correspondência nunca resolva para um checkout antigo demais ou incompleto
demais para operar.

<a id="42010605-00a9"></a>

<a id="shared-host-portability-helpers-for-the-amisad-host-action-scripts-clear-lab"></a>

### Auxiliares compartilhados de portabilidade de hospedeiro para os scripts de ação do AmisAd (Clear-Lab

`amisad.dev/test/AmisAd.HostCommon.ps1`

Uma ação no hospedeiro que chame `Hyper-V\Get-VM` diretamente ou use por padrão
uma raiz com letra de unidade não pode executar em host.ubuntu.kvm nem
host.macos.utm: o módulo Hyper-V está ausente, e um 'c:' inicial é interpretado
como nome de PSDrive; Join-Path falha com "Cannot find drive".

O Yuruna resolve isso: host/<host-type>/modules/Yuruna.Host.psm1 exporta UM
contrato (New-VM / Start-VM / Stop-VMForce / Remove-VM / Get-VMState /
Save-VMDiskSnapshot / ...), implementado por hipervisor; Initialize-YurunaHost
importa o driver correto para o hospedeiro detectado. Estes auxiliares conectam
o projeto a esse contrato, para que as ações não tenham ramificações próprias
por hipervisor.

<a id="42010605-00aa"></a>

<a id="authorize-the-public-half-of-vm-cores-demo-key-on-the-edge-vms-over-the-harness-ssh-channel-and-p"></a>

### Autorize a metade PÚBLICA da chave de demonstração de vm-core nas VMs de borda pelo canal SSH do ambiente de testes

`amisad.dev/test/AmisAd.Lab.psm1`

vm-core gera o par de chaves core->edge dentro de si e mantém ali a metade
privada. Apenas a metade pública é lida (por SSH com a chave do ambiente de testes,
o canal usado por toda outra ação em convidados) e gravada da mesma forma em
authorized_keys de cada borda. Nada privado é copiado, enviado nem servido,
e nenhuma parte da chave trafega pelo HTTP do status service.

A ordem explica por que isso ocorre aqui, não dentro das sequências de borda:
as bordas são provisionadas antes de vm-core existir; a chave em que devem
confiar ainda não existe quando são construídas.

vm-core é iniciado se estiver parado e permanece ativo. Os cenários restauram
seu snapshot antes de usá-lo, e a chave fica nesse snapshot; a restauração,
portanto, a mantém.

O progresso e a decisão são retornados, não escritos: uma função de módulo não
vê $InformationPreference no escopo de script do chamador; imprimir aqui
suprimiria silenciosamente o relatório que explica uma interrupção.

<a id="42010605-00ab"></a>

<a id="delete-a-core-edge-demo-key-that-an-earlier-lab-run-left-in-the-status-services-served-tree"></a>

### Exclua uma chave de demonstração core->edge deixada por uma execução anterior na árvore servida pelo status service

`amisad.dev/test/AmisAd.Lab.psm1`

Um hospedeiro que executou uma versão antiga deste laboratório mantém o par de
chaves de demonstração em test/status/handoff: aquele projeto o gerava no
hospedeiro e fazia os convidados baixá-lo, inclusive a metade privada, do
status service, que fornece seus arquivos a qualquer máquina que alcance a porta.
Uma chave mantida ali está exposta independentemente de quando foi criada;
por isso é excluída, não reutilizada, e vm-core gera seu próprio par.
Remover o arquivo deixa de servi-lo, mas não torna segura uma VM de longa duração
que ainda confie na chave: ela deve ser reconstruída ou ter removida a linha de
authorized_keys terminada em "amisad-demo", o que Sync-AmisAdDemoKey faz nas
bordas que alcança.

<a id="42010605-00ac"></a>

<a id="every-leg-of-this-resolution-rides-the-hosts-link-and-that-link-is-not-continuously-up-a-dhcp-ren"></a>

### Cada parte desta resolução usa a conexão do hospedeiro, que não fica continuamente ativa: uma renovação DHCP

`amisad.dev/test/AmisAd.StashService.psm1`

Cada parte desta resolução usa a conexão do hospedeiro, que não fica continuamente
ativa: uma renovação DHCP a interrompe por alguns segundos, mesmo quando devolve
o MESMO endereço; assim, nada adiante sequer relata uma mudança. Nessa janela,
a consulta ao grupo retorna nada e um stash perfeitamente saudável falha em
/healthz — ambos com a mesma aparência de um stash inexistente. Responder na
primeira tentativa transforma uma interrupção breve em parada obrigatória antes
de qualquer VM iniciar; a execução termina por uma condição que se resolveria
segundos depois.

Consulte, portanto, ao longo de uma janela maior que uma renovação, não em um
único instante. A descoberta é refeita a cada tentativa, não apenas a verificação:
a resposta vazia é o sintoma mais comum, e uma lista de candidatos em cache só
a repetiria. Apenas um ambiente ainda sem resposta ao final da janela realmente
não tem stash, e isso continua interrompendo a execução.

<a id="42010605-00ad"></a>

<a id="find-the-stash-service-verify-it-answers-and-publish-the-address-for-the-rest-of-the-cycle-to-reso"></a>

### Encontre o stash service, confirme sua resposta e publique o endereço para resolução no restante do ciclo

`amisad.dev/test/AmisAd.StashService.psm1`

A construção envia seus binários ao stash, e vm-core os baixa; um stash
inacessível torna toda a execução inútil — mas os convidados só descobrem isso
nas próprias cadeias longas, dezenas de minutos depois. Resolver aqui, antes
de qualquer VM iniciar, transforma o caso em interrupção imediata.

Uma fixação (-Pin ou $env:YURUNA_STASH_SERVICE_HOST para o endereço fornecido
pelo grupo a este hospedeiro) é o ÚNICO candidato quando presente — uma execução
instruída a usar um stash específico deve falhar, em vez de testar silenciosamente
outro. Caso contrário, cada endereço encontrado pelo framework para a área
(Get-ExtensionHostAddress -HostType 'stash-service') é tentado em ordem, e vence
o primeiro que responde a /healthz: uma fixação do operador para a área, uma VM
stash NESTE hospedeiro em seu endereço atual e o endereço informado pelo grupo
para um stash executado em outro hospedeiro. A resposta do grupo mantém um
laboratório funcionando após o stash ser reconstruído com novo IP — o serviço
se anuncia, e este hospedeiro lê o anúncio.

Tanto a descoberta quanto a verificação são repetidas com uma espera progressiva
curta, em vez de consultadas uma vez. Um hospedeiro cuja conexão desapareça
brevemente — uma renovação DHCP basta, mesmo que devolva o mesmo endereço —
produz uma resposta vazia da descoberta e uma falha de /healthz indistinguíveis
da ausência total de stash. Isso ocorre antes de qualquer VM iniciar; um único
instante desfavorável encerraria a execução. Um stash realmente ausente permanece
ausente durante toda a janela e ainda a interrompe.

Publicar o vencedor faz toda expansão posterior de
${ext:stash-service.ResolveHost(...)} retornar o endereço realmente verificado,
em vez de cada sequência verificar novamente uma VM que este hospedeiro talvez
não execute e avisar quando não encontrar nenhuma. Se nada responder, o endereço
publicado é LIMPO; assim, uma execução nunca herda um endereço comprovado pelo
ciclo anterior, mas não por este.

O progresso é retornado como Lines, não escrito aqui: uma função de módulo não
vê $InformationPreference no escopo de script do chamador; imprimir internamente
suprimiria silenciosamente o relatório de que o operador precisa quando a
checagem prévia interrompe a execução.

<a id="42010605-00ae"></a>

<a id="stash-service-pre-flight-shared-by-the-amisad-entry-points-that-build-the-topology-testinitialize-"></a>

### Checagem prévia de stash-service compartilhada pelos pontos de entrada AmisAd que constroem a topologia (test/Initialize-

`amisad.dev/test/AmisAd.StashService.psm1`

Um módulo em vez de auxiliar carregado por dot-sourcing, para que os dois
drivers usem UMA implementação: o endereço para o qual uma execução envia seus
binários não deve depender do ponto de entrada que a iniciou.

Este projeto não declara um endereço próprio de stash. O endereço do stash de
um ambiente pertence a ele — informá-lo aqui o exporia e ficaria desatualizado
na primeira mudança do serviço. Portanto, todo candidato é descoberto pelo
framework Yuruna ou informado pelo operador; um ambiente que não produza nenhuma
dessas opções não tem stash para os fins da execução.

<a id="42010605-00af"></a>

<a id="refuse-concurrent-runner"></a>

### Recuse um executor simultâneo

`amisad.dev/test/Clear-Lab.ps1`

Apenas em execução independente. Dentro de um ciclo do executor, a orquestração
invoca este script como etapa de remoção (initialize-lab); o executor DEVE estar
ativo: $env:YURUNA_CYCLE_CONTEXT — publicado pelo orquestrador antes de cada etapa
e herdado por este pwsh filho (ausência significa execução independente;
veja Get-CycleContext) — identifica essa invocação dentro do ciclo e ignora a
proteção. Sem ele, um operador executou manualmente, e a proteção continua
recusando concorrer com as VMs de um ciclo ativo.

<a id="42010605-00b0"></a>

<a id="tear-down-the-amisad-poc-lab-to-a-known-clean-host-remove-every-amisad--vm-and-its-storage-then"></a>

### Remova o laboratório POC do AmisAd para deixar o hospedeiro limpo: remova toda VM amisad-* (e seu armazenamento), depois

`amisad.dev/test/Clear-Lab.ps1`

A metade de remoção da execução ponta a ponta (Initialize-Lab.ps1 a reconstrói).
Etapas, em ordem:

  1. Verifique que este hospedeiro consegue operar o próprio hipervisor
     (veja PRIVILÉGIO abaixo), para que uma permissão ausente falhe aqui com
     a solução, não na primeira remoção com a mensagem bruta do hipervisor.
  2. Recuse executar se um executor Yuruna for proprietário de runner.pid —
     haveria concorrência com as VMs do ciclo ativo.
  3. Feche consoles do laboratório que tirariam o foco de teclado da interface
     (apenas Hyper-V; veja Stop-LabConsole).
  4. Entregue toda a remoção a Remove-TestVMFiles.ps1 do framework, com o
     prefixo de nomes de VM do laboratório.

Toda remoção de VM fica no framework: Remove-TestVMFiles.ps1 enumera, força a
parada e remove toda VM cujo nome começa com o prefixo; depois limpa arquivos
órfãos e encerra com código não zero se algo sobreviver. Esse único caminho é
exercitado por todo projeto em todo tipo de hospedeiro; o projeto não mantém
lista de VMs nem lógica própria de remoção — um defeito de remoção é corrigido
uma vez no framework, para todos.

PRIVILÉGIO é verificado no runtime contra o hospedeiro DETECTADO, em vez de
ser declarado por '#requires -RunAsAdministrator': o necessário para remover uma
VM varia por hospedeiro — Administrator no Hyper-V, associação ao grupo libvirt
no KVM, sessão utmctl do próprio usuário no UTM —; um requisito estático é
interpretado como "root" no Linux/macOS e recusaria justamente os hospedeiros
que o script pretende atender. Test-HostRequirement pergunta ao driver o que
se aplica e explica o que falta.

<a id="42010605-00b1"></a>

<a id="authorize-demo-public-key"></a>

### Autorize a chave pública de demonstração

`amisad.dev/test/Initialize-Lab.ps1`

vm-core gerou o par de chaves durante a implantação, depois da construção das
bordas; elas não podiam receber a chave no provisionamento. Apenas a metade
PÚBLICA é transportada, lida de vm-core e gravada em authorized_keys de cada
borda pelo canal SSH do ambiente de testes (o mesmo de toda outra ação em convidados);
a metade privada permanece em vm-core, e nada da chave passa pelo HTTP do
status service. O login é então comprovado a partir de vm-core pelo mesmo
motivo de esperar os relatórios de IP das bordas acima: um cenário não relata
utilmente uma confiança ausente, apenas falha no primeiro ssh à borda.

<a id="42010605-00b2"></a>

<a id="where-a-stages-stdoutstderr-are-written-a-stage-log-is-the-only-record-of-the-provisioning-half-o"></a>

### Onde stdout/stderr de uma etapa são gravados. O log da etapa é o único registro da metade de provisionamento

`amisad.dev/test/Initialize-Lab.ps1`

Onde stdout/stderr de uma etapa são gravados. O log da etapa é o único registro
da metade de provisionamento — verificação de imagem base, criação da VM,
primeira inicialização —, pois a transcrição da sequência gravada por uma
execução de convidado começa na mensagem da sequência, depois de tudo isso.
Essa evidência esclarece falhas de inicialização e mídia no convidado; por isso,
deve sobreviver onde quer que os artefatos do ciclo sejam lidos: um diretório
temporário do sistema não faz parte do que o operador envia quando um ciclo
falha e é o primeiro a desaparecer na reinicialização da máquina.

A pasta do ciclo vem do identificador YURUNA_CYCLE_CONTEXT publicado pelo
framework para os processos filhos de uma ação no hospedeiro; sua ausência
indica uma execução independente sem ciclo no qual gravar, usando o diretório
temporário como alternativa. O próprio manifesto do ciclo enumera a pasta
recursivamente, portanto nada precisa ser registrado.

<a id="42010605-00b3"></a>

<a id="build--start-the-amisad-poc-topology-on-a-clean-host-the-warm-up-half-of-the-end-to-end-pass-cl"></a>

### Construa e inicie a topologia POC do AmisAd em um hospedeiro limpo (a metade de aquecimento da execução ponta a ponta; Cl

`amisad.dev/test/Initialize-Lab.ps1`

Adapta as etapas de construção de poc/build/run-tests.ps1 (tudo exceto o laço de
cenários, gerenciado pela sequência de orquestração amisad.end-to-end.yml).
Pressupõe que o hospedeiro já esteja limpo (Clear-Lab.ps1 executado) e
<RepoRoot>/project já clonado (Debug-TestSequence, ao executar a orquestração,
clona uma vez; as construções de convidados usam -NoProjectClone).
Etapas, em ordem:

  0. Exclua uma chave privada de demonstração na árvore servida pelo status service
     (está exposta; vm-core gera seu próprio par e mantém a metade privada).
  1. Resolva o stash service e publique seu endereço para o ciclo
     (descoberto ou fixado; sem stash, a execução para imediatamente).
  2. Construa uma vez: compile e envie binários ao stash (amisad-build).
  3. VMs de borda: provisione e salve snapshots de amisad-edge-a / -b, reduza a 4GB.
  4. vm-core: k8s + PostgreSQL + NATS + implantação de 10 serviços + usuários de
     demonstração, incluindo o par de chaves core->edge (gerado dentro de vm-core).
  5. Inicie ambas as bordas e aguarde seus relatórios de IP da inicialização
     (handoff/*.ip.txt novos usados pelos cenários para resolver a borda).
  6. Autorize a metade PÚBLICA da chave de demonstração de vm-core em ambas as
     bordas pelo canal SSH do ambiente de testes e comprove que vm-core entra em cada uma.

Mantém amisad-core e ambas as bordas em execução.

PRIVILÉGIO é verificado no runtime contra o hospedeiro DETECTADO, em vez de
ser declarado por '#requires -RunAsAdministrator': o necessário para construir
uma VM varia por hospedeiro — Administrator no Hyper-V, associação ao grupo
libvirt no KVM, sessão utmctl do próprio usuário no UTM —; um requisito estático
é interpretado como "root" no Linux/macOS e recusaria justamente os hospedeiros
que o script pretende atender. Test-HostRequirement pergunta ao driver o que
se aplica e explica o que falta.

PORTABILIDADE. O ciclo de vida de VMs passa pelo contrato de hospedeiro do Yuruna
(Get-VMState / Start-VM / Stop-VMForce, carregado por Initialize-AmisAdHost);
nenhuma etapa identifica um hipervisor. Restam dois AJUSTES específicos do
Hyper-V, cada um protegido e intencionalmente inativo nas demais plataformas,
não por omissão:

  * Remoção da mídia de instalação e nova captura de checkpoint. Uma VM
    Hyper-V renomeada/restaurada mantém referências ABSOLUTAS ao diretório do
    DVD de autoinstall; ciclos seguintes o sobrescrevem com arquivos cujas
    ACLs pertencem a uma VM mais nova, e a antiga falha ao iniciar com
    0x80070005. KVM e UTM anexam a seed do cloud-init por caminho a cada
    inicialização, sem herança de ACL; não há nada a remover.
  * Redução da borda para 4GB. Hyper-V tem Set-VM em execução; no KVM/UTM,
    o tamanho do convidado é uma propriedade do provisionamento (a variável
    memoryStartupBytes da sequência), portanto não pode — nem precisa —
    ser alterado depois.

<a id="42010605-00b4"></a>

<a id="resolved-relative-to-this-files-folder-test-run-in-order-the-pass-stops-if-either-script-exits"></a>

### Resolvidos em relação à pasta deste arquivo (test/), executados em ordem; a execução para se qualquer script sair

`amisad.dev/test/initialize-lab.yml`

Resolvidos em relação à pasta deste arquivo (test/), executados em ordem;
a execução para se qualquer script retornar código não zero.

elevated: true é a checagem prévia do orquestrador no Windows — recusa um shell
sem elevação antes de iniciar o pwsh filho, informando imediatamente um operador
do Hyper-V, em vez de após a primeira chamada de VM falhar. É intencionalmente
inativo no KVM/UTM (elevação ali significa sudo/polkit, não um token Administrator):
cada script verifica o que SEU PRÓPRIO hospedeiro detectado realmente exige
por Test-HostRequirement.

<a id="42010605-00b5"></a>

<a id="authorize-demo-public-key-1"></a>

### Autorize a chave pública de demonstração

`amisad.dev/poc/build/run-tests.ps1`

amisad-core gerou o par de chaves durante a implantação, depois da construção
das bordas; só agora elas podem recebê-lo. Apenas a metade PÚBLICA é transportada,
lida de amisad-core e gravada em authorized_keys de cada borda pelo canal SSH do
ambiente de testes; a metade privada permanece em amisad-core. O login é comprovado a partir
de amisad-core para que uma confiança ausente interrompa a execução aqui,
não no ssh à borda do primeiro cenário.

<a id="42010605-00b6"></a>

<a id="clean-start"></a>

### Início limpo

`amisad.dev/poc/build/run-tests.ps1`

Toda a limpeza cabe ao framework: Remove-TestVMFiles.ps1 enumera, força a parada
e remove toda VM cujo nome começa com um dos prefixos, pelo contrato de hospedeiro;
depois limpa arquivos órfãos para remover diretórios de armazenamento por VM
deixados pela retirada do registro (um diretório remanescente causaria colisão na
renomeação por saveDiskSnapshot da próxima cadeia). O atual 'amisad-' e o antigo
'amisad.' cobrem a topologia; 'test-' cobre as VMs transitórias de provisionamento
do framework. Não manter aqui lista de VMs nem lógica de remoção faz um defeito
ser corrigido uma vez no framework, para todo tipo de hospedeiro.

<a id="42010605-00b7"></a>

<a id="amisad-poc-test-automation-driver-builds-the-design-topology-and-runs-every-scenario-against-a-shar"></a>

### Driver de automação de testes POC do AmisAd: constrói a topologia do projeto e executa todos os cenários em um ambiente compartilhado

`amisad.dev/poc/build/run-tests.ps1`

Em uma falha, a execução para com tudo ativo para depuração; no sucesso,
amisad-core e ambas as bordas ficam ativos como ambiente de demonstração.
Os logs das etapas ficam sob -LogDir.

PORTABILIDADE. O ciclo de vida de VMs passa pelo contrato de hospedeiro do Yuruna
(Get-VMState / Start-VM / Stop-VMForce, carregado por Initialize-AmisAdHost),
e a limpeza inicial usa Remove-TestVMFiles.ps1 do framework; nenhuma etapa
identifica um hipervisor. Restam dois AJUSTES específicos do Hyper-V, cada um
protegido e intencionalmente inativo nas demais plataformas, não por omissão:

  * Remoção da mídia de instalação e nova captura de checkpoint. Uma VM
    Hyper-V renomeada/restaurada mantém referências ABSOLUTAS ao diretório do
    DVD de autoinstall; ciclos seguintes o sobrescrevem com arquivos cujas
    ACLs pertencem a uma VM mais nova, e a antiga falha ao iniciar com
    0x80070005. KVM e UTM anexam a seed do cloud-init por caminho a cada
    inicialização, sem herança de ACL; não há nada a remover.
  * Redução da borda para 4GB. Hyper-V tem Set-VM em execução; no KVM/UTM,
    o tamanho do convidado é uma propriedade do provisionamento (a variável
    memoryStartupBytes da sequência), portanto não pode — nem precisa —
    ser alterado depois.

ELEVAÇÃO é verificada no runtime contra o hospedeiro DETECTADO, em vez de ser
declarada por '#requires -RunAsAdministrator': apenas host.windows.hyper-v
registra RequiresElevation, e um requisito estático exigiria root no KVM/UTM,
onde o framework usa deliberadamente associação ao grupo libvirt e a sessão
utmctl do próprio usuário.

<a id="42010605-0007"></a>

<a id="amisad-guest-readiness-and-scenarios"></a>

## Prontidão de convidados e cenários AmisAd

<a id="42010605-00b9"></a>

<a id="amisad-poc---vm-edge-a-region-a-slice-vm-install-a-boot-time-ip-reporter-posts-iptx"></a>

###  POC AmisAd — vm-edge-a (VM de partição da região A): instale um relator de IP na inicialização (envia <hostname>.ip.tx

`amisad.dev/poc/test/workload.guest.ubuntu.server.24.amisad-edge-a.baseline.yml`

POC AmisAd — vm-edge-a (VM de partição da região A): instale um relator de IP
na inicialização (envia <hostname>.ip.txt ao status server do hospedeiro), para
que amisad-core localize esta borda. Snapshot salvo como "amisad-edge-a";
slice-runtime é entregue a cada execução de cenário. A chave de demonstração
core->edge não é instalada aqui: vm-core a gera depois que as bordas existem,
e o driver do laboratório autoriza sua metade pública nesta VM pelo canal SSH
do ambiente de testes (poc/usernames.md).

<a id="42010605-00ba"></a>

<a id="the-snapshot-carries-deployment-and-pod-status-frozen-at-snapshot-time-so-every-readiness-signal-in"></a>

### O snapshot contém status de implantação e pod congelados no momento da captura; todo sinal de prontidão nele

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-core.ready.sh`

O snapshot contém status de implantação e pod congelados no momento da captura;
cada sinal de prontidão descreve contêineres já substituídos pela reinicialização.
Esperar esse status pode indicar sucesso enquanto a rede de pods ainda muda,
e uma regra NodePort que aponte para um pod antigo responde à conexão seguinte
com "No route to host". Reiniciar primeiro dá sentido à espera: rollout status
passa a informar uma geração criada após esta restauração e só termina quando
os pods que existem AGORA estão prontos e os endpoints por trás das regras
pertencem a eles. Os pares são endereçados por nome DNS do cluster; CoreDNS
também deve responder a partir de pods ativos. As duas reinicializações são
solicitadas antes de esperar qualquer uma, para que ocorram em paralelo.

<a id="42010605-00bb"></a>

<a id="amisad-poc---s001fulfillment-run-on-amisad-core-start-slice-runtime-on-the-real-edge-amisad-edge-"></a>

### POC AmisAd — s001.fulfillment em amisad-core: inicie slice-runtime na borda real (amisad-edge-

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-core.s001.fulfillment.sh`

POC AmisAd — execução s001.fulfillment em amisad-core: inicie slice-runtime na
borda real (amisad-edge-a, resolvida pelo relatório de IP de status-server),
prepare as ofertas de Elena, execute o caminho de sucesso de fechamento automático
de Maya e verifique o Target Verification Point COMPLETO. Os dez serviços já
estão implantados (snapshot amisad-core); os binários pré-compilados estão no
disco desde a implantação. EDGE_HOST (substituição opcional): destino ssh de
slice-runtime; não definido -> resolve amisad-edge-a; se não resolvido,
AMISAD_ALLOW_SINGLE_VM=1 é obrigatório para execução local.

<a id="42010605-00bc"></a>

<a id="amisad-poc---s002fitting-run-against-the-deployed-amisad-core-cluster-start-slice-runtime-seed-el"></a>

### POC AmisAd — s002.fitting no cluster amisad-core implantado: inicie slice-runtime e prepare os vestidos de El

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-core.s002.fitting.sh`

POC AmisAd — execução s002.fitting no cluster amisad-core implantado:
inicie slice-runtime, prepare os vestidos de Elena (um azul acinzentado),
ofertas de outro vendedor fora da faixa/depois do prazo e horários de prova;
execute a necessidade de vestido de Maya sob política MANUAL e verifique o
Target Verification Point COMPLETO: a seleção respeita todas as restrições,
inclusive exclusões; nada é confirmado antes da reserva explícita; comprador
e vendedor mantêm registros de agendamento consistentes e sem identidade;
o log de notificações tem exatamente duas entradas.

<a id="42010605-00bd"></a>

<a id="amisad-poc---s003silence-run-on-amisad-core-consent-revocation-and-the-right-to-silence-seed-one"></a>

### POC AmisAd — s003.silence em amisad-core: revogação de consentimento e direito ao silêncio. Prepare um

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-core.s003.silence.sh`

POC AmisAd — execução s003.silence em amisad-core: revogação de consentimento e
direito ao silêncio. Prepare um pedido em andamento e duas necessidades abertas;
pause a participação (revogação no ledger de consentimento), comprove que uma
nova oferta perfeitamente adequada não produz NADA (nenhum ambiente,
correspondência nem notificação), liquide normalmente o pedido anterior à
revogação, retire a participação (a agregação perde sua contribuição), retome
(as necessidades abertas voltam a ser atendidas imediatamente) e verifique o
Target Verification Point COMPLETO, inclusive o histórico imutável de
concessão-revogação-nova concessão. EDGE_HOST (substituição opcional): destino
ssh de slice-runtime.

<a id="42010605-00be"></a>

<a id="amisad-poc---s004failover-run-on-amisad-core-sovereign-slice-allocation-isolation-fault-attested"></a>

### POC AmisAd — s004.failover em amisad-core: alocação de partição soberana, falha de isolamento e failover atestado

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-core.s004.failover.sh`

POC AmisAd — execução s004.failover em amisad-core: alocação de partição soberana,
falha de isolamento e failover atestado. Ambas as bordas executam slice-runtime
com sua identidade de região; a política de Tom fixa a jurisdição restrita em
region-a, embora region-b tenha mais espaço. Duas falhas de isolamento injetadas
interrompem dois ambientes COM SEGURANÇA (interrupção atestada com motivo,
antes de qualquer abertura do envelope); a repetição automática do fabric conclui
a correspondência com exatamente uma liquidação. Ambos os incidentes entram
na fila de Tom, e o padrão sistêmico é escalado ao caso de plataforma de Priya
entre as partes. Este cenário EXIGE ambas as bordas — não há alternativa degradada.

<a id="42010605-00bf"></a>

<a id="amisad-poc---s005attribution-run-on-amisad-core-campaign-boosted-match-edge-creative-serving-and"></a>

### POC AmisAd — s005.attribution em amisad-core: correspondência impulsionada por campanha, conteúdo criativo servido na borda e

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-core.s005.attribution.sh`

POC AmisAd — execução s005.attribution em amisad-core: correspondência impulsionada
por campanha, conteúdo criativo servido na borda e crédito de atribuição.
Marcel cria uma campanha e um briefing; Kai produz um ativo aprovado;
Marcel o ativa; a necessidade de Maya na categoria da campanha corresponde à
oferta de Elena, impulsionada com o conteúdo de Kai (renderizado DENTRO do
ambiente selado). Na aceitação, a liquidação contém créditos não zero de agência
e criador; o orçamento da campanha diminui pelo compromisso por correspondência;
e nenhum sinal do comprador aparece no lado da campanha.
EDGE_HOST (substituição opcional): destino ssh de slice-runtime.

<a id="42010605-00c0"></a>

<a id="amisad-poc---s006mandate-run-on-amisad-core-delegated-procurement-under-a-scoped-mandate-maya-gra"></a>

### POC AmisAd — s006.mandate em amisad-core: compras delegadas por mandato com escopo. Maya concede

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-core.s006.mandate.sh`

POC AmisAd — execução s006.mandate em amisad-core: compras delegadas por mandato
com escopo. Maya concede a Pat um mandato de bens domésticos com limite por item;
Pat fecha por sua própria autoridade uma correspondência dentro do escopo e
abaixo do limite (atribuição dupla no histórico de Maya). Uma correspondência
acima do limite fica RETIDA até a aprovação de Maya; uma necessidade fora do
escopo é recusada na submissão, com zero ambientes e zero entradas de ledger;
a revogação remove a autoridade delegada imediatamente.
EDGE_HOST (substituição opcional): destino ssh de slice-runtime.

<a id="42010605-00c1"></a>

<a id="amisad-poc---s007inventory-run-on-amisad-core-enterprise-integration-onboarding-and-inventory-trut"></a>

### POC AmisAd — s007.inventory em amisad-core: integração empresarial e correspondência baseada no estoque real

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-core.s007.inventory.sh`

POC AmisAd — execução s007.inventory em amisad-core: integração empresarial e
correspondência baseada no estoque real. Alex registra e certifica um conector;
Elena concede credenciais com escopo; o conector sincroniza o catálogo ERP e
uma alteração de estoque que zera a última unidade de um item. A necessidade
de um comprador corresponde então apenas à alternativa em estoque;
eventos do ciclo de vida do pedido são espelhados idempotentemente no ERP;
uma chamada fora do escopo é recusada e registrada; a revogação invalida as
credenciais. EDGE_HOST (substituição opcional).

<a id="42010605-00c2"></a>

<a id="amisad-poc---s008mediation-run-on-amisad-core-zero-knowledge-dispute-mediation-and-settlement-adju"></a>

### POC AmisAd — s008.mediation em amisad-core: mediação de disputa sem conhecimento e ajuste de liquidação

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-core.s008.mediation.sh`

POC AmisAd — execução s008.mediation em amisad-core: mediação de disputa sem
conhecimento e ajuste de liquidação. A partir de um pedido liquidado,
Maya informa a não entrega; um caso de suporte é aberto com apenas metadados
operacionais (sem identidade do comprador). Sam solicita, e Maya concede,
uma divulgação com escopo e prazo; o reembolso é registrado como entradas
compensatórias de liquidação que referenciam o caso (histórico original
intocado). Após a concessão expirar, o artefato divulgado deixa de ser acessível.
EDGE_HOST (substituição opcional).

<a id="42010605-00c3"></a>

<a id="amisad-poc---s009suppression-run-on-amisad-core-aggregate-insight-publication-and-the-demand-plann"></a>

### POC AmisAd — s009.suppression em amisad-core: publicação de informações agregadas e ciclo de planejamento da demanda

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-core.s009.suppression.sh`

POC AmisAd — execução s009.suppression em amisad-core: publicação de informações
agregadas e ciclo de planejamento da demanda. Prepare demanda em uma região de
alto volume (acima do limiar de anonimato) e em outra abaixo do limiar;
comprove que a região abaixo é SUPRIMIDA (ausente, não zerada) da bancada de Dana,
da projeção publicada e versionada e das visões de Elena como vendedora e
Marcel em anúncios — todas com números idênticos. Sem borda/correspondência.

<a id="42010605-00c4"></a>

<a id="amisad-poc---s010certification-run-on-amisad-core-independent-certification-of-the-full-evidence-t"></a>

### POC AmisAd — s010.certification em amisad-core: certificação independente de todo o histórico de evidências

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-core.s010.certification.sh`

POC AmisAd — execução s010.certification em amisad-core: certificação independente
de todo o histórico de evidências. Como cada cenário restaura um snapshot novo,
esta execução PREPARA SEUS PRÓPRIOS DADOS representativos para exercitar as quatro
dimensões de auditoria — uma correspondência concluída e uma interrupção injetada
(atestação e residência), concessão/revogação de consentimento e um mandato
(consentimento, todos os tipos de concessão), e uma concessão de divulgação com
ajuste de liquidação (consentimento e conservação da liquidação). Depois,
audit-svc de Ingrid verifica novamente, de forma independente, as cadeias de
hashes, localiza uma adulteração deliberada e comprova que só fez leituras.
EDGE_HOST (substituição opcional): destino ssh de slice-runtime.

<a id="42010605-00c5"></a>

<a id="amisad-poc---vm-core-demo-users-add-the-non-administrator-persona-accounts-maya-elena-buyerssell"></a>

### POC AmisAd — usuários de demonstração de vm-core: acrescente contas de personas sem administração (maya, elena compradores/vendedores

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-core.users.sh`

POC AmisAd — usuários de demonstração de vm-core: acrescente as contas de personas
sem administração (maya, elena compradores/vendedores; tom, priya operadores;
marcel, kai agência e criador — s005; pat delegado — s006; alex parceiro de
integração — s007; sam suporte — s008; dana analista — s009; ingrid auditora — s010)
e gere o par de chaves SSH de demonstração core->edge para o administrador,
permitindo que os scripts dos cenários enviem slice-runtime às VMs de borda por
scp/ssh. O par é criado AQUI, e a chave privada nunca sai desta VM: não é obtida
do status service do hospedeiro nem enviada a ele (que serve seus arquivos a
toda a LAN). Só a metade pública atravessa até as bordas, levada pelo hospedeiro
no canal SSH do ambiente de testes quando ambas existem (test/AmisAd.Lab.psm1 Sync-AmisAdDemoKey).
As senhas são definidas em uma etapa de sequência sshExec sensível separada
(renderizada do vault, mascarada), nunca passadas a este script.
Executa como administrador (sudo sem senha).

<a id="42010605-00c6"></a>

<a id="boot-only-reporting-publishes-the-address-this-vm-had-when-it-started-and-amisad-core-reads-that-fi"></a>

### Relatar apenas na inicialização publica o endereço que esta VM tinha ao iniciar, e amisad-core lê esse arquivo

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-edge.setup.sh`

Relatar apenas na inicialização publica o endereço que esta VM tinha ao iniciar,
e amisad-core lê esse arquivo para encontrar a borda durante todo o ciclo.
Com uma concessão DHCP curta, nenhuma ponta mantém o endereço por um ciclo;
um relatório nunca repetido fica desatualizado e bloqueia o cenário — que
recusa degradar para uma única VM, em vez de fingir silenciosamente sucesso.
Reenviar o relatório exige um pequeno PUT; o intervalo fica bem dentro do tempo
entre a mudança de endereço e o próximo cenário precisar dele.

<a id="42010605-00c7"></a>

<a id="amisad-poc---edge-vm-setup-shared-by-amisad-edge-ab-install-a-boot-time-ip-reporter-that-posts-"></a>

### POC AmisAd — preparação da VM de borda (compartilhada por amisad-edge-a/b): instale um relator de IP na inicialização que envia <

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-edge.setup.sh`

POC AmisAd — preparação da VM de borda (compartilhada por amisad-edge-a/b):
instale um relator de IP na inicialização que envia <hostname>.ip.txt ao
status service do hospedeiro, para que amisad-core localize esta borda.
O runtime da partição é entregue a cada cenário — a VM de borda permanece sem estado.

A chave de demonstração core->edge NÃO é instalada aqui. vm-core gera o par
(depois da construção das bordas) e mantém a metade privada; o hospedeiro
então autoriza a metade PÚBLICA em authorized_keys desta VM pelo canal SSH do
ambiente de testes (test/AmisAd.Lab.psm1 Sync-AmisAdDemoKey). Nenhuma parte da chave é obtida
pelo HTTP do status service, onde uma resposta de qualquer participante da
LAN seria aceita.

<a id="42010605-0008"></a>

<a id="verified-downloads-and-stash-delivery"></a>

## Downloads verificados e entrega ao stash

As três cópias de `amisad_host_fetch` releem os endereços do hospedeiro a cada
tentativa. Uma falha forçada do resolvedor interrompe a repetição e mantém seu
stderr no log do convidado; não se deve tentar novamente um endereço antigo
ocultando a falha na descoberta de um novo.

<a id="42010605-00c9"></a>

<a id="the-stash-records-the-upload-usernameamisad-poc-filenameamisad--binariestgz-for-later-in"></a>

### O stash registra o envio (username=amisad-poc, filename=amisad-<arch>-binaries.tgz) para investigação posterior

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-build.compile.sh`

O stash registra o envio (username=amisad-poc, filename=amisad-<arch>-binaries.tgz)
para investigação posterior; amisad-core o localiza por esse rótulo.
Apenas scp (o servidor SSH do stash aceita o envio); não exige chave — é um
destino somente de escrita. STASH_HOST estava acessível na checagem prévia
acima, garantia mais fraca do que parece: era um HTTP GET, não esta transferência.

Repetição limitada, no formato já usado por amisad_host_fetch acima.
Qualquer falha desse envio chega ao cliente como o genérico "lost connection"
de scp — o servidor fecha o canal sem informar motivo; daqui, uma interrupção
de transporte e uma recusa de envio pelo servidor são indistinguíveis.
Repetir é correto para ambas: cria uma nova conexão, e o servidor aloca um
identificador novo para a sessão. O limite é de três tentativas, para que um
destino realmente indisponível ainda faça a etapa falhar, em vez de repetir
indefinidamente.

O stderr de scp é capturado por tentativa e reexibido sob seu rótulo, pois a
transcrição do ciclo intercala vários convidados: um simples "lost connection"
nesse fluxo não pode ser associado à tentativa que o emitiu, e uma repetição
silenciosa parece um travamento.

<a id="42010605-00ca"></a>

<a id="what-this-establishes-the-address-is-populated-and-the-host-answers-on-the-bridged-lan-from-this-gu"></a>

### O que isso comprova: o endereço está preenchido, e o hospedeiro responde na LAN em ponte a partir do NAT deste convidado

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-build.compile.sh`

O que isso comprova: o endereço está preenchido, e o hospedeiro responde na LAN
em ponte a partir do NAT deste convidado. É a falha que vale detectar antes de
uma construção de ~20 minutos — um endereço errado ou sem rota custa a construção
inteira. O que NÃO comprova: /healthz é servido apenas pelo listener HTTP e não
informa nada sobre sshd em :22, o compartilhamento de destino nem o índice de
metadados que registra o envio. Um GET de poucos bytes também não equivale a
uma transferência de vários megabytes. Uma verificação aprovada ainda permite
que o envio falhe; por isso, o envio tem repetição própria, sem confiar neste
resultado. Sem endereço padrão: o chamador fornece um que já verificou;
adivinhar aqui enviaria binários de uma construção a quem respondesse na rede
de alguém.

<a id="42010605-00cb"></a>

### amisad_sha256

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-build.compile.sh`

fetch-and-execute verificou ESTE script contra um SHA-256 informado pelo
hospedeiro no comando de execução. Tudo que este script baixa e depois extrai,
instala ou entrega a um programa é uma resposta HTTP simples de um serviço LAN;
por isso, é verificado aqui contra um SHA-256 levado pelo mesmo comando
(o texto command: da sequência, preenchido por ${ext:digest....} no hospedeiro)
ANTES do uso. O digest é a fronteira de confiança; o transporte não.
Um digest vazio recusa o download; AMISAD_ALLOW_UNVERIFIED=1 é a substituição
explícita para execução manual, e nenhuma sequência a define.
poc/test/download_contracts.py mantém as três cópias iguais.

<a id="42010605-00cc"></a>

<a id="amisad-poc---amisad-build-compile-step-build-every-release-binary-and-upload-the-tarball-to-the-sta"></a>

### POC AmisAd — compilação em amisad-build: construa todos os binários de release e envie o tarball ao stash

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-build.compile.sh`

POC AmisAd — compilação em amisad-build: construa todos os binários de release e
envie o tarball ao stash service para amisad-core baixar e implantar.
Esta VM tem as ferramentas Rust, mas não Kubernetes; produz artefatos, não os
executa. STASH_HOST: o stash service que recebe os binários. OBRIGATÓRIO e sem
padrão — a sequência o fornece por ${ext:stash-service.ResolveHost(...)},
que retorna o endereço resolvido e confirmado em /healthz no aquecimento do ciclo.
Uma execução que chegue aqui sem endereço publicado para imediatamente, em vez
de enviar binários a um hospedeiro presumido.
AMISAD_PROJECT_ARCHIVE_SHA256: o SHA-256 do tarball do projeto baixado e construído
por este script. A sequência o fornece por ${ext:digest.GetArchiveSha256(project)};
o tarball é verificado antes da extração (veja "Verified nested downloads" em
poc/test.md). AMISAD_ALLOW_UNVERIFIED=1 dispensa um digest ausente em execução manual.

<a id="42010605-00cd"></a>

<a id="retried-for-the-same-reason-the-rustup-install-above-is-a-single-empty-reply-from-server-through"></a>

### Repetido pelo mesmo motivo da instalação rustup acima: uma única resposta "empty reply from server" pelo

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-build.tools.sh`

Repetido pelo mesmo motivo da instalação rustup acima: uma única resposta
"empty reply from server" pelo proxy do laboratório — falha transitória que
realmente ocorre — encerraria o script sob `set -e` e custaria o ciclo inteiro,
depois de Rust já ter sido instalado corretamente.

O download não tem privilégios, e a instalação é a única etapa privilegiada.
Colocar sudo dentro da unidade repetida impediria distinguir se a falha foi no
download ou na elevação; curl gravando diretamente em /usr/local/bin deixa um
binário truncado após uma transferência parcial.

bazelisk é fixado em uma versão, não no que "latest" indicar no dia da execução,
pois só vale verificar um executável instalado como root se existir um arquivo
definido contra o qual compará-lo. Atualize a versão e ambos os digests juntos;
a página de release informa o SHA-256 de cada artefato. O download fica em um
diretório privado, impedindo que outro usuário local o troque entre a verificação
e a instalação.

<a id="42010605-00ce"></a>

### amisad_verify_pinned

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-build.tools.sh`

rustup-init, bazelisk e o servidor NATS são baixados de seus publicadores e depois
executados ou instalados como root; cada um é verificado antes do uso contra
um SHA-256 fixado NESTE script. Os valores são dos próprios publicadores
(o arquivo .sha256 de cada rustup-init, o digest de cada artefato de release de
bazelisk e SHA256SUMS da versão de NATS), registrados ao escolher a versão.
Ficam em um script verificado por fetch-and-execute contra o digest informado
pelo hospedeiro no comando de execução; são tão confiáveis quanto o script.
Uma divergência exclui o download, para que a unidade repetida o baixe novamente.

<a id="42010605-00cf"></a>

<a id="amisad-poc---create-the-amisad-database-load-the-schema-and-open-the-instance-to-in-cluster-pods"></a>

### POC AmisAd — crie o banco amisad, carregue o esquema e abra a instância para pods do cluster:

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-core.db.sh`

POC AmisAd — crie o banco amisad, carregue o esquema e abra a instância para pods
do cluster: papel 'amisad' (senha fixa do laboratório, passada em DATABASE_URL
— veja poc/test.md), listen_addresses '*', pg_hba para as redes de pods e nós.
O papel NÃO recebe UPDATE/DELETE nas tabelas de ledger — o próprio banco impõe
apenas acréscimos. O esquema é obtido do status service do hospedeiro em um
diretório privado e entregue a psql por stdin, pois o usuário postgres não lê
o diretório pessoal 0750 do usuário de login, e uma cópia legível por todos
em /tmp poderia ser trocada após a verificação do digest.
AMISAD_SCHEMA_SHA256: o SHA-256 de poc/db/schema.sql como servido pelo hospedeiro.
A sequência o fornece por ${ext:digest.GetFileSha256(project/poc/db/schema.sql)};
o esquema executa como superusuário postgres, portanto é verificado antes que
psql veja qualquer byte (veja "Verified nested downloads" em poc/test.md).
AMISAD_ALLOW_UNVERIFIED=1 dispensa um digest ausente em execução manual.

<a id="42010605-00d0"></a>

<a id="wait-reports-only-that-the-condition-never-arrived-so-on-its-own-a-failure-here-says-a-deployment"></a>

### `wait` só informa que a condição nunca chegou; uma falha aqui, sozinha, diz que uma implantação

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-core.deploy.sh`

`wait` só informa que a condição nunca chegou; uma falha aqui, sozinha, diz que
uma implantação está travada, sem explicar por quê — e a VM é removida antes
que alguém possa examiná-la. Exiba o que o cluster já sabe: a fase do pod,
os eventos de agendamento/obtenção de imagem e o que o contêiner escreveu antes
de falhar bastam, cada um por si, para identificar a causa. Toda verificação é
de melhor esforço; a saída abaixo é o resultado real.

<a id="42010605-00d1"></a>

<a id="--noproxy--the-stash-ip-is-not-in-the-guest-no_proxy-list-so-an-http-get-would-otherwise-be-sen"></a>

### --noproxy '*': o IP do stash não está na lista no_proxy do convidado; um HTTP GET seria enviado

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-core.deploy.sh`

--noproxy '*': o IP do stash não está na lista no_proxy do convidado; um HTTP GET
seria enviado pelo squid. O rótulo inclui a arquitetura (amisad-<arch>-binaries;
veja "Stash artifact naming" em poc/test.md): corresponda apenas ao nosso
uname -m. /api/stashes retorna do mais novo ao mais antigo; a construção desta
execução é o envio mais novo sob esse rótulo, a menos que outra execução ou
hospedeiro tenha enviado depois; amisad_fetch_stash_binaries o seleciona pelo digest.
Sem endereço padrão: o chamador fornece um já verificado; adivinhar aqui
baixaria executáveis de quem respondesse na rede de alguém.

<a id="42010605-00d2"></a>

### amisad_fetch_stash_binaries

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-core.deploy.sh`

amisad_fetch_stash_binaries <stash base url> <label> <dest file>
Obtém o envio mais novo de stash sob <label> cujo SHA-256 corresponda ao lido
pelo hospedeiro na VM de construção (AMISAD_BINARIES_SHA256), examinando os dez
mais novos: o stash é compartilhado por todo o laboratório, e outra execução ou
hospedeiro pode ter enviado o mesmo rótulo após a construção desta execução.
Retorna 3 quando o stash não lista nada para o rótulo e 7 quando nenhum envio
é verificado. Sem digest definido, apenas o mais novo é candidato,
e amisad_verify_download decide se ele pode ser usado.

<a id="42010605-00d3"></a>

<a id="amisad-poc---amisad-core-deploy-step-download-the-prebuilt-binaries-from-the-stash-service-produce"></a>

### POC AmisAd — implantação em amisad-core: baixe os binários pré-compilados do stash service (produzidos

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-core.deploy.sh`

POC AmisAd — implantação em amisad-core: baixe os binários pré-compilados do
stash service (produzidos por amisad-build), crie imagens distroless pequenas
com eles e implante os dez serviços no cluster Kubernetes da VM.
Esta VM tem a pilha de runtime (Docker+containerd+kubeadm K8s+Helm+PostgreSQL+NATS
da baseline amisad-core-k8s) e python3 — mas NÃO tem ferramentas Rust nem
construção de código-fonte. STASH_HOST: o stash service de onde obter binários.
OBRIGATÓRIO e sem padrão — a sequência o fornece por
${ext:stash-service.ResolveHost(...)}, que retorna o endereço resolvido e
confirmado em /healthz no aquecimento do ciclo. Uma execução que chegue aqui
sem endereço publicado para imediatamente, em vez de obter executáveis de um
hospedeiro presumido.
AMISAD_PROJECT_ARCHIVE_SHA256 e AMISAD_BINARIES_SHA256: os SHA-256 do tarball do
projeto e do tarball de binários baixados e depois extraídos por este script.
A sequência fornece o primeiro por ${ext:digest.GetArchiveSha256(project)} e
o segundo por ${ext:digest.GetPublishedSha256(amisad-binaries)} (o digest lido
pelo hospedeiro na VM de construção após o envio). Cada download é verificado
antes da extração; os binários executam nos pods como root, por isso esse é o
mais importante (veja "Verified nested downloads" em poc/test.md).
AMISAD_ALLOW_UNVERIFIED=1 dispensa um digest ausente em execução manual.

<a id="42010605-0009"></a>

<a id="demo-credentials-and-request-serving"></a>

## Credenciais de demonstração e atendimento de solicitações

<a id="42010605-00d5"></a>

<a id="the-vault-passwords-are-the-one-thing-here-that-must-not-travel-further-than-the-operator-intends-s"></a>

### As senhas do vault são o único item aqui que não deve ir além da intenção do operador

`amisad.dev/poc/demo/data-view/serve-data-view.ps1`

As senhas do vault são o único item aqui que não deve ir além da intenção do
operador; por isso são controladas por SOLICITAÇÃO, não por vinculação:
abrir o console à rede ainda deixa o navegador do próprio hospedeiro com todas
as funções, e visitantes remotos veem os cards sem os segredos.
O journal só permite acréscimos em memória, com sequência monotônica.
Os clientes consultam com o maior seq que possuem; um 'latest' menor indica
que este processo reiniciou e que a visão deve ser reconstruída do zero.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.
