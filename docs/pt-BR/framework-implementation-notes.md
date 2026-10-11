<a id="4213a0b3-0001"></a>

<a id="framework-implementation-notes"></a>

# Notas de implementação do framework

Estas notas preservam a justificativa vinculada a partir das fontes de automação
compartilhada e do executor de testes. Siga o contrato de consistência com o código-fonte
ao alterar os blocos correspondentes.

<a id="4213a0b3-0002"></a>

<a id="automationcheck-dependencyversionps1-host-tool-floors-from-yurunarequirementyml"></a>

## automation/Check-DependencyVersion.ps1: Versões mínimas das ferramentas do hospedeiro em Yuruna.Requirement.yml

Versões mínimas das ferramentas do hospedeiro em Yuruna.Requirement.yml. São as
versões usadas para verificar um hospedeiro, não as versões que algo instala;
portanto, o avanço das versões upstream é informativo: nunca faz a execução falhar.
Sem elas, nada monitora o lado do hospedeiro, e uma versão mínima pode ficar
defasada por meses sem que ninguém perceba.

São listadas apenas ferramentas com um feed de versões upstream inequívoco.
Docker e Docker buildx ficam ausentes deliberadamente: ambos seguem o que o
Docker Desktop inclui, e não a tag upstream mais recente; portanto, compará-los
com o upstream indicaria desvio sempre, mesmo em uma máquina corretamente provisionada.

<a id="4213a0b3-0003"></a>

<a id="automationset-hostaliasps1-2-elevation--root-assertion"></a>

## automation/Set-HostAlias.ps1: 2. Asserção de elevação / root

Gravar o arquivo não encerra a alteração. O sistema operacional resolve nomes
a partir de um cache em memória que continua respondendo com o endereço
ANTERIOR depois que a linha correspondente do arquivo hosts mudou; no macOS,
essa janela é suficientemente longa para importar: mDNSResponder relê
/etc/hosts em seu próprio ritmo, portanto um consumidor que resolve o nome
algumas centenas de milissegundos após a gravação ainda alcança o hospedeiro antigo.

O dano é maior exatamente para a edição que este script foi criado para fazer
-- redirecionar um nome de outra máquina para esta. O chamador acredita estar
conectando a um serviço local; a conexão, em vez disso, sai pela LAN para a
máquina que o nome DESIGNAVA e falha ali contra uma credencial, um compartilhamento
ou um certificado que só faz sentido localmente. Todos os detalhes visíveis
(nome do hospedeiro, caminho do compartilhamento, conta, ponto de montagem)
estão corretos enquanto isso ocorre, o que dificulta deduzir a causa a partir do erro.

Melhor esforço por decisão de projeto, e nunca fatal: um cache que não pode
ser limpo demora a convergir, em vez de estar quebrado, e um hospedeiro sem
resolvedor com cache (comum no Linux) não tem nada para limpar. A gravação já
foi concluída quando isto é executado, portanto nada aqui pode fazê-la falhar.

<a id="4213a0b3-0004"></a>

<a id="automationwindows-guest-bootstrapps1-git-does-not-read-gh_token----that-name-is-a-gh1-convention----so-the-token"></a>

## automation/windows-guest-bootstrap.ps1: git NÃO lê GH_TOKEN -- esse nome é uma convenção de gh(1) -- portanto o token

git NÃO lê GH_TOKEN -- esse nome é uma convenção de gh(1) -- portanto o token
sozinho deixa um `git clone` de repositório privado solicitando um nome de
usuário, o que trava um convidado não supervisionado. GIT_ASKPASS faz com que
clone/fetch/pull autentiquem sem alterar nenhum ponto de chamada; o shim .cmd
existe apenas porque GIT_ASKPASS deve nomear um executável, não uma função PowerShell.

Esta metade é condicionada, e o trabalho de coordenadas acima não é, nessa
ordem: um laboratório sem token configurado é exatamente aquele cujos
convidados mais precisam conseguir alcançar seu hospedeiro.
Suprima o prompt ANTES da condição do token, nunca depois. Windows é a pior
plataforma para errar nisso: Git Credential Manager responde à falta de uma
credencial com uma caixa de diálogo gráfica que o OCR que controla esse
convidado não consegue ler -- portanto a etapa esgota o tempo limite em uma
captura de tela que não mostra nada errado. Escopo da máquina pela mesma razão
usada para o token abaixo: um comando SSH não interativo não lê nenhum perfil.

<a id="4213a0b3-0005"></a>

<a id="automationyuruna-host-locateps1-how-hard-to-press-the-directory-once-the-baked-coordinate-is-dead"></a>

## automation/yuruna-host-locate.ps1: Quanto insistir no diretório depois que a coordenada incorporada deixa de funcionar

Quanto insistir no diretório depois que a coordenada incorporada deixa de
funcionar. O diretório recebe o novo endereço do hospedeiro do próprio
hospedeiro; portanto, um convidado que começa a resolver no instante de uma
renumeração pode receber o endereço que acabou de deixar de funcionar -- as
duas pontas disputam a mesma alteração. Espaçar algumas novas consultas ao
longo de cerca de dez segundos cobre essa lacuna, evitando que o ciclo termine.
Os nomes e padrões são os da biblioteca shell, portanto uma substituição
controla os dois pares; um valor que não é inteiro é ignorado, em vez de gerar
uma exceção, porque nada neste arquivo pode lançar uma exceção para seu chamador.

<a id="4213a0b3-0006"></a>

## automation/yuruna-host-locate.ps1: Invoke-YurunaHostLocate

O diretório recebe um novo endereço do hospedeiro; portanto, consultar no
instante em que o hospedeiro é renumerado retorna o endereço que acabou de
deixar de funcionar -- o convidado e o diretório disputam a mesma alteração.
Uma única tentativa perde essa disputa e envia o chamador para uma alternativa
que não pode ajudá-lo. Em vez disso, consulte novamente algumas vezes, com
intervalos que deem ao diretório tempo para se atualizar. Isso não custa nada
no caminho comum: a coordenada incorporada respondeu à verificação de atividade
acima e retornou antes de chegar aqui; portanto, só pagam esse custo os
chamadores que já ficaram sem outras opções.

<a id="4213a0b3-0007"></a>

## automation/Yuruna.Clear.psm1: Clear-Configuration

A desmontagem lê resources.output.yml (o manifesto do estado implantado,
condicionado por Test-Path abaixo) e destrói a partir das pastas de trabalho
.yuruna implantadas -- NÃO a partir do resources.yml de entrada e das pastas
de modelos que ele referencia. Bloquear a destruição pela validação de entrada
permitiria que um desvio no código-fonte após a implantação (pasta de modelo
renomeada/excluída, variável que agora se expande para vazio) deixasse o
operador com recursos que não consegue destruir, contrariando a limpeza
idempotente; portanto, a verificação de entrada é apenas um aviso aqui, e a
condição de resources.output.yml abaixo é a verdadeira pré-condição.

<a id="4213a0b3-0008"></a>

## automation/Yuruna.Clear.psm1: Clear-Configuration

Os nomes dos recursos implantados são as chaves de nível superior de
resources.output.yml, exceto globalVariables: Set-Resource grava esse mapa e
um bloco `<resourceName>: <tofu outputs>` antes de aplicar cada recurso sob
sua responsabilidade. Não existe uma lista `resources:` aqui -- esse formato
pertence ao resources.yml de entrada, e lê-lo não encontraria nada
silenciosamente e informaria uma desmontagem bem-sucedida que não destruiu
nenhum recurso. Duas propriedades do conjunto de chaves importam: um recurso
declarado com modelo vazio nunca é gravado aqui (apenas nomeia um recurso já
existente e não possui pasta de trabalho), portanto as chaves incluem
aplicações parciais que ainda precisam de desmontagem; e as chaves já têm
suas variáveis expandidas, correspondendo literalmente aos nomes das pastas
de trabalho .yuruna, portanto não devem ser expandidas uma segunda vez.

<a id="4213a0b3-0009"></a>

## automation/Yuruna.CloudInitTemplate.psm1: New-CloudInitUserData

As duas identidades que permitem a um convidado corrigir um endereço obsoleto
do hospedeiro. Os padrões são definidos aqui, em vez de por chamador, pela
mesma razão dos corpos dos scripts: todo seed quer a mesma resposta, e uma
cópia por chamador é uma oportunidade por chamador de gerar um convidado que
não consegue encontrar o caminho de volta. Um chamador com uma resposta melhor
ainda prevalece -- os seeds das VMs de serviço passam um hostId já resolvido.

Ambas são lidas do ambiente disponível, em vez de resolvidas pelos módulos
do ambiente de testes que as detêm, mantendo esta dependência terminal livre
de dependências (a mesma convenção flexível em tempo de chamada documentada
por Get-PortMapStatePath). Vazio é um resultado aceito, não uma falha: um
laboratório sem diretório de grupos gera valores vazios nos seeds, e seus
convidados se comportam exatamente como antes da existência dessa indireção.

<a id="4213a0b3-000a"></a>

## automation/Yuruna.Common.psm1: Get-ServiceVmMemoryVerdict

O que este operador pode efetivamente alterar, obtido do próprio plano. Um
controle que não se aplica à execução diante dele compromete a credibilidade
de toda a frase: um laboratório não pode definir storage.kind = none -- o
stash e o armazenamento de intenções precisam dos compartilhamentos --,
portanto essa opção nunca é oferecida a um laboratório.

Leia TODAS as linhas planejadas, não apenas aquelas com dimensionamento: um
serviço cujo construtor não pôde ser lido ainda é um serviço que esta execução
inicia e que o operador pode recusar.

<a id="4213a0b3-000b"></a>

## automation/Yuruna.Common.psm1: Invoke-BoundedNativeCommand

Ambos os fluxos e o sinal de saída são processados por esta única thread via
WaitAny, nunca por uma thread em segundo plano: scriptblocks PowerShell têm
afinidade com o runspace e não podem ser executados com segurança em uma thread
arbitrária do pool de threads .NET, como exigiria um delegado Task.Run puro.
Task.WaitAny abaixo nunca bloqueia além da quantidade de milissegundos recebida,
e GetAwaiter().GetResult() (equivalentemente .Result) só é lido de uma tarefa
que essa chamada já confirmou como concluída; ler o resultado de uma tarefa
inacabada bloquearia esta thread enquanto um descendente mantivesse o pipe aberto.

<a id="4213a0b3-000c"></a>

<a id="automationyurunahostredirectpsm1-runs-a-host-specific-script-from-a-host-neutral-entry-point-detect-the-host"></a>

## automation/Yuruna.HostRedirect.psm1: Executa um script específico do hospedeiro a partir de um ponto de entrada neutro: detecta o hospedeiro,

Executa um script específico do hospedeiro a partir de um ponto de entrada
neutro: detecta o hospedeiro, resolve host/<short>/<name>.ps1 e o executa em
um pwsh filho cujo diretório de trabalho É essa pasta do hospedeiro -- o mesmo
shell que um operador obtém ao usar cd para entrar nela e chamar ./<name>.ps1
manualmente. A localização do próprio chamador é restaurada na saída.

A detecção de hospedeiro NÃO é reimplementada aqui. Get-HostType / Get-HostFolder
(test/modules/Test.HostDetection.psm1) são a única definição usada na resolução
por todo o ambiente de testes; este módulo os importa sob demanda e nunca
mantém uma segunda cópia, porque uma segunda cópia é uma segunda resposta
no dia em que um novo tipo de hospedeiro é adicionado.

Nada aqui é específico dos quatro scripts que o usam hoje: -ScriptName aceita
qualquer script existente em todas (ou algumas) das pastas de hospedeiro.

<a id="4213a0b3-000d"></a>

<a id="automationyurunalogpsm1-the-one-definition-of-what-a-step-rule-looks-like"></a>

## automation/Yuruna.Log.psm1: A definição única do formato de uma regra de etapa.

A definição única do formato de uma regra de etapa.

A estrutura do documento da transcrição é construída a partir dessas linhas;
até o compartilhamento, o formato existia duas vezes: no orquestrador que
grava a regra e em uma regex aqui que a recupera. Duas cópias de um formato
divergem, e a falha é silenciosa da pior maneira -- a transcrição ainda é
renderizada, apenas fica sem títulos, então quem navega por dezenas de
quilobytes de um único <pre> perde todos os marcos e nada informa um problema.

Recuperar a estrutura do texto renderizado é a metade mais fraca da solução
e é mantida apenas pelo recurso de acessibilidade na própria página. A
estrutura legível por máquina é emitida como eventos estruturados ao lado da
transcrição, sem que um consumidor jamais precise ler a prosa.

<a id="4213a0b3-000e"></a>

## automation/Yuruna.Log.psm1: Write-Error

Repasse diretamente por splatting os parâmetros vinculados do próprio
chamador. Os conjuntos de parâmetros deste proxy espelham os de Write-Error
(NoException = Message, WithException = Exception [+ optional Message]),
portanto $PSBoundParameters sempre é uma invocação válida de Write-Error,
nunca uma combinação Message+Exception rejeitada por Write-Error. Copiá-lo
preserva os parâmetros comuns (-ErrorAction, -ErrorVariable, ...) que uma
reconstrução explícita por conjunto descartaria silenciosamente. (Não há
parâmetro InputObject para remover aqui -- isto é Write-Error, não o proxy
de Write-Output.) Forneça o ErrorAction efetivo quando omitido.

<a id="4213a0b3-000f"></a>

## automation/Yuruna.Resource.psm1: Publish-ResourceListHelper

Tente novamente apenas diante de um sinal transitório; um erro real de plano
ou de provisionador null_resource não corresponde ao classificador compartilhado
e falha rapidamente. docs/architecture.md#shared-transient-failure-retry-policy

Os closures capturam o comando e o predicado por valor porque o scriptblock
de nova tentativa é executado no escopo do módulo Yuruna.Retry, que não consegue
ver pelo nome a importação privada de Invoke-DynamicExpression deste módulo
-- portanto, capture seu CommandInfo aqui e invoque-o via &.

<a id="4213a0b3-0010"></a>

<a id="automationyurunaretrypsm1-shared-transient-failure-classifier-the-single-source-of-truth-for-is"></a>

## automation/Yuruna.Retry.psm1: Classificador compartilhado de falhas transitórias: a fonte única de verdade para "vale

Classificador compartilhado de falhas transitórias: a fonte única de verdade
para "vale a pena tentar novamente após esta falha?" em todas as fases que acessam a rede.
O que cada token cobre, por que um 500 isolado está na lista e as condições
por fase: docs/architecture.md#shared-transient-failure-retry-policy

Os códigos de status e EOF são reconhecidos como tokens delimitados por
palavras (\b429\b ... \b504\b, \bEOF\b), para que cada um corresponda sozinho
em qualquer contexto ao redor ("HTTP 500", um 500 isolado; "unexpected EOF",
um ": EOF" final), enquanto dígitos embutidos ("1500", "2500") e EOF dentro
de um token sem relação (EOFError em um stack trace) não correspondam.

Uma conexão recusada chega a este classificador em duas formulações distintas;
reconhecer apenas a do runtime Go deixa a ferramenta para a qual esta política
existe falhando rapidamente exatamente diante do sintoma que ela deveria
suportar. Go imprime a forma de errno, "connect: connection refused"; kubectl
captura o mesmo errno e o reformata em torno do hospedeiro da URL --
"The connection to the server
<host> was refused - did you specify the right host or port?" --, que não
compartilha nenhuma substring contígua com a primeira. Ambas nomeiam um par
que não estava escutando, como ocorre com um proxy ou registro reiniciando.

"server misbehaving" é a formulação do resolvedor Go para um upstream que
respondeu sem um registro nem um NXDOMAIN claro. É transitório pela mesma
razão de "no such host" ao lado: um resolvedor que está voltando responde
em uma tentativa posterior.

<a id="4213a0b3-0011"></a>

## automation/Yuruna.Validation.psm1: Confirm-WorkloadList

Duas cargas de trabalho que compartilham um contexto kube colidem:
Publish-WorkloadList limpa .yuruna/<subfolder>/workloads/<context> no início de
CADA carga de trabalho, então a segunda sobrescreve silenciosamente os charts/values
preparados pela primeira. Um chart também é implantado como release helm
<installName> em <context>, então duas implantações de charts que compartilham
ambas as chaves atingem a mesma release, e a segunda atualiza sobre a primeira
em vez de instalar uma carga de trabalho distinta -- detectado aqui como
defesa em profundidade (o helm install acontece antes de reutilizar qualquer
pasta), transformando uma sobrescrita confusa no cluster em um erro claro de
configuração. Rejeite duplicatas literais de copiar e colar e colisões após
a expansão (valores brutos distintos que resolvem para a mesma string),
espelhando a deduplicação de resources.yml.

<a id="4213a0b3-0012"></a>

<a id="testmodulesinvoke-poolstoragedrainps1-one-shot-poolstorage-drain-fired-detached-by-the-outer-loop-at-each-cycle-end"></a>

## test/modules/Invoke-PoolStorageDrain.ps1: Drenagem única de poolStorage, disparada de forma DESACOPLADA pelo laço externo no fim de cada ciclo

Drenagem única de poolStorage, disparada de forma DESACOPLADA pelo laço externo
no fim de cada ciclo (Test.RunnerOuterLoop.psm1) em um hospedeiro no modo COPY.
Ela drena a fila de pastas de ciclos ainda não arquivadas para o compartilhamento
SMB opcional (ypool-nas): falha rapidamente quando o NAS está inacessível,
operação atômica por ciclo, instância única por um arquivo de bloqueio adquirido
pelo orquestrador. Executa em seu próprio processo novo para que um NAS lento/ausente
nunca atrase o laço de ciclos e as importações de módulos comecem de um escopo
global limpo. O ambiente (YURUNA_CONFIG_PATH / YURUNA_RUNTIME_DIR / YURUNA_LOG_DIR)
é herdado do executor que a inicia; HostId é passado (com uma alternativa).

Um hospedeiro no modo MOVE não usa este script no caminho do ciclo: o
movimentador precisa executar de forma síncrona para que seu resultado possa
fazer o ciclo falhar, portanto o laço externo chama Invoke-PoolStorageDrain
no mesmo processo. A execução manual ainda funciona e respeita o modo indicado
pela configuração -- -MoveLogs é resolvido da configuração aqui para que uma
execução manual não arquive sob regras diferentes das usadas pelo executor.

<a id="4213a0b3-0013"></a>

<a id="testmodulesinvoke-testcyclerunnerps1-host-refresh-transport"></a>

## test/modules/Invoke-TestCycleRunner.ps1: Transporte de atualização do hospedeiro

Invocado sem capturar o fluxo de sucesso; o resultado tipado é lido por meio de
`Get-LastOuterCycleResult`, deixando a saída do ciclo no console do operador.
O processo de execução do ciclo inicia o interno com `Process.Start`, herda o
console sem redirecionar stdout ou stderr e usa `WaitForExit` para acompanhar
o encerramento do processo.

Na inicialização anterior pelo operador de chamada, capturar
`$result = Invoke-RunnerOuterCycle ...` fornecia ao interno um pipe anônimo
para stdout. O operador de chamada aguardava EOF, e o status service podia
manter esse pipe aberto após o interno sair: `Start-Process -RedirectStandard*`
habilitava a herança de handles, duplicando a extremidade de gravação no serviço.
O sintoma no Windows era um ciclo concluído, um log do interno dizendo
"about to exit with code 0" e nenhuma mensagem posterior "outer runner back in control".
O desacoplamento POSIX substituía esses descritores. A espera atual pelo
processo não depende de EOF no pipe.
<a id="4213a0b3-0014"></a>

<a id="testmodulesinvoke-testrunnerinnerloopps1-resolve-paths"></a>

## test/modules/Invoke-TestRunnerInnerLoop.ps1: Resolução de caminhos

O conjunto de módulos do tipo Inner inclui Test.SingleInstance, Test.YurunaDir,
Test.Extension, Test.HostContract, Test.Status, Test.Notify, Test.Provenance,
Test.Start-GuestOS, Test.Start-GuestWorkload, Test.Log, Test.SequencePlanner,
Test.CachingProxyService, Test.Perf, Test.HostIO, Test.Capability e Test.Transport.
Um auxiliar carrega tanto os módulos de bootstrap inicial quanto os módulos
de trabalho por ciclo, substituindo listas inline de Import-Module em cada
ponto. Test.Prelude.psm1 define o conjunto canônico; o executor interno o
carrega uma vez no início do arquivo. Cada ciclo inicia um novo processo
interno, portanto alterações no código-fonte se propagam sem um laço de
atualização no meio do ciclo.

<a id="4213a0b3-0015"></a>

<a id="testmodulesinvoke-testrunnerinnerloopps1-resolve-paths-1"></a>

## test/modules/Invoke-TestRunnerInnerLoop.ps1: Resolução de caminhos

Defensivo: se outro Start-TestRunner.ps1 (o externo) estiver em execução,
encerre-o e remova as VMs de teste abandonadas. O caminho normal de chamada é
o executor externo iniciar ESTE interno com YURUNA_RUNNER_RELAUNCH=1 -- nesse
caso, todo este bloco é ignorado (o externo detém o pidfile). Este ramo só é
executado quando um operador invoca modules/Invoke-TestRunnerInnerLoop.ps1
diretamente (o que não deveria fazer -- ele fica em modules/ por esse motivo,
mas a proteção é a rede de segurança quando isso acontece).
Implementação compartilhada em Test.SingleInstance.psm1 -- a mesma lógica de
sondagem de identidade do executor externo, com o padrão de cmdline específico
do interno abaixo (corresponde apenas a Start-TestRunner.ps1, nunca a outro
interno). Importado pelo tipo Inner no início do arquivo.

<a id="4213a0b3-0016"></a>

<a id="testmodulesinvoke-testrunnerinnerloopps1-inner-pid--heartbeat"></a>

## test/modules/Invoke-TestRunnerInnerLoop.ps1: PID interno + heartbeat

Arquivo complementar de runner.heartbeat. O runner.heartbeat, acionado por
um timer do pool de threads, comprova atividade no nível do processo, mas
permanece atualizado mesmo quando o runspace está preso em um laço OCR / SSH
que não termina -- não pode detectar travamentos dentro do runspace.
runner.stepHeartbeat é atualizado pelo próprio runspace no início de cada etapa de
Invoke-Sequence; o watchdog externo lê seu mtime para detectar uma etapa
individual que excedeu testCycle.stepTimeoutSeconds. Inicialize aqui para
que a primeira consulta do watchdog veja um arquivo atualizado antes mesmo
da execução da primeira etapa da sequência.

<a id="4213a0b3-0017"></a>

<a id="testmodulesinvoke-testrunnerinnerloopps1-inner-pid--heartbeat-1"></a>

## test/modules/Invoke-TestRunnerInnerLoop.ps1: PID interno + heartbeat

inner.pid: arquivo temporário atômico + renomeação pelo auxiliar compartilhado
de arquivos de estado, para que uma falha durante a gravação não deixe um PID
truncado que o watchdog externo interprete incorretamente. UTF-8 sem BOM é
correto aqui: dígitos inteiramente ASCII, e o executor externo lê por meio de
[int]::Parse, que rejeitaria um prefixo BOM.
Verifique a gravação: uma falha em inner.pid deixa o interno fora do alcance
do watchdog externo, portanto um interno travado executaria sem proteção.
Isso é uma execução degradada (não monitorada), não fatal -- avise e continue.
O Write-Warning do console aqui é herdado apenas pelo externo (o proxy
Write-Warning de Yuruna.Log ainda não foi importado, e a inicialização via
Process.Start não redireciona stderr), portanto também o espelhe em
outer.log por meio de Write-InnerLog, onde fica durável e diagnosticável ao
lado das entradas do executor externo/watchdog.
O registro de início vem primeiro, para que um leitor nunca associe um PID
novo a uma hora de início antiga: inner.start + inner.pid são a identidade
exata que uma atualização do hospedeiro verifica antes de poder retomar este interno.

<a id="4213a0b3-0018"></a>

<a id="testmodulesinvoke-testrunnerinnerloopps1-inner-pid--heartbeat-2"></a>

## test/modules/Invoke-TestRunnerInnerLoop.ps1: PID interno + heartbeat

O processo de execução do ciclo inicia este interno com `Process.Start`, sem
redirecionamento dos fluxos padrão; portanto, o interno herda o terminal de
inicialização. Qualquer prompt que ele emita bloqueia
todo o hospedeiro até o watchdog encerrá-lo -- e, como runner.heartbeat é gravado
por um timer do pool de threads que continua avançando com um runspace bloqueado,
o painel permanece VERDE durante todo o período. Neutralize cada prompt que
este processo pode emitir por si mesmo.

NÃO coberto aqui, deliberadamente: `sudo` lê /dev/tty, NÃO o stdin deste
processo, portanto redirecionar ou fechar stdin não impede um `sudo` simples
em um driver de hospedeiro de solicitar entrada. Esses pontos de chamada
passam a usar `sudo -n` por trás de um wrapper compartilhado; até isso acontecer,
o limite de runner.phase abaixo é o que converte esse bloqueio em um
encerramento rápido e atribuível, em vez de 45 minutos de silêncio verde.

YURUNA_NONINTERACTIVE normalmente é herdado do executor externo; defina-o aqui
também para que um interno invocado diretamente (modules/Invoke-TestRunnerInnerLoop.ps1
executado manualmente) receba o mesmo contrato, em vez de outro que possa travar.

<a id="4213a0b3-0019"></a>

<a id="testmodulesinvoke-testrunnerinnerloopps1-the-inner-kind-import-set-covers-testhostcontract-teststatus-testnotify"></a>

## test/modules/Invoke-TestRunnerInnerLoop.ps1: O conjunto de importações do tipo Inner cobre Test.HostContract, Test.Status, Test.Notify,

O conjunto de importações do tipo Inner cobre Test.HostContract, Test.Status,
Test.Notify, Test.Provenance, Test.Start-GuestOS, Test.Start-GuestWorkload, Test.Log,
Test.SequencePlanner, Test.CachingProxyService, Test.Perf, Test.HostIO,
Test.Capability, Test.Transport (mais as importações de bootstrap inicial).
A passagem no início do arquivo por Initialize-YurunaEntryPointModuleSet -For
Inner carrega esse conjunto uma vez. O executor externo despacha novos processos
pwsh de ciclo e internos em todas as plataformas, portanto seus caches de
módulos recarregam a cada ciclo e incorporam alterações no código-fonte sem
um laço de atualização no mesmo processo.

<a id="4213a0b3-001a"></a>

<a id="testmodulesinvoke-testrunnerinnerloopps1-read-config-syncs-against-template-first"></a>

## test/modules/Invoke-TestRunnerInnerLoop.ps1: Leitura da configuração (primeiro sincroniza com o modelo)

Uma barreira, no início do ciclo, antes de qualquer trabalho no hospedeiro:
o executor externo verifica uma vez na inicialização, mas depois executa
ciclos por dias, portanto uma verificação apenas na inicialização não diz
nada sobre uma configuração -- ou uma credencial GitHub -- que deixou de
funcionar na nona hora. Validar aqui significa que um ciclo incapaz de ter
sucesso é recusado nos primeiros segundos, com o bloco FAILURES de Test-Config
indicando o que corrigir, em vez de surgir depois como uma falha opaca de
etapa no meio das construções de VMs do laboratório.

Esta também é a ÚNICA barreira executada pelo ciclo. Etapas Debug-TestSequence
aninhadas, iniciadas por ações do hospedeiro, herdam esse resultado em vez de
reexecutar a verificação por etapa: a barreira acessa a rede, e um remoto que
pare de responder entre duas etapas, de outro modo, abortaria um ciclo saudável
em andamento e descartaria todas as etapas já construídas.
Um interno de verificação prévia ignora a barreira: o externo retomado executou
sua barreira de inicialização na mesma cadeia segundos antes, e o primeiro
ciclo comum verifica novamente.

<a id="4213a0b3-001b"></a>

<a id="testmodulesinvoke-testrunnerinnerloopps1-held-control-barrier"></a>

## test/modules/Invoke-TestRunnerInnerLoop.ps1: Barreira de controle retido

Dois ciclos em um conjunto de VMs corrompem um ao outro, portanto um ciclo só
inicia em um hospedeiro comprovadamente livre de outros convidados. Em algumas
versões do macOS, vmnet-shared também coloca cada sessão vmnet em uma bridge
separada no lado do hospedeiro (bridge100, bridge101, ...) que não roteia para
as outras, portanto uma VM externa concorrente pode separar os convidados
de teste para uma bridge diferente daquela do gateway vmnet do hospedeiro e
interromper a URL host-proxy do cloud-init incorporada em seed.iso.
A etapa de admissão encerra primeiro e recusa depois: um convidado remanescente
de um ciclo que morreu antes da desmontagem é o caso comum aqui, e recusá-lo
imobiliza o hospedeiro, porque a varredura que o removeria só é executada quando
um ciclo começa. VMs de serviço são isentas porque o ciclo as utiliza.
Um hospedeiro incapaz de dizer o que está executando também é recusado:
saída "cannot run", com a razão em vm-admission.json para o executor externo informar.

<a id="4213a0b3-001c"></a>

<a id="testmodulesinvoke-testrunnerinnerloopps1-concurrent-vm-admission"></a>

## test/modules/Invoke-TestRunnerInnerLoop.ps1: Admissão de VMs concorrentes

Um objeto de switch virtual sobrevive à sua associação de uplink após uma
reinicialização do hospedeiro, portanto a sobrevivência do objeto não comprova
que a bridge ainda transporte tráfego: todo convidado se conecta a um switch
sem sinal enquanto o próprio hospedeiro está online e todas as outras
verificações do hospedeiro passam. Nada mais no preâmbulo pergunta se um
convidado criado agora conseguiria alcançar algo, portanto a resposta é
informada aqui -- no início do ciclo --, em vez de ser deduzida de uma frota
de falhas idênticas de convidados um quarto de hora depois.

Informa; quase nunca recusa. Um hospedeiro que ainda tenha QUALQUER caminho
utilizável (um vSwitch External funcional ou um endereço Default Switch --
NAT + DHCP, o estado estável permanente de todo hospedeiro Wi-Fi aqui) executa
o ciclo inteiro pelo caminho disponível e PASSA; a barreira de notificações
transforma uma degradação persistente em um alerta por sequência de ocorrências,
em vez de um por ciclo. Somente a perda TOTAL, em que todo convidado certamente
falharia da mesma forma, pode recusar.

Posicionado após a admissão de VMs para que uma recusa nunca abandone convidados
que o ciclo anterior deixou executando: recusar antes de encerrar deixa o
hospedeiro mais sujo que um ciclo normal, e esses remanescentes são justamente
o que impede a condição de desaparecer. O caminho de recusa executa a varredura
de VMs pela mesma razão.

<a id="4213a0b3-001d"></a>

<a id="testmodulesinvoke-testrunnerinnerloopps1-cycle-start-host-guest-network-gate"></a>

## test/modules/Invoke-TestRunnerInnerLoop.ps1: Barreira da rede de convidados do hospedeiro no início do ciclo

host-network.txt é HTML pronto para incorporar, anexado literalmente pela
página de status; host-network.json é o equivalente legível por máquina que
Write-HostRegistrationRecord anuncia ao grupo. A mesma observação, dois
públicos -- portanto UM gravador detém ambos, e ele é esta barreira: a
sondagem acima é a única que examina o estado da rede de convidados do
hospedeiro exatamente uma vez por ciclo, o que dá significado à contagem
de ciclos consecutivos.

"Arquivo presente == degradado, arquivo ausente == saudável" é todo o
contrato, portanto a recuperação EXCLUI ambos os arquivos. Esvaziá-los deixa
um hospedeiro degradado para todo consumidor que só verifica a existência.

<a id="4213a0b3-001e"></a>

<a id="testmodulesinvoke-testrunnerinnerloopps1-degraded-host-pair---runtimehost-networktxt--host-networkjson"></a>

## test/modules/Invoke-TestRunnerInnerLoop.ps1: Par de hospedeiro degradado -> runtime/host-network.txt + host-network.json

control.cycle-restart é gravado pelo worker por trás do endpoint
/control/start-cycle do serviço de status. O laço de espera entre ciclos o consome no próximo
tick; a barreira por etapa de Test.SequenceEngine.psm1 também o respeita.
Mas, se uma sessão anterior foi encerrada no meio do ciclo antes de consumir
o indicador (Ctrl+C do operador, reinício do executor externo, falha do
processo), o arquivo persiste. Um interno que acaba de iniciar É o reinício
solicitado pelo operador, portanto consuma o indicador aqui -- caso contrário,
a primeira etapa do ciclo novo lançaria imediatamente YurunaCycleRestart,
marcaria o ciclo como malsucedido e repetiria até ConsecutiveCrashes abortar
o executor. A função do indicador é despertar um interno em execução, não
insistir com um novo.
-SkipInteractiveState: os indicadores break-active + pausa do interno são
responsabilidade do pai para a varredura (a recuperação de inicialização do
externo ou a transferência PreSpawn de Invoke-TestProject). Um interno
invocado diretamente mantém uma pausa definida pelo operador aqui, portanto
o interno nunca refaz a varredura dessa classe.

<a id="4213a0b3-001f"></a>

<a id="testmodulesinvoke-testrunnerinnerloopps1-stale-cycle-restart-flag-sweep"></a>

## test/modules/Invoke-TestRunnerInnerLoop.ps1: Varredura de indicador cycle-restart obsoleto

Reimporte Test.CachingProxyService com -Global -Force APÓS Initialize-YurunaHost.
Yuruna.Host.psm1 força a importação de Test.CachingProxyService durante seu
carregamento; conforme o padrão de remoção, esse -Force aninhado retira
Test.CachingProxyService da sessão global, então Invoke-CachingProxyServiceProbe
deixa de ser resolvido a partir deste script, mesmo que a importação de
bootstrap do tipo Inner acima tenha ocorrido primeiro. -Global -Force aqui
o restaura; a mesma correção é usada por Start-StatusService.ps1 imediatamente
após seu próprio Initialize-YurunaHost.

<a id="4213a0b3-0020"></a>

<a id="testmodulesinvoke-testrunnerinnerloopps1-stale-cycle-restart-flag-sweep-1"></a>

## test/modules/Invoke-TestRunnerInnerLoop.ps1: Varredura de indicador cycle-restart obsoleto

Uma reinicialização do hospedeiro deixa toda VM de serviço registrada no
hipervisor e DESLIGADA, e nada mais no ciclo as liga novamente. As duas falhas
resultantes não se parecem: o proxy de cache apenas degrada para downloads
diretos, enquanto o stash service é fatal -- o aquecimento o resolve, não
encontra nada e ignora todas as etapas de cargas de trabalho. Assim, um
hospedeiro reiniciado desperdiça ciclo após ciclo incapaz de passar até um
operador iniciar as VMs manualmente.

ANTES da barreira de caching-proxy abaixo, para que um proxy reiniciado aqui
seja detectado pela próxima sondagem, em vez de informado como ausente por
mais um ciclo. Executa a cada ciclo, não apenas na inicialização: um serviço
também pode ser encerrado durante a sessão, e, em um hospedeiro saudável,
isso custa uma consulta de estado por serviço.

Inicia apenas o que já foi construído -- nunca reconstrói. Uma reconstrução
leva ~15 minutos e descarta um cache squid aquecido; iniciar leva segundos e o preserva.

<a id="4213a0b3-0021"></a>

<a id="testmodulesinvoke-testrunnerinnerloopps1-cycle-start-service-vm-restore"></a>

## test/modules/Invoke-TestRunnerInnerLoop.ps1: Restauração de VMs de serviço no início do ciclo

AQUI, e em nenhum outro lugar do ciclo. Uma nova associação retira o sinal
de todo convidado no switch e interrompe por um instante a rede do hospedeiro
na NIC de destino -- ambas são aceitáveis em um limite de ciclo sem convidados
ativos, e nenhuma é aceitável entre duas construções de convidados. O auxiliar
de switch chamado durante uma construção continua apenas detectando.

Condicionado por Get-Command porque só o driver Hyper-V define isto: um vSwitch
que sobrevive à associação de uplink é uma falha específica do Windows. A
correção se recusa a atuar em qualquer caso que não seja uma associação
obsoleta, limita suas próprias tentativas e reverte se o hospedeiro perder
sua rota padrão -- consulte Repair-YurunaExternalSwitch.

Melhor esforço por construção. Um hospedeiro incapaz de corrigir sua bridge
ainda executa o ciclo no Default Switch com encaminhadores de porta, como
já fazia; a correção apenas tenta recuperar o caminho em bridge.

<a id="4213a0b3-0022"></a>

<a id="testmodulesinvoke-testrunnerinnerloopps1-cycle-start-external-vswitch-repair-hyper-v-only"></a>

## test/modules/Invoke-TestRunnerInnerLoop.ps1: Correção do vSwitch External no início do ciclo (somente Hyper-V)

A barreira acima gravou o par degradado a partir de uma sondagem feita ANTES
desta correção, portanto um switch corrigido aqui continuaria anunciando uma
falha que já não tem pelo resto do ciclo -- tanto na página de status quanto
no registro do grupo, um quarto de hora de informação incorreta. Sonde novamente e limpe.

Este ramo apenas LIMPA. A barreira continua sendo a única gravadora de um par
degradado, o que dá significado à sua contagem de ciclos consecutivos; uma
correção só pode aproximar um hospedeiro do estado saudável, portanto não há
nada para gravar aqui. Condicionado pelo arquivo de registro para que um
hospedeiro já saudável não pague por uma segunda sondagem a cada ciclo.

<a id="4213a0b3-0023"></a>

<a id="testmodulesinvoke-testrunnerinnerloopps1-cycle-start-external-vswitch-repair-hyper-v-only-1"></a>

## test/modules/Invoke-TestRunnerInnerLoop.ps1: Correção do vSwitch External no início do ciclo (somente Hyper-V)

Sonde as duas fontes do operador em ordem de prioridade (a chave persistente
de configuração vmStart.cachingProxyIp, depois a variável de ambiente da sessão)
-- a prioridade das fontes e a política de sondagem estão documentadas em
Resolve-CachingProxyServiceEndpoint (Test.CachingProxyService.psm1). A aceitação
exige SOMENTE acessibilidade de :3128: usar Success da sondagem completa
rejeitaria caches barebones-squid sem Grafana/ssl-bump e destruiria
silenciosamente $env:YURUNA_CACHING_PROXY_SERVICE_IP para o código subsequente.
Sem fonte definida, a variável de ambiente permanece intacta (a descoberta
local abaixo continua igual); com fontes definidas, mas :3128 inacessível em
todas, a variável é limpa para aplicar a mesma alternativa de descoberta local.
A atualização do mapa de portas abaixo é a única etapa do preâmbulo que
invoca sudo, e é onde um prompt de senha impossível de responder realmente
bloqueou um hospedeiro. Nomear a fase coloca 'caching-proxy-gate' na linha de
encerramento do watchdog.

<a id="4213a0b3-0024"></a>

<a id="testmodulesinvoke-testrunnerinnerloopps1-cycle-start-caching-proxy-service-gate"></a>

## test/modules/Invoke-TestRunnerInnerLoop.ps1: Barreira de caching-proxy-service no início do ciclo

Despacho do mapa de portas (externo / caminho rápido Yuruna-External /
alternativa Default-Switch) e o formato da lista de portas Windows-vs-macOS:
https://yuruna.link/42f6b05f-003c

Serialize esta gravação do mapa de portas por ciclo em relação à inicialização
de caching-proxy-service. Uma tentativa (não bloqueante): se
Start-CachingProxyServiceVM detém o bloqueio (uma reconstrução), ignore o
mapa de portas deste ciclo -- a reconstrução detém os mapas, e o cache fica
indisponível durante ela de qualquer forma; o próximo ciclo reaplica após a
liberação. Protegido por Get-Command para que um executor de longa duração
anterior ao módulo de bloqueio degrade para o comportamento sem bloqueio,
em vez de gerar erro.

<a id="4213a0b3-0025"></a>

<a id="testmodulesinvoke-testrunnerinnerloopps1-cycle-start-caching-proxy-service-gate-1"></a>

## test/modules/Invoke-TestRunnerInnerLoop.ps1: Barreira de caching-proxy-service no início do ciclo

Deliberadamente NÃO há mais preparação de sudo aqui. A elevação de um
hospedeiro não supervisionado pertence à inicialização (Assert-RunnerElevation,
executado uma vez por Start-TestRunner.ps1 antes do laço) ou a um arquivo
drop-in em /etc/sudoers.d -- nunca ao meio do ciclo, quando ninguém está no
console para responder.

Uma preparação condicionada por Test-CacheVMOnExternalNetwork também seria
incorreta: ela pergunta "a VM de cache LOCAL está em bridge?" e retorna false
TANTO para um cache local em NAT que precisa de encaminhadores QUANTO para
um hospedeiro cujo cache está em outra máquina. Neste último, a preparação
aconteceria a cada ciclo enquanto o despacho abaixo toma o ramo externo, em
que Remove-PortMap não encontra unidades e não emite sudo algum: um prompt
de senha a cada ciclo para trabalho que nunca acontece.

<a id="4213a0b3-0026"></a>

<a id="testmodulesinvoke-testrunnerinnerloopps1-cycle-start-caching-proxy-service-gate-2"></a>

## test/modules/Invoke-TestRunnerInnerLoop.ps1: Barreira de caching-proxy-service no início do ciclo

O tratamento externo abaixo remove os encaminhadores deste hospedeiro,
portanto só pode executar quando o endpoint é COMPROVADAMENTE outro hospedeiro.
'local': o endpoint "external" é o próprio conjunto de encaminhadores deste
hospedeiro diante de sua VM de cache em NAT -- removê-lo rompe justamente os
listeners que acabaram de responder à sondagem (autodesmontagem).
'unknown': mudanças de NIC causadas pelo início/fim de VMs por ciclo podem
esvaziar a enumeração por um instante, e um resultado incorreto 'external'
derruba os encaminhadores, enquanto um resultado incorreto 'local' apenas
reafirma um mapa de portas -- portanto unknown deve ficar no lado local.

<a id="4213a0b3-0027"></a>

<a id="testmodulesinvoke-testrunnerinnerloopps1-cycle-start-caching-proxy-service-gate-3"></a>

## test/modules/Invoke-TestRunnerInnerLoop.ps1: Barreira de caching-proxy-service no início do ciclo

O conjunto de portas expostas (incluindo a visualização contínua de logs de
caching-proxy-parser-service em 9302) vem de Get-CachingProxyServiceExposedPort,
para não divergir da lista de instalação de Start-CachingProxyServiceVM;
Add-PortMap primeiro limpa tudo, portanto uma porta removida deixa de atender
na reinstalação. macOS remapeia apenas as duas portas abertas manualmente por
um operador: Grafana e 80 -- onde fica a página inicial da VM caching-proxy
e, portanto, o destino do link Dashboards das páginas de status do hospedeiro.
Sem 80, esse link não alcança nada a partir de um hospedeiro Mac.

<a id="4213a0b3-0028"></a>

## test/modules/Test.CachingProxyService.psm1: Invoke-CachingProxyServiceProbe

Política de conexão da sondagem compartilhada. 3 tentativas porque um único
prazo faz FALHAR indevidamente um cache que está ativo: no Wi-Fi, um rádio
inativo mais uma ida e volta ARP pelo ar podem consumir quase todo o orçamento,
e uma retransmissão ou mudança de AP ultrapassa o limite (a primeira tentativa
aquece ARP / desperta o rádio; a seguinte conecta em milissegundos).
3s/tentativa porque um cache remoto / entre hospedeiros (por exemplo, squid
UTM/macOS em rede em bridge) normalmente leva 600ms-1s+ para ACEITAR; o limite
não custa nada a um cache local rápido -- connect retorna assim que a porta aceita.

<a id="4213a0b3-0029"></a>

## test/modules/Test.CachingProxyService.psm1: Get-PoolAggregatorServiceSeedUrl

Corrija um endereço armazenado que perdeu para um ativo, para que a próxima
chamada não pague por outra sondagem para refutá-lo. Só é regravado um endereço
já registrado por este hospedeiro: uma chave vazia significa "não executo
proxy próprio", e preenchê-la com um proxy executado por outro afirmaria
uma propriedade que este hospedeiro não possui.

ShouldProcess, não $WhatIfPreference: variáveis de preferência são resolvidas
no PRÓPRIO estado de sessão do módulo, onde $WhatIfPreference lê $false
independentemente de como o chamador foi invocado, e um -WhatIf não vinculado
também não é repassado por esse limite. Um chamador que não deve gravar
precisa passar -WhatIf explicitamente, e esta condição é o que dá efeito ao repasse.

<a id="4213a0b3-002a"></a>

<a id="testmodulestestcachingproxyservicelockpsm1-caching-proxy-serialization-lock--adopt-if-healthy-decision"></a>

## test/modules/Test.CachingProxyServiceLock.psm1: Bloqueio de serialização de caching-proxy + decisão de adotar se saudável.

Bloqueio de serialização de caching-proxy + decisão de adotar se saudável.

O bloqueio é um mutex PID+StartTime no estilo da drenagem, para que o ciclo
de vida destrutivo da VM e as gravações de mapas de portas do hospedeiro não
se intercalem; os dois perfis de retenção ('rebuild' e 'portmap') diferem
apenas no tempo limite de aquisição. A identidade do bloqueio, a drenagem
de detentor obsoleto, a retomada própria, o limite de idade de abandono,
a tabela de perfis de retenção e a estrutura da decisão de adotar ou reconstruir:
docs/caching.md#rebuild-adopt-if-healthy-and-the-bring-up-lock

<a id="4213a0b3-002b"></a>

<a id="testmodulestestcachingproxyservicelockpsm1-age-past-which-a-recorded-lock-is-abandoned-rather-than-slow-so-it-is-drained"></a>

## test/modules/Test.CachingProxyServiceLock.psm1: Idade após a qual um bloqueio registrado é ABANDONADO, não lento, portanto é drenado

Idade após a qual um bloqueio registrado é ABANDONADO, não lento, portanto é
drenado na aquisição (e por Clear-CachingProxyServiceLock). Drenar retira o
bloqueio de quem o registrou, portanto o limite é definido a partir do pior
caso real da reconstrução e depois ampliado:
  * As fases LIMITADAS totalizam ~36 min -- host/ubuntu.kvm/guest.caching-proxy-service/
    New-VM.ps1 espera até 20 min pelo IP da VM e 15 min por squid em :3128;
    o caminho macOS UTM em Start-CachingProxyServiceVM.ps1 espera 15 min pela
    descoberta MAC/ARP mais ~1 min de tentativas de registrar + iniciar.
  * A busca da imagem base na Etapa 2 é a única fase SEM LIMITE (~600 MB, e
    nada em Yuruna.Image define um tempo limite de download). 6 h deixam >5 h
    para ela -- 600 MB a ~250 kbit/s --, mais lento que qualquer conexão de um
    hospedeiro de laboratório.
Portanto, isso não pode ser acionado durante uma reconstrução lenta legítima.
Também é o ÚLTIMO recurso de recuperação: uma sobra própria é retomada
imediatamente na aquisição, e Stop-CachingProxyServiceVM.ps1 limpa um bloqueio
abandonado sob demanda.
<a id="4213a0b3-002c"></a>

## test/modules/Test.CachingProxyServiceLock.psm1: Enter-CachingProxyServiceLock

NOSSA PRÓPRIA sobra de uma invocação anterior NESTE processo -- não um par
ativo. Um .ps1 executa dentro do pwsh do chamador, portanto uma inicialização
que saiu sem liberar registrou o shell interativo duradouro do operador como
detentor; esse shell permanece ativo, então a drenagem por atividade acima
nunca ocorre e toda execução posterior é recusada. Seguro porque um processo
pwsh nunca detém dois bloqueios de inicialização ao mesmo tempo: o único outro
chamador (a retenção 'portmap' de Invoke-TestRunnerInnerLoop.ps1) tem escopo
try/finally e nunca inicia uma inicialização dentro de sua janela, e
Start-CachingProxyServiceVM.ps1 nunca é dot-sourced nem executado como job.
Um bloqueio próprio é, portanto, obsoleto por definição. Avisado (não Verbose):
significa que uma inicialização anterior neste shell morreu, algo que o operador deve saber.

<a id="4213a0b3-002d"></a>

## test/modules/Test.Capability.psm1: Write-HostRegistrationRecord

poolId: o grupo deste hospedeiro, DERIVADO pela sincronização de grupos do
laço externo a partir de members[] de pools.yml (a única fonte de verdade) e
persistido em runtime/pool.state.json -- o canal entre processos, porque este
gravador executa no processo interno NOVO, que não herda $global do externo.
null quando não pertence a grupo ou a intenção ainda não foi obtida (o
agregador então recorre ao próprio rótulo de grupo). Leia inline para que
Test.Capability não mantenha dependência de Test.PoolSync.
gating: a política consultiva de alertas do grupo, levada junto com poolId em
pool.state.json (null quando o grupo não definiu nenhuma). Repassada
literalmente para que o agregador analise os limites; gating null/ausente
informa que ele deve observar os indicadores do grupo, mas nunca emitir um alerta.
poolGuid: o 42-GUID estável do grupo, levado junto com poolId em
pool.state.json. Anunciado para que o agregador possa usá-lo como rótulo de
host_info. null quando não pertence a grupo.

<a id="4213a0b3-002e"></a>

## test/modules/Test.Capability.psm1: Write-HostRegistrationRecord

activeExtensions: as áreas de extensão que este hospedeiro está executando
ATIVAMENTE agora (distintas de capabilities.extensions, que representa o que
PODERIA executar -- verdadeiro para todo hospedeiro). pool-aggregator-service
lê isto para preencher a tabela Extension hosts do painel SEM montar
ystash-nas (sem dependência de serviço de configuração entre hospedeiros /
credenciais NAS). Controlado por marcadores de runtime por serviço, gravados
por um hospedeiro quando inicia um serviço -- Start-StashServiceVM.ps1 grava
runtime/stash-service.json; Stop-StashServiceVM.ps1 o remove.
extensionTargets contém o link direto por área que o hospedeiro anuncia para
seu serviço (a URL base da interface da VM de serviço, resolvida pelo hospedeiro
via Get-VMIp), para que o agregador redirecione sem armazenamento próprio de
endereços. Em um pacote UTM Shared-NAT, essa URL base é o endereço encaminhado
do HOSPEDEIRO, não o IP do convidado, porque o endereço do convidado é
inacessível do restante da LAN.

Um laço sobre os marcadores, em vez de um bloco por serviço: uma cópia fixa
por área colocaria uma edição deste gravador no caminho de todo novo serviço
de extensão que queira ficar visível ao grupo.

<a id="4213a0b3-002f"></a>

## test/modules/Test.Capability.psm1: Write-HostRegistrationRecord

projectUrl / projectCommit: o projeto clonado pelo último ciclo deste
hospedeiro, publicado como fatos do hospedeiro junto à identidade, para que
quem lê um registro saiba o que um membro executa sem clonar nada -- o
hospedeiro já possui o clone, e seu GH_TOKEN nunca precisa sair dele.

Lido do clone de projeto já produzido pelo ciclo; apenas leituras git locais,
de acordo com a política de resolução desta função. Melhor esforço: um clone
que não pode ser lido informa valores null, porque esses fatos nunca devem
poder fazer uma gravação de registro falhar.

NOTA (ordem): este registro é gravado na Fase 0, ANTES da substituição dos
repositórios do grupo e da atualização do clone de projeto, portanto ambos
os campos descrevem o clone do ciclo ANTERIOR. Depois que a Project URL de
um grupo muda, o primeiro registro ainda nomeia o projeto antigo.

<a id="4213a0b3-0030"></a>

## test/modules/Test.Capability.psm1: Write-HostRegistrationRecord

network: a topologia de rede de convidados deste hospedeiro quando NÃO é
a saudável. Um objeto vSwitch Hyper-V sobrevive à associação de uplink após
uma reinicialização do hospedeiro; portanto, um hospedeiro pode estar totalmente
online, passar em toda verificação e ainda conectar todo convidado a um switch
sem sinal -- um estado que o resultado do ciclo sozinho não expressa, porque
esse hospedeiro continua executando e passando no Default Switch (NAT + DHCP).
Marcador ausente = saudável, portanto o campo permanece null e um agregador
que nunca soube dele não é afetado. Lido como arquivo, de acordo com a política
de resolução desta função.

<a id="4213a0b3-0031"></a>

<a id="testmodulestestcatalogpsm1-render-a-message-from-the-compiled-catalog-in-the-locale-a-run-resolved"></a>

## test/modules/Test.Catalog.psm1: Renderiza uma mensagem do catálogo compilado na localidade resolvida pela execução.

Renderiza uma mensagem do catálogo compilado na localidade resolvida pela execução.

O compilador de catálogos emite uma tabela por localidade e domínio, já
dividida nas partes percorridas por um renderizador: uma mensagem sem
argumentos é uma string simples, uma mensagem com argumentos é uma lista
alternada de texto literal e descritores de argumentos, e uma mensagem que
varia por contagem contém suas variantes ao lado do argumento que as seleciona.
Nada aqui analisa uma gramática de mensagens nem percorre uma string de formato,
porque a análise já ocorreu na compilação -- o que mantém o custo baixo o
bastante para estar em um laço de transcrição por linha.

O carregamento é sob demanda e armazenado em cache para o processo. Um comando
que não renderiza texto não paga nada; um que renderiza mil mensagens lê cada
domínio uma vez. Import-PowerShellDataFile é o carregador deliberadamente:
analisa o arquivo na linguagem restrita do PowerShell, portanto um artefato
gerado é dado e não pode executar.

Uma chave ausente é um erro de compilação, não de runtime -- um catálogo
compatível é completo por definição, e o compilador falha diante de uma lacuna.
Em runtime, a própria chave é retornada para que a interface ainda diga algo
identificável, e o chamador a vê no único lugar em que uma chave errada pode ser percebida.

<a id="4213a0b3-0032"></a>

## test/modules/Test.Catalog.psm1: Format-CatalogArgument

Em uma localidade da direita para a esquerda, todo argumento é isolado, para
que o algoritmo bidi não reordene um número ou uma string externa para dentro
da frase ao redor. Um número, duração ou timestamp é lido da esquerda para a
direita (LRI); uma string externa decide sua própria direção (FSI). Um argumento
vazio permanece vazio: um isolamento em torno de nada são dois caracteres
invisíveis que um leitor não consegue excluir. O SDK Go e o kernel do navegador
gravam os mesmos bytes.
Um valor já isolado pelo chamador começa com um isolador e termina com seu
fechamento; um segundo par apenas criaria aninhamento.

<a id="4213a0b3-0033"></a>

## test/modules/Test.Config.psm1: Publish-TestConfigSnapshot

O snapshot é uma cópia literal de tudo que foi analisado e fica no diretório
de runtime publicado pelo status service por HTTP. Os arquivos de credenciais
sob a extensão de autenticação contêm senhas e o token de autenticação do
laboratório em texto claro, e a lista de bloqueio do servidor usa NOMES DE
ARQUIVOS -- portanto protege vault.yml enquanto serve sem problemas uma cópia
de vault.yml com outro nome. Nunca produzir a cópia é a única forma dessa
proteção que um novo nome não pode contornar. Os consumidores não perdem nada:
toda ausência de snapshot já recorre a uma análise YAML completa.

<a id="4213a0b3-0034"></a>

<a id="testmodulestestconfignamingpsm1-test-retiredconfigkeyline-answers-does-this-file-still-say-it-the-old-way"></a>

## test/modules/Test.ConfigNaming.psm1: Test-RetiredConfigKeyLine responde "este ARQUIVO ainda usa a forma antiga",

Test-RetiredConfigKeyLine responde "este ARQUIVO ainda usa a forma antiga",
que é o necessário para uma reconciliação local. Uma configuração obtida de
outro hospedeiro chega já analisada, e a pergunta ali é diferente: reescrever
as grafias obsoletas nos caminhos atuais para que o consumidor -- que só
procura os nomes atuais -- veja os valores, em vez de nada.

Nada fazia essa reescrita, e "não vê nada" não é inerte: o conversor
networkStorage lê a ausência de poolStorageNetworkPath como "a referência
não possui armazenamento de grupos" e LIMPA o nível, levando os nomes de
usuários e deixando a sincronização de credenciais com uma lista de usuários
vazia. Um hospedeiro de referência atrasado em uma renomeação, portanto,
apagava a seção que deveria fornecer.

<a id="4213a0b3-0035"></a>

<a id="testmodulestestconfigpreflightpsm1-pre-cycle-config-gate-spawn-test-configps1-in-a-fresh-pwsh-so-an"></a>

## test/modules/Test.ConfigPreflight.psm1: Barreira de configuração antes do ciclo: inicia Test-Config.ps1 em um novo pwsh para que um

Barreira de configuração antes do ciclo: inicia Test-Config.ps1 em um novo
pwsh para que um Out-Of-Order ::Stop / saída antecipada dentro de Test-Config
não desfaça o laço eterno do chamador. -SkipSend é obrigatório neste contexto
de barreira: o caminho de notificações dentro de Test-Config é um teste básico,
e enviar um email a cada relançamento externo / iteração de desenvolvimento
inundaria a lista subscribers["config.smoke"].

Centralizar a barreira aqui mantém a inicialização externa de Start-TestRunner,
Debug-TestSequence e Invoke-TestProject de acordo sobre sua semântica -- um
novo parâmetro de barreira alcança todo chamador a partir de um único lugar,
em vez de divergir entre cópias quase idênticas.

<a id="4213a0b3-0036"></a>

## test/modules/Test.ConfigPreflight.psm1: Invoke-ConfigGate

Invocação em modo oculto: a transcrição de ~80 linhas de Test-Config é
capturada silenciosamente e só chega ao CONSOLE quando a barreira falha (o
bloco de falhas é reemitido sob o banner de falha da barreira abaixo), portanto
uma barreira aprovada não mostra nada ao operador -- como toda outra
verificação prévia do ambiente de testes. É retornada ao chamador em ambos
os casos; consulte .OUTPUTS.
A captura inclui 2>&1 para que stderr do filho entre na mesma lista e o
extrator do bloco FAILURES veja a transcrição completa, independentemente
do fluxo usado por Test-Config.
Resolva o pwsh em execução pelo resolvedor compartilhado, reforçado para macOS:
um (Get-Process -Id $PID).Path simples é null no macOS (sem /proc), e um
caminho null de pwsh filho faz a inicialização abaixo lançar uma exceção.
O ponto de entrada Sequence carrega esta barreira SEM Test.InnerSpawn,
portanto importe-o sob demanda; -Global evita a classe de remoção global por
importação aninhada (feedback_module_force_import_evicts_global.md). A chamada
é qualificada pelo módulo porque o módulo de hospedeiro Windows exporta um
Get-PwshExePath de mesmo nome com semântica diferente.

<a id="4213a0b3-0037"></a>

## test/modules/Test.ConfigPreflight.psm1: Invoke-ConfigGate

Extraia o bloco FAILURES (a seção entre o cabeçalho "FAILURES (N) --" e o
rodapé correspondente "END OF FAILURES (N)", incluindo as linhas de banner
=== ao redor) para repeti-lo sob o banner de falha da barreira. Write-Summary
de Test.Output já inclui ali mensagens WARN por seção, portanto esse único
trecho contém toda a cadeia de razões (FAIL + os avisos aos quais apontou).
Coletado à medida que é gravado para que o retorno ao chamador e o que o
console mostrou não possam divergir.

<a id="4213a0b3-0038"></a>

<a id="testmodulestestconfigservicecapsm1-per-host-config-ca-backing-the-config-service-mtls-one-server-leaf"></a>

## test/modules/Test.ConfigServiceCA.psm1: CA de configuração por hospedeiro que sustenta o serviço de configuração (mTLS): um certificado folha SERVER

CA de configuração por hospedeiro que sustenta o serviço de configuração
(mTLS): um certificado folha SERVER para o serviço, um certificado folha
CLIENT por VM (incorporado em seu seed cloud-init) -- prova de que a VM foi
criada por ESTE hospedeiro. Persistido em $env:YURUNA_RUNTIME_DIR/host-config-ca/
(ignorado pelo git). Consulte docs/test-config.md.

A criptografia é uma postura de segurança aprovada pelo operador (não altere
sem autorização; consulte feedback_no_unauthorized_security_changes):
EC P-256, SHA-256, CA 10y, certificados folha 2y. O SAN do certificado folha
do servidor é um nome dns ESTÁVEL (ConfigServerSan); os convidados alcançam
o IP atual do hospedeiro via `curl --connect-to <san>:<port>:<hostIp>:<port>`,
portanto uma mudança DHCP do hospedeiro nunca invalida o certificado folha
(só invalida o IP incorporado do hospedeiro, a mesma obsolescência que a
busca de status-service já apresenta).

<a id="4213a0b3-0039"></a>

<a id="testmodulestestconfigservicecapsm1-x509-key-storage-flags-for-loading-the-ca-signing-material-capfx"></a>

## test/modules/Test.ConfigServiceCA.psm1: Flags de armazenamento de chaves X509 para carregar o material de assinatura da CA (ca.pfx)

Flags de armazenamento de chaves X509 para carregar o material de assinatura
da CA (ca.pfx). No Windows e no Linux, EphemeralKeySet mantém a chave privada
exclusivamente na memória, portanto a assinatura frequente por VM não deixa
resíduos no armazenamento de chaves do hospedeiro. macOS NÃO suporta
EphemeralKeySet -- o carregador lança "This platform does not support
loading with EphemeralKeySet" --, portanto carrega com Exportable, a mesma
flag já usada pelo certificado folha do servidor. A chave da CA já está
armazenada em ca.pfx (chmod 600), portanto o caminho macOS não acrescenta
exposição em repouso; a postura criptográfica EC P-256 / SHA-256 permanece
igual em toda plataforma.

<a id="4213a0b3-003a"></a>

## test/modules/Test.ConfigServiceCA.psm1: Get-YurunaConfigCaPublicCertificate

Carregue a partir dos bytes DER analisados do PEM, NÃO do construtor de arquivo
X509Certificate2: esse construtor detecta automaticamente o formato do
arquivo pelo backend criptográfico da plataforma, que lê PEM no Windows,
mas NÃO no macOS -- ali lança uma exceção, encerrando o processo -Serve
desacoplado antes que pudesse escutar (o iniciador nunca carrega ca.crt como
certificado, então a falha apareceu apenas no serviço). Bytes DER carregam
de forma idêntica em toda plataforma. (CreateFromPem recebe um
ReadOnlySpan<char> ao qual PowerShell não consegue vincular [string] de forma
confiável entre versões -- consulte Test.ConfigServiceCA.Tests.ps1; o arquivo
.Tests usa a mesma reconstrução remover cabeçalhos -> base64 -> DER.)

<a id="4213a0b3-003b"></a>

<a id="testmodulestestconfigservicesyncpsm1-pure-conversion-helpers-no-io-unit-tested-directly"></a>

## test/modules/Test.ConfigServiceSync.psm1: Auxiliares puros de conversão (sem E/S; testados unitariamente de forma direta)

Ambas as pontas possuem a chave de autenticação interna; nada mais é
compartilhado. A requisição contém uma prova HMAC de conhecimento (o próprio
token nunca atravessa a rede), e a senha da resposta é criptografada com
AES-256-GCM usando uma chave HKDF derivada do token + um salt novo por resposta,
com o usuário e o nonce do cliente vinculados à derivação -- uma resposta
capturada não pode ser descriptografada sem o token nem reutilizada para
outro usuário. O status service usa HTTP simples em uma LAN confiável; isso
mantém o segredo confidencial em trânsito sem dependência de TLS.

<a id="4213a0b3-003c"></a>

## test/modules/Test.ConfigServiceSync.psm1: Get-ConfigSyncHmac

A vírgula unária é essencial. Um `return $bytes` simples grava o array no
pipeline ELEMENTO POR ELEMENTO, e o chamador coleta os pedaços de volta em
[object[]] -- não no [byte[]] anunciado pelo OutputType acima (esse atributo
documenta, não converte). A maioria dos chamadores não percebe, porque um
parâmetro do tipo [byte[]] converte object[] de volta. Test-ConfigSyncProof
percebe: passa esse valor a um parâmetro ReadOnlySpan<byte>, e um tipo
semelhante a ByRef é justamente o que PowerShell não consegue converter de
object[]; portanto, a comparação lança uma exceção, em vez de retornar um resultado.

<a id="4213a0b3-003d"></a>

## test/modules/Test.ConfigServiceSync.psm1: Invoke-ConfigSyncHostAlias

-n (nunca bloquear em um prompt de senha) e, no macOS, -E: um PowerShell
Homebrew não consegue iniciar sob o ambiente reduzido de sudo e sai com
131 antes de ler o script. Consulte Get-SudoPwshArgumentList.
O prompt nomeia a conta e a razão. Chegar aqui significa que a execução
acabou de descrever chaves do vault e credenciais de contas de armazenamento
obtidas do hospedeiro de referência; portanto, um "Password:" simples parece
uma continuação disso e convida a responder com uma dessas credenciais.
O que se deseja é a senha de login desta própria máquina, e somente o
prompt pode dizer isso.

<a id="4213a0b3-003e"></a>

<a id="testmodulestestconfigservicesyncpsm1-side-channel-reconciliation-hosts-file--vault"></a>

## test/modules/Test.ConfigServiceSync.psm1: Reconciliação por canal lateral (arquivo hosts + vault)

Converge cada nome de servidor networkStorage na configuração convertida
para o endereço em que o hospedeiro de REFERÊNCIA o resolve: a referência é
a fonte de verdade da sincronização, portanto sua resposta é consultada para
cada nome, não apenas os que não resolvem aqui. Ignorar a consulta sempre que
um nome resolve localmente faria da sincronização um bootstrap de uso único:
um NAS que mudou de endereço deixa uma entrada hosts obsoleta que ainda
"resolve", portanto nenhuma reexecução poderia corrigi-la e as montagens
continuariam falhando contra o IP antigo. Uma reexecução, portanto, regrava
um mapeamento que discorda da referência e não grava nada quando já concordam.
O prompt do operador continua sendo o último recurso.

<a id="4213a0b3-003f"></a>

## test/modules/Test.ConfigServiceSync.psm1: Sync-ConfigSyncHostAlias

Travado na primeira elevação que este laço não consegue obter, para que o
operador seja solicitado no máximo uma vez. sudo armazena em cache uma
autenticação bem-sucedida por alguns minutos, portanto uma execução que
acerta a senha já pergunta apenas pelo primeiro nome; sem a trava, uma
execução que ERRA pergunta novamente por cada nome restante, e cada prompt
é uma nova rodada de três tentativas com a mesma rejeição. Dois nomes
transformam um erro em seis recusas, o que parece uma máquina discordando de
si mesma, e não uma resposta errada -- e o segundo prompt convida o operador
a concluir que deve ser solicitada uma senha DIFERENTE.

<a id="4213a0b3-0040"></a>

## test/modules/Test.ConfigServiceSync.psm1: Sync-ConfigSyncVaultCredential

Não há chave de autenticação interna para obter um valor possivelmente
rotacionado, e já existe uma entrada funcional aqui: mantenha-a, sem ida e
volta de rede nem prompt. Obter (e, portanto, atualizar) é impossível sem a
chave por decisão de projeto, então nada que a referência pudesse informar
mudaria o resultado. Passe -InternalAuthKey (ou armazene uma chave de
autenticação interna aqui) para que reexecuções atualizem isto contra a referência.

-RequireReferenceValue retira esse ramo das opções. O chamador declarou que
uma entrada não verificada não é aceitável, e, em um hospedeiro deixando de
ser standalone, ela é ativamente incorreta: a entrada mantida foi criada
aqui, para um compartilhamento que este hospedeiro servia anteriormente.

<a id="4213a0b3-0041"></a>

## test/modules/Test.ConfigServiceSync.psm1: Sync-HostConfiguration

Reescreva-os nos caminhos atuais ANTES que algo leia a configuração. Todo
consumidor subsequente procura apenas os nomes atuais, portanto um valor
sob um nome obsoleto é indistinguível de um ausente -- e "ausente" não é
inerte: Convert-ConfigSyncNetworkStorage lê a falta de poolStorageNetworkPath
como "a referência não possui armazenamento de grupos" e LIMPA o nível,
levando os nomes de usuários e deixando a sincronização de credenciais
iterando sobre uma lista vazia. Uma referência atrasada em uma renomeação
apagaria justamente a seção que foi buscada para fornecer.

Antes da barreira de verificação da atualidade, para que uma referência cujo único desvio
seja a grafia sincronize sem problemas -- inclusive sem supervisão, em que
essa barreira é uma falha fatal. O operador ainda é informado, porque a
correção pertence à origem: esta reescrita ocorre por sincronização, e a
referência continua servindo nomes antigos a todos os demais até ser reconciliada.

<a id="4213a0b3-0042"></a>

## test/modules/Test.ConfigServiceSync.psm1: Sync-HostConfiguration

No Linux, a montagem poolStorage executa `sudo -n mount/mkdir/umount`, que
falha sem um arquivo drop-in em /etc/sudoers.d concedendo NOPASSWD para essas
ações -- o WARN visto pelo operador no fim da validação, após o qual o
executor armazena localmente. O executor não supervisionado não pode elevar
os próprios privilégios, mas ESTA é uma sessão interativa do operador,
portanto ofereça instalar o drop-in agora (um prompt sudo), em vez de deixar
a montagem falhar. Idempotente (nenhuma ação quando já configurado), apenas
Linux (montagens no macOS via mount_smbfs -N e no Windows via mapeamentos SMB
não precisam de sudo), e condicionado a uma montagem configurada.

<a id="4213a0b3-0043"></a>

<a id="testmodulestestconfigservicesyncpsm1-reference-freshness-gate"></a>

## test/modules/Test.ConfigServiceSync.psm1: Barreira de verificação da atualidade da referência

Execute Start-StatusService.ps1 -Restart em um pwsh filho, transmitindo sua
saída à medida que chega, SEM dar a esse filho -- nem ao status service que
ele desacopla -- um handle para qualquer pipe lido por este processo.

No Windows, o formato da inicialização abaixo é essencial: adicionar -Redirect*
ou -NoNewWindow aqui habilita a herança de handles, o status service desacoplado
herda e mantém aberto o pipe stdout do chamador, e a reinicialização trava
silenciosamente e sem limite. Descrição completa da armadilha e por que o
redirecionamento para arquivo não a corrige:
docs/workarounds.md#a-detached-grandchild-pins-the-callers-pipe-on-windows
(também registrada em feedback_windows-detached-grandchild-pins-pipe.md).

<a id="4213a0b3-0044"></a>

## test/modules/Test.ConfigSync.psm1: Update-TestConfigFromTemplate

A configuração de notificações (incluindo segredos) fica em
test/status/extension/notification/transports.yml. O modelo é distribuído
na árvore em test/extension/notification/transports.yml.template.
As chaves legadas secrets.resend e notification.toEmailAddress em
test.config.yml não são mais válidas no esquema. A mesclagem
(ConvertTo-MergedHashtable) descarta chaves ausentes do modelo, portanto
valores legados preenchidos desapareceriam silenciosamente -- avise o
operador para movê-los manualmente. Migração flexível: NÃO mova credenciais
automaticamente entre arquivos.

<a id="4213a0b3-0045"></a>

## test/modules/Test.ConfigSync.psm1: Update-TestConfigFromTemplate

O arquivo no disco não corresponde mais à estrutura aninhada do modelo
(o esquema mudou). Faça backup do arquivo anterior e grave a mesclagem que
preserva valores (NÃO uma simples restauração do modelo): todo campo que
ainda corresponde ao mesmo caminho no novo esquema mantém seu valor do
arquivo anterior, e nós exclusivos do modelo são preenchidos com seus padrões.
Campos que realmente não correspondem mais (órfãos de nível superior ou
valores sob um nó cuja estrutura mudou) não podem ser mantidos -- se algum
continha um valor real, interrompa a execução para que o operador os migre
manualmente de .backup; caso contrário (uma mudança de esquema puramente
aditiva -- um novo nó que apenas faltava no arquivo), continue, pois nada
foi perdido e o laço não supervisionado não deve parar por uma mudança benigna.

<a id="4213a0b3-0046"></a>

<a id="testmodulestestconfigsyncpsm1-schema-migration-shape-departed"></a>

## test/modules/Test.ConfigSync.psm1: Migração de esquema (a estrutura deixou de corresponder)

Renderização da configuração ativa a partir do TEXTO DO MODELO, não de
ConvertTo-Yaml. YAML foi escolhido para este arquivo para que cada controle
pudesse conter sua explicação, mas uma ida e volta ConvertFrom-Yaml/ConvertTo-Yaml
descarta todos os comentários -- o test.config.yml de um operador ficou sem
nenhuma das 29 linhas de comentários do modelo. O modelo já é a fonte de
verdade do esquema E tem ordem canônica, portanto também serve de estrutura
de renderização: percorra suas linhas, mantenha comentários/linhas vazias/ordem
literalmente e substitua pelo valor do operador onde houver um no arquivo.
Chaves que o modelo não define mais são regravadas como entradas comentadas
`#   path: value`, em vez de desaparecer, para que uma renomeação deixe seu
valor antigo visível para migração manual (o scanner de Test.ConfigNaming
ignora linhas de comentários, portanto uma chave ali deixa de falhar na
verificação de chaves obsoletas).

<a id="4213a0b3-0047"></a>

<a id="testmodulestestconfigvalidatorpsm1-reusable-validation-primitives----schema-validation-emptiness-check"></a>

## test/modules/Test.ConfigValidator.psm1: Primitivas reutilizáveis de validação -- validação de esquema, verificação de vazio,

Primitivas reutilizáveis de validação -- validação de esquema, verificação
de vazio, verificação da atualidade da árvore git -- que qualquer script de verificação
(incluindo Test-Config.ps1) pode chamar sem reimplementar.

Todos os chamadores alcançam Write-Pass / Write-Fail / Write-Warn / Write-Info
de Test.Output.psm1, importado por este módulo no carregamento. Os contadores
PASS/FAIL sobrevivem na âncora $global: de Test.Output, portanto o resumo de
Test-Config no fim da execução reflete toda chamada a Test-AgainstSchema
e Test-RepoFreshness, independentemente da ordem de importação.

<a id="4213a0b3-0048"></a>

## test/modules/Test.CredentialProvider.psm1: Clear-CredentialProvider

Altere o dicionário compartilhado; NÃO revincule os nomes a um novo.
Yuruna.CredentialProvider cria um alias desse mesmo objeto em seu próprio
$script:Providers na importação, e esse alias é o que Get-CredentialProvider
e Register-CredentialProvider efetivamente leem e gravam. Revincular aqui
deixaria esse alias apontando para o dicionário original: a matriz informaria
um registro vazio enquanto as consultas continuariam resolvendo os provedores
integrados ativos, e um provedor registrado após a limpeza cairia na cópia
órfã, invisível para tudo. Um teste que acreditasse ter isolado o registro
exercitaria então os provedores reais -- e Repair-Credential invocaria um
`az acr login` real.

<a id="4213a0b3-0049"></a>

<a id="testmodulestestcriticalrecordpsm1-checksummed-generation-numbered-private-records-with-a-retained-previous"></a>

## test/modules/Test.CriticalRecord.psm1: Registros privados com checksum, número de geração e geração anterior preservada

Registros privados com checksum, número de geração e geração anterior
preservada, para estados que autorizam uma alteração: um diário de requisições,
um registro de recuperação, uma barreira do executor, uma reserva de orçamento.
Arquivos de progresso de melhor esforço (Test.StateFile) podem perder uma
gravação e apenas degradar os relatórios; perder ou corromper um desses deve,
em vez disso, recusar a alteração protegida, portanto o contrato é mais estrito:

  * Uma gravação vai para um novo arquivo temporário, é descarregada e lida de
    volta antes de substituir o registro, e a geração substituída é mantida
    como <Path>.prev. Uma falha em qualquer ponto deixa legível a geração
    antiga ou a nova, nunca uma mistura incompleta.
  * Cada registro contém seu tipo, um número de geração e um SHA-256 de seu
    conteúdo, para detectar um arquivo truncado ou com bits alterados e fazer
    o leitor recorrer à geração anterior, em vez de confiar nele.
  * Um gravador declara a geração lida (compare-and-set); um gravador obsoleto
    é recusado, em vez de sobrescrever silenciosamente uma decisão mais recente.
  * Uma versão de formato mais recente ou o tipo de outro registro nunca é
    substituído por uma geração mais antiga: isso é uma recusa, não uma alternativa.

A substituição atômica protege contra falhas do processo. Sobreviver a uma
queda de energia também exige descarregar os dados e a entrada do diretório
para armazenamento estável; essas operações são emitidas (fsync no Linux,
F_FULLFSYNC no macOS, renomeação write-through no Windows) e informadas por
FlushesConfirmed, mas nenhuma plataforma afirma durabilidade contra perda
de energia até que um teste de corte de energia a comprove, portanto
Get-YurunaCriticalRecordDurability declara process-crash em todas as plataformas.

Toda operação bloqueante de arquivo executa em uma tarefa do auxiliar
compilado e é aguardada com um Task.Wait limitado, portanto um sistema de
arquivos travado resulta em io-timeout, em vez de travar. Uma tarefa com
tempo esgotado mantém sua thread do pool (uma chamada bloqueada no kernel
não pode ser cancelada); os limites por etapa mantêm essa quantidade pequena.

<a id="4213a0b3-004a"></a>

<a id="testmodulestestdiagnosticpsm1-ocr-is-used-only-to-verify-the-echo-of-the-console-one-liner-before-it-is"></a>

## test/modules/Test.Diagnostic.psm1: OCR é usado apenas para verificar o eco do comando de console de uma linha antes de ser

OCR é usado apenas para verificar o eco do comando de console de uma linha
antes de seu envio. É estritamente um auxílio à precisão em um caminho de
depuração de melhor esforço, portanto a importação pode falhar: um hospedeiro
sem a cadeia OCR ainda deve poder coletar diagnósticos, apenas sem a verificação
pré-Enter. Todo consumidor sonda novamente com Get-Command e degrada para
'unknown', portanto uma importação malsucedida aqui custa somente a verificação.

-Global é obrigatório, não uma escolha de estilo. Uma reimportação apenas com
-Force remove um módulo já global para o escopo privado DESTE módulo, e a
próxima chamada Get-EnabledOcrProvider de qualquer outro chamador falha com
"not
recognized" (feedback_module_force_import_evicts_global.md).

<a id="4213a0b3-004b"></a>

<a id="testmodulestestdiagnosticpsm1-longest-tolerated-run-of-consecutive-normalized-characters-counted-only"></a>

## test/modules/Test.Diagnostic.psm1: Maior sequência tolerada de caracteres normalizados consecutivos, contada apenas

Maior sequência tolerada de caracteres normalizados consecutivos que o
comando esperado não explica, contada apenas depois de reconhecer o eco do
próprio comando (consulte AnchorMinRun abaixo). Calibrada com capturas reais:
uma linha digitada corretamente -- mesmo com uma tela inteira de histórico
sem relação acima dela -- mantém essa sequência abaixo de 40, enquanto uma
captura realmente corrompida por repetição automática mede ~860 e uma tecla
presa sintética chega aos milhares. 80 fica aproximadamente 2x acima do
limite saudável e uma ordem de grandeza abaixo da corrupção observada.

<a id="4213a0b3-004c"></a>

<a id="testmodulestestdiagnosticpsm1-how-many-consecutive-explained-positions-mark-where-the-commands-echo"></a>

## test/modules/Test.Diagnostic.psm1: Quantas posições explicadas consecutivas marcam onde o eco do comando

Quantas posições explicadas consecutivas marcam onde o eco do comando
realmente começa na tela. Até ver essa quantidade em sequência, uma posição
explicada é tratada como uma correspondência casual de um grama OCR no
histórico sem relação, e não como o próprio comando; o trecho não explicado
que segue essa correspondência NÃO é contado como corrupção. Isso permite
que um banner de login, um log de inicialização ou a saída de um comando
anterior, impressos antes do comando, permaneçam na tela -- legitimamente
não explicados e sem limite -- sem serem classificados como tecla presa.
12 é confortavelmente maior que a sequência incidental compartilhada por
um prompt de shell ou linha de log com o comando, e muito menor que o eco
contíguo do próprio comando.

<a id="4213a0b3-004d"></a>

## test/modules/Test.Diagnostic.psm1: Invoke-RemoteDiagnosticsConsole

Antes de digitar: descarte o que já estiver no buffer de linha do tty.
Sem isso, o resíduo se concatena aos primeiros caracteres do comando de
uma linha, deixando-o malformado antes mesmo de ser enviado. O resultado
é descartado deliberadamente: uma limpeza que não chegou não é motivo
para ignorar o conteúdo, e a verificação de eco abaixo decide se a linha
é utilizável. Ainda assim, precisa ser capturado: um [bool] não capturado
entra no fluxo de saída desta função e transforma a hashtable retornada
em um array de dois elementos, cujo .success então lê $null.

<a id="4213a0b3-004e"></a>

## test/modules/Test.Diagnostic.psm1: Invoke-RemoteDiagnosticsConsole

Nem a combinação de teclas nem o texto alcançaram o convidado, portanto o
console ainda contém exatamente os caracteres lidos pelo primeiro resultado.
Solicitar um segundo resultado aqui mediria novamente uma tela inalterada
e, portanto, certamente retornaria 'corrupt' outra vez -- um resultado sobre
o transporte apresentado como um resultado sobre o convidado. Informe o
transporte: "a redigitação nunca aconteceu" e "o convidado ecoou um comando
malformado" precisam de correções diferentes, e confundi-los leva quem lê
ao console quando o caminho das teclas é o que está quebrado.

<a id="4213a0b3-004f"></a>

## test/modules/Test.Diagnostic.psm1: Invoke-RemoteDiagnosticsConsole

TimeoutSeconds é o orçamento do chamador para o nível inteiro, não apenas
para aguardar o envio. A verificação de eco e uma possível redigitação
ocorrem antes dessa espera, portanto seu custo medido é descontado do
orçamento, e não acrescentado -- caso contrário, uma captura verificada e
redigitada excederia o orçamento por comando que Save-GuestDiagnostic deriva
do total do ciclo.

O limite mínimo existe porque o desconto não pode deixar a espera sem tempo:
o convidado ainda precisa buscar, executar e enviar a captura por POST após
Enter, e uma espera menor que isso certamente produziria um falso tempo
esgotado em uma linha corrigida com sucesso.

<a id="4213a0b3-0050"></a>

## test/modules/Test.Diagnostic.psm1: Select-MoreInformativeDiagResult

Seletor de alternativa para o manifesto em que todos os níveis falharam:
mantenha o nível malsucedido que produziu o texto de erro capturado mais longo.
Na prática, isso classifica apenas os dois níveis SSH (key-ssh, password-ssh)
-- são os únicos cujos resultados malsucedidos contêm .output. O nível de
console envia sua captura por POST diretamente para a pasta de falha e
retorna output='' (consulte Invoke-RemoteDiagnosticsConsole), portanto seu
candidato é sempre ignorado aqui. Preferir apenas a ordem dos níveis prenderia
o manifesto a key-ssh mesmo quando o password-ssh posterior capturou stderr
mais completo; portanto, o comprimento é o indicador de conteúdo entre ambos.
Comprimento é apenas um indicador: uma captura detalhada, mas pouco informativa
(por exemplo, o banner de uso de pwsh com exit-64), pode superar um erro real
conciso -- aceitável para um auxílio de depuração após falha. Um empate mantém
o atual, para que um nível posterior de mesmo tamanho não altere a escolha;
um candidato sem saída é ignorado, para que uma captura vazia nunca substitua uma real.

<a id="4213a0b3-0051"></a>

## test/modules/Test.Diagnostic.psm1: Invoke-GuestDiagnosticCapture

Verificação prévia: peça ao driver para aquecer o cache de vizinhos do hospedeiro
antes de consultar qualquer endereço. Sempre que o hospedeiro não é o servidor
DHCP da rede de convidados -- um vSwitch External, uma rede libvirt bridge-forward
-- não há fonte no próprio canal para consultar, e uma leitura passiva do
cache só encontra o convidado enquanto ele estiver falando conosco. Sem isso,
a resolução de endereço retorna o nome da VM, e Wait-SshReady gasta todo o
orçamento em "Could not resolve hostname", que nada informa sobre a falha real.
(nota de memória: hyperv_external_vswitch_arp_discovery)

Um verbo de contrato, não uma sondagem por nome: todo driver responde, e cada
um decide o que aquecer significa para si. Um driver cujo Get-VMIp já amplia
a sondagem internamente recusa aqui, para que sua própria varredura limitada
e memorizada não seja duplicada por uma ilimitada feita de fora.

<a id="4213a0b3-0052"></a>

## test/modules/Test.Diagnostic.psm1: Invoke-GuestDiagnosticCapture

Resolva uma vez a URL do status-service do hospedeiro e passe-a a AMBOS os
níveis SSH como alternativa de bootstrap via curl -- um bootstrap apenas
no nível de console deixa uma lacuna quando SSH está saudável, mas o convidado
ainda não extraiu o tarball yuruna (por exemplo, o watchdog do ciclo foi
acionado no meio de update.sh durante a fase apt-get): o comando SSH sai com
64 no banner de uso de pwsh, e o arquivo de diagnóstico captura esse banner,
em vez do estado real. Falhe de forma flexível para $null se o endpoint não
puder ser resolvido -- os níveis degradam para o comando `pwsh -File` simples,
e o nível de console continua sendo a alternativa final.

<a id="4213a0b3-0053"></a>

<a id="testmodulestestdownloadagentservicepsm1-a-first-boot-installs-the-go-toolchain-builds-the-daemon-and-mounts-the-pool"></a>

## test/modules/Test.DownloadAgentService.psm1: A primeira inicialização instala a cadeia de ferramentas Go, constrói o daemon e monta o compartilhamento do grupo

A primeira inicialização instala a cadeia de ferramentas Go, constrói o
daemon e monta o compartilhamento do grupo antes que algo se associe a :80.
Minutos, não segundos -- e ainda mais lento quando o tráfego apt passa por um
proxy de cache frio: medido em aproximadamente meia hora em um convidado
UTM Apple Silicon usando um mirror frio, contra dez a quinze minutos em um
hospedeiro x86 aquecido.

Dimensionado para o caso lento, não o típico. A sondagem retorna assim que
:80 aceita, portanto um orçamento nunca gasto pelo hospedeiro rápido não
lhe custa nada, enquanto um dimensionado para ele faz o hospedeiro lento
falhar durante uma construção que progredia normalmente. A espera se estende
além disso enquanto cloud-init informa que ainda trabalha, portanto este é
o limite mínimo, não toda a situação.

<a id="4213a0b3-0054"></a>

## test/modules/Test.EventSchema.psm1: Test-CycleEventSchema

$null é aceito como array vazio válido porque o if-pipeline do PowerShell
achata tanto arrays de um elemento QUANTO vazios na saída de um if;
`[string[]]$x = if (...) { @() }` produz $null no ramo vazio, embora a intenção
do emissor fosse "nenhuma entrada". Tratar $null como array vazio no validador
é a correção duradoura -- pontos de emissão que encontram a armadilha
permanecem válidos sem precisar localizá-los um a um. Um campo realmente
ausente (chave ausente da hashtable) ainda é detectado pelo laço de campos
obrigatórios acima.

<a id="4213a0b3-0055"></a>

## test/modules/Test.Extension.psm1: Import-Extension

Ignore a reimportação se o mesmo caminho .psm1 já estiver carregado. -Force
em Import-Module remove qualquer módulo com o mesmo nome base ('default')
-- então default.psm1 de uma segunda área é recarregado sobre o primeiro,
e as exportações do primeiro desaparecem da tabela global, mesmo que seu
ponto de chamada nunca tenha pedido atualização. Compare pelo caminho
absoluto para que edições durante desenvolvimento ainda permitam reimportar
(o operador pressiona Ctrl+C, altera algo e reexecuta -- a alteração de
mtime do arquivo não é verificada aqui, mas Remove-Module explícito +
nova chamada a Import-Extension ainda funciona).

<a id="4213a0b3-0056"></a>

<a id="testmodulestestextensionservicepsm1-the-host-side-of-the-extension-interface-what-an-area-declares-about-itself"></a>

## test/modules/Test.ExtensionService.psm1: O lado do hospedeiro da interface de extensões: o que uma área DECLARA sobre si,

O lado do hospedeiro da interface de extensões: o que uma área DECLARA
sobre si e o marcador de runtime que informa que este hospedeiro a executa.

A declaração -- qual VM, qual porta de saúde, qual script de início, qual
rótulo -- pertence ao bloco `service:` do próprio <area>.config.yml da área
(esquema: test/schemas/extension-config.schema.yml), e cada marcador é
gravado por uma função que sempre emite a chave uniforme de URL base,
independentemente do que mais uma área declare. Nenhum pode se espalhar por
scripts Start específicos de serviço, uma lista fixa de hospedeiros ou um
bloco por serviço no gravador de registros: esse formato torna os serviços
impossíveis de enumerar e exige uma edição do framework para cada novo.
Um novo serviço de extensão é descoberto por existir.

Toda leitura aqui é de melhor esforço e apenas de arquivos: um manifesto
malformado ou marcador ilegível não informa nada, em vez de lançar uma
exceção, porque uma conveniência de descoberta nunca pode fazer falhar
uma inicialização, desmontagem ou gravação de registro.

<a id="4213a0b3-0057"></a>

<a id="testmodulestestfailuretaxonomypsm1-canonical-failureclass--severity-taxonomy-the-single-source-of-truth-for"></a>

## test/modules/Test.FailureTaxonomy.psm1: Taxonomia canônica de FailureClass + Severity: a única fonte de verdade para

Taxonomia canônica de FailureClass + Severity: a única fonte de verdade
para o ValidateSet de Register-SequenceAction (Test.SequenceAction.psm1)
e a verificação de enum do validador de esquema (Test.EventSchema.psm1).
Um argumento de ATRIBUTO ValidateSet deve ser uma expressão constante e
não pode referenciar esses arrays, portanto Test.SequenceAction mantém uma
cópia literal e chama Assert-FailureTaxonomyInSync no carregamento do módulo
para detectar divergência silenciosa; todo OUTRO consumidor lê os arrays
aqui. Módulo terminal: não importa nada, portanto pode ser carregado com
segurança primeiro em qualquer conjunto de módulos.

<a id="4213a0b3-0058"></a>

<a id="testmodulestestframeworksourcepsm1-which-framework-snapshot-an-extension-service-vm-is-built-from"></a>

## test/modules/Test.FrameworkSource.psm1: De qual snapshot do framework é construída uma VM de serviço de extensão.

De qual snapshot do framework é construída uma VM de serviço de extensão.

Os daemons de serviço são binários Go cuja versão é marcada na COMPILAÇÃO
(`go build -ldflags "-X main.version=$VERSION_STR"`, lida do arquivo VERSION
do checkout obtido pelo convidado). Nada a relê depois: o convidado constrói
uma vez, e o número impresso na interface, em /api/hostinfo e em todo conteúdo
de diagnóstico fica congelado naquele momento por toda a vida da VM.

Isso torna a BUSCA toda a questão. O seed cloud-init obtém o checkout deste
hospedeiro do status service (/yuruna-archive.tar.gz) e, como alternativa,
clona o mirror público do github quando o hospedeiro não responde. O mirror
é um snapshot de release -- fica atrás do checkout de trabalho pelo tempo
desde a última publicação --, portanto a alternativa troca silenciosamente
o código implantado por uma base mais antiga, e a única evidência deixada é
uma linha no log cloud-init do convidado.

Este módulo torna isso visível nas duas pontas:

  * ANTES da construção, Assert-GuestFrameworkSource recusa uma inicialização
    cujo convidado não poderia alcançar o checkout deste hospedeiro. É uma
    parada antecipada barata -- economiza a construção de meia hora no
    convidado, nada mais. Não pode comprovar qual endereço o seed acabará
    incorporando, porque isso é resolvido por tipo de hospedeiro em New-VM.ps1.

  * DEPOIS que o daemon atende, Assert-ServiceVmFrameworkSource lê o que o
    convidado REALMENTE fez (/etc/yuruna/framework-source, gravado pelo seed)
    e o que o daemon realmente informa (/api/hostinfo). Essa verificação é
    a autoridade, e é ela que faz a inicialização falhar.

A separação importa: a verificação prévia é uma previsão e a posterior à
inicialização é uma observação, portanto só a segunda pode afirmar com
confiança que um serviço implantado executa código atual.

<a id="4213a0b3-0059"></a>

<a id="testmodulestestguestquarantinepsm1-failure-classes-whose-cause-lives-on-the-host-not-in-any-one-guest"></a>

## test/modules/Test.GuestQuarantine.psm1: Classes de falha cuja causa está no HOSPEDEIRO, não em um convidado individual

Classes de falha cuja causa está no HOSPEDEIRO, não em um convidado individual.
O disjuntor conta uma sequência da mesma classe por convidado, portanto
uma falha com escopo de hospedeiro -- que produz a mesma classe em todo
convidado que acessa a rede simultaneamente -- colocaria todos em quarentena
dentro de failuresToQuarantine ciclos e depois os IGNORARIA, deixando um
ciclo aprovado em um hospedeiro quebrado. Essas classes, portanto, nunca
iniciam nem prolongam uma sequência: o disjuntor existe para suprimir um
convidado individualmente quebrado, e uma falha de hospedeiro não pode ser
suprimida nem atribuída ao convidado que a informou.

<a id="4213a0b3-005a"></a>

<a id="testmodulestesthostaddressbeaconpsm1-two-pieces-of-state-not-one-because-they-answer-different-questions-and-a"></a>

## test/modules/Test.HostAddressBeacon.psm1: Dois estados, não um, porque respondem a perguntas diferentes e um

Dois estados, não um, porque respondem a perguntas diferentes e um campo
único os confunde de forma destrutiva. LastRecorded é "o que os registros
locais já dizem" e avança assim que são regravados. LastAnnounced é "o que
o grupo aceitou" e só avança diante de um anúncio confirmado, para que um
diretório inacessível seja tentado novamente no próximo tick, e não após
um intervalo inteiro do beacon.

Compartilhar um campo faz um diretório inacessível registrar novamente a
mudança de endereço e regravar os mesmos arquivos em TODO tick, para sempre:
o anúncio nunca tem sucesso, o campo nunca avança, e nada subsequente distingue
um hospedeiro que continua mudando de um que apenas não consegue alcançar o grupo.

<a id="4213a0b3-005b"></a>

<a id="testmodulestesthostaddressbeaconpsm1-renumbering-rate-warning"></a>

## test/modules/Test.HostAddressBeacon.psm1: Aviso de taxa de renumeração

Aviso de taxa de renumeração. O beacon é o único que vê toda mudança de
endereço, portanto é o único lugar que distingue "o hospedeiro mudou uma vez"
de "o hospedeiro recebe um endereço diferente a cada concessão". O segundo
é uma configuração incorreta do laboratório à qual o caminho de descoberta
apenas sobrevive -- custa uma ida e volta ao diretório por convidado por
mudança e abandona qualquer convidado cuja rede não consiga alcançar o
diretório --, portanto vale informar uma vez, com a solução, em vez de deixar
o operador deduzi-lo de um log de ciclo cheio de endereços corrigidos.

Com trava: informado uma vez por processo de beacon. Um aviso repetido a
cada renovação é um aviso que ninguém lê.

<a id="4213a0b3-005c"></a>

## test/modules/Test.HostAddressBeacon.psm1: Get-HostAddressChangeCount

-1, nunca 0, quando não há nada para ler. Um ciclo sem mudança de endereço
e um ciclo cujo registro nunca foi gravado são fatos diferentes, e apenas
um comprova sobrevivência a mudanças. Confundi-los levou cinco ciclos a
serem lidos como "não houve mudanças" quando três deles tiveram mudanças.

A linha de base mantém essa distinção correta na outra direção. Ela é
analisada -- portanto um hospedeiro com beacon ativo e endereço que nunca
mudou informa um 0 real --, mas não é uma mudança, portanto nunca conta.
Sem ela, o arquivo só aparecia depois que um hospedeiro já tivesse mudado,
e os hospedeiros mais estáveis do laboratório informavam que não podiam ser medidos.

<a id="4213a0b3-005d"></a>

## test/modules/Test.HostAddressBeacon.psm1: Get-HostAddressStabilityReport

Informa a taxa e para aí. Transformar "N endereços por dia" em drenagem --
muito menos em esgotamento -- exige o período de concessão e o tamanho do
escopo, e este beacon não recebe NENHUM DOS DOIS: vê apenas o log de
endereços do próprio hospedeiro. A mesma taxa é comum em uma concessão curta
e fatal em uma longa, portanto afirmar a leitura fatal é uma suposição
apresentada como medição e envia quem lê ao servidor DHCP para corrigir um
conjunto de endereços que pode estar quase livre. Informe a observação; nomeie os dois
números que resolveriam a questão.

<a id="4213a0b3-005e"></a>

## test/modules/Test.HostAddressBeacon.psm1: Get-HostAddressStabilityReport

"Mudou de endereço N vezes" só pode ser dito quando mais de um endereço
foi realmente visto. Uma janela em que todas as mudanças informam o mesmo
endereço atual registra um hospedeiro que continuou PERDENDO e RECUPERANDO
um endereço, não um que foi renumerado -- nenhum segundo endereço foi
observado e nenhuma concessão extra foi obtida. Dizer que mudou 62 vezes
inventa uma renumeração sem vestígio em nenhum outro lugar e esconde o
sinal real: algo perde o endereço deste hospedeiro e lhe devolve o mesmo.

<a id="4213a0b3-005f"></a>

## test/modules/Test.HostAddressBeacon.psm1: Get-HostAddressStabilityReport

Sem histórico de endereços. Qual das duas situações ocorre depende de o
status service já ter sido iniciado aqui: iniciá-lo materializa
.status-service.ps1 no diretório de runtime, e o beacon desacoplado de
endereços do hospedeiro grava sua primeira linha quando observa um endereço
pela primeira vez. Sem marcador é o estado esperado de um hospedeiro recém
configurado -- diga isso claramente e não peça nada, porque não há o que
fazer -- e também o estado estável de um hospedeiro deliberadamente executado
com status service desabilitado (statusService.enabled false ou
-NoStatusService), portanto a mensagem não deve afirmar que nenhum ciclo
executou, apenas que o registro não começou. Um marcador sem histórico
significa que um serviço iniciado nunca registrou, o que merece um aviso,
e não apenas uma informação consultiva: um hospedeiro não monitorado é
justamente onde se esconde renumeração sem limite.

<a id="4213a0b3-0060"></a>

<a id="testmodulestesthostautomationstatepsm1-the-version-of-the-capture-format-and-equally-of-what-its-readers-mean"></a>

## test/modules/Test.HostAutomationState.psm1: A versão do FORMATO da captura e também do significado atribuído por seus leitores

A versão do FORMATO da captura e também do significado atribuído por seus
leitores. Incremente-a sempre que um leitor passar a ver algo que antes não
via, porque "present = $false" é a resposta dada TANTO quando o controle
realmente não estava definido QUANTO quando não pôde ser lido. Uma captura
gravada por um leitor antigo é confiável sobre os valores que contém, mas
não sobre aqueles que declara ausentes, e Invoke-HostKnobRestore é onde essa
distinção precisa ser aplicada -- remoção é o ramo em que cai um controle
ilegível, e uma remoção não pode ser desfeita.

<a id="4213a0b3-0061"></a>

## test/modules/Test.HostAutomationState.psm1: Get-MacPreAutomationState

O seletor de hospedeiro pertence ANTES do verbo; emitido com o verbo primeiro,
`defaults` vincula '-currentHost' como domínio e informa todo controle ByHost
como ausente -- portanto uma captura assim registra "não havia nada aqui"
para três controles com valores reais, e a restauração os exclui.

O argv é montado DENTRO do leitor para que a resolução do construtor seja
coberta pelo catch de Invoke-CaptureRead. Esta captura ocorre nos segundos
antes da alteração do hospedeiro, e uma instalação incapaz de alcançar o
módulo do lado de aplicação deve registrar "não pôde ser lido" e deixar a
configuração continuar, não abortá-la apenas para registrá-la.

<a id="4213a0b3-0062"></a>

## test/modules/Test.HostAutomationState.psm1: Get-WindowsPreAutomationState

Duas decisões de desempenho, ambas valendo um minuto do dia de um operador:

  -PolicyStore ActiveStore -- a política efetiva de runtime, que também é
  o significado de "esta regra está habilitada agora?". Medido em um
  hospedeiro com 318 regras: 2.6 s aqui contra 43 s no armazenamento padrão,
  que mescla os armazenamentos persistente e GPO em toda travessia de associação.
  Ambos selecionam exatamente o mesmo conjunto de regras.

  UM pipeline em lote para Get-NetFirewallPortFilter, associado por InstanceID
  (igual ao Name da regra), em vez de uma chamada de filtro por regra dentro
  de Where-Object. Por regra custa uma travessia de associação CIM para cada
  uma -- 318 delas, 55 s.

<a id="4213a0b3-0063"></a>

<a id="testmodulestesthostbootstrappsm1-import-the-three-sibling-modules-so-a-caller-that-only-imports"></a>

## test/modules/Test.HostBootstrap.psm1: Importa os três módulos irmãos para que um chamador que só importa

Importa os três módulos irmãos para que um chamador que só importa
Test.HostBootstrap (ou Test.HostContract -- a fachada reimporta Bootstrap)
ainda receba toda a interface Test.Host*. -Global para que os nomes cheguem
à sessão do chamador; -DisableNameChecking porque Get-* / Test-* / Assert-* /
Set-* / Update-* / Install-* abrangem várias famílias de substantivos.
NÃO -Force: são módulos irmãos COMPARTILHADOS, carregados transitivamente
por outros módulos, e uma reimportação -Force os removeria/reinicializaria
(e seu estado $script:) debaixo desses chamadores -- importe apenas quando ausentes.

<a id="4213a0b3-0064"></a>

## test/modules/Test.HostCondition.Mac.psm1: Get-MacPmsetGuardList

AlwaysApply: macOS não lista disablesleep em `pmset -g custom` até que tenha
sido gravado ao menos uma vez, portanto, em um Mac que nunca o definiu --
justamente o hospedeiro que precisa dele --, a ausência seria lida como
"já 1", e a gravação nunca ocorreria. Com disablesleep 0, um MacBook suspende
assim que sua tampa fecha, interrompendo todos os convidados em execução
e o restante do ciclo.
AbsentEquivalent 0: um Mac em que disablesleep nunca foi gravado se comporta
exatamente como um com 0 -- suspende ao fechar a tampa --, portanto 0 é o
que retorna o hospedeiro ao estado anterior, não uma suposição de padrão.

<a id="4213a0b3-0065"></a>

## test/modules/Test.HostCondition.Mac.psm1: Get-MacScreenLockIssue

7. System sleep + disk sleep -> Never. Somente repouso da tela (a região
   "Display sleep -> Never") não basta: acordar de repouso do sistema/disco
   bloqueia novamente a tela em Ventura+, independentemente das configurações
   do protetor de tela. Set-MacHostConditionSet desabilita ambos, portanto
   a barreira deve verificá-los novamente.
8. Proteções pmset ampliadas (Power Nap, standby, autopoweroff, hibernate, ...)
   aplicadas por Set-MacHostConditionSet. A barreira as verifica novamente
   pela mesma Get-MacPmsetGuardList aplicada por Set-, portanto o conjunto
   verificado é exatamente o aplicado, e um hospedeiro com desvio falha aqui,
   em vez de apagar a tela do UTM durante a execução. Uma chave ausente de
   'pmset -g custom' (dependente da versão do macOS) é ignorada aqui mesmo
   quando Set- força sua gravação (AlwaysApply): um Mac sem tampa nunca expõe
   disablesleep, e falhar na barreira por uma chave que esse hospedeiro não
   pode ter bloquearia um desktop perfeitamente válido para testes.
   Um laptop que volta a 0 lista a chave, portanto ainda falha aqui.

<a id="4213a0b3-0066"></a>

## test/modules/Test.HostCondition.Mac.psm1: Initialize-SudoCache

Um chamador já obteve a ÚNICA autorização desta execução e informou isso
(install/<host>.sh, install/setup.ps1). Ainda assim, o timestamp está frio
-- expirou, ou a pós-instalação de um cask brew executou `sudo -k` --, e
perguntar novamente aqui quebraria a promessa "you will be prompted ONCE"
impressa pelo chamador, para uma elevação de que esta própria função não
precisa. Retorne $false silenciosamente; toda gravação privilegiada
subsequente sonda por si com Test-MacSudoAvailable e informa o comando exato
a executar quando não pode elevar, uma resposta útil ao operador, em vez
de uma segunda caixa de senha sem contexto.

<a id="4213a0b3-0067"></a>

## test/modules/Test.HostCondition.Mac.psm1: Initialize-SudoCache

Sem supervisão: ninguém está no console para digitar uma senha. O executor
de testes inicia seu interno com stdout nativo conectado ao console, portanto
o interno herda o terminal de inicialização -- `sudo -v` aqui imprimiria o prompt
nesse terminal e bloquearia todo o hospedeiro até o watchdog encerrá-lo,
com a página de status ainda mostrando o verde do ciclo anterior. Recuse
exatamente como no caminho preparado pelo wrapper: retorne $false
silenciosamente e deixe o chamador ignorar o trabalho elevado ou fazê-lo
falhar com uma mensagem que indique a ação necessária. Elevação de um
hospedeiro não supervisionado pertence à INICIALIZAÇÃO (ou a um arquivo
drop-in em /etc/sudoers.d), nunca ao meio do ciclo.

<a id="4213a0b3-0068"></a>

## test/modules/Test.HostCondition.Mac.psm1: Initialize-SudoCache

Cache frio E sem contexto do wrapper: imprima o aviso amigável e solicite a senha.

Write-Host, não Write-Output: todo chamador envolve esta função como
`[void](Initialize-SudoCache ...)`, e essa conversão descarta todo o fluxo
de sucesso -- um aviso Write-Output seria engolido, deixando o operador
apenas com "[sudo] password for ..." e sem explicação. Isso também mantém
correto o contrato [OutputType([bool])]: linhas da caixa no fluxo de sucesso
transformam o retorno em ARRAY, e um array não vazio sempre é verdadeiro,
portanto `if (-not (Initialize-SudoCache ...))` em test/Test-Config.ps1 nunca
seria acionado no caminho frio.

<a id="4213a0b3-0069"></a>

<a id="testmodulestesthostconditionmacpsm1-utm-ships-its-command-line-interface-inside-the-app-bundle-and-no-installer"></a>

## test/modules/Test.HostCondition.Mac.psm1: UTM distribui sua interface de linha de comando DENTRO do pacote do aplicativo, e nenhum instalador

UTM distribui sua interface de linha de comando DENTRO do pacote do aplicativo,
e nenhum instalador -- nem o cask nem o .dmg -- coloca esse diretório no PATH.
Toda operação de VM do ambiente de testes invoca `utmctl`, portanto um
hospedeiro com UTM.app corretamente instalado ainda não consegue iniciar
um único ciclo até que o binário seja acessível pelo nome. O link vai em
/usr/local/bin porque esse diretório consta de /etc/paths padrão, o que
significa que um shell de login, um LaunchAgent e um `ssh host command`
o veem; bin do Homebrew só alcança shells que executaram `brew shellenv`.

<a id="4213a0b3-006a"></a>

## test/modules/Test.HostCondition.Mac.psm1: Set-MacHostConditionSet

Todo bloco privilegiado abaixo sonda `sudo -n true` imediatamente antes
de gravar, e toda gravação usa -n. Os dois fatos que uma variável de ambiente
poderia conter -- quem iniciou esta execução, se alguém digitou uma senha
minutos atrás -- não respondem se root está acessível AGORA: o timestamp
pode ter expirado durante uma etapa longa, a pós-instalação de um cask brew
pode ter executado `sudo -k`, ou uma regra /etc/sudoers.d pode conceder a
gravação sem envolver qualquer timestamp.

Initialize-SudoCache ainda executa primeiro para que um operador em um
terminal seja solicitado uma vez, visivelmente, com as razões na tela, em
vez de encontrar um prompt de senha isolado no meio de um bloco. Recusa
silenciosamente quando não há ninguém para perguntar, e as sondagens abaixo
encaminham cada bloco para seu ramo de aviso com o comando exato. Ignorado
inteiramente quando se exige não perturbar a interface gráfica: a preparação
pode emitir um prompt de senha, e as sondagens por bloco já cobrem um
hospedeiro em que root não está acessível.

<a id="4213a0b3-006b"></a>

## test/modules/Test.HostCondition.Mac.psm1: Set-MacHostConditionSet

Somente repouso da tela não basta: repouso do sistema -> a tela bloqueia ao
acordar, independentemente das configurações do protetor de tela. O repouso
do disco tem o mesmo efeito -- ao acordar, verifica novamente o estado de
bloqueio e, em Ventura+, pode ativar o bloqueio de tela unificado mesmo com
askForPassword=0.

Cada chave é decidida pelo próprio valor, pelo mesmo auxiliar que decide as
proteções ampliadas, porque ambos podem divergir: um hospedeiro com sleep=0
e disksleep=10 é exatamente o que a barreira recusa, e uma decisão única
obtida de `sleep` informaria "already Never" e não gravaria nada em toda
execução -- deixando o operador repetir um script de configuração incapaz
de alcançar a configuração que interrompe a barreira.

<a id="4213a0b3-006c"></a>

## test/modules/Test.HostCondition.Mac.psm1: Set-MacHostConditionSet

SOMENTE as chaves pendentes. `pmset` não tem exclusão, portanto uma chave que
este hospedeiro nunca teve não pode ser retirada depois: a captura anterior
à automação a registra como ausente, e a restauração não tem nada para
gravar além de um valor que ninguém escolheu. Get-MacPmsetGuardPending já
faz exatamente a separação correta -- uma chave presente com valor errado,
mais as chaves AlwaysApply cuja ausência não traz informação e às quais a
lista de proteções dá um AbsentEquivalent para permitir desfazê-las na
restauração. Tudo que deixa de fora é um nome não exposto por esta versão
do macOS, e gravá-lo não oferece nada além de uma configuração do hospedeiro
que sobrevive à automação. Os nomes das chaves vêm do conjunto pendente para
que esta mensagem não divirja do que é efetivamente gravado.

<a id="4213a0b3-006d"></a>

## test/modules/Test.HostCondition.Mac.psm1: Set-MacHostConditionSet

O padrão do UTM é terminar quando sua última janela fecha, e seu caminho
de encerramento SALVA O ESTADO de toda VM ainda ativa, em vez de deixá-la
executando: voltam como `suspended`, não `started`. As VMs de serviço (proxy
de cache, stash, pool-control) são infraestrutura duradoura usada pelos
convidados durante todo o ciclo, portanto fechar uma janela de VM -- ou a
janela da biblioteca -- retira silenciosamente as dependências do ciclo,
e todo convidado que precisa do proxy ou stash então falha. Manter o
aplicativo residente elimina a rota de fechamento de janela para esse estado.
UTM lê isto na inicialização, portanto uma instância já em execução mantém
o comportamento antigo até ser iniciada novamente.

<a id="4213a0b3-006e"></a>

## test/modules/Test.HostCondition.Mac.psm1: Set-MacHostConditionSet

`sysadminctl -screenLock` é o controle unificado moderno (macOS 13+)
gravado por System Settings > Lock Screen > "Require password after screen
saver begins or display is turned off".
CRÍTICO: substitui askForPassword / askForPasswordDelay legados.
Uma máquina com idleTime=0, askForPassword=0 e askForPasswordDelay=MAX_INT
ainda pode bloquear após minutos porque sysadminctl informa, por exemplo,
"screenLock delay is 300 seconds".

"off" define o atraso como -1 (desabilitado). sysadminctl exige a senha do
usuário (não sudo) porque altera a entrada segura do keyring que sustenta
a política de tela de bloqueio. `-password -` lê stdin -- um segundo prompt
aparece após o prompt sudo.
Get-MacScreenLockDisabled remove o prefixo NSLog e aplica a verificação
compartilhada "off" (também usada pela barreira de Assert-ScreenLock), para
que aplicação e asserção concordem sobre o que conta como desabilitado.

<a id="4213a0b3-006f"></a>

## test/modules/Test.HostCondition.Mac.psm1: Set-MacHostConditionSet

Este bloco precisa de duas coisas diferentes, e só uma é root.
`-password -` lê a senha da CONTA em stdin, portanto uma execução incapaz
de apresentar uma pergunta a uma pessoa não pode fazer isso: em um filho
capturado, stdin está fechado, a leitura retorna EOF, e a tentativa seria
informada como desabilitação MALSUCEDIDA, em vez de uma que nunca foi possível.
Informe o comando de uso único -- também quando o chamador pediu que a
interface gráfica não fosse perturbada, pois a própria leitura de senha
é um prompt no terminal da sessão.

<a id="4213a0b3-0070"></a>

## test/modules/Test.HostCondition.Mac.psm1: Set-MacHostConditionSet

`com.apple.autologout.AutoLogOutDelay` (nível de sistema) é o controle
"Log out after N minutes of inactivity" em Lock Screen / Security. macOS
devolve o usuário a loginwindow após o atraso -- indistinguível de um
bloqueio ("exige senha"), mas nenhuma chave de protetor de tela / pmset
controlada por nós o impediria. Nível de sistema
(/Library/Preferences/.GlobalPreferences); a GRAVAÇÃO exige sudo, mas o
plist tem modo 644, portanto a LEITURA não -- lê-lo por sudo gastaria uma
elevação em um valor visível a qualquer um e, em um hospedeiro incapaz de
elevar, esconderia completamente o estado.

<a id="4213a0b3-0071"></a>

## test/modules/Test.HostCondition.Mac.psm1: Set-MacHostConditionSet

Quando o ambiente de testes chama `tell application "UTM" to activate`
(a alternativa de teclas de convidado AVF em Send-KeyUTM / Send-TextUTM),
macOS por padrão leva o operador através de Spaces para a janela UTM --
uma interrupção indesejada quando ele mudou para VS Code em outro Space
para investigar algo durante um teste longo.
AppleSpacesSwitchOnActivation=false mantém a ativação no Space atual;
UTM ainda fica à frente (para receber as teclas), mas a visão do operador
permanece no lugar. Dock precisa ser reiniciado para a mudança entrar em vigor.

<a id="4213a0b3-0072"></a>

<a id="testmodulestesthostconditionmacpsm1-host-clock"></a>

## test/modules/Test.HostCondition.Mac.psm1: Relógio do hospedeiro

Permissões sem as quais o ambiente de testes não pode executar e que
NENHUMA quantidade de root fornece. macOS as mantém nos bancos TCC, System
Integrity Protection os protege de todo gravador, inclusive root,
`tccutil` só pode REDEFINIR uma decisão, nunca concedê-la, e a única forma
compatível de pré-autorizar qualquer uma é um payload Privacy Preferences
Policy Control entregue por um servidor MDM no qual o Mac esteja inscrito.
Uma senha de administrador não oferece nada aqui, portanto nenhuma elevação
transforma isto em uma etapa não supervisionada.

O que É possível, e o que esta região faz: detectar cada concessão SEM
emitir uma caixa de diálogo, emitir o diálogo do sistema e abrir o painel
exato de configurações com um operador presente, nomear o aplicativo que
ele realmente precisa habilitar e esperar que o faça, para que a resposta
seja confirmada, não presumida.

Um registro, porque as mesmas concessões são informadas em dois lugares
-- a barreira de configuração antes do ciclo e a asserção por ciclo.
Instruções mantidas duas vezes divergem, e um operador que segue um conjunto
e depois é recusado pelo outro não consegue saber qual dos dois está obsoleto.

<a id="4213a0b3-0073"></a>

## test/modules/Test.HostCondition.psm1: Register-HostConditionProvider

Convergência opcional por ciclo para o exportador de métricas deste hospedeiro:
instale um onde não há nenhum e forneça os coletores, a porta e a regra de
firewall publicados pelo hospedeiro. Assinatura: `param()`, retorna um
registro com Status e Reason. Invocado por Initialize-HostMetricsExporter.

Seu próprio campo, em vez de parte de Assert, pela mesma razão que Assert
e Set são separados em todo outro lugar aqui: Assert decide se um ciclo
pode executar e informa isso com bool, e uma alteração do hospedeiro
escondida atrás dessa resposta é invisível a todo leitor da chamada.

$null para um hospedeiro em que este trabalho precisaria pedir seu privilégio.
Essa é a linha: o laço não supervisionado não faz nenhuma correção que pare
para perguntar, porque um laço esperando por uma credencial que ninguém
está presente para digitar é um travamento. Um hospedeiro só registra este
campo quando o ciclo já possui o que a correção precisa -- por isso o
chamador fica depois da barreira de elevação, não antes.

<a id="4213a0b3-0074"></a>

<a id="testmodulestesthostconditionwindowspsm1-windows-sibling-of-testhostconditionpsm1-applies-and-asserts-the"></a>

## test/modules/Test.HostCondition.Windows.psm1: Módulo irmão Windows de Test.HostCondition.psm1: aplica E verifica as

Módulo irmão Windows de Test.HostCondition.psm1: aplica E verifica as
pré-condições por hospedeiro para testes não supervisionados de VMs em
host.windows.hyper-v (serviço Hyper-V, tempo limite da tela, bloqueio por
inatividade, relógio do hospedeiro, regras de firewall para ICMPv4 + a porta
TCP de status-service e -- quando YURUNA_VIRTUAL_DISPLAY está definido --
escala de tela/texto = 100% para que HiDPI não prejudique OCR em capturas de
tela de VMs), mais a sondagem apenas informativa da rede de convidados,
despachada pela fachada pelo campo NetworkHealth. Carregado pela fachada
Test.HostCondition.psm1; os chamadores continuam importando a fachada e
resolvendo esses nomes por seu Export-ModuleMember. Consulte
Test.HostCondition.psm1 para a justificativa da separação por plataforma.

<a id="4213a0b3-0075"></a>

## test/modules/Test.HostCondition.Windows.psm1: Install-YurunaVirtualDisplay

Condição de ativação explícita: a tela virtual (conexão usbmmidd + imposição
de clone / resolução / escala) só executa quando YURUNA_VIRTUAL_DISPLAY é
verdadeiro. Não definido/false torna isto totalmente sem efeito -- nenhuma
tela virtual é conectada, e a topologia, resolução e escala do hospedeiro
permanecem intactas. Test-YurunaVirtualDisplayEnabled também respeita um
valor persistido no escopo User/Machine, para que um executor iniciado de
um shell que o definiu ali (e, portanto, tem um bloco de processo obsoleto)
ainda conecte a tela. Consulte docs/host-hyperv.md.

<a id="4213a0b3-0076"></a>

## test/modules/Test.HostCondition.Windows.psm1: Install-YurunaVirtualDisplay

o limite mínimo de resolução OCR.
A tela virtual deve DUPLICAR (não estender) a física e ser a principal,
para que a superfície capturada permaneça ativa quando o monitor físico
é removido (desconectar um cabo remove a principal a quente; se ela fosse
a física, a captura congelaria). Como a topologia é um clone, janelas do
hospedeiro (Display Settings etc.) ainda aparecem no monitor físico
enquanto conectado. A fonte do clone deve ser >=1920x1080 ou OCR no frame
capturado falha. Melhor esforço: uma falha de topologia / resolução não
pode fazer o ciclo falhar (o monitor conectado é a parte essencial),
portanto avise e mantenha o status do monitor.

<a id="4213a0b3-0077"></a>

## test/modules/Test.HostCondition.Windows.psm1: Set-YurunaDisplayCloneAndResolution

A tela VIRTUAL é definida como principal para que a superfície capturada
pelo executor fique ancorada na tela sempre presente; desconectar o monitor
físico então apenas remove um secundário, e a captura do console do convidado
nunca congela. Um clone só se vincula quando toda tela ativa compartilha
exatamente o mesmo modo; a tela virtual é fixa em 1920x1080 (a região
"Force every VIRTUAL display to the 1920x1080 floor"), portanto o monitor
físico também é normalizado para 1920x1080 -- reduzido se antes usava uma
resolução maior. Reduzir um monitor de alta resolução durante um teste é
o custo aceito de uma superfície sempre duplicada; a alternativa (deixar
um monitor de alta resolução estendido) abandona janelas do hospedeiro em
uma região separada da área de trabalho. Como a topologia é um clone,
o operador ainda vê a mesma imagem no monitor físico enquanto conectado.

<a id="4213a0b3-0078"></a>

## test/modules/Test.HostCondition.Windows.psm1: Remove-YurunaVirtualDisplay

Desmonte com força crescente, parando assim que nenhum monitor usbmmidd
restar. `enableidd 0` desabilita a superfície do monitor, mas deixa o
dispositivo preparado para um `enableidd 1` rápido no próximo ciclo. Se
um monitor ainda persistir (um devnode travado ou um switch KVM no meio
do ciclo que o deixou presente, mas não saudável), avance para
`stop usbmmidd`, que desacopla o nó do dispositivo -- a própria etapa de
desinstalação do fornecedor. O INF do driver assinado permanece no cache
ProgramData em ambos os casos, portanto a próxima execução reconecta sem
novo download (Install-YurunaVirtualDisplay prepara novamente o devnode
se `stop` o removeu).

<a id="4213a0b3-0079"></a>

## test/modules/Test.HostCondition.Windows.psm1: Set-WindowsHostConditionSet

Uma alocação de memória de VM recusada é decidida pela carga de commit do
hospedeiro contra seu limite de commit naquele instante, e nenhum dos dois
números sobrevive em qualquer artefato gravado pelo ambiente de testes --
o único registro no hospedeiro é um evento Windows de nível Information
que nada coleta. Um exportador consultado torna isso mensurável depois
do fato e leva consigo o censo de CPU, discos e VMs do hospedeiro.

Nunca uma condição não atendida, qualquer que seja o resultado. Telemetria
que existe para explicar uma falha não pode virar motivo de falha, e um
hospedeiro informado como degradado pela ausência de um endpoint de métricas
-- enquanto provisiona seus convidados perfeitamente -- ensina o operador
a parar de ler o estado degradado que importa. Emite um aviso, nomeando o
comando que corrige, e, daí em diante, o destino de coleta ficar indisponível
é o sinal permanente.

<a id="4213a0b3-007a"></a>

## test/modules/Test.HostCondition.Windows.psm1: Test-WindowsGuestNetworkHealth

O classificador de uplink é privado do módulo do driver Hyper-V, que os
chamadores deste módulo voltados ao operador (Test-Config,
Enable-TestAutomation) nunca carregam. Sua ausência significa que o switch
não foi avaliado, o que conta como utilizável.
Chame apenas com -SwitchName: vincular qualquer parâmetro de registros
coloca todos em modo de injeção de uma vez, portanto uma chamada
parcialmente preenchida julgaria o switch contra registros de adaptadores
e endereços que ninguém forneceu.

<a id="4213a0b3-007b"></a>

<a id="testmodulestesthostcontractpsm1-thin-facade-for-the-testhost-family"></a>

## test/modules/Test.HostContract.psm1: Fachada fina para a família Test.Host*

Fachada fina para a família Test.Host*. A interface Test.Host* é dividida
em quatro módulos irmãos por limites de funcionalidades (detecção, conjunto
de condições, git/projeto, bootstrap do driver de hospedeiro). Importar este
arquivo importa os quatro com -Global, para que chamadores que conhecem
apenas a fachada -- o executor, Debug-TestSequence.ps1, extensões de
sequência -- alcancem toda exportação. Código novo deve importar diretamente
o módulo irmão correspondente.
Alinhado a host/Yuruna.Host.Contract.psm1: o lado do ambiente de testes
do limite do contrato de hospedeiro.

<a id="4213a0b3-007c"></a>

<a id="testmodulestesthostcontractpsm1-testhostdetection-carries-the-testvmutility--global-self-heal-at-its"></a>

## test/modules/Test.HostContract.psm1: Test.HostDetection contém a autocorreção -Global de Test.VMUtility em seu

Test.HostDetection contém a autocorreção -Global de Test.VMUtility em seu
próprio escopo de módulo, portanto importá-lo (primeiro na lista abaixo)
recoloca Wait-VMRunning / Test-IpAddress / Format-IpUrlHost na sessão do
chamador a cada carregamento da fachada. Manter a autocorreção apenas no
módulo irmão também cobre os chamadores que importam Test.HostDetection
diretamente, sem passar por esta fachada.
Yuruna.Common contém Get-YurunaServiceVmName, resolvido pela lista de
isenções de Stop-ConcurrentVM no vínculo de parâmetros. Importado aqui,
em vez de depender da importação -Global de um driver de hospedeiro:
o padrão precisa ser vinculado mesmo quando o chamador chegou a esta
fachada sem carregar um driver.

<a id="4213a0b3-007d"></a>

<a id="testmodulestesthostdetectionpsm1-host-detection--per-host-preflight-identifies-the-platform"></a>

## test/modules/Test.HostDetection.psm1: Detecção de hospedeiro + verificação prévia por hospedeiro: identifica a plataforma

Detecção de hospedeiro + verificação prévia por hospedeiro: identifica a
plataforma (host.macos.utm / host.windows.hyper-v / host.ubuntu.kvm), mapeia
o tipo de hospedeiro para a pasta de repositório, deriva nomes de VMs de
teste, verifica os requisitos mínimos de runtime (elevação no Windows,
/dev/kvm no Linux, pacote UTM no macOS) e trata a reexecução para o grupo
libvirt em novas instalações Ubuntu. Exclui deliberadamente qualquer
alteração da configuração do hospedeiro (Set-*HostConditionSet fica em
Test.HostCondition.psm1) ou importação de drivers de hospedeiro
(Initialize-YurunaHost fica em Test.HostBootstrap.psm1).

<a id="4213a0b3-007e"></a>

<a id="testmodulestesthostdetectionpsm1-module-level-self-healing-re-import-testvmutilitypsm1-with--global"></a>

## test/modules/Test.HostDetection.psm1: Autocorreção no nível do módulo: reimporta Test.VMUtility.psm1 com -Global

Autocorreção no nível do módulo: reimporta Test.VMUtility.psm1 com -Global
sempre que este módulo é carregado. O interno importa Test.HostContract
em um processo novo a cada ciclo, e a fachada importa este módulo irmão;
a importação -Global aqui mantém Wait-VMRunning / Test-IpAddress /
Format-IpUrlHost (e os outros auxiliares entre hospedeiros) na sessão do
executor, mesmo quando algo no meio do ciclo apagou a tabela global de
módulos -- por exemplo, uma etapa de sequência chamando
`Get-Module | Remove-Module`, ou um Import-Module transitivo sem -Global.
Sem isso, o runspace de um chamador poderia perder Wait-VMRunning em um
momento sem relação e falhar na próxima etapa New-VM.Resource. Este módulo
(não a fachada Test.HostContract) detém a autocorreção, para que ela também
ocorra para chamadores que importam Test.HostDetection diretamente.
-ErrorAction SilentlyContinue: um módulo irmão ausente não é fatal aqui;
Initialize-YurunaHost ainda falha explicitamente depois se realmente quebrado.

<a id="4213a0b3-007f"></a>

## test/modules/Test.HostDetection.psm1: Get-TestVMName

Proteção de segurança do shell no ponto de entrada da composição. O nome
da VM passa para comandos interpolados subsequentes -- uma invocação
virt-viewer KVM via `bash -c` e CLIs de hipervisor em toda plataforma.
O segmento HostId é reduzido a [A-Za-z0-9] acima, mas nem o prefixo
configurável pelo operador (vmStart.testVmNamePrefix) nem a chave do
convidado são: qualquer um com espaço ou metacaractere de shell passaria
pela interpolação. Rejeite aqui para que um nome com metacaractere nunca
alcance uma string de comando, qualquer que seja o tipo de hospedeiro
que acabe executando-a.

<a id="4213a0b3-0080"></a>

## test/modules/Test.HostDetection.psm1: Test-HostRequirement

Modo silencioso: suprime a indicação final "There may be more host-health
recommendations available...". Linhas Write-Warning de falha existentes
NUNCA são silenciadas -- um requisito ausente sempre é mostrado. A indicação
é o único banner silenciado por esta opção; um chamador automatizado
(Remove-TestVMFiles.ps1 -Quiet) passa -Quiet para que a desmontagem do ciclo
não emita ruído de saúde do hospedeiro. -InformationAction Continue fixo
do Write-Information interno, de outro modo, substitui qualquer
-InformationAction SilentlyContinue do chamador, por isso uma opção explícita é necessária.

<a id="4213a0b3-0081"></a>

## test/modules/Test.HostGit.psm1: Invoke-GitPull

Busca sem alterar a árvore de trabalho. Novas tentativas com espera linear
progressiva após falha: no macOS, Application Firewall bloqueia conexões
TCP de saída logo após um processo abrir um novo socket de escuta
(status service, encaminhadores de caching-proxy-service). Aparece como
"Couldn't
connect / No route to host" nas primeiras buscas de um executor novo e
se recuperou após uma espera de 5s em execuções observadas. 5 novas
tentativas com esperas de 10/20/30/40/50s cobrem ~2.5 min de interrupção
breve sem mascarar uma indisponibilidade real.

<a id="4213a0b3-0082"></a>

<a id="testmodulestesthostidentitypsm1-host-identity-for-the-pool-a-reimageable-host-loses-its-local-runtime-and"></a>

## test/modules/Test.HostIdentity.psm1: Identidade do hospedeiro para o grupo: um hospedeiro que pode ser reinstalado perde seu runtime/ local (e

Identidade do hospedeiro para o grupo: um hospedeiro que pode ser reinstalado
perde seu runtime/ local (e host.uuid com ele), portanto, sem uma forma de
reconhecer a mesma máquina física, seu histórico no grupo se dividiria sob
um uuid novo a cada reinstalação. Após cada drenagem poolStorage, um
hospedeiro publica <networkPath>/hosts/info.<uuid>.yml contendo seu uuid +
uma impressão digital de hardware. No próximo Enable-TestAutomation,
um hospedeiro SEM uuid local examina esses registros e, quando uma
impressão digital corresponde com força suficiente, oferece RETOMAR
o uuid anterior (o operador confirma -- nunca silenciosamente).

As chaves fortes da impressão digital (UUID do produto SMBIOS, número de
série da placa-base) só são acessíveis a root no Linux, e a drenagem por
ciclo sem privilégios não pode lê-las. Portanto, a impressão digital é
coletada UMA VEZ, COM PRIVILÉGIOS, em Enable-TestAutomation (sudo é preparado
ali) e armazenada em cache em runtime/host.hwid.json; a drenagem lê o cache.

<a id="4213a0b3-0083"></a>

## test/modules/Test.HostIdentity.psm1: Invoke-PoolStorageSetupAndReclaim

Uma sincronização de configuração de um hospedeiro de referência grava os
três valores do grupo e armazena a credencial correspondente no vault.
Solicitá-los novamente depois não é uma confirmação inofensiva: o
questionário é a ÚNICA forma pela qual esta função alcança a montagem e
a retomada de identidade abaixo, portanto o operador precisa redigitar
manualmente, a partir do hospedeiro de referência, valores já obtidos pela
sincronização, e um erro de digitação substitui silenciosamente uma
configuração funcional.

A completude é avaliada na configuração E na credencial, porque qualquer
uma sozinha ainda deixa uma montagem incapaz de funcionar. Alterar um
hospedeiro configurado é função da sincronização (ou de uma edição em
test.config.yml); este caminho existe para configurar um que ainda não está.

<a id="4213a0b3-0084"></a>

<a id="testmodulestesthostiopsm1-host-io-provider-registry"></a>

## test/modules/Test.HostIO.psm1: Registro de provedores de E/S do hospedeiro

Registro de provedores de E/S do hospedeiro. O modelo espelha
Test.OcrEngine.psm1: cada par (HostType, Action) é um scriptblock registrado;
o despachador consulta o par e o invoca. Uma única tabela de consultas
substitui o que seriam cadeias if/elseif paralelas em $HostType dentro de
cada ação (Send-Key, Send-Text, Send-Click, ...), e um backend ausente é
informado pela matriz de capacidades, em vez de como "Unknown host:
$HostType" no meio da execução de uma sequência.

A matriz de capacidades (Get-HostIOProviderMatrix) fornece visibilidade na
inicialização sobre o que cada hospedeiro realmente pode fazer -- consulte
docs/host-io.md.

<a id="4213a0b3-0085"></a>

<a id="testmodulestesthostiopsm1-two-level-table--hosttype----action---scriptblock--"></a>

## test/modules/Test.HostIO.psm1: Tabela de dois níveis: { HostType -> { Action -> scriptblock } }

Tabela de dois níveis: { HostType -> { Action -> scriptblock } }. Ordenada
para que Get-HostIOProviderMatrix retorne hospedeiros e ações na ordem de
registro, que (hoje) coloca o hospedeiro local primeiro em qualquer exibição da matriz.

A tabela externa é sustentada pela primitiva compartilhada Test.Registry
(New-YurunaRegistry). O nome de âncora $global:YurunaHostIOProviders é o
ponto de entrada documentado para leitores entre módulos que inspecionam
o registro diretamente. As hashtables internas por hospedeiro continuam
sendo [ordered]@{} simples (a primitiva as mantém como valores opacos).

<a id="4213a0b3-0086"></a>

<a id="testmodulestesthostmetricsexporterpsm1-the-collectors-this-host-must-publish-and-why-each-one-is-on-the-list"></a>

## test/modules/Test.HostMetricsExporter.psm1: Os coletores que este hospedeiro deve publicar e por que cada um está na lista:

Os coletores que este hospedeiro deve publicar e por que cada um está na lista:
  memory       -- bytes comprometidos e o limite de comprometimento, o par que
                  explica uma alocação recusada; nenhum outro os expõe.
  os           -- identidade do hospedeiro e informações do sistema operacional.
  cpu          -- tempo por núcleo, para distinguir um hospedeiro travado de um ocupado.
  logical_disk -- espaço livre, cuja falta impede a criação do disco de um convidado da mesma
                  maneira silenciosa como um limite de comprometimento impede a memória.
  hyperv       -- estado por VM, para que o inventário de VMs de um hospedeiro durante um incidente seja uma
                  série registrada em vez de uma lembrança do que estava em execução.
Mantido deliberadamente curto: todos os coletores são consultados a cada intervalo, e
os padrões do exportador diferem entre versões, portanto o conjunto é declarado em vez
de herdado.

<a id="4213a0b3-0087"></a>

<a id="testmodulestesthostmetricsexporterpsm1-how-long-one-unattended-install-attempt-may-run-before-it-is-stopped-and-the"></a>

## test/modules/Test.HostMetricsExporter.psm1: Quanto tempo uma tentativa de instalação sem intervenção pode executar antes de ser interrompida, e o

Quanto tempo uma tentativa de instalação sem intervenção pode executar antes de ser interrompida, e o
único lugar em que esse número é escrito. O trabalho envolvido é baixar um pacote de
algumas dezenas de megabytes e registrar um serviço, portanto três minutos são
várias vezes o tempo necessário -- atingir esse limite indica que algo
está errado, não apenas lento. Ele limita quanto um ciclo pode perder com
telemetria de que não precisa para executar, e esse é o único motivo para
existir um limite. Os chamadores não mantêm uma segunda cópia: dois responsáveis pelo mesmo
limite são a maneira pela qual um limite deixa de ser aplicado sem que ninguém perceba.

<a id="4213a0b3-0088"></a>

## test/modules/Test.HostMetricsExporter.psm1: Get-YurunaHostMetricsInstallAttempt

ConvertFrom-Json reconhece um timestamp com representação reversível e retorna um
[datetime], que já carrega o instante e o Kind corretos. Formatá-lo
novamente como string para analisá-lo outra vez é o que falha: o formato padrão
descarta o marcador de fuso, portanto a nova análise lê um instante UTC como
local, e o registro fica deslocado por uma diferença inteira de fuso UTC -- o que, em um
hospedeiro a oeste do meridiano, parece uma tentativa no FUTURO e
cancela o intervalo; a leste, impede a instalação por horas
além do previsto. Portanto, o valor tipado é usado como valor tipado,
e somente um valor que realmente seja texto é analisado como texto.

<a id="4213a0b3-0089"></a>

## test/modules/Test.HostMetricsExporter.psm1: Invoke-YurunaWingetInstall

A própria chamada de instalação, mantida como um ponto de substituição separado para que cada chamador acima possa ser
exercitado sem um gerenciador de pacotes. A lista de argumentos que ela executa -- e o
motivo pelo qual nada nessa lista pode levar a uma solicitação interativa -- está em
Get-YurunaHostMetricsInstallArgument.

Os fluxos deliberadamente NÃO são redirecionados, e não se usa -Wait nem
WaitForExit() sem parâmetros. Redirecionar qualquer fluxo habilita a
herança de identificadores para toda a subárvore, permitindo que um descendente que
permaneça ativo após esta chamada mantenha aberto o pipe lido por um processo envolvente e o trave
sem saída e sem tempo limite (veja feedback_windows-detached-grandchild-
pins-pipe). Não fornecer fluxos faz desta uma criação por ShellExecute, que
não transmite nenhum identificador herdável; a sobrecarga de WaitForExit com tempo limite
espera apenas por este processo; e o diagnóstico vai para o próprio arquivo de log
do gerenciador de pacotes.

Encerrar no prazo final faz este processo parar de esperar -- não interrompe um
instalador já entregue ao próprio serviço de instalação do sistema operacional.
Por isso o chamador determina o resultado procurando o serviço
depois, em vez de confiar no código de saída: uma instalação que termine um
minuto após o prazo final é encontrada pela verificação de presença do próximo ciclo.

<a id="4213a0b3-008a"></a>

<a id="testmodulestesthostrefreshpsm1-host-refresh-the-repair-ladder-declaration-the-local-repair-worker-and"></a>

## test/modules/Test.HostRefresh.psm1: Atualização do hospedeiro: a declaração da sequência de reparo, o trabalhador de reparo local e

Atualização do hospedeiro: a declaração da sequência de reparo, o trabalhador de reparo local e
tudo de que um chamador precisa em torno dele (orçamento, veredito e código de saída, projeção pública
do progresso, resolução de contexto e identidade, fechamento dos comandos).

O módulo não mantém nenhuma importação de driver. O processo filho status-server gerado o carrega
por Import-RouteModule para anunciar a capacidade sem nunca
chamar Initialize-YurunaHost; carregar um driver ali forçaria a importação de
Test.CachingProxyService e executaria a verificação de cobertura de contrato desse driver
dentro do listener. Todo comando de driver, evidência de serviço e protocolo do executor
usado pelo trabalhador, portanto, é resolvido pelo nome durante a chamada, e um
comando ausente resulta em uma recusa estruturada ou uma etapa ignorada, nunca em uma falha abrupta.

<a id="4213a0b3-008b"></a>

## test/modules/Test.HostRefreshAuth.psm1: Write-HostRefreshSecretFile

Grava uma ou mais linhas secretas com acesso somente pelo proprietário desde o primeiro byte. Cada
arquivo temporário é criado ao lado de seu destino com modo 0600 (Unix)
ou uma ACL exclusiva do proprietário (Windows), e sua privacidade é verificada antes de qualquer byte
secreto ser gravado; depois, a gravação é descarregada. Somente depois que todos os arquivos estão preparados eles são
renomeados para seus destinos, em ordem: uma falha durante a criação, verificação ou
gravação deixa todos os destinos como estavam, e somente uma renomeação que falhe
depois de outra ter sido bem-sucedida deixa o conjunto parcialmente substituído, o que sua
própria recusa identifica. Toda recusa indica caminhos, nunca conteúdo, e remove
cada arquivo temporário ainda não renomeado.

<a id="4213a0b3-008c"></a>

<a id="testmodulestesthostrefreshintentpsm1-the-private-request-journal-for-host-refresh-who-asked-for-a-repair-with"></a>

## test/modules/Test.HostRefreshIntent.psm1: O diário privado de solicitações de atualização do hospedeiro: quem pediu um reparo, com

O diário privado de solicitações de atualização do hospedeiro: quem pediu um reparo, com
qual política imutável, o que cada tentativa fez, o que interrompeu e ainda
deve restaurar, e quais IDs de solicitação estão encerrados definitivamente.

  * Tudo fica sob a raiz de estado privada ($HOME/.yuruna/host-refresh),
    fora de qualquer árvore servida pelo status service; o arquivo público de
    progresso no diretório do runtime é uma projeção e nunca
    tem autoridade.
  * Um registro com checksum e número de geração (Test.CriticalRecord) contém
    todo o diário, e cada operação de leitura, modificação e gravação ocorre sob um curto
    bloqueio de admissão. A ordem de bloqueio é o bloqueio de duração do reparo e depois o
    bloqueio de admissão, nunca o inverso: um trabalhador assume a solicitação com ambos, enquanto o
    listener e o executor externo adquirem apenas o bloqueio de admissão.
  * A idade nunca remove algo ativo. A atividade é determinada pela identidade do processo
    (pid mais horário de início); uma identidade que não possa ser lida é desconhecida, e
    desconhecida é tratada como ativa.
  * Uma solicitação que interrompeu algo mantém suas obrigações até que sejam
    verificadas ou explicitamente resolvidas por um operador local; nenhum veredito as
    elimina silenciosamente.

<a id="4213a0b3-008d"></a>

<a id="testmodulestesthostrefreshtriggerpsm1-the-automatic-host-refresh-policy-when-the-resident-runner-may-start-a"></a>

## test/modules/Test.HostRefreshTrigger.psm1: A política automática de atualização do hospedeiro: quando o executor residente pode iniciar um

A política automática de atualização do hospedeiro: quando o executor residente pode iniciar um
reparo do hipervisor por conta própria e como comprova que o reparo foi executado.

Três processos estão envolvidos, e somente arquivos passam entre eles. O executor
interno observa o hipervisor (a varredura de restauração de VMs de serviço) e grava um
arquivo de evidência por ciclo, marcado com a geração criada pelo executor externo
residente para esse ciclo; o processo por ciclo apenas transmite sua saída; o
externo residente consome o arquivo logo após o despacho, mantém a
contagem de tempos limite em um arquivo privado e decide. Um arquivo auxiliar de qualquer outro
ciclo é rejeitado por sua geração, portanto uma observação desatualizada nunca pode
contar duas vezes ou contar para o ciclo errado.

A contagem e o orçamento diário ficam em arquivos privados separados de propósito:
uma observação responsiva limpa a contagem, mas somente a passagem de um
dia UTC libera o orçamento, e atrasar o relógio nunca o libera. O registro
do orçamento é um registro crítico com checksum, gravado sob o bloqueio de admissão
antes que exista qualquer solicitação, portanto uma falha abrupta após a reserva ainda conta
o dia como usado -- a direção segura em caso de falha para uma reinicialização sem intervenção.

Toda plataforma é declarada não qualificada até que uma verificação canário nativa comprove o
reparo nela; o executor ainda lê a opção, conta as evidências e informa
uma vez por que não age. O módulo não integra nenhum conjunto de módulos de ponto de entrada: o
externo residente e o interno o importam com proteção em seus locais de chamada, e
tudo que é pesado (o diário de reparo, o bloqueio, o registro crítico, os
auxiliares de raiz privada, o leitor da verificação de atualização consultado pela admissão
do diário) é resolvido pelo nome sob demanda, portanto uma parte ausente produz uma
recusa estruturada 'dependency-missing:<module>' em vez de uma exceção em
um laço que precisa continuar executando.

<a id="4213a0b3-008e"></a>

<a id="testmodulestestinnerspawnpsm1-two-launch-shapes-for-a-fresh-child-pwsh-live-here"></a>

## test/modules/Test.InnerSpawn.psm1: Duas formas de iniciar um novo processo filho pwsh ficam aqui.

Duas formas de iniciar um novo processo filho pwsh ficam aqui.

New-InnerRunnerArgList constrói o vetor -Command usado pelo executor para seus
filhos internos e por ciclo:
Por que -Command (não -File):
  o vinculador de parâmetros de -File do pwsh converte todo token argv em [string],
  o que quebra os parâmetros internos [bool]/[int]. -Command analisa a linha
  como PowerShell, para que $true/$false/0/1 mantenham seus tipos.
Por que -NoProfile:
  $PROFILE no shell que inicia o processo pode redefinir variáveis de ambiente YURUNA_* no
  filho DEPOIS que a captura do pai fixou os valores corretos.
Por que um módulo auxiliar:
  Start-TestRunner.ps1, Invoke-TestProject.ps1 e Invoke-TestCycleRunner.ps1
  precisam do mesmo escape de aspas simples e construção de -Command; se houver duplicação,
  uma correção de um caso extremo de aspas em um não chegará aos outros.

Start-YurunaDetachedProcess inicia um trabalhador que deve permanecer ativo após seu
iniciador -- um trabalhador de atualização do hospedeiro, um executor reiniciado -- com -File, um
argumento por elemento, -NonInteractive e os três fluxos desacoplados do
iniciador. No POSIX, os caminhos dos fluxos passam pelo ambiente, e cada
argumento é um parâmetro posicional de um corpo fixo `set -m; nohup "$@"`, portanto
nenhum valor do chamador é interpolado no texto do shell; `set -m` em vez de
setsid dá ao filho seu próprio grupo de processos, porque o macOS não tem setsid.
No Windows, uma primeira etapa, iniciada sem identificadores redirecionados, inicia o
trabalhador final com os redirecionamentos: um iniciador que redireciona transmite ao filho todo
identificador herdável que mantém, e é isso que impede a espera de um chamador
de retornar.

<a id="4213a0b3-008f"></a>

<a id="testmodulestestkeycoderegistrypsm1-maps-owned-by-this-module"></a>

## test/modules/Test.KeyCodeRegistry.psm1: Mapas de responsabilidade deste módulo

Combinações de controle precisam de sua própria família de mapas: os mapas *-Named contêm um código
ESCALAR por nome, e cada backend os desreferencia como escalares, portanto uma entrada
de array ali seria lida como um objeto verdadeiro em vez de uma combinação. Uma combinação
também não é um caractere, portanto os mapas *-Char (identificados pelo caractere literal e
com um sinalizador needsShift) também não conseguem expressá-la.

Dar nome a uma combinação ('CtrlU') em vez de ampliar Send-Key com um parâmetro
-Modifier mantém toda a pilha de teclas intacta: o contrato da fachada do hospedeiro,
o despachante Invoke-Sequence e os scriptblocks de registro por
hospedeiro encaminham uma única string KeyName, portanto uma combinação nomeada não exige
nenhuma alteração de assinatura.

As duas combinações das quais a infraestrutura de testes depende são os controles de tty em modo canônico:
Ctrl+U é VKILL (descartar a linha de entrada atual), e Ctrl+C é VINTR
(interromper o grupo de processos em primeiro plano).

<a id="4213a0b3-0090"></a>

<a id="testmodulestestlabpsm1-lab-level-knowledge-shared-by-the-lab-entry-points-what-a-lab-vault-records"></a>

## test/modules/Test.Lab.psm1: Conhecimento do laboratório compartilhado pelos pontos de entrada do laboratório: o que um cofre do laboratório registra,

Conhecimento do laboratório compartilhado pelos pontos de entrada do laboratório: o que um cofre do laboratório registra,
onde os laboratórios de uma máquina colocam seu armazenamento e quais credenciais a máquina
já mantém. Um módulo é responsável pelo formato do cofre do laboratório para que um leitor e um gravador
não possam divergir sobre ele.

Os dois cofres acessados por este módulo NÃO são intercambiáveis:
  * o cofre do LABORATÓRIO (lab.<name>.vault.yml) é por laboratório e deliberadamente pode ser COPIADO
    para as outras máquinas do laboratório;
  * o cofre do HOSPEDEIRO (vault.yml) é por máquina e é o que a infraestrutura de testes lê.
Quando contêm a mesma credencial, devem concordar, e essa é a razão da existência de
Get-YurunaMachineCredential -- veja sua descrição.

Tudo aqui é SOMENTE LEITURA. Nada neste módulo cria, altera ou
armazena uma credencial.

<a id="4213a0b3-0091"></a>

<a id="testmodulestestlabhealthpsm1-the-lab-health-gate-before-a-chain-entry-and-before-each-sequence-step-check"></a>

## test/modules/Test.LabHealth.psm1: A verificação de saúde do laboratório: antes de uma entrada da cadeia e antes de cada etapa da sequência, verificar

A verificação de saúde do laboratório: antes de uma entrada da cadeia e antes de cada etapa da sequência, verificar
os serviços declarados por este laboratório e pausar o ciclo enquanto um serviço que ESTAVA
respondendo tiver parado de responder.

O conjunto de sondagens é DERIVADO, nunca configurado: cada área de extensão já
declara healthPort/healthPath no bloco `service:` de seu <area>.config.yml, e
Get-ExtensionServiceManifestAll percorre essas áreas. Uma área entregue amanhã é
verificada no dia em que chega; uma área que não declare uma superfície de saúde fica fora
do escopo. Uma lista por serviço aqui precisaria ser editada para cada um e estaria
errada na primeira vez em que isso não fosse feito.

A verificação se arma em uma MUDANÇA de condição, não no estado absoluto. Um serviço que este
hospedeiro nunca acessou não representa uma mudança -- esperar por ele deixaria um novo
hospedeiro parado para sempre, enquanto a própria verificação prévia do chamador fornece um rápido e preciso "there
is no stash here". Portanto, uma pausa exige lastOkUtc dentro da janela de ativação, e
esse registro é mantido ENTRE ciclos: um serviço parado para recriação já
estará ausente quando o próximo ciclo começar, portanto uma referência capturada no início do ciclo
nunca veria a transição que existe para detectar.

Módulo folha. Toda dependência entre módulos (Get-PollDelay, os leitores de
extensão, Send-CycleEventSafely, Write-YurunaStateFileJson) é resolvida durante a
CHAMADA e protegida por Get-Command, portanto uma sondagem degrada para "cannot tell" em vez de
lançar uma exceção dentro da verificação de uma etapa.

<a id="4213a0b3-0092"></a>

<a id="testmodulestestlocalepsm1-which-language-a-reader-gets-decided-once-and-then-carried"></a>

## test/modules/Test.Locale.psm1: Qual idioma um leitor recebe, decidido uma vez e depois transmitido.

Qual idioma um leitor recebe, decidido uma vez e depois transmitido.

Todo runtime que renderiza texto precisa responder à mesma pergunta, e todos
precisam respondê-la da MESMA maneira: uma página em um idioma ao lado de uma transcrição
em outro é pior que qualquer dos idiomas sozinho. Portanto, a resposta é definida por
um conjunto de fixtures (globalization/fixtures/locale-matching.json) executado por este
módulo, pelo navegador e pelo Go, em vez de três implementações
escritas a partir do mesmo parágrafo de prosa.

As regras fáceis de implementar incorretamente e por que são assim:

  q=0 é uma recusa. O RFC 9110 diz que qualidade zero significa "not acceptable",
  portanto uma tag que a contenha é removida da consideração em vez de classificada
  por último -- caso contrário, um cliente que tenha rejeitado explicitamente um idioma o recebe
  sempre que nada mais corresponder.

  Um curinga simples não seleciona candidato. "*" não expressa preferência, portanto as entradas
  posteriores ou o padrão decidem; responder com a primeira tag suportada
  faria o idioma servido depender da ordem de uma tabela.

  Uma região não declarada usa a alternativa. pt-AO não é pt-BR: supor que todo
  português é português brasileiro entrega ao leitor um dialeto que nenhum revisor
  aprovou. Somente os aliases declarados pelo manifesto são seguidos.

  A tag resolvida identifica um ARQUIVO. Ela é comparada com o conjunto suportado e
  nunca usada como um fragmento de caminho, porque a entrada que chega a esta função
  vem de um cabeçalho HTTP.

O contexto produzido é imutável e limitado a um ciclo, um comando
ou uma solicitação. Deliberadamente não existe um "current locale" global do processo:
um serviço que responde a dois leitores ao mesmo tempo não deve ter um.

<a id="4213a0b3-0093"></a>

<a id="testmodulestestlocallabstoragepsm1-local-lab-storage-turn-one-machine-into-its-own-poolstash-smb-server-and"></a>

## test/modules/Test.LocalLabStorage.psm1: Armazenamento local do laboratório: transformar UMA máquina em seu próprio servidor SMB de grupo/stash e

Armazenamento local do laboratório: transformar UMA máquina em seu próprio servidor SMB de grupo/stash e
depois consumir esses compartilhamentos pela pilha de rede, exatamente como consumiria
um NAS. O objetivo do loopback é a uniformidade -- o executor, a verificação de configuração,
a drenagem e as imagens de inicialização dos convidados usam o caminho SMB, portanto um laboratório de uma máquina
exercita o mesmo código que um laboratório com um NAS real e pode depois apontar para
um alterando apenas o alias do hospedeiro.

Este módulo é responsável pela metade específica de cada sistema operacional (contas, o servidor SMB, os
compartilhamentos, as exceções de loopback); a própria montagem continua sendo Connect-YurunaPoolStorage de
Test.PoolStorage, sem alterações, portanto existe exatamente uma implementação de montagem
na árvore.

Os auxiliares puros (composição de caminhos, seleção de unidades, texto de smb.conf, mesclagem do
registro) são separados das chamadas ao sistema operacional para que possam ser testados unitariamente em qualquer
plataforma -- as chamadas ao sistema operacional são verificadas por integração, pois alteram o hospedeiro.

<a id="4213a0b3-0094"></a>

<a id="testmodulestestlocallabstoragepsm1-runs-a-native-command-returning-its-merged-stdoutstderr-and-throwing-on-a"></a>

## test/modules/Test.LocalLabStorage.psm1: Executa um comando nativo, retornando stdout+stderr mesclados e lançando uma exceção em uma

Executa um comando nativo, retornando stdout+stderr mesclados e lançando uma exceção em uma
saída diferente de zero com essa saída anexada. A saída contém todo o valor diagnóstico
aqui: `sharing`, `smbpasswd`, `sysadminctl` e `testparm` saem com 1
para uma ampla variedade de causas não relacionadas, portanto o código de saída sozinho nunca informa o que
corrigir. -AllowFailure transforma isso em uma sondagem que retorna o resultado.

O caminho sudo passa por Invoke-YurunaSudo em vez de executar sudo aqui.
sudo lê sua senha em /dev/tty, portanto uma execução cujo console pertence a um
pai não pode impedir um simples `sudo` de solicitar entrada onde ninguém pode vê-la --
Invoke-YurunaSudo acrescenta -n precisamente nesse caminho e reconhece as próprias
assinaturas de recusa do sudo. Essa distinção é o que -AllowFailure NÃO deve suprimir:
a maioria das chamadas abaixo são sondagens cuja saída diferente de zero é a resposta ("no such
sharepoint", "package absent"), mas "sudo would not run this at all" não é uma
resposta para nenhuma delas, e tratá-la como uma é a maneira de construir metade de uma configuração
de armazenamento e depois relatá-la como as camadas que chegou a criar.

<a id="4213a0b3-0095"></a>

## test/modules/Test.LocalLabStorage.psm1: Set-MacSmbCredential

`dscl -passwd`, NÃO `sysadminctl -resetPasswordFor`. Ambos definem a senha
e ambos deixam o OpenDirectory aceitando-a -- `dscl -authonly` passa de qualquer
maneira -- mas somente a gravação no nível do diretório regenera os hashes armazenados
pela lista de hashes que acabou de ser alterada. Pelo sysadminctl, a conta
fica com uma senha correta e sem hash NT, que é precisamente a
divisão desta falha: o OpenDirectory aceita, o smbd informa
"server rejected the authentication", e a montagem seguinte relata
a rejeição como "No such file or directory".

<a id="4213a0b3-0096"></a>

## test/modules/Test.LocalLabStorage.psm1: Set-LocalLabStorageAccount

sysadminctl recebe a senha em seu vetor de argumentos, expondo-a brevemente
a `ps`. Não existe um equivalente com suporte a stdin no macOS; a mesma
exposição residual é aceita (e documentada) por New-LocalTestUser e
pelo ramo macOS da montagem de poolStorage.

sysadminctl não tem um marcador '--' de fim de opções, portanto um '-' inicial seria
analisado como uma opção, e a conta ficaria com uma senha que não
corresponde à do cofre. New-Lab reutiliza uma credencial do cofre do hospedeiro quando
ela já existe, e uma entrada preenchida manualmente não oferece nenhuma
garantia sobre o caractere inicial, portanto esse caso é alcançável -- a mesma proteção de
New-LocalTestUser.

<a id="4213a0b3-0097"></a>

## test/modules/Test.LocalLabStorage.psm1: Set-YurunaHostAlias

Reiniciado sob sudo porque o arquivo hosts pertence a root, e
Set-HostAlias se recusa a executar como usuário sem privilégios. O vetor
de argumentos vem de Get-SudoPwshArgumentList: um simples 'pwsh' no
ambiente reduzido do sudo termina com uma saída .NET "libhostfxr not found"
de código 131, três etapas antes de o cofre e a configuração serem gravados.
A solicitação indica de quem é a senha e para quê: o padrão do sudo não informa
nenhum dos dois, e essa elevação ocorre no meio de uma execução que vem
gerando e armazenando credenciais do laboratório, portanto um
"Password:" sem identificação parece um pedido de uma delas.

<a id="4213a0b3-0098"></a>

<a id="testmodulestestlocallabstoragepsm1-a-machine-that-served-its-own-shares-and-now-consumes-a-labs-has-to-stop"></a>

## test/modules/Test.LocalLabStorage.psm1: Uma máquina que servia seus próprios compartilhamentos e agora consome os de um laboratório precisa parar

Uma máquina que servia seus próprios compartilhamentos e agora consome os de um laboratório precisa parar
de ser um servidor de armazenamento, e cada etapa acima precisa de uma operação inversa para isso. Elas
são agrupadas aqui em vez de ao lado de suas criadoras para que a metade destrutiva
deste módulo forme uma única região que o operador possa ler do início ao fim antes de executá-la.

Os DADOS nunca são alterados por nada nesta região. As pastas sob a
raiz de armazenamento contêm arquivos de ciclos concluídos, artefatos de stash, o cofre do laboratório e
o repositório de intenções do grupo -- conteúdo cuja única cópia pode estar ali. O que é
desativado é a configuração de SERVIÇO: as definições de compartilhamento, as contas restritas
a eles, as exceções de loopback e os aliases. Essa divisão torna
seguro executar a desmontagem antes de o operador decidir qualquer coisa sobre os bytes.

<a id="4213a0b3-0099"></a>

<a id="testmodulestestlogpsm1-one-of-three-yuruna-logger-modules-with-disjoint-responsibilities---"></a>

## test/modules/Test.Log.psm1: Um de TRÊS módulos de registro do Yuruna com responsabilidades separadas --

Um de TRÊS módulos de registro do Yuruna com responsabilidades separadas --
veja test/modules/README.md "Three loggers, three jobs" antes de adicionar
auxiliares aqui. Este módulo é responsável SOMENTE pela disposição do sistema de arquivos do ciclo:
Start-LogFile, Stop-LogFile, Get-CycleGuestDataFolder, Get-CycleScreenDir,
Write-CycleNdjsonEvent, Write-CycleManifest. Módulos irmãos: Yuruna.Log
(interceptador de fluxos) e Test.Output (contagem PASS/FAIL por script).
Não adicione wrappers de cmdlets Write-* nem auxiliares de contagem PASS aqui -- eles
pertencem aos outros dois.

Dois canais entre módulos abrangem intencionalmente todo o processo: __YurunaLogFile
(definido aqui, lido pelo proxy Yuruna.Log) e __YurunaCycleFolder (a
pasta do ciclo sob test/status/log/, lida por auxiliares de falha e
diagnóstico para que o caminho não precise passar por todo local de chamada).

<a id="4213a0b3-009a"></a>

## test/modules/Test.Log.psm1: Start-LogFile

Aloque a pasta do ciclo com o sufixo `.incomplete` para que um
ciclo interrompido por falha abrupta seja visível no nome da pasta (além
do arquivo marcador dentro dela). Stop-LogFile renomeia para o simples
<base>/ no fechamento normal; a recuperação na inicialização renomeia para
<base>.aborted.<UTC>/ quando detecta a falha na inicialização. Todo
evento NDJSON registra o simples <base> como `cycleFolder` (a
identidade estável do ciclo), independentemente do sufixo no disco
durante a emissão -- os consumidores associam eventos através da renomeação
sem ver o sufixo mudar no meio do ciclo.

<a id="4213a0b3-009b"></a>

## test/modules/Test.Log.psm1: Start-LogFile

A identidade do ciclo RESPONSÁVEL, mantida separadamente da pasta
em que os eventos são gravados. Uma execução aninhada redireciona __YurunaCycleFolder
para sua própria subpasta, para que sua transcrição e seus eventos fiquem ao lado dela,
e derivar a marca cycleFolder disso identificaria os eventos do filho
com o nome final do filho -- dividindo um ciclo em tantos ciclos
aparentes quantos fossem seus nós aninhados, nenhum associável ao
ciclo realmente executado. Esta referência é a origem da marca,
e uma execução aninhada a herda em vez de substituí-la.

<a id="4213a0b3-009c"></a>

## test/modules/Test.Log.psm1: Start-LogFile

Correlacionador estável de execução marcado em todo registro NDJSON por Write-
CycleNdjsonEvent. cycleFolder sozinho É único em um hospedeiro,
mas um consumidor de grupo com vários hospedeiros que associe fluxos ao vivo de três
máquinas precisaria, de outra forma, analisar o nome final para recuperar
o horário do ciclo de origem. cycleStartUtc é o timestamp ISO atribuído pelo
externo no início do ciclo. Os consumidores do grupo o combinam com hostId para
identificar o ciclo de cada hospedeiro; o timestamp sozinho não distingue ciclos
que começam no mesmo instante em hospedeiros diferentes.

<a id="4213a0b3-009d"></a>

## test/modules/Test.Log.psm1: Start-LogFile

Qual código produziu este ciclo, informado no próprio evento: um
consumidor que lê o fluxo fora do hospedeiro tem somente essas linhas, e o
documento de status do hospedeiro a essa altura descreve o ciclo em execução
agora, não aquele ao qual esses eventos pertencem. Usa a mesma estrutura {sha, repoUrl}
do documento de status e de cada linha de seu histórico, para que um único
leitor analise commits em todos os lugares. Omitido em vez de emitido vazio --
um ciclo cujos commits nunca foram resolvidos não deve parecer
um ciclo que não executou código.

<a id="4213a0b3-009e"></a>

## test/modules/Test.Log.psm1: Write-CycleManifest

Save-StepFailureEvidence copia os quadros do buffer circular e o
par de falha para <VM>/failed_<label>/, portanto eles chegam com
um prefixo de caminho que os padrões ancorados acima e abaixo não conseguem
corresponder e, sem estes, são classificados como 'other'.
Os quadros do buffer circular realocados mantêm os tipos BRUTOS: são os
mesmos quadros, apenas copiados, e os tipos brutos são aqueles cujo
hash o manifesto não calcula. Calcular o hash de todo um buffer circular por tentativa
malsucedida custa segundos do ciclo e não informa ao operador
nada além do próprio quadro.

<a id="4213a0b3-009f"></a>

## test/modules/Test.Log.psm1: Stop-LogFile

cycle_end é emitido ANTES do manifesto para que a varredura
de artefatos do manifesto inclua o agora concluído
cycle.events.ndjson. A gravação NDJSON faz o possível; o
sentinela de lacunas dentro de Write-CycleNdjsonEvent apresenta
qualquer falha.
Quantas vezes o endereço deste hospedeiro mudou durante o ciclo. Em um
hospedeiro cuja concessão é deliberadamente curta, esse número dá
significado ao veredito: uma aprovação com três mudanças é
evidência de que a infraestrutura de testes resiste à instabilidade de IP, e uma aprovação sem nenhuma
é evidência apenas de que a rede estava estável. Sem isso, ambas são
a mesma palavra no mesmo lugar. O módulo anunciador é uma dependência opcional:
um módulo ausente relata -1 (não medido), enquanto um hospedeiro medido cujo
endereço não mudou relata 0. Nenhum caso impede o fechamento do ciclo.
-1, não 0, quando a contagem não puder ser obtida. Zero é uma resposta
SIGNIFICATIVA aqui -- diz que este ciclo foi executado em uma rede
estável e não comprova resistência a mudanças -- portanto uma falha de
medição não deve poder imitá-la. Relatar um ciclo não medido
como zero é pior que não relatar nada: isso parece evidência.

<a id="4213a0b3-00a0"></a>

## test/modules/Test.Log.psm1: Stop-LogFile

A contagem acima diz o que ESTE ciclo encontrou. O veredito diz
se o hospedeiro tem algum limite, a pergunta que uma concessão de uma
semana torna urgente e que nenhum ciclo individual pode responder.
Emitido como seu próprio evento para chegar ao mesmo log já lido
pelo painel: o veredito de periodicidade existiu por algum tempo sem uma
rota para fora do hospedeiro, o que o tornava uma detecção sobre a qual ninguém podia agir.
Faz o possível e nunca é fatal -- um ciclo ainda deve fechar se a
bridge não puder ser consultada.

<a id="4213a0b3-00a1"></a>

## test/modules/Test.Log.psm1: Stop-LogFile

Espelhe last_failure.json do ciclo na pasta do ciclo ANTES
da varredura do manifesto, para que o registro completo schema-v2 -- padrão
correspondente, rótulo, trecho final de OCR, reprodução, causa interna -- persista com o
ciclo para análise posterior, não apenas o evento step_failure achatado
em cycle.events.ndjson. Write-CycleManifest classifica tanto
a cópia no nível do ciclo quanto a própria cópia de cada convidado, portanto os arquivos espelhados
são catalogados automaticamente.

Esta é a passagem de atualização, não a única oportunidade: cada gravador do
registro o espelha durante a classificação por
Copy-CycleFailureRecord, porque a cópia raiz sob
$env:YURUNA_LOG_DIR é limpa a cada início de sequência e
costuma já não existir quando um ciclo termina.

Um ciclo que se recuperou -- uma retomada a quente executou novamente a sequência malsucedida
e ela passou -- chega a um resultado de aprovação com os espelhos da primeira tentativa
ainda na pasta. Um registro em qualquer lugar sob a pasta do ciclo
significa "this cycle failed", e o manifesto o cataloga como
tal, portanto uma aprovação limpa todas as cópias, inclusive as dos convidados; o
evento step_failure mantém a tentativa recuperada observável no
fluxo.

<a id="4213a0b3-00a2"></a>

## test/modules/Test.Log.psm1: Stop-LogFile

A decisão do despachante de correção (Invoke-Remediation) segue
o mesmo caminho de arquivamento da falha que orientou sua decisão, portanto a pasta
do ciclo -- e sua cópia no grupo -- contém a recomendação
ao lado da falha. Somente em um resultado que não seja aprovação: um ciclo aprovado
não tem sua própria correção, portanto qualquer arquivo presente é desatualizado.

Um resultado que não seja aprovação, sozinho, não basta para comprovar a origem. A
fonte fica na RAIZ do log, compartilhada por todos os ciclos, e o
despachante NÃO executa para toda falha -- uma que pare
antes da classificação (uma verificação prévia recusando iniciar o
ciclo) deixa o arquivo raiz intacto. Copiar pela presença
então entrega a este ciclo a recomendação do ciclo ANTERIOR,
que parece o diagnóstico de uma falha que ele nunca observou e conduz
o operador à causa errada. Compare a marca de execução;
um registro sem marca é anterior à marca e também
não é nosso.

<a id="4213a0b3-00a3"></a>

<a id="testmodulestestlogpsm1-telemetry-is-best-effort-by-design-a-cycle-never-fails-because-an-event-could"></a>

## test/modules/Test.Log.psm1: A telemetria faz o possível por projeto: um ciclo nunca falha porque um evento não pôde

A telemetria faz o possível por projeto: um ciclo nunca falha porque um evento não pôde
ser gravado. Essa política esconde algo de que todo consumidor precisa -- se o
fluxo que está lendo está completo. Um laço de correção que encontre o fluxo silencioso
não consegue distinguir "nothing happened" de "the writer broke", e um gravador que
nunca foi carregado não deixa nenhum vestígio.

Portanto, toda emissão é contada, e toda perda é registrada com seu motivo em
cycle.events.delivery.json ao lado do fluxo, onde o manifesto a cataloga.
A primeira perda em um ciclo também gera um aviso. Nada disso muda o efeito de uma
gravação malsucedida no ciclo: a falha original mantém seu próprio motivo, e
o registro apenas diz quanto das evidências em torno dela chegou ao disco.

<a id="4213a0b3-00a4"></a>

## test/modules/Test.Log.psm1: Write-CycleNdjsonEvent

Marque cycleFolder + cycleStartUtc em todo registro para que consumidores fora do hospedeiro
possam associar os eventos a seu ciclo sem analisar novamente o caminho
do arquivo ou o formato do nome final. Valores existentes do chamador prevalecem
(cycle_start, em particular, já contém ambos); defina somente quando
ausentes. Os consumidores do grupo usam hostId junto com cycleStartUtc como
chave do ciclo, portanto timestamps iguais de hospedeiros diferentes continuam sendo ciclos separados.

Marque cycleFolder como a IDENTIDADE estável do ciclo, não o
nome final no disco -- a pasta no disco transita entre
<base>.incomplete/ -> <base>/ -> <base>.aborted.<UTC>/, e o
fluxo NDJSON NÃO deve alterar o campo cycleFolder nessas
renomeações, ou a associação de um consumidor de fluxo falharia. Get-CycleFolderIdentity remove qualquer um dos três sufixos.

<a id="4213a0b3-00a5"></a>

<a id="testmodulestestloglevelpsm1-canonical-log-level-cascade"></a>

## test/modules/Test.LogLevel.psm1: Cascata canônica de níveis de log

Cascata canônica de níveis de log. Por que fica em seu próprio módulo: ele é
a fonte única da tabela de classificação e da lógica da cascata de preferências compartilhadas
por Invoke-TestRunnerInnerLoop.ps1, Debug-TestSequence.ps1, Test.SequenceEngine.psm1
e todo host/<platform>/guest.<x>/{Get-Image,New-VM}.ps1 (28+
consumidores). Um novo nível (ou um ajuste em ProgressPreference) exige uma única
edição aqui em vez de uma edição manual em cada cópia.

Veja docs/loglevels.md para a semântica da cascata e por que a propagação por
variáveis de ambiente é a única maneira de alcançar processos filhos pwsh.

<a id="4213a0b3-00a6"></a>

<a id="testmodulestestloglevelpsm1-the-two-values-below-are-deliberately-not-in-module-scope"></a>

## test/modules/Test.LogLevel.psm1: Os dois valores abaixo deliberadamente NÃO ficam no escopo do módulo

Os dois valores abaixo deliberadamente NÃO ficam no escopo do módulo. `Import-Module
-Force` cria uma nova instância do módulo com novo estado de sessão, portanto uma proteção
mantida em $script: deixa de proteger assim que um script aninhado no mesmo processo
reimporta este módulo (feedback_module_force_import_evicts_global) -- e
ambos descrevem o processo, não uma instância do módulo. O escopo $global:
pertence ao runspace, e uma reimportação forçada o deixa intacto, portanto ele é o
escopo de variável mais amplo acessível daqui; o carregamento do módulo, por isso, nunca deve
sobrescrever um valor deixado por uma instância anterior.
Test-Path na unidade de variáveis em vez de Get-Variable: a sondagem é executada em
toda importação, e uma ausência em Get-Variable registra uma entrada "Cannot find a variable"
em $Error mesmo sob -ErrorAction SilentlyContinue, o que gera ruído justamente
na análise posterior que este módulo existe para tornar legível.

<a id="4213a0b3-00a7"></a>

<a id="testmodulestestloglevelpsm1-path-this-process-is-transcribing-to-or-null-when-it-is-not-paired-with"></a>

## test/modules/Test.LogLevel.psm1: Caminho para o qual este processo está transcrevendo, ou $null quando não está, associado a

Caminho para o qual este processo está transcrevendo, ou $null quando não está, associado ao
pid que o abriu -- a mesma chave usada para construir o nome do arquivo, portanto um
valor que não descreva ESTE processo nunca pode suprimir sua
transcrição. Sem a proteção, um segundo Start-Transcript tem sucesso (PS 7
permite transcrições simultâneas): ambos os gravadores abrem o mesmo caminho em modo Append,
cada um posiciona no fim do arquivo uma vez durante a construção e depois avança seu
próprio deslocamento, portanto o gravador posterior sobrescreve as linhas do anterior em vez
de segui-las, e o arquivo termina com um bloco de início e N blocos de término.

<a id="4213a0b3-00a8"></a>

<a id="testmodulestestnotifypsm1-send-yurunanotification-is-a-thin-dispatcher-to-the-active-extensions"></a>

## test/modules/Test.Notify.psm1: Send-YurunaNotification é um despachante simples para as extensões ativas

Send-YurunaNotification é um despachante simples para as extensões ativas
sob test/extension/notification/. Cada extensão exporta o verbo do contrato
  Send-Notification -EventCode <string> -EventMessage <string> -EventNote <string>
e o despachante o invoca.

O despachante deliberadamente NÃO se chama Send-Notification. As extensões são
importadas no escopo GLOBAL, portanto um despachante com o mesmo nome do verbo
do contrato seria ocultado pela extensão assim que a primeira fosse carregada -- e
todo chamador sem qualificação a partir daí acessaria diretamente o transporte,
ignorando o laço de despacho, a verificação -EventData e o registro de entregas. Essa
falha é silenciosa por construção: o próprio try/catch do chamador suprime o
erro de vinculação de parâmetros, e o alerta simplesmente nunca é enviado. Dois nomes distintos
tornam a colisão impossível em vez de apenas improvável.

Format-FailureMessage permanece aqui para que os chamadores possam construir o corpo
de EventNote a partir de campos estruturados sem reimplementar o formato.

<a id="4213a0b3-00a9"></a>

## test/modules/Test.Notify.psm1: Send-YurunaNotification

Dispara sem esperar; o caminho de falha do ciclo retorna imediatamente.
A tarefa de thread herda a tabela de módulos do runspace, portanto $cmd
é resolvido da mesma maneira que no ramo síncrono.

O resultado da entrega é persistido em <cycleFolder>/notification.delivery.json
(JSON Lines somente de acréscimo) dentro da tarefa de thread, para que um
corretor autônomo possa ver se o canal de escalonamento
realmente recebeu o alerta. Sem isso, um HTTP 503 do Resend
é suprimido em Write-Warning, e a transcrição do ciclo parece
indicar que o operador foi notificado quando ninguém foi.

<a id="4213a0b3-00aa"></a>

## test/modules/Test.Notify.psm1: Get-FailureEventData

Onde o registro ESTÁ depende de quando somos consultados. Durante um ciclo, o
mecanismo e as etapas de infraestrutura gravam last_failure.json na RAIZ do log
($env:YURUNA_LOG_DIR) e o espelham sob a pasta do ciclo; a cópia raiz
é limpa a cada início de sequência. Procurar em apenas um dos lugares não encontra
nada em algum momento em que um chamador ativo precisa da causa classificada, e todo
consumidor então recebe silenciosamente o conteúdo sintetizado 'unknown' abaixo.

O mais específico primeiro: o próprio espelho do convidado que falhou, que comprovadamente
pertence a ESTE ciclo e a ESTE convidado; depois, a cópia da pasta do ciclo, que
comprovadamente pertence a este ciclo, mas ao convidado que falhou por último; depois,
a raiz ativa, compartilhada entre ciclos e convidados.

Um chamador que identifica seu convidado também recusa uma cópia compartilhada que identifique
outro. Um hospedeiro que execute vários convidados por ciclo e não pare
na primeira falha deixa o registro de um convidado em ambos os lugares compartilhados, portanto,
sem isso, um convidado posterior cuja própria falha não produzisse registro -- um
alvo de retomada a quente que não esteja na lista, um arquivo de sequência ausente para
a segunda sequência ou uma posterior -- receberia a causa de seu predecessor,
no resumo do painel e na sequência de quarentena por convidado. Um registro
que não identifique nenhum convidado é uma falha no nível do hospedeiro e continua sendo oferecido a
todos.

<a id="4213a0b3-00ab"></a>

## test/modules/Test.Notify.psm1: Get-FailureEventData

URL da pasta do ciclo: o nome base do log do ciclo acrescentado ao ponto de montagem do status
server. Os consumidores podem ir diretamente da notificação
à transcrição HTML + artefatos.

Precedência da URL base:
  1. $env:YURUNA_STATUS_PUBLIC_URL -- endereço acessível explicitamente
     publicado (o operador o define em hospedeiros cujo painel é
     exposto por um proxy reverso, um nome de hospedeiro com túnel ou um IP
     LAN). Um corretor LLM fora do hospedeiro pode seguir o link.
  2. http://<HOST_FQDN>:8080 -- melhor estimativa a partir do
     nome de hospedeiro registrado pelo ciclo + a porta padrão do serviço de status,
     quando o nome de hospedeiro é conhecido. Funciona na maioria das LANs em que o nome de
     hospedeiro do painel é resolvido.
  3. http://localhost:8080/ -- alternativa de último recurso. Útil somente
     para um consumidor em execução no mesmo hospedeiro que o executor.

<a id="4213a0b3-00ac"></a>

## test/modules/Test.OcrEngine.psm1: Get-EnabledOcrProvider

host.macos.utm -- Apple Vision é o mecanismo nativo, o caminho mais rápido
para uma correspondência. O recorte no eixo x de Invoke-MacVisionOcr lida com o
caso silenciosamente vazio para as capturas de framebuffer que o executor
realmente fornece. O Tesseract fica como alternativa
para os poucos casos em que o Vision ainda não retorna nada (glifos esparsos em
fontes incomuns, faixas de contraste muito baixo). Com o modo de combinação 'Or',
tesseract só executa quando o Vision NÃO corresponde ao padrão
de busca, portanto o caso comum é uma chamada OCR por consulta. winrt é
inteiramente omitido -- é exclusivo do Windows e seria filtrado
durante a execução de qualquer maneira; listá-lo aqui apenas acrescenta linhas confusas ao log
sobre um provedor que não pode executar.

<a id="4213a0b3-00ad"></a>

<a id="testmodulestestocrenginepsm1-provider-registry"></a>

## test/modules/Test.OcrEngine.psm1: Registro de provedores

-Global é obrigatório: uma simples reimportação com -Force de um Test.Tesseract já global
o remove da sessão global e o coloca no escopo privado deste
módulo (classe de regressão de remoção de módulos legados). Como esta
linha executa novamente a cada reimportação de Test.OcrEngine -- e a cadeia
Invoke-Sequence -> Test.OcrMatch -> Test.OcrEngine o reimporta
a cada Initialize-SequenceEngineRegistry -- a remoção deixaria
as exportações de Tesseract (Assert-TesseractInstalled, ...) invisíveis ao
escopo global do ponto de entrada, embora as próprias exportações de Test.OcrEngine
continuassem resolvíveis. Mantenha -Global para que Tesseract permaneça globalmente visível.

<a id="4213a0b3-00ae"></a>

<a id="testmodulestestocrenginepsm1-built-in-provider-winrt-windows-only-via-powershellexe-51"></a>

## test/modules/Test.OcrEngine.psm1: Provedor integrado: WinRT (somente Windows, via powershell.exe 5.1)

Prazo de leitura do trabalhador persistente. StandardOutput.ReadLine() não tem
tempo limite, portanto um trabalhador criado corretamente que depois trave (parada de WinRT/COM,
travamento do driver de GPU -- nunca emite seu marcador de fim de resposta) bloquearia a chamada
OCR até o tempo limite completo de Wait-ForText (minutos), transformando uma falha recuperável
em consumo de todo o tempo limite sem falha rápida. Limitar a leitura permite que
Invoke-WinRtOcr recorra a uma criação de processo para uma única chamada em segundos. Generoso em relação ao OCR
normal na escala de ms: um raro tempo limite falso custa apenas uma chamada única mais lenta
mais um novo trabalhador, nunca um resultado OCR errado. Sobrescreva com um valor positivo em
YURUNA_OCR_WORKER_TIMEOUT_SECONDS.

<a id="4213a0b3-00af"></a>

## test/modules/Test.OcrEngine.psm1: Invoke-WinRtOcr

powershell.exe -File sai com 0 mesmo quando o script executado lança uma exceção, portanto o
código de saída sozinho não distingue uma tela em branco de um auxiliar que nunca
chegou à chamada OCR. O stderr os distingue: uma tela sem
texto não produz stdout nem stderr, portanto uma saída sem texto acompanhada de um
diagnóstico é uma leitura malsucedida e deve lançar uma exceção. Retornar '' seria o
caso silencioso -- o chamador é informado de que o console está vazio, nenhum aviso nem
evento ocr_provider_failed é emitido, e qualquer coisa que espere esse
console mudar consome todo seu orçamento diante de um leitor inativo.

<a id="4213a0b3-00b0"></a>

<a id="testmodulestestocrenginepsm1-built-in-provider-winrt-windows-only-via-powershellexe-51-1"></a>

## test/modules/Test.OcrEngine.psm1: Provedor integrado: WinRT (somente Windows, via powershell.exe 5.1)

Cache de compilação sob demanda para o código-fonte Swift do Vision OCR. `swift script.swift`
executa novamente o frontend Swift a cada invocação -- empiricamente 1-2s por
chamada no Apple Silicon, o que domina a latência de Wait-ForText em hospedeiros macOS
UTM quando Vision é o mecanismo principal (o padrão do macOS).
`swiftc -O` compila uma vez para um binário nativo; as invocações posteriores
são execuções puras, ~50-150ms. Identificamos o caminho do binário pelo SHA-256 do
código-fonte para que uma edição no local provoque uma nova compilação e para que vários
ciclos paralelos não disputem o mesmo caminho.

Retorna $null quando swiftc não está disponível ou a compilação falha;
Invoke-MacVisionOcr recorre ao caminho de código original `swift script.swift`
para preservar o comportamento (apenas mais lento) nesses hospedeiros.

<a id="4213a0b3-00b1"></a>

<a id="testmodulestestocrmatchpsm1-ocr-tolerant-matching"></a>

## test/modules/Test.OcrMatch.psm1: Correspondência tolerante a OCR

Caracteres inteiramente removidos durante a normalização.
Os mecanismos OCR frequentemente inserem travessões, meias-riscas, aspas tipográficas ou outras
substituições Unicode para pontuação ASCII em telas de terminal.
Removê-los (junto com seus equivalentes ASCII) evita
divergências quando o padrão usa ASCII simples.

'@' NÃO está nesta lista -- fica no grupo de confusão oO0@
(acima) porque erros OCR para '0' são mais comuns neste código
que a remoção de '@' de uma solicitação. Com '@' normalizado para 'o',
um padrão com '@' literal (por exemplo, "[ec2-user@host]$") ainda corresponde
a texto OCR que leia '@' como '@' OU como '0' -- ambos são normalizados da mesma maneira.

<a id="4213a0b3-00b2"></a>

## test/modules/Test.OcrMatch.psm1: Test-OCRMatch

Os caracteres correspondentes devem caber no comprimento do próprio padrão mais o mesmo
orçamento de erros permitido pelo limite: um padrão que perdoa N caracteres
removidos tolera aproximadamente N inseridos, e não mais. Um orçamento ligado
ao comprimento inteiro do padrão permite, em vez disso, que uma linha longa de prosa satisfaça
um padrão curto de solicitação dispersando-o -- o aviso que um convidado imprime
antes de "New password:" forma esse padrão em ordem quando os grupos de
confusão reduzem n->m e e->c, e uma espera que aceite o aviso digita o
segredo em um terminal que ainda não desligou o eco.

<a id="4213a0b3-00b3"></a>

## test/modules/Test.OcrMatch.psm1: Test-OCRMatch

O OCR pode reordenar partes de uma linha (por exemplo, "[ec2-user@test-amazon-linux01 ~]$"
vira "test-amazon-I inux01 login: ecZ-user"). Divida o padrão original
nos delimitadores de segmentos (@, -, etc.) para obter
segmentos significativos, normalize cada um e verifique se todos aparecem
em algum lugar no texto normalizado completo (em todas as linhas).

Diferentemente das duas estratégias acima, esta não é limitada por nada: nenhuma linha,
ordem ou extensão. Cada segmento precisa apenas existir em algum lugar. Um chamador
que corresponda a uma solicitação ou determine que algo deu errado a ignora:
uma coincidência não deve enviar entrada antecipadamente nem reprovar um convidado saudável.

<a id="4213a0b3-00b4"></a>

<a id="testmodulestestocrpathpsm1-windows-passes-a-path-of-260-characters-or-more-to-a-process-only-when-that"></a>

## test/modules/Test.OcrPath.psm1: O Windows passa um caminho de 260 caracteres ou mais a um processo somente quando esse

O Windows passa um caminho de 260 caracteres ou mais a um processo somente quando esse
processo declara em seu manifesto o suporte a caminhos longos. Os mecanismos OCR são nativos e não o declaram:
o leitor do tesseract responde "cannot read input file ... No such file or
directory", e StorageFile.GetFileFromPathAsync do WinRT lança uma exceção, ambos para um arquivo
que claramente está no disco. O .NET *tem* suporte a caminhos longos, portanto os próprios
Test-Path, Get-VMScreenshot e Copy-Item do PowerShell no mesmo caminho têm sucesso --
e é isso que torna o problema silencioso. Toda proteção que a infraestrutura de testes possa escrever em PowerShell
passa, e somente o mecanismo no fim da cadeia não consegue abrir o arquivo, portanto a
captura é gravada, sua presença é confirmada e depois ela é lida como uma tela em branco.

MAX_PATH conta o NUL final, portanto 259 caracteres é o caminho mais longo
aceito por esses mecanismos, e 260 é o primeiro recusado. O gatilho é essa
fronteira, não uma margem abaixo dela: os mecanismos recebem a captura e
a leem para stdout, sem nunca derivar dela um nome mais longo, e uma margem faria
copiar caminhos comprovadamente legíveis -- a cada consulta, para cada quadro.

<a id="4213a0b3-00b5"></a>

<a id="testmodulestestorchestratorpsm1-orchestration-sequence-execution-for-debug-testsequenceps1-runs-every"></a>

## test/modules/Test.Orchestrator.psm1: Execução de sequência de orquestração para Debug-TestSequence.ps1: executa toda

Execução de sequência de orquestração para Debug-TestSequence.ps1: executa toda
sequência interna `InvokeTestSequence` NO MESMO PROCESSO sob UM ciclo
status.json, uma linha de painel por sequência interna. Veja
docs/runner-outer-loop.md#what-a-testrunneryml-entry-can-be.

Duplicação conhecida: Invoke-OrchestratorGuestRun abaixo espelha a preparação por convidado
e a execução da cadeia realizadas diretamente por Debug-TestSequence.ps1 em uma execução independente
(plano -> serviço de proxy de cache -> substituição do usuário ssh -> garantir/iniciar VM ->
Invoke-TestSequenceChain). Os dois são mantidos separados para que uma mudança aqui não possa
causar regressão no caminho independente; reuni-los em um auxiliar exige uma execução de laboratório
completa para verificar ambos novamente.

<a id="4213a0b3-00b6"></a>

## test/modules/Test.Orchestrator.psm1: Invoke-OrchestratorHostAction

Encaminhe por pipe a Write-OrchestratorLine, não ao fluxo de sucesso: esta
função retorna o código de saída, portanto stdout sem pipe seria incorporado
àquele valor em vez de exibido. O fluxo de informação (em vez do
aplicativo de console) chega aos artefatos do ciclo, pois o proxy de log
duplica os cmdlets Write-* e nada mais -- uma ação do hospedeiro cuja
saída o ignorasse falharia com seu motivo apenas no terminal,
e somente "FAIL" na transcrição e no log de eventos. 2>&1 incorpora
o stderr do filho, onde um script malsucedido do hospedeiro
explica a falha.

<a id="4213a0b3-00b7"></a>

## test/modules/Test.Orchestrator.psm1: Invoke-OrchestrationSequence

Consciência de ciclo aninhado. Uma orquestração normalmente é a RESPONSÁVEL pelo ciclo, mas
pode ela mesma executar aninhada em outro ciclo (uma orquestração referenciada
como sequência interna). Quando $ctx está presente, esta execução é ANINHADA: ela associa
UM nó à orquestração inteira e ignora toda operação de status exclusiva do responsável
(Reset/Initialize/Set-Guest*/Complete-Run/Start-LogFile). Em ambos os casos, o
laço de etapas publica uma referência de contexto do ciclo antes de cada etapa, para que um PROCESSO
filho criado pela etapa (uma ação do hospedeiro que entra novamente em Debug-TestSequence.ps1)
se associe como nó aninhado sob o pai correto. Veja Test.Status.psm1
"Nested-cycle support".

<a id="4213a0b3-00b8"></a>

## test/modules/Test.Orchestrator.psm1: Invoke-OrchestrationSequence

A parte do registro de contêineres é debitada do preâmbulo do ciclo de propósito. O
registro de contêineres do cache fica disponível após o squid em uma recriação, e um
convidado que inicie nesse intervalo gasta todo seu orçamento de etapa
descobrindo que o registro está ausente e depois reprova o ciclo -- a
mesma espera, paga no único lugar em que é fatal. Esperar aqui
custa o preâmbulo e não reprova nada.

Adesão explícita com orçamento configurável porque a ausência e uma reinicialização
são indistinguíveis por uma sondagem: um laboratório sem registro de contêineres
define isso como 0 em vez de pagar o orçamento a cada ciclo por
algo que nunca chegará.

<a id="4213a0b3-00b9"></a>

## test/modules/Test.Orchestrator.psm1: Invoke-OrchestrationSequence

Coloque no disco um registro de falha para a entrada malsucedida. O mecanismo de sequência
de uma entrada de CONVIDADO grava seu próprio registro, muito mais rico,
e esta chamada deliberadamente nunca o sobrescreve; uma ação de HOSPEDEIRO não tem
esse gravador, portanto, sem isso, um ciclo que termine em uma
verificação prévia acaba sem last_failure.json -- o painel e o
despachante de correção veem uma falha não classificada, e a
pasta do ciclo não contém nada que identifique o que o interrompeu.
Opcional por contrato: o resultado já está decidido, portanto uma falha ao
REGISTRÁ-LO não deve alterá-lo. Test.RunnerInnerLoop é importado
sob demanda porque uma orquestração aprovada nunca precisa dele.

<a id="4213a0b3-00ba"></a>

## test/modules/Test.Orchestrator.psm1: Invoke-OrchestrationSequence

Adote a classe já estabelecida pela execução aninhada, em vez
de anunciar 'unknown' sobre ela. Uma ação do hospedeiro
que conduza uma sequência de convidado falha PORQUE essa sequência
falhou, e o mecanismo de sequência já gravou um
registro classificado com precisão; fixar 'unknown' aqui
descartava isso justamente na camada lida pelo painel,
portanto uma classe inteira de falhas chegava previamente anonimizada, e
a correlação de incidentes entre hospedeiros -- que exige uma classe
compartilhada -- nunca conseguia agrupá-las.
'unknown' continua sendo a resposta honesta quando não há um registro
interno: uma ação do hospedeiro que falhou sozinha não tem nada
mais específico a dizer, e adivinhar seria pior.

<a id="4213a0b3-00bb"></a>

<a id="testmodulestestoutputpsm1-reusable-pass--fail--warn-reporter-for-check-style-scripts"></a>

## test/modules/Test.Output.psm1: Relator reutilizável PASS / FAIL / WARN para scripts de verificação

Relator reutilizável PASS / FAIL / WARN para scripts de verificação. Permite
que scripts de verificação (Test-Config, Test-CachingProxyService, futuras verificações de saúde)
compartilhem o mesmo formato voltado ao operador sem copiar e colar os
contadores e o banner Write-Summary.

Um de TRÊS módulos de registro do Yuruna com responsabilidades separadas. Veja
../../docs/loglevels.md e test/modules/README.md "Three loggers, three
jobs" antes de adicionar auxiliares aqui -- este módulo é responsável SOMENTE pela contagem
PASS/FAIL por script + banner Write-Summary + auxiliar Exit-WithSummary.

Contadores resistentes à remoção de módulo: $global:YurunaOutputState ancora o estado
ativo para que os auxiliares de Test-Config e qualquer módulo que importe este
(por exemplo, Test.ConfigValidator) compartilhem a mesma contagem PASS/FAIL/WARN
independentemente das reimportações com -Force. Veja repo-memory
feedback_module_force_import_evicts_global.md.

<a id="4213a0b3-00bc"></a>

<a id="testmodulestestpooladminpsm1-one-admin-command-at-a-time-may-work-in-a-given-admin-clone"></a>

## test/modules/Test.PoolAdmin.psm1: Um comando administrativo por vez pode trabalhar em um determinado clone administrativo

Um comando administrativo por vez pode trabalhar em um determinado clone administrativo. Cada CLI administrativa é seu próprio processo,
e todas compartilham <runtime>/pool-intent-admin; sem isso, o clone é aberto por vários
processos ao mesmo tempo: dois primeiros usos não encontram .git e clonam no mesmo diretório (um
vence, os demais falham), e o reset --hard de uma leitura pode ocorrer entre a edição e o
commit de um gravador, fazendo-o não encontrar nada para preparar e relatar sucesso para uma mudança que nunca
ocorreu. O bloqueio, portanto, cobre todo o comando: é adquirido quando o clone é aberto e
mantido até o processo sair (o sistema operacional o libera mesmo após uma falha abrupta) ou
Unlock-YurunaPoolIntentClone executar. Administradores em outros hospedeiros trabalham em seus próprios clones e ainda se encontram
no remoto, onde Publish-YurunaPoolIntent faz rebase após perder uma corrida de push.

<a id="4213a0b3-00bd"></a>

## test/modules/Test.PoolAdmin.psm1: Open-YurunaPoolIntent

Recuse reset --hard a menos que o remoto comprovadamente contenha nosso HEAD: um
commit local ausente no remoto é uma intenção de grupo com commit, mas sem push (um
Publish anterior chegou ao commit, mas não ao push), e um reset silencioso
a apagaria sem vestígio. merge-base --is-ancestor: rc==0 significa que HEAD
ESTÁ contido em FETCH_HEAD (um avanço rápido seguro -- reset somente acrescenta
commits); rc==128 é um HEAD ainda não criado / referência ausente, em que reset É a
recuperação. Qualquer outro rc -- 1 (local à frente / divergente), 124 (tempo limite), -1
(git não executável) -- não pode comprovar a inclusão, portanto recuse em vez de
autorizar um reset destrutivo.

<a id="4213a0b3-00be"></a>

## test/modules/Test.PoolNotifier.psm1: Invoke-PoolNotifierDelivery

Recupere reservas órfãs: uma drenagem que terminou abruptamente (por exemplo, um SIGKILL do watchdog) entre a
renomeação de reserva e a movimentação terminal deixa uma mensagem presa em sending/ -- de outra forma perdida
para sempre (somente outgoing/ é examinado abaixo). Mova qualquer entrada sending/ cuja reserva seja
mais antiga que o período de tolerância de recuperação de volta a outgoing/ para que seja tentada novamente. A tolerância evita
tomar uma reserva realmente em andamento de um segundo notificador (uma precaução adicional para a fila
compartilhada). A idade é medida a partir de claimedUtc marcado na mensagem por quem a reserva
(laço de reserva abaixo), NÃO de LastWriteTime do arquivo: a renomeação de reserva
preserva o mtime de gravação do conteúdo da mensagem, portanto uma mensagem enfileirada há muito tempo e
reservada há um instante pareceria imediatamente obsoleta e seria recuperada e entregue duas vezes,
e um NAS cujo relógio difira do deste hospedeiro poderia nunca ou sempre recuperá-la.
claimedUtc usa o mesmo relógio UtcNow que o limite. Uma mensagem sem claimedUtc
(uma drenagem mais antiga ou uma que terminou entre a renomeação e a marca) recorre ao
mtime do arquivo em UTC -- menos preciso, mas ainda limitado.

<a id="4213a0b3-00bf"></a>

<a id="testmodulestestpoolplannerpsm1-pool-planner-read-yurunapoolmanifest-reads-runtimepoolmanifestjson-the"></a>

## test/modules/Test.PoolPlanner.psm1: Planejador do grupo: Read-YurunaPoolManifest lê runtime/pool.manifest.json (os

Planejador do grupo: Read-YurunaPoolManifest lê runtime/pool.manifest.json (os
repositórios da infraestrutura e do projeto do grupo) para o executor interno. Os
auxiliares de guests.compatibility.yml abaixo avaliam as regras de hipervisor
por convidado de um projeto. O executor não os chama, porque cada membro do grupo
executa todo o plano de seu projeto; Test.PoolPlanner.Tests.ps1 é seu único
chamador, e Test-PoolIntent.ps1 valida a cópia desse arquivo no armazenamento
por Test.PoolAdmin. Veja ../../docs/pool-admin.md#what-a-pool-is
para o modelo descentralizado que faz o possível. -- Test.PoolPlanner.psm1

<a id="4213a0b3-00c0"></a>

## test/modules/Test.PoolPush.psm1: Invoke-PoolEventPush

Um ciclo que executou etapas de ações do hospedeiro mantém os eventos de suas execuções filhas em
nested/<node>/cycle.events.ndjson, gravados ali para que a transcrição
e o fluxo de cada subexecução permaneçam juntos. Esses registros descrevem
trabalho realizado dentro DESTE ciclo e carregam sua identidade, portanto ler somente
o arquivo de nível superior descarta a maior parte da telemetria desse ciclo --
e a descarta de forma invisível, porque o arquivo de nível superior está sempre
presente, e um fluxo curto parece um ciclo curto em vez de um
fluxo truncado.

<a id="4213a0b3-00c1"></a>

<a id="testmodulestestpoolstoragepsm1-move-mode-policy"></a>

## test/modules/Test.PoolStorage.psm1: Política do modo de movimentação

Política do modo de movimentação. Constantes de código deliberadas -- a mesma decisão de
CycleHistoryLimit e FailurePauseMaxSeconds: um operador pesquisa e ajusta esses valores
em um lugar, sem uma migração de esquema de configuração e sem dois hospedeiros no mesmo
compartilhamento discordarem sobre o quanto "full" significa cheio.

Reserva: o que AINDA deve estar livre depois que uma cópia chegar. O compartilhamento não pertence somente a esta
funcionalidade -- o grupo de downloads de imagens de convidados, o arquivo de observabilidade
do proxy e pool-intent.git ficam nele -- portanto o arquivamento não pode
levar o espaço livre a zero e quebrá-los.
Folga: margem além do tamanho medido da pasta para o custo adicional da própria cópia.
Projeção: a verificação anterior à criação do processo precisa estimar o custo do PRÓXIMO ciclo.
Ela usa o MÁXIMO da amostra recente em vez da média, porque o custo de
estimar alto é um ciclo ignorado, enquanto o custo de estimar baixo é um ciclo
que termina de executar e depois não pode ser arquivado.

<a id="4213a0b3-00c2"></a>

<a id="testmodulestestpoolstoragepsm1-invoke-poolstorageprocessresult-runs-a-native-command-bounded-by-a-wall-clock-cap"></a>

## test/modules/Test.PoolStorage.psm1: Invoke-PoolStorageProcessResult executa um comando nativo limitado por um prazo de relógio

Invoke-PoolStorageProcessResult executa um comando nativo limitado por um prazo de relógio
e encerra toda a árvore de processos ao excedê-lo, para que uma montagem/cópia travada nunca possa bloquear
o laço. stdin é redirecionado e fechado imediatamente, portanto um filho que, de outra forma,
pediria entrada (por exemplo, sudo pedindo senha) recebe EOF e falha rapidamente
em vez de travar. Retorna @{ ExitCode; StdOut; StdErr }, em que ExitCode é 124
ao exceder o tempo limite (convencional) ou -1 se não foi possível iniciar o processo. Reflete o
padrão limitado Process.Start + WaitForExit + Kill($true) usado em Test.Ssh.psm1.

O stderr do filho precisa ser REDIRECIONADO (um pipe não drenado trava um
filho que produz muita saída), portanto ele é capturado de qualquer maneira -- retorná-lo não custa nada e é a
diferença entre "sudo mount -t cifs rc=32" mais uma suposição sobre a causa e o
motivo literal do kernel/mount.cifs ("unknown filesystem type 'cifs'", "Permission
denied", "Host is down"), cada um exigindo uma correção completamente diferente.

<a id="4213a0b3-00c3"></a>

<a id="testmodulestestpoolstoragepsm1-invoke-poolstorageboundedscript-runs-a-scriptblock-under-a-wall-clock-cap-via-a"></a>

## test/modules/Test.PoolStorage.psm1: Invoke-PoolStorageBoundedScript executa um scriptblock sob um prazo de relógio por uma

Invoke-PoolStorageBoundedScript executa um scriptblock sob um prazo de relógio por uma
tarefa de thread, para que um cmdlet lento (o redirecionador SMB do Windows não tem -TimeoutSec e
pode travar por dezenas de segundos com um NAS inacessível) não possa bloquear o laço. Ao
exceder o tempo limite, abandona a tarefa e retorna imediatamente; a chamada órfã se libera
quando o próprio tempo limite interno do redirecionador expira. Retorna uma hashtable
@{ TimedOut; Result; Error }. Recorre à execução direta quando Start-ThreadJob
não está disponível (ainda limitada pelo tempo limite interno do redirecionador, apenas sem o
limite mais restrito).

<a id="4213a0b3-00c4"></a>

<a id="testmodulestestpoolstoragepsm1-who-is-actually-serving-a-mount"></a>

## test/modules/Test.PoolStorage.psm1: Quem está realmente servindo uma montagem

Resolve-YurunaConfigDoc carrega test.config.yml para o caminho sem Config dos
leitores de configuração de armazenamento: resolve $env:YURUNA_CONFIG_PATH, exige que ele exista E
que Read-TestConfig esteja carregado, e depois o lê dentro de try/catch. Retorna o documento
de configuração analisado ou $null quando a funcionalidade está efetivamente desligada (sem caminho
resolúvel, Read-TestConfig não carregado ou uma exceção na leitura). Read-TestConfig é SEMPRE
chamado com o $Path RESOLVIDO -- nunca pelo nome com $Path omitido -- porque seu
$Path Mandatory travaria para sempre na solicitação interativa de parâmetro sob o
executor sem interface (veja feedback_byname_detection_mandatory_param_prompt_hang). A
alternativa com Read-TestConfig não carregado impede que um chamador que nunca importou Test.Config
(um leitor de armazenamento pode ser carregado por dot-source de forma independente) lance uma exceção. CallerName apenas
identifica o diagnóstico detalhado para que a linha de log de cada leitor continue se identificando.

<a id="4213a0b3-00c5"></a>

## test/modules/Test.PoolStorage.psm1: Connect-YurunaPoolStorage

Chegar aqui com uma entrada AINDA na tabela de montagem significa que a entrada existe,
mas a montagem não responde -- uma sessão SMB inativa cujo servidor desapareceu,
cuja credencial foi alterada ou que foi deixada por outra conta. Remova-a
antes de montar: mount_smbfs do macOS recusa um ponto de montagem ocupado com
"File exists", e mount do Linux o relata como ocupado; essa falha depois é
relatada pelos chamadores como um problema de credencial, o que leva o operador a
redefinir uma senha que nunca esteve errada. O Windows não precisa disso (Connect
já remove o mapeamento primeiro), mas a chamada é inofensiva e mantém as três
plataformas no mesmo caminho.
<a id="4213a0b3-00c6"></a>

## test/modules/Test.PoolStorage.psm1: Connect-YurunaPoolStorage

Crie o ponto de montagem. Primeiro tente sem privilégios -- isso funciona quando
o diretório pai permite gravação pelo usuário (por exemplo, um localPath sob $HOME). Um
pai de propriedade de root, como /mnt, recusa a tentativa, portanto recorra a
`sudo -n mkdir -p`: a MESMA precondição de sudo sem senha já necessária
para a montagem cifs abaixo, portanto não há uma nova superfície de privilégio. `mount`
não cria seu destino, portanto um ponto de montagem ausente, de outra forma,
faz a montagem falhar com um erro enganoso. A tentativa sem privilégios
é silenciada: a recusa em um pai de propriedade de root é esperada e
tratada pela alternativa, portanto um registro de erro ali seria ruído.

<a id="4213a0b3-00c7"></a>

## test/modules/Test.PoolStorage.psm1: Connect-YurunaPoolStorage

Uma recusa significa que mount nunca executou, portanto o NAS nunca recebeu a
credencial -- diga isso, porque os chamadores que recebem apenas um
bool, de outra forma, relatam uma senha rejeitada e mandam
o operador redefinir uma que sempre esteve correta.

Se o arquivo de configuração NOPASSWD atende a mount é determinado
AQUI, enquanto a falha acontece: sudo-rs não grava nenhuma entrada de log
para um `sudo -n` recusado, portanto nada no hospedeiro registra
esse momento, e a pergunta não pode ser respondida depois.

<a id="4213a0b3-00c8"></a>

<a id="testmodulestestpoolstoragepsm1-who-is-actually-serving-a-mount-1"></a>

## test/modules/Test.PoolStorage.psm1: Quem está realmente servindo uma montagem

Join-PoolStoragePath combina uma base localPath com um subcaminho relativo. Uma
base qualificada por unidade do Windows ('y:' ou 'y:\...') é composta como string pura por
[IO.Path]::Combine, NÃO Join-Path: Join-Path resolve o qualificador de unidade
da base na tabela PSDrive, portanto uma letra de unidade para uma montagem SMB que o
runspace atual ainda não enumerou -- referenciada antes da montagem ou
depois de o mapeamento cair silenciosamente no meio do ciclo -- lança uma
DriveNotFoundException NÃO TERMINANTE ("A drive with the name 'y' does not exist"); a chamada
então retorna $null, e o caminho vazio aparece adiante como uma falha enganosa de criação
de pasta "null Path argument". Uma letra de unidade simples também é
RELATIVA à unidade, portanto primeiro a ancore à raiz ('y:' -> 'y:\'), ou a composição
apontará para o CWD por processo naquela unidade. Qualquer outra base (um ponto de montagem
macOS/Linux com raiz '/') não tem qualificador de unidade, portanto Join-Path é seguro ali
e mantém sua normalização de separadores. SubPath é usado literalmente; os chamadores
normalizam quaisquer separadores incorporados antes de passá-lo.

<a id="4213a0b3-00c9"></a>

## test/modules/Test.PoolStorage.psm1: Merge-PoolStorageLedger

Transfira os campos escalares anteriores antes de sobrepor $Status: uma execução
malsucedida fornece um $Status que omite lastCopied (somente uma cópia bem-sucedida o
define), portanto reconstruir apenas a partir de $Status apagaria
lastCopied/lastConnectOk da execução anterior. Inicializar a partir de $Ledger preserva uma chave
omitida, enquanto uma chave presente em $Status ainda a sobrescreve. 'replicated' é
ignorado -- já é reconstruído (e reduzido a LocalNames) acima. Isso
transfere TODAS as demais chaves do registro (atualmente todos os escalares de status); uma chave
que NÃO deva persistir entre execuções precisaria de uma exclusão explícita aqui.

<a id="4213a0b3-00ca"></a>

<a id="testmodulestestpoolstoragepsm1-replicator-async-fail-fast-atomic-backlog-draining"></a>

## test/modules/Test.PoolStorage.psm1: Replicador: assíncrono, falha rápida, atômico, drena pendências

Copy-PoolStorageCycle copia uma pasta de ciclo para
<localPath>/hosts/<HostId>/test-cycles/<CycleName>/ e a confirma com um
sentinela .yuruna-complete gravado POR ÚLTIMO. Qualquer cópia existente SEM sentinela
(uma tentativa anterior interrompida abruptamente) é excluída primeiro e copiada novamente, portanto uma cópia parcial nunca é
confiável. Retorna $true somente quando todas as etapas têm sucesso. Privado; pressupõe que o compartilhamento
já esteja montado.

-Verify (modo de movimentação) compara a cópia com sua fonte ANTES de o sentinela ser
gravado. A ordem importa por dois motivos: o sentinela fica DENTRO do destino,
portanto uma comparação feita depois de gravá-lo sempre difere por um arquivo e pelos bytes
de uma marca; e o sentinela é o que todo leitor trata como "committed", portanto
gravá-lo em uma árvore não verificada publicaria uma cópia pela metade. Uma verificação
malsucedida remove o destino -- sem sentinela, ele não é o arquivo de
ninguém -- e deixa a fonte intacta para a próxima execução.

<a id="4213a0b3-00cb"></a>

## test/modules/Test.PoolStorage.psm1: Get-PoolStorageDrainOrder

Acumule em uma List tipada, NÃO em fatias `$x = if (...) { @(...) }`: um
`@(...)` de um único elemento emitido por uma instrução if é desempacotado como escalar (e um
ramo vazio como $null), portanto `$newest + $oldest` CONCATENARIA strings quando
newestCount==1 e fundiria ou descartaria nomes de ciclos silenciosamente. A List é resistente ao desempacotamento.
Mais recentes PRIMEIRO: a drenagem confirma na ordem da lista e para na primeira falha
de cópia (tratada como conexão perdida), portanto copiar os ciclos de hoje antes do
preenchimento dos mais antigos garante que dados recentes cheguem mesmo que um ciclo antigo depois trave
a execução. Os demais mais antigos seguem e são preenchidos ao longo das drenagens subsequentes.

<a id="4213a0b3-00cc"></a>

<a id="testmodulestestpoolsyncpsm1-invoke-poolsyncgitcapture-and-its-exit-code-wrapper-invoke-poolsyncgit"></a>

## test/modules/Test.PoolSync.psm1: Invoke-PoolSyncGitCapture (e seu wrapper de código de saída Invoke-PoolSyncGit)

Invoke-PoolSyncGitCapture (e seu wrapper de código de saída Invoke-PoolSyncGit)
executa um comando git limitado por um prazo de relógio e encerra
toda a árvore de processos ao excedê-lo, para que um remoto travado ou inacessível nunca possa bloquear o
laço. stdin é fechado imediatamente, e o ambiente de solicitação de credenciais é neutralizado
(GIT_TERMINAL_PROMPT=0 + GIT_ASKPASS vazio + GCM_INTERACTIVE=never), portanto um remoto
que, de outra forma, pediria senha falha rapidamente em vez de travar.
Retorna o código de saída, 124 ao exceder o tempo limite ou -1 se não foi possível iniciar git.
Reflete Invoke-PoolStorageProcess; mantido local para que Test.PoolSync não tenha dependência
de Test.PoolStorage.

<a id="4213a0b3-00cd"></a>

<a id="testmodulestestpoolworkerpsm1-get-locallabstoragesharepath-whether-this-machine-still-publishes-a-share-can"></a>

## test/modules/Test.PoolWorker.psm1: Get-LocalLabStorageSharePath: se esta máquina ainda PUBLICA um compartilhamento só pode

Get-LocalLabStorageSharePath: se esta máquina ainda PUBLICA um compartilhamento só pode
ser respondido pela tabela de compartilhamentos do sistema operacional -- a configuração de uma máquina apoiada
por um NAS e de outra que sirva seus próprios compartilhamentos é idêntica em todas as chaves.

-Global tem uma função essencial aqui, diferentemente das duas importações acima. Test.LocalLabStorage
é um módulo importado pelos PONTOS DE ENTRADA para seu próprio uso, e uma simples importação `-Force`
de dentro deste descarrega a instância pela qual suas exportações são resolvidas: o
chamador continua executando com os comandos carregados há um instante já não
definidos, e falha na primeira chamada com "not recognized as a name of a
cmdlet". Reimportar globalmente mantém uma instância visível a ambos os escopos.

<a id="4213a0b3-00ce"></a>

## test/modules/Test.PortOwner.psm1: Get-PortListenerPid

Windows: HTTP.sys esconde o verdadeiro responsável de Get-NetTCPConnection
(OwningProcess relata 4, a conta de kernel System), portanto netsh é
a única fonte confiável para o mapeamento url-group -> PID. A saída é
agrupada por bloco "Request queue name:"; dentro de um bloco,
`Processes: ID: <pid>` lista PIDs em modo de usuário, e `Registered URLs:`
lista prefixos de URL. Transfira os PIDs de um bloco ao conjunto de resultados quando
sua lista de URLs contiver :$Port. A regex corresponde tanto a
"HTTP://*:8080/" quanto à forma mais rara "HTTP://127.0.0.1:8080:127.0.0.1/"
de vinculação ao hospedeiro.

<a id="4213a0b3-00cf"></a>

## test/modules/Test.PortOwner.psm1: Get-PortHolderServiceInfo

Exija a COMBINAÇÃO de campos que um status.json do Yuruna sempre emite, não
uma única chave comum: schemaVersion + overallStatus juntas são uma
assinatura do Yuruna presente em TODO documento servido (tanto documentos ativos por ciclo
quanto o status.json.template de inicialização com que o servidor responde antes
do primeiro ciclo), enquanto 'host' / 'hostname' / 'schemaVersion' sozinhos
aparecem em muitos JSONs não relacionados e classificariam incorretamente um serviço
externo nesta porta como nosso. hostId deliberadamente NÃO é exigido: o
modelo de inicialização o omite, portanto exigi-lo retiraria o nome do responsável
do banner de conflito para outro participante que acabou de iniciar.

<a id="4213a0b3-00d0"></a>

<a id="testmodulestestportownerpsm1-internal-a-live-sudo-authorization-for-the-takeover-or-false"></a>

## test/modules/Test.PortOwner.psm1: Interno: uma autorização sudo ativa para assumir a porta, ou $false.

Interno: uma autorização sudo ativa para assumir a porta, ou $false.

sudo lê sua senha em /dev/tty, NÃO em stdin -- portanto uma solicitação feita
em uma execução cuja saída é capturada (toda ativação de serviço chamada por
Start-YurunaStatusServiceIfEnabled, todo ciclo do executor) imprime em um log
que ninguém está observando e depois espera por uma tecla que ninguém sabe que deve pressionar. A
sondagem, portanto, é sempre `-n`, e o único lugar que pode realmente pedir entrada é
condicionado a Test-YurunaCanPrompt: uma pessoa que possa tanto VER a pergunta quanto
RESPONDÊ-LA. Em qualquer outro lugar, isso retorna $false, e o chamador relata a situação.

<a id="4213a0b3-00d1"></a>

<a id="testmodulestestpreludepsm1-canonical-exit-codes"></a>

## test/modules/Test.Prelude.psm1: Códigos de saída canônicos

Códigos de saída canônicos. Stop-WithReason / Write-Summary apresentam o "why"
em stdout; o código numérico permanece amplo para que um consumidor não precise de uma
tabela por script.

2 não é um 1 mais brando. Diz que a verificação não pôde chegar a nenhum veredito --
uma ferramenta ausente, uma entrada ausente, um navegador ausente -- e existe para que
esse estado deixe de parecer sucesso. Uma verificação que não possa executar não comprovou
nada, portanto um chamador que exija evidência completa deve tratar 2 como fatal;
um chamador deliberadamente consultivo pode deixá-lo passar, mas somente
declarando essa escolha.

<a id="4213a0b3-00d2"></a>

## test/modules/Test.Prelude.psm1: Initialize-YurunaEntryPointModuleSet

Varredura de recuperação na inicialização + auxiliar atômico de arquivos de estado + máquina
de estados do executor. A ordem importa: Test.EventSchema antes de
Test.Log para que Send-CycleEventSafely valide emissões no carregamento
do módulo; Test.StateFile antes de Test.Recovery para que Resolve-Orphan-
IncompleteCycle resolva o auxiliar durante o carregamento; Test.Log
antes de Test.RunnerState para que emissões de transição de estado sejam gravadas
corretamente; Test.RunnerState por último para que as transições
sintéticas de Initialize-RunnerState alcancem um caminho de emissão completamente carregado.

<a id="4213a0b3-00d3"></a>

## test/modules/Test.Prelude.psm1: Initialize-YurunaEntryPointModuleSet

O conjunto principal Inner carrega módulos de inicialização inicial e os módulos
de trabalho por ciclo por uma chamada Initialize-YurunaEntryPointModuleSet -For Inner
durante a inicialização. O ponto de entrada interno também importa OCR/Tesseract e SSH
após a verificação do ciclo. Test.Prelude.psm1 declara o conjunto canônico, e
o externo despacha um novo processo interno a cada ciclo para que alterações no código-fonte
sejam carregadas no próximo ciclo. A ordem de importação preserva as relações de dependência
(Test.HostContract depende de Test.VMUtility, etc.).

<a id="4213a0b3-00d4"></a>

## test/modules/Test.Prelude.psm1: Initialize-YurunaEntryPointModuleSet

Test.Recovery é carregado para que Invoke-TestProject possa arquivar qualquer
break-active.json desatualizado deixado por um Debug-TestSequence /
Start-TestRunner anterior que terminou abruptamente no meio de uma interrupção. Sem essa varredura,
o executor interno herda o estado de breakpoint pausado, e a
interface de status mostra um botão "Continue" para o ciclo anterior.
Os chamadores de Send-CycleEventSafely / Write-YurunaStateFileJson de Test.Recovery
são protegidos por Get-Command, portanto não precisamos carregar previamente
Test.EventSchema / Test.StateFile aqui; o caminho de arquivamento
continua fazendo o possível em ambos os casos.

<a id="4213a0b3-00d5"></a>

## test/modules/Test.Prelude.psm1: Initialize-YurunaEntryPointModuleSet

Módulos necessários ao código status-service do pai (que não é o servidor
desacoplado): Test.YurunaDir para Initialize-YurunaRuntimeDir /
Initialize-YurunaLogDir, Test.VMUtility para auxiliares de IP / porta,
Test.CachingProxyService para auxiliares de arquivo de estado + sondagem, Test.HostContract
para Get-HostType + Initialize-YurunaHost. Test.PortOwner é
consumido mais adiante no arquivo (Resolve-PortOrphan), portanto também é
incluído aqui -- uma passagem de inicialização carrega todos os módulos
necessários ao pai. O processo filho status-service desacoplado
importa seus próprios módulos a partir de uma here-string e não é
afetado por esse conjunto.

<a id="4213a0b3-00d6"></a>

## test/modules/Test.Prelude.psm1: Initialize-YurunaEntryPointModuleSet

União das importações locais nos cinco scripts de entrada do proxy
de cache sob test/ -- Start-CachingProxyServiceVM.ps1,
Stop-CachingProxyServiceVM.ps1, Move-CachingProxyService.ps1,
Test-CachingProxyService.ps1 e
Repair-CachingProxyServiceForwarder.ps1. Este conjunto deve continuar abrangendo
todos os cinco: Test.HostContract (para Initialize-YurunaHost, Get-HostType,
Invoke-LibvirtGroupReExecIfNeeded, Add-PortMap / Remove-PortMap,
Test-CacheVMOnExternalNetwork, Remove-HostProxy / Set-HostProxy,
Initialize-SudoCache), Test.CachingProxyService (Get-CachingProxyServiceState-
Path, Save-/Read-CachingProxyServiceState, Test-CachingProxyServiceAvailable,
Invoke-CachingProxyServiceProbe, Get-CachingProxyServiceVmIp), Test.VMUtility
(Test-IpAddress, Get-CachingProxyServicePort, Format-IpUrlHost) para
os ramos de variável de ambiente / -CacheIp que ignoram as importações transitivas de Test-CachingProxyService-
Available. Yuruna.Host.psm1 por hospedeiro fica
sob host/<short>/modules/ e é carregado por Initialize-Yuruna-
Host pela camada de contrato -- não faz parte deste conjunto.

<a id="4213a0b3-00d7"></a>

<a id="testmodulestestrecoverypsm1-cycle-folder-name-patterns"></a>

## test/modules/Test.Recovery.psm1: Padrões de nomes de pastas de ciclo

Padrões de nomes de pastas de ciclo. Duas formas:

  Simples:        NNNNNN.YYYY-MM-DD.HH-mm-ss.HOSTID
                  (fechamento normal)
  Com sufixo:     NNNNNN.YYYY-MM-DD.HH-mm-ss.HOSTID.incomplete
                  (em andamento OU falha abrupta antes da renomeação de Stop-LogFile)

Qualquer outra coisa sob status/log/ é deixada intacta (pastas criadas pelo
operador, agrupamentos history.YYYY-MM-DD, arquivos anteriores .aborted.<UTC>,
etc.).

<a id="4213a0b3-00d8"></a>

## test/modules/Test.Recovery.psm1: Clear-StalePidFile

O PID está ativo, mas o sistema operacional pode ter reciclado o PID de um
ocupante anterior encerrado para um processo não relacionado. Confie no pidfile como
ativo somente quando StartTime do processo ativo corresponder ao StartTime
auxiliar registrado (runner.start, gravado por Write-RunnerPidFile
como ToString('o')). A tolerância de 2s corresponde a Get-RunnerInstanceState:
DateTimeOffset.Parse + StartTime podem perder precisão durante a
conversão de ida e volta em alguns kernels, mas a janela é muito menor que
qualquer reciclagem real. Quando a identidade não puder ser determinada (sem
StartTime auxiliar ou StartTime ativo ilegível), mantenha uma abordagem
conservadora e trate-o como ativo.

<a id="4213a0b3-00d9"></a>

## test/modules/Test.Registry.psm1: New-YurunaRegistry

Quando já existe uma âncora global (uma reimportação com -Force ou um segundo chamador
que compartilhe AnchorVar), o armazenamento construído aqui é descartado, e o ativo é reutilizado.
Se o chamador pediu explicitamente um comparador diferente do armazenamento ativo,
respeitar somente o armazenamento ativo manteria silenciosamente a distinção menos estrita entre maiúsculas e minúsculas que um
chamador tentava restringir -- uma redução da política. Migre: construa um novo
armazenamento com o comparador solicitado, copie as entradas existentes sob as
novas regras de igualdade de chaves e depois vincule novamente a âncora. Migrar (não lançar uma exceção) mantém
todos os chamadores atuais funcionando; todos pedem o próprio comparador do armazenamento, portanto este
ramo nunca é executado para eles.

<a id="4213a0b3-00da"></a>

<a id="testmodulestestremediationpsm1-which-failures-the-runner-may-retry-without-an-operator-and-how-many-times"></a>

## test/modules/Test.Remediation.psm1: QUAIS falhas o executor pode tentar novamente sem um operador, e QUANTAS vezes.

QUAIS falhas o executor pode tentar novamente sem um operador, e QUANTAS vezes.
A lista fica aqui, ao lado do registro que classifica as falhas, porque
mantê-la ao lado impede que o conjunto que CLASSIFICA uma falha
divirja do conjunto que pode AGIR sobre uma. Em particular, todas as
classes cujos tratadores recomendem uma nova tentativa inofensiva devem estar representadas aqui.

Uma classe ganha lugar aqui somente quando tentar novamente é todo o reparo, e uma
repetição é inofensiva. Todo o restante -- plano incorreto, conteúdo ausente,
cofre expirado, disco cheio -- permanece consultivo, porque tentar novamente
não pode ajudar ou destrói as evidências de que o operador precisa.

credential_expired está deliberadamente ausente: um cofre expirado permanece consultivo.
Nenhum caminho de produção chama a primitiva de reautenticação disponível, e o
tratador registrado da classe pede um operador em vez de nova tentativa.
A inclusão não despacha um reparo em nenhum caso; seu único
efeito é terminar antecipadamente a pausa após falha, o que é a resposta errada para
uma credencial que ninguém corrigiu ainda.

<a id="4213a0b3-00db"></a>

## test/modules/Test.Remediation.psm1: Invoke-Remediation

Roteamento da causa interna. Um `retry` esgotado relata a classe externa
'retry_exhausted', que oculta a causa acionável do verbo mais profundo
preservada pelo registro em innerFailureClass. Roteie pela classe interna quando estiver
presente E tiver seu próprio tratador registrado, para que a recomendação trate
a falha real em vez do wrapper genérico de nova tentativa. Severity /
suggestedRecoveries seguem a classe roteada; a classe externa é preservada como
$routedFromClass (apresentada como RoutedFromFailureClass / outerFailureClass), para que
a trilha de auditoria ainda mostre o ocultamento.

<a id="4213a0b3-00dc"></a>

## test/modules/Test.Remediation.psm1: Register-BuiltinRecoveryHandler

Deliberadamente NÃO restart_from_snapshot, que é o recomendado por ocr_timeout
acima. Os dois parecem iguais no registro -- uma espera encerrada sem
seu padrão --, mas a suposição por trás da repetição a partir de um snapshot é que
a tela divergiu do caminho registrado, e uma execução limpa voltará a segui-lo.
Aqui, a tela nunca ficou legível: algo preencheu o console
mais rápido que o padrão podia ser encontrado, e uma repetição reproduz
isso à mesma velocidade. O conteúdo do console é a evidência, e uma pessoa precisa
lê-lo, portanto esta classe para em vez de gastar outro tempo limite completo.

<a id="4213a0b3-00dd"></a>

## test/modules/Test.Remediation.psm1: Register-BuiltinRecoveryHandler

Duas telas chegam a esta classe. Uma ainda está mudando: uma linha que se repete
mais rápido que o padrão pode ser lido nela, em que a resposta é corrigir
o que se repete. A outra parou de mudar há muito tempo e apenas
PARECE uma inundação, porque a contagem de repetições é medida em um único
quadro -- uma parede de texto já rolado em um convidado que espera por
algo. Indicar uma rede instável no segundo caso leva o leitor a
uma falha inexistente, portanto a leitura estática determina qual
causa é descrita.

<a id="4213a0b3-00de"></a>

## test/modules/Test.RootArtifact.psm1: Get-YurunaRootHomeArtifact

Sem privilégios primeiro: em um hospedeiro onde o diretório pessoal de root permite travessia, isso responde
sem envolver sudo.

-ErrorAction SilentlyContinue porque uma sondagem NEGADA é uma resposta esperada
aqui, não uma falha. O macOS mantém /var/root em 0700, portanto um
Test-Path sem privilégios retorna $false E grava um erro vermelho "Access to the path is denied"
no console do chamador -- durante a configuração, no meio da lista de
etapas, em uma verificação que depois tem sucesso ao pedir sudo.
A sondagem apoiada por sudo abaixo é a que decide; este ramo é apenas o
atalho para hospedeiros em que a resposta não tem custo.

<a id="4213a0b3-00df"></a>

<a id="testmodulestestrunnerelevationpsm1-per-host-type-command-manifest-for-the-per-cycle-path"></a>

## test/modules/Test.RunnerElevation.psm1: Manifesto de comandos por tipo de hospedeiro para o caminho POR CICLO

Manifesto de comandos por tipo de hospedeiro para o caminho POR CICLO. Um driver de hospedeiro pode assumir a
responsabilidade exportando Get-HostElevationCommand (resolvido primeiro, abaixo); até que
algum faça isso, esta tabela é o único lugar em que a lista fica, portanto um novo local de chamada sudo
no caminho do ciclo tem exatamente um lugar para se registrar.

ubuntu.kvm: o mapeamento de portas do proxy de cache (Add-PortMap / Remove-PortMap) grava
e remove /etc/systemd/system/yuruna-cacheproxy-p<port>.{socket,service} e
recarrega systemd. Essa é toda a superfície de elevação por ciclo no KVM.

<a id="4213a0b3-00e0"></a>

## test/modules/Test.RunnerHeartbeat.psm1: Clear-RunnerPhase

A exclusão vem PRIMEIRO, é verificada e tentada novamente. Dois motivos, e
este é o único lugar do módulo onde uma operação de arquivo que apenas fizesse o possível
falharia na direção do limite RESTRITO:

 * Ordem. Uma exceção .NET é TERMINANTE em PowerShell, portanto, se a
   gravação de stepHeartbeat abaixo viesse antes desta e lançasse uma exceção (disco cheio, um
   identificador de antivírus/backup -- a classe de falha para a qual o próprio bloco catch
   do temporizador de heartbeat já existe), o controle saltaria a exclusão, e o
   marcador sobreviveria durante o ciclo.
 * Disputa. O watchdog consulta o marcador com Get-Content, cujo
   identificador é adquirido sem FILE_SHARE_DELETE, portanto um Remove-Item que ocorra
   nessa janela falha -- e -ErrorAction SilentlyContinue o torna um
   erro não terminante que try/catch nunca vê. Esse identificador dura
   microssegundos em comparação com uma consulta de vários segundos, portanto uma repetição praticamente
   sempre vence.

Qualquer falha deixaria o limite de preâmbulo de 600 s em vigor durante todo o
ciclo e encerraria incorretamente o download semanal da imagem base em ~10 minutos.

<a id="4213a0b3-00e1"></a>

<a id="testmodulestestrunnerinnerlooppsm1-yuruna-archivetargz-and-yuruna-project-archivetargz-are-built-via"></a>

## test/modules/Test.RunnerInnerLoop.psm1: /yuruna-archive.tar.gz e /yuruna-project-archive.tar.gz são construídos por

/yuruna-archive.tar.gz e /yuruna-project-archive.tar.gz são construídos por
`git archive HEAD`, portanto os convidados só veem conteúdo COM COMMIT. Se o processo
do hospedeiro estiver executando código da árvore de trabalho que referencie novos caminhos de arquivos ainda sem
commit (renomeação em andamento, novo script de automação preparado, mas sem push),
as chamadas SSH/console do hospedeiro invocam os novos nomes, enquanto o convidado ainda tem
o conteúdo antigo de HEAD -- o sintoma é um confuso "script not found" com
uma linha de comando aparentemente correta. Write-Warning ignora a filtragem por logLevel
para que isso apareça independentemente da configuração logLevel em test.config.yml.

<a id="4213a0b3-00e2"></a>

<a id="testmodulestestrunnerinnerlooppsm1-cycle-start-guard-warn-on-working-tree-drift-vs-head"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Proteção no início do ciclo: avisar sobre divergência da árvore de trabalho em relação a HEAD

Contexto: um modo de falha real é o Wi-Fi do hospedeiro mudar para outro
SSID/sub-rede no meio do ciclo. A VM caching-proxy-service está no
Default Switch (Hyper-V) / NAT compartilhado VZ (UTM) do hospedeiro e continua roteável a partir
dele, MAS a URL injetada em cidata do convidado durante New-VM pode ter
apontado para o IP que o hospedeiro tinha na rede anterior -- que os convidados não
conseguem mais acessar. Sintoma: fetch-and-execute.sh excede o tempo limite em /livecheck
e recorre silenciosamente ao GitHub, ocultando o caminho de proxy quebrado.

Este auxiliar sonda por TCP a URL do proxy detectada na inicialização do executor antes de
cada etapa, para que o operador veja o momento em que a conectividade é perdida. O estado
é acompanhado para manter o log legível: um aviso explícito "LOST" uma vez na
transição para indisponível, notas breves "still unreachable" durante uma indisponibilidade
sustentada e uma nota "recovered" quando retorna. Não faz nada quando nenhum proxy
foi detectado na inicialização (nada a perder) ou quando a URL não é analisada
como http://ip:port. O estado indisponível/disponível fica no escopo do módulo: toda sondagem passa
por esta função, para que o log de transições permaneça coerente.

<a id="4213a0b3-00e3"></a>

<a id="testmodulestestrunnerinnerlooppsm1-per-cycle-config-reload"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Recarga de configuração por ciclo

Ponto de recarga de configuração por etapa para o laço interno: lê novamente test.config.yml em
$State (Sync-RunnerCycleConfig) e atualiza o nível de log por etapa
(Resolve-RunnerLogLevel) em uma chamada, para que uma fronteira de etapa seja uma única chamada mais
o espelhamento da opção, em vez do par recarga/nível de log repetido após cada etapa.
Também captura o resultado de Sync-RunnerCycleConfig para acompanhar uma indisponibilidade sustentada de
recarga: a primitiva avisa a cada recarga malsucedida, mas uma série de falhas consecutivas
significa que o executor continua usando a última configuração válida, portanto isso é apresentado uma vez,
de maneira explícita, em vez de degradar silenciosamente.

<a id="4213a0b3-00e4"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Copy-FailureArtifactsToStatusLog

GuestKey opcional: quando fornecido, a URL da pasta de dados por convidado
produzida é registrada no documento de status ativo por
Set-GuestFailureArtifact, para que Complete-Run possa promovê-la para
history.guestSummary, e o painel vincula o indicador por convidado
diretamente aos artefatos. A pasta é criada no
início de cada iteração de convidado (portanto ciclos bem-sucedidos também têm um
lugar para receber a saída de saveSystemDiagnostic) -- esta função apenas
a preenche com arquivos específicos de falha.

<a id="4213a0b3-00e5"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Copy-FailureArtifactsToStatusLog

Três fontes de artefatos, gravadas por caminhos de código diferentes:
  * screens_<VM>/raw_*.png         -- buffer circular de Wait-ForText (modo GUI)
  * failure_screenshot_<VM>.png    -- captura única de um instante congelado de
                                     falhas que não sejam waitForText (qualquer
                                     etapa de sequência que não seja
                                     waitForText/waitForAndEnter,
                                     inclusive sshExec)
  * failure_ocr_<VM>.txt           -- último texto OCR de waitForText

Todos os arquivos ficam diretamente em cycleGuestDataFolder (a pasta por convidado
sob cycleFolder). Na prática, há no máximo uma falha por convidado por
ciclo, portanto os nomes de arquivos raw_<stamp>.png já
codificam sua própria ordem e não precisam de um prefixo adicional.
É o mesmo local aninhado na pasta do ciclo em que Wait-ForText grava por
Get-CycleScreenDir. Recorre a $env:YURUNA_LOG_DIR no
caso extremo sem pasta de ciclo (defensivo; não deveria ocorrer aqui,
porque Start-LogFile executou anteriormente).

<a id="4213a0b3-00e6"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Copy-FailureArtifactsToStatusLog

Captura do último log de fetch-and-execute. O fetch-and-execute.sh do convidado
duplica toda execução de script interno em /tmp/yuruna-last-fetch-and-execute.log
(truncado a cada invocação), portanto esse arquivo contém stdout/
stderr completos do wrapper em execução quando a sequência falhou --
essencial para a classe de falha em que o `set -e` do wrapper
saiu silenciosamente enquanto a captura OCR/tela ainda estava focada em um
laço de consulta posterior. Falha não fatal como as outras etapas: um convidado
sem SSH ou um log nunca gravado apenas gera uma linha Verbose.
Save-GuestDiagnostic já comprovou que SSH funciona por Wait-SshReady, portanto
podemos chamar Invoke-GuestSsh sem repetir a confirmação de prontidão.

<a id="4213a0b3-00e7"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Copy-FailureArtifactsToStatusLog

Captura de diagnósticos do sistema do hospedeiro. Separada do snapshot do convidado
acima (Save-GuestDiagnostic acessa o convidado por SSH); esta executa
automation/Get-SystemDiagnostic.ps1 no próprio hospedeiro do executor
de testes para que o operador possa correlacionar o estado do hospedeiro (docker,
kubectl, pressão de disco, sockets de escuta, eventos recentes do kernel)
com a falha. Executada em um processo filho pwsh para que Start-Transcript
do script e a lista global $script:Problems não vazem
para o executor. Falha não fatal, alinhada com o caminho do convidado.

<a id="4213a0b3-00e8"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Copy-FailureArtifactsToStatusLog

Relatórios de falha abrupta do aplicativo de hipervisor (macOS). Quando o UTM (ou seu iniciador QEMU
por VM) termina abruptamente no meio do ciclo, tudo acima registra apenas sintomas --
a E/S do console para de responder, capturas de tela deixam de chegar, a descoberta de IP
fica silenciosa -- enquanto o verdadeiro "why" é o relatório .ips gravado pelo macOS
sob ~/Library/Logs/DiagnosticReports. Copie os relatórios gravados
desde o início deste ciclo (o horário de criação da pasta é o início do ciclo), para que
a causa acompanhe as evidências de falha em vez de expirar
no hospedeiro. Falha não fatal como os vizinhos.

<a id="4213a0b3-00e9"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Copy-FailureArtifactsToStatusLog

Captura DHCP na rede (drivers que a ativam em Start-VM). O diagnóstico
de rede do lado do convidado só pode dizer "no lease"; se o DISCOVER
nunca saiu do convidado, desapareceu ao atravessar o vSwitch ou uplink, ou saiu
sem resposta, isso só é visível no caminho dos pacotes do hospedeiro, e cada
situação aponta para uma máquina diferente. Protegido por Get-Command
porque somente alguns drivers de hospedeiro o implementam, e com falha não fatal como
os vizinhos: um diagnóstico nunca deve transformar uma etapa malsucedida em uma
coleta malsucedida.

<a id="4213a0b3-00ea"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Update-CycleModuleImport

Chame novamente Initialize-YurunaHost para que o driver do hospedeiro (Yuruna.Host.psm1)
seja reimportado com -Global -Force a cada ciclo. Os auxiliares entre hospedeiros
(Test.VMUtility.psm1 -- Wait-VMRunning, Test-IpAddress, ...) são importados com
-Global apenas quando esse módulo ainda não está carregado.
Sem isso, qualquer coisa que limpe a sessão do executor no meio do ciclo
(uma etapa de sequência chamando Get-Module | Remove-Module, um
Import-Module transitivo sem -Global, etc.) deixa o executor incapaz de
encontrar Wait-VMRunning na próxima etapa New-VM.Resource -- um
executor de longa duração no mesmo processo acabará falhando abruptamente com
"Wait-VMRunning is not recognized" sem essa defesa.

<a id="4213a0b3-00eb"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Complete-CycleRun

Um convidado recriado sob sua própria identidade que retornou com um
endereço diferente violou a única propriedade que torna suportável uma concessão
longa, e já consumiu o endereço antes que alguém pudesse
verificar. Incorporado AQUI, no único ponto que decide aprovação/reprovação, porque
um ciclo cujos convidados obtiveram cada um uma nova concessão não é um ciclo aprovado --
é um que funcionou enquanto esgotava o grupo de endereços de que precisará na próxima vez.

Um ciclo já malsucedido mantém a falha que tem: a anterior é o
registro mais rico e o que identifica uma etapa, e Write-CycleInfraFailure
não o sobrescreverá em nenhum caso. Isso somente transforma uma aprovação em reprovação.

<a id="4213a0b3-00ec"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Get-CycleGuestAndSequenceList

Write-Information, não Write-Output: o valor de retorno desta função é
atribuído por seu chamador, e o PowerShell fornece à atribuição TODO
objeto do fluxo de sucesso. Uma linha de progresso Write-Output aqui transforma o
resultado em um Object[] de [String, Hashtable] em vez da hashtable --
o acesso a membros ainda lê através dele, portanto nada parece quebrado, mas uma
GuestList vazia então enumera para $null em vez de @(), e a própria
linha nunca chega à transcrição. Esta também não: a resolução do plano
executa antes de a transcrição do ciclo ser aberta, portanto a contagem é
apenas uma pista no console, e o conjunto de convidados necessário a um leitor do log é
gravado ao lado da exibição da configuração mais adiante no ciclo.

<a id="4213a0b3-00ed"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Start-CycleHostDiagnostic

O filho também grava um arquivo irmão legível por máquina ao lado do
relatório em prosa (<OutFile>.json, esquema yuruna.diagnostic.problems/v1), cujas
contagens por classe são a única declaração estruturada do que o
diagnóstico do hospedeiro realmente encontrou. Sem lê-lo de volta, todo o
veredito fica em um artefato que ninguém abre até uma análise posterior, portanto
um problema no escopo do hospedeiro presente no início do ciclo (um switch virtual
cujo uplink já não encaminha, pressão de disco, um serviço
parado) permanece invisível enquanto o ciclo consome todo seu orçamento.
Somente console, sem alerta: uma notificação por ciclo dispararia para uma
condição permanente a cada ~18 minutos. Seu próprio catch fica dentro do
catch da captura, para que um arquivo auxiliar malformado seja apresentado como tal,
em vez de tomar a expressão "capture failed" de uma captura
que claramente teve sucesso -- e nunca reprova um ciclo em nenhum dos casos.

<a id="4213a0b3-00ee"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Wait-CyclePauseFlag

Atualize runner.stepHeartbeat a cada iteração: o watchdog externo
lê apenas o mtime desse arquivo e encerra o interno após
testCycle.stepTimeoutSeconds (2700 segundos como valor de fallback; o modelo
distribuído define 3600) sem atualização. Uma pausa deliberada não tem fronteiras
de etapa para atualizá-lo pelo caminho normal de Invoke-Sequence, portanto, sem isso, o watchdog
usaria TerminateProcess no interno durante a pausa, levaria o externo a
sua espera progressiva após falha e deixaria /control/cycle-resume e
/control/start-cycle de index.html sem nada com que se comunicar.

<a id="4213a0b3-00ef"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-RunnerInnerCycle

Invariante de ordem para last_failure.json: Write-CycleInfraFailure nunca
sobrescreve um registro existente, e essa regra protege o registro
MAIS RICO escrito pelo mecanismo posteriormente no MESMO ciclo. Mas
$env:YURUNA_LOG_DIR é a RAIZ do log compartilhada por todos os ciclos, portanto um registro
presente ali neste ponto -- a primeira verificação, antes de qualquer trabalho do ciclo --
foi deixado por um ciclo ANTERIOR e é exatamente o que a
correção automática e a retomada a quente do laço externo continuariam usando no roteamento. Limpá-lo é
correto SOMENTE aqui, onde nada deste ciclo pode ter gravado ainda;
mover isso para qualquer ponto posterior inverte a regra e destrói evidências ativas.

<a id="4213a0b3-00f0"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-RunnerInnerCycle

Faça convergir o exportador de métricas deste hospedeiro -- uma ALTERAÇÃO, não uma verificação,
colocada aqui em vez de dentro da verificação acima por dois motivos.

A verificação decide se um ciclo pode executar e relata isso como bool; uma
alteração do hospedeiro incorporada nela seria invisível a todo leitor dessa
chamada, e Assert-*/Set-* são separados em todos os outros lugares aqui.

Esta posição também é o que torna seguro um reparo privilegiado sem intervenção.
O laço sem intervenção não faz nenhum reparo que precise pedir seu
privilégio -- um laço esperando uma credencial que ninguém está presente para digitar é um
travamento, e é por isso que o relógio do hospedeiro é apenas medido aqui e reparado
onde um console pode responder. Este nunca pede: no único tipo de hospedeiro
que registra um provedor, a verificação acima começa com Assert-Elevation e
recusa o ciclo quando ela falha, portanto chegar a esta linha comprova que
Administrator já está disponível. Nenhum provedor é registrado para os hospedeiros
onde o mesmo trabalho exigiria uma credencial sudo.

Executa antes de qualquer convidado iniciar, para que uma instalação que reinicie um serviço ou
altere o firewall nunca ocorra no meio do provisionamento. Custa uma consulta de serviço
em um hospedeiro que já tenha o exportador; um que não tenha recebe
uma tentativa de instalação limitada, e uma tentativa malsucedida garante um intervalo silencioso para que
um hospedeiro que não consiga instalar não gaste parte de cada ciclo
redescobrindo isso.

Duas precauções, porque isso é telemetria, e telemetria não pode encerrar um ciclo.
O try garante que nem um módulo que falhou ao importar -- tornando o
próprio comando irresolúvel -- possa lançar uma exceção aqui. Descartar o valor
garante que esta etapa nunca contribua para o retorno da função
envolvente; tudo destinado à leitura por uma pessoa está nos fluxos de aviso e
informação.

<a id="4213a0b3-00f1"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-RunnerInnerCycle

Falha na etapa de inicialização -- ainda sem pasta de ciclo, portanto o auxiliar
constrói um conteúdo mínimo a partir destes escalares. O registro de infraestrutura acima
já gravou a classe canônica (network_timeout quando uma sondagem DNS/TCP
falhou; caso contrário, bootstrap_sync) + severidade 'hard'; passe a mesma
para que as extensões roteiem por failureClass em vez de pesquisar texto livre.
O subcaso de rede (uma sondagem DNS/TCP falhou) é transitório e permite nova tentativa
-> network_timeout; caso contrário, uma falha git por divergência / autenticação / árvore suja
-> bootstrap_sync (operador). Grave o registro schema-v2
antes da notificação para que seu EventData obtenha a classe real.

<a id="4213a0b3-00f2"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-RunnerInnerCycle

Quando este hospedeiro está em um grupo que contém repositórios
(runtime/pool.manifest.json, gravado por
Sync-YurunaPoolIntent do laço externo), o PAR de repositórios de infraestrutura/projeto do grupo substitui
repositories.frameworkUrl / repositories.projectUrl deste hospedeiro para ESTE ciclo, portanto
a atualização do projeto + a clonagem da infraestrutura abaixo usam os repositórios do grupo. GH_TOKEN
deliberadamente NÃO é substituído -- permanece local ao hospedeiro (nunca passa pela intenção
do grupo). Hospedeiros fora de grupo (sem manifesto / sem repositórios) não são alterados.
Limpo a cada ciclo: um valor desatualizado faria um ciclo fora de grupo sondar uma
atribuição que já não se aplica (e possivelmente falhar nela).

<a id="4213a0b3-00f3"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-RunnerInnerCycle

Um grupo pode fornecer a este hospedeiro uma projectUrl que sua credencial não consegue ler. Sem
esta sondagem, isso só aparece quando a clonagem abaixo falha, no meio do ciclo, como um
erro genérico de inicialização -- e a pessoa que FEZ a atribuição não é
a pessoa que observa este hospedeiro. Sonde primeiro, classifique com precisão e
publique o resultado para que o painel de controle do grupo possa identificar os hospedeiros bloqueados.

Executa somente para uma URL ATRIBUÍDA PELO GRUPO: a própria projectUrl de um hospedeiro já é
verificada previamente em Update-ProjectClone, e duplicar isso aqui
dobraria sem motivo o custo de rede de início de ciclo de cada hospedeiro fora de grupo.

<a id="4213a0b3-00f4"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-RunnerInnerCycle

A reimportação com -Force acima substitui a instância de módulo de Test.Status, o que
descarta o documento de status em memória construído no início do ciclo (status.json no
disco permanece intacto). Reconstrua-o desse arquivo para que o restante do ciclo tenha um
documento ativo para alterar. Um ciclo por convidado o recriaria algumas regiões
adiante em Initialize-StatusDocument, mas um ciclo cujo nível superior seja uma
sequência de orquestração ignora inteiramente aquele bloco e, de outra forma, executaria
toda gravação de status sem documento até que o orquestrador instalasse o
seu -- descartando registros de falha de infraestrutura e falhando diretamente no timestamp de
Get-Image. Barato e idempotente: a mesma passagem de preservação e regravação da
chamada no início do ciclo, relendo o que acabou de gravar.

<a id="4213a0b3-00f5"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-RunnerInnerCycle

Construa o plano de execução por ciclo a partir de project/test/test.runner.yml.
Cada entrada do plano é uma tupla (carga de trabalho de nível superior, convidado, cadeia de sequências);
vários níveis superiores podem compartilhar um convidado, portanto removemos duplicatas em GuestList para
as partes do ciclo que operam por VM única (verificação de pasta,
Get-Image, o laço por convidado de limpeza -> criação -> início -> verificação).
Recorre à lista legada guestSequence quando a configuração do ciclo está
ausente -- útil antes de a inicialização da clonagem do repositório do projeto terminar e
para operadores que ainda não migraram.

<a id="4213a0b3-00f6"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-RunnerInnerCycle

PlannerFatal (atualmente: arquivos de sequência de projeto duplicados com o
mesmo nome sob pastas test/ diferentes) significa que o plano é
ambíguo -- recorrer silenciosamente a guestSequence deixaria o
ciclo executar com um vencedor arbitrário. Imprima o erro com destaque
e esvazie GuestList imediatamente para que o laço foreach abaixo
execute zero iterações. O ciclo ainda segue naturalmente por "Finalize cycle",
portanto $OverallPassed=false incrementa ConsecutiveFailures e
dispara notificações no mesmo limite que qualquer outra falha.

<a id="4213a0b3-00f7"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-RunnerInnerCycle

Uma entrada test.runner.yml pode ser uma sequência de orquestração (sem resource:/
baseline; as etapas são InvokeTestSequence). Ela não contribui com entradas de plano
por convidado, portanto assume todo o ciclo por Invoke-OrchestrationSequence
(Test.Orchestrator) -- Reset/Initialize/Start-Log, uma linha de painel por
sequência interna, Complete/selagem -- exatamente como uma execução independente `Debug-TestSequence
<orch>`. O executor delega a ela abaixo em vez do ciclo de vida
de VM por convidado e força GuestList vazia para que a alternativa de plano vazio da
guestSequence legada NÃO crie um convidado inexistente.

<a id="4213a0b3-00f8"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-RunnerInnerCycle

Atribua o resultado do auxiliar DIRETAMENTE -- NÃO envolva a chamada em @(). A vírgula
unária dentro de New-CycleGitCommitList já emite toda a lista como um
item de pipeline (portanto até uma lista de um elemento continua sendo um array). Envolver esse único
item de array em @() o aninha um nível mais fundo, produzindo gitCommits = [[{...}]]
em vez de [{...}] -- a classe de armadilha de envolvimento duplo de array. Essa forma malformada é
rejeitada pelo leitor gitCommits do esquema de status e pelo serviço pool-aggregator,
que então não consegue analisar o status.json do hospedeiro.
Um ciclo de orquestração ignora todo este bloco: Invoke-OrchestrationSequence
(delegado em "Finalize cycle" abaixo) faz seu próprio Reset/Initialize-Status
Document + Start-LogFile, portanto é responsável pelo documento de status + transcrição. Executar
Initialize do executor aqui também criaria um ciclo de convidado vazio que o
orquestrador depois sobrescreveria. $CycleStartUtc/$LogFile permanecem vazios; o laço de convidados
(GuestList vazia) e a parte final de notificação de falha toleram isso.

<a id="4213a0b3-00f9"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-RunnerInnerCycle

CycleNumber é lido DEPOIS de Initialize-StatusDocument para ver o
valor incrementado (1, 2, 3, ...). Determina o prefixo de 6 dígitos no
nome de cycleFolder; Start-LogFile também publica a URL da pasta no
documento de status por Set-CycleFolderUrl para que o painel possa construir
links de blocos por convidado a partir dela.
CycleNumber (também retornado pelo auxiliar) não é lido adiante no
corpo do ciclo -- é consumido dentro de Start-CycleLogFile para nomear a pasta
do ciclo --, portanto somente LogFile é capturado aqui.

<a id="4213a0b3-00fa"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-RunnerInnerCycle

Reafirme o driver do hospedeiro na sessão GLOBAL antes do laço de convidados.
Os scripts filhos invocados com & logo acima (reinicialização de status-service, a
varredura de VMs Remove-TestVMFiles) executam aninhados no estado de sessão
deste módulo, onde uma importação com -Force sem -Global retira o driver do hospedeiro da
tabela global (a classe de regressão de remoção legada). Chamadas do contrato do hospedeiro
feitas do escopo DESTE módulo (New-VM/Start-VM) ainda são resolvidas a partir da
cópia do módulo, mas uma chamada feita de OUTRO módulo no meio da sequência
(o redesenho por Restart-VMConsole de Invoke-Sequence no início da sequência) precisa da
cópia GLOBAL. Reimportar aqui é idempotente e barato, e restaura o
contrato global para o mecanismo de sequência.

<a id="4213a0b3-00fb"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-RunnerInnerCycle

EventData: alerta durante o ciclo -- a pasta do ciclo está
estabelecida, portanto Get-FailureEventData lê last_failure.json
schema-v2 (failureClass/severity/suggested
Recoveries do registro de verbos) e acrescenta o
contexto de ciclo/hospedeiro. Construído aqui para poder ser corrigido
abaixo antes de Send-CycleFailureNotification enviá-lo --
o trecho JSON final do corpo e o conteúdo -EventData carregam
a mesma hashtable; as extensões que declaram -EventData
roteiam por ela, enquanto as legadas ainda a veem no corpo.

<a id="4213a0b3-00fc"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-RunnerInnerCycle

Feche o laço de observabilidade do autorreparo: roteie a falha
pelo despachante de correção para que ele calcule uma recomendação
de recuperação, emita o evento NDJSON remediation_recommended
(internamente, por Send-CycleEventSafely), persista o
last_remediation.json durável ao lado da falha (arquivado na
pasta do ciclo e replicado para o grupo) e registre a próxima
etapa. Apenas consultivo -- o despachante registra a decisão, mas
nunca age. Passe o conteúdo em memória para que uma limpeza de last_failure.json
na fronteira do ciclo não roteie isso por um arquivo desatualizado. Aplicar
automaticamente uma recomendação é uma funcionalidade separada, desligada por padrão,
que precisa de um limite de tentativas por ciclo, uma lista de classes permitidas
(e revisão humana suficiente) antes de poder agir.

<a id="4213a0b3-00fd"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-RunnerInnerCycle

A verificação por etapa de Invoke-Sequence lança "YurunaCycleRestart: ..." quando
/control/start-cycle pede um aborto no meio do ciclo. É o
operador clicando em "Save and start cycle" enquanto um ciclo está ativamente
executando etapas: Remove-TestVMFiles já removeu as VMs,
o sinalizador foi criado, e o ciclo precisa terminar de maneira limpa.
Detectado pelo prefixo da mensagem (exceções tipadas entre módulos
precisariam de um assembly compartilhado; o prefixo é suficientemente único). Tratado como um
término NORMAL de ciclo, não um ERRO NÃO TRATADO:
  - Sem incremento de ConsecutiveCrashes -- isso não é uma falha abrupta de código.
  - Sem banner de origem de 60 linhas + pilha -- o sinalizador era visível ao
    operador que o definiu; não é necessária análise posterior.
  - O ciclo é finalizado como 'fail' para que status.json reflita o aborto
    em vez de uma aprovação inexistente; a desmontagem prossegue normalmente; a
    verificação de sinalizador já existente no laço de espera entre ciclos então consome
    control.cycle-restart em sua primeira execução e sai do interno; depois,
    o externo cria uma nova instância com estado limpo.

<a id="4213a0b3-00fe"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-RunnerInnerCycle

Espera progressiva de nova tentativa automática no estilo yuruna_retry: exponencial limitada com variação aleatória.
Aplicada além da espera existente entre ciclos para que uma falha transitória
(subiquity restore_apt_config com saída 100, github.com 5xx durante tofu init,
...) adie a nova tentativa tempo suficiente para passar a instabilidade a montante
sem saturar MaxConsecutiveCrashes. A mesma política de
automation/yuruna-retry.sh: a base dobra a cada falha abrupta consecutiva,
limitada por MaxDelaySeconds. Ignorada quando Get-YurunaRetryBackoff
não está disponível (caminho de inicialização inicial anterior à importação de Yuruna.Retry).

<a id="4213a0b3-00ff"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-RunnerInnerCycle

A espera entre ciclos FICA NO INTERNO (não no externo), para que o operador
veja a contagem regressiva no mesmo console que a saída do próprio ciclo.
O externo é intencionalmente simples: cria nossa instância, espera e então
cria outra imediatamente (sucesso) ou entra em sua pausa após falha (saída diferente
de zero). Colocar a espera aqui torna um período "Start-TestRunner is
idle for 30s between cycles" observável no hospedeiro do
executor -- com a espera no externo, principalmente os hospedeiros Windows ficam
sem saída entre ciclos, pois Write-Output do externo pode ser suprimido
pelo conhost enquanto o pwsh interno está ausente.

A contagem regressiva é dividida em esperas de 1 segundo para que Ctrl+C / desligamento /
sinalizador de pausa de ciclo possam interrompê-la sem aguardar um
Start-Sleep longo. Write-Progress mostra uma barra de porcentagem; Write-Output
registra somente o início e o fim da espera, portanto um coletor de log que não renderize
progresso não registra atualizações intermediárias.
$CycleDelaySeconds é definido dentro do bloco try do ciclo depois que a configuração é
mesclada; uma exceção anterior a esse ponto o deixaria nulo.
Recorra ao parâmetro do script para que a espera entre ciclos ainda seja
respeitada no raro caminho de falha abrupta anterior à configuração.

<a id="4213a0b3-0100"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-RunnerInnerCycle

Contraparte de pausa do ciclo da verificação "Cycle-pause back-channel" acima: uma
pausa ativada pela interface de status DURANTE a espera cycleDelaySeconds é respeitada
aqui -- depois que a espera termina, antes de sairmos do interno, para que o
externo crie o próximo ciclo somente após a retomada. É isso que faz o
botão "Pause after cycle" da interface ter efeito logo após a
espera entre ciclos. Condicionado a $effectiveDelay para ocorrer somente quando uma espera
realmente executou; sem espera entre ciclos, a verificação anterior à espera acima é a
única fronteira de ciclo. Reflete o laço de espera daquela verificação -- mantenha a atualização
do heartbeat / retomada / tratamento de desligamento sincronizados.

<a id="4213a0b3-0101"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-GuestProvisionIteration

Todo o ciclo de vida de um convidado: limpeza -> New-VM -> Start-VM -> Start-GuestOS ->
New-VM.Resource -> capturas de tela -> carga de trabalho -> parada. Extraído do foreach de convidados
do ciclo para permitir testes unitários. O foreach chamador despacha conforme
$IterState.Control: 'break' encerra a varredura de convidados, 'continue' passa ao próximo
convidado, 'proceed' prossegue. O estado mutável do ciclo retorna de duas maneiras -- os
quatro campos de falha por $IterState e a configuração recarregável pela
estrutura compartilhada $cfg (alterada no local pelo Sync por etapa; o chamador relê os
espelhos necessários de $cfg após a chamada). Este auxiliar relê somente as opções
sobre as quais age: $StopOnFailure (as proteções de parada) e o tempo limite de início da VM.
Write-Output de status segue para o fluxo do chamador exatamente como quando estava no próprio local (o
auxiliar é invocado como instrução, sem capturar o retorno).

<a id="4213a0b3-0102"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-GuestProvisionIteration

failure_screenshot_<VM>.png e failure_ocr_<VM>.txt ainda ficam
na raiz YURUNA_LOG_DIR (compartilhada entre ciclos, identificada apenas pelo
nome da VM), portanto, sem esta remoção, um ciclo posterior que falhe antes de
qualquer sequência executar (por exemplo, New-VM aborta por uma precondição do hospedeiro,
como openssl ausente) faria Copy-FailureArtifactsToStatusLog
copiar a captura de tela do ciclo anterior, enganando o
operador. Feito incondicionalmente no início de cada iteração de convidado
para que qualquer artefato que chegue à pasta por ciclo pertença a
este ciclo. O buffer circular screens_<VM>/ fica DENTRO da pasta
do ciclo (Get-CycleScreenDir), portanto não pode vazar para o próximo -- nenhuma limpeza
é necessária para ele aqui.

<a id="4213a0b3-0103"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-GuestProvisionIteration

Em hospedeiros com poucas threads de hardware, convidados ainda executando
sequências anteriores competem com a instalação do sistema operacional deste convidado: totais de vCPU
acima da contagem de threads do hospedeiro mais RAM de convidados acima da física
podem tirar as vCPUs de um instalador de execução por segundos de cada vez, portanto o
console de autoinstall parece congelado até que o tempo limite da etapa desista
dele. Primeiro pare os outros convidados de teste do ciclo -- a varredura de convidados
executa um ciclo de vida completo por vez, portanto os convidados anteriores a este
já terminaram suas sequências. Limitado a $VMNames (somente convidados deste
ciclo), para que VMs de infraestrutura -- por exemplo, o serviço de proxy de cache cuja acessibilidade
é verificada em toda etapa -- nunca sejam alteradas. Force, porque um
convidado em um instalador ignora o desligamento ACPI.
Sem continue/break neste laço: a invariante de fluxo de controle do auxiliar
envolvente (veja Test.RunnerInnerLoop.Tests.ps1) reserva saídas de laço
para sinalização por $IterState.Control, portanto a lógica de ignorar é aninhada.

<a id="4213a0b3-0104"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-GuestProvisionIteration

Encaminhe a URL do cache detectada na inicialização do executor para que todo convidado
use o mesmo endereço. Sem isso, New-VM.ps1 de cada convidado
sonda de maneira independente e disputa com listeners transitórios (concessões DHCP
desatualizadas, VMs irmãs removidas), incorporando um IP inativo à
imagem cidata -- observado no UTM, onde apt então falha com "No route
to host" durante a instalação. É a mesma URL sondada por Test-CachingProxyService.ps1;
as VMs de instalação a acessam diretamente: convidados Default-Switch
pelo NAT-to-LAN do Hyper-V, convidados UTM pelo encaminhador do gateway
vmnet-shared. Nenhum cache detectado -> passe "" para que os convidados ignorem
sua sondagem: um evento de detecção, um resultado.

<a id="4213a0b3-0105"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-GuestProvisionIteration

Nome de usuário em cascata pelo planejador: uma carga de trabalho que substitua
`variables.username` propaga esse valor de volta à sequência de
início (e, portanto, à conta cloud-init provisionada por esta invocação
de New-VM). effectiveUsername vazio recorre ao padrão de New-VM.ps1
por hospedeiro, preservando o comportamento atual quando nenhum plano
foi resolvido (caminho legado guestSequence).

variables.hostname é transmitido da mesma maneira e se torna local-hostname
do cloud-init do convidado, o nome sob o qual o convidado se registra no DHCP.
Vazio deixa o convidado com o nome da VM. Quando está definido, a
consulta dhcpd_leases do UTM deve usar o nome fixado como chave: os blocos sob o
nome da VM são então de predecessores e resolvem para endereços inativos. O driver
do hospedeiro lê o nome fixado de volta da ISO de inicialização do pacote, portanto ele
não precisa ser repassado daqui.

<a id="4213a0b3-0106"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-GuestProvisionIteration

Resolva o IP do convidado visto pelo hospedeiro para que o operador possa usar ssh /
vmconnect / VNC diretamente do log do ciclo. Consulta brevemente --
os serviços de integração KVP no Hyper-V e utmctl/dhcpd_leases no
UTM normalmente precisam de alguns segundos após o início para publicar um
endereço. "(pending)" significa ausência de resposta do hospedeiro dentro do
orçamento; o endereço real aparece na saída posterior do executor
(New-VM.Resource / scripts de extensão) quando o convidado estiver totalmente ativo.

Quando o hospedeiro não é o servidor DHCP da rede do convidado, a descoberta
de endereço não tem uma fonte no próprio canal para consultar e recorre à leitura de um
cache do hospedeiro que só contém o convidado enquanto ele estiver se comunicando
conosco. Preparar esse cache primeiro é o que faz a consulta abaixo
responder na primeira tentativa em vez da quinta.
(memória: feedback_hyperv_external_vswitch_arp_discovery.md)
Um verbo de contrato, portanto todo driver responde: cada um decide por si
se uma varredura é a ação correta e limita seu próprio custo.

<a id="4213a0b3-0107"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-GuestProvisionIteration

Proteção de serialização: os convidados executam um por vez, portanto confirme que esta VM
realmente desapareceu antes de iniciar a frio o próximo convidado -- caso contrário, uma desmontagem
que tenha travado silenciosamente (por exemplo, utmctl sem responder sob pressão de memória
do hospedeiro) a deixa executando, e o próximo convidado dobra a carga.
O próprio retorno de Remove-VM não responde a isso: suas linhas Write-Output de status
são incorporadas à conversão [bool], portanto sonde Get-VMState diretamente. Uma VM ainda
'running' após uma nova tentativa bloqueia o próximo convidado; qualquer outra situação (ausente /
parada / não é possível determinar) prossegue.

<a id="4213a0b3-0108"></a>

<a id="testmodulestestrunnerouterlooppsm1-forward-env-helper"></a>

## test/modules/Test.RunnerOuterLoop.psm1: Auxiliar de encaminhamento de ambiente

Todo retorno de Invoke-RunnerOuterCycle também atualiza o espaço reservado ao
último resultado no módulo, para que Invoke-TestCycleRunner.ps1 possa ler o
resultado tipado sem capturar o fluxo de sucesso. O interno é iniciado por
`Process.Start` com os fluxos herdados do console, e `WaitForExit` acompanha
seu encerramento independentemente de EOF em stdout.

A inicialização anterior pelo operador de chamada podia travar quando o chamador
capturava o fluxo de sucesso: o PowerShell fornecia um pipe anônimo para stdout,
e o status service do interno herdava a extremidade de gravação por meio de
`Start-Process -RedirectStandard*`. No Windows, o serviço podia manter esse pipe
aberto após o interno registrar "about to exit with code 0", impedindo a mensagem
"outer runner back in control" e o próximo ciclo. O desacoplamento POSIX
substituía esses descritores. A espera explícita atual pelo processo evita
essa dependência de EOF.

<a id="4213a0b3-0109"></a>

## test/modules/Test.RunnerOuterLoop.psm1: Invoke-RunnerOuterCycle

1b. Sincronização de intenção do grupo (faz o possível, NO MESMO PROCESSO, DESLIGADA POR PADRÃO). Obtenha a
    intenção do grupo pela LAN e reconcilie desiredState ANTES de criar
    o interno, para que um paused/drain obtido restrinja ESTE ciclo. Não faz nada (uma
    única chamada envolvida em try que retorna imediatamente) quando a sincronização do grupo não está configurada
    -- um hospedeiro fora de grupo não é afetado. A obtenção é limitada por prazo de relógio e
    protegida contra solicitações de credenciais em Sync-YurunaPoolIntent, portanto não pode
    travar o laço externo (pwsh simples INTERATIVO); qualquer erro não é fatal.
Substituição de config.testCycle por grupo (desligada por padrão, vazia para um hospedeiro fora de grupo),
capturada na fronteira do ciclo para que o watchdog (tempo limite de etapa) abaixo possa permitir
que um grupo reduza o tempo limite de etapa em toda a frota sem editar
test.config.yml de cada hospedeiro. Este valor é por PROCESSO: a pausa após falha fica em
Invoke-RunnerOuterLoop, no pai, e não pode lê-lo.

<a id="4213a0b3-010a"></a>

## test/modules/Test.RunnerOuterLoop.psm1: Invoke-RunnerOuterCycle

Nenhum reparo de relógio aqui. Os convidados obtêm seu relógio do RTC
virtual do hospedeiro ao ligar, portanto vale saber de um hospedeiro com desvio
-- mas a correção de toda plataforma é uma chamada privilegiada (Administrator
ou uma credencial sudo que ninguém está presente para digitar), e um laço sem intervenção
que pare para pedir entrada é um travamento. Assert-HostConditionSet dentro
do interno mede o desvio uma vez por ciclo e avisa; o reparo
é oferecido onde um console possa responder por ele (test/Test-Config.ps1,
host/*/Enable-TestAutomation.ps1).

<a id="4213a0b3-010b"></a>

## test/modules/Test.RunnerOuterLoop.psm1: Invoke-RunnerOuterCycle

2. Iniciar o executor interno. YURUNA_RUNNER_RELAUNCH=1 (definido imediatamente antes da
   inicialização e limpo no finally seguinte) informa ao executor interno
   que nós (o executor externo) controlamos o pidfile e o tratador de Ctrl+C; o interno
   ignora suas próprias cópias desses recursos. O escopo fica restrito à inicialização:
   se continuar definido em $env: após o retorno do interno, suprimirá a
   proteção de instância única do interno em qualquer invocação direta POSTERIOR na
   mesma sessão do shell, desativando silenciosamente a proteção contra concorrência.
   Sync-ForwardEnv reafirma o instantâneo, obtido na inicialização, das variáveis YURUNA_*
   (IP do cache, diretórios de runtime/log, nível de log, combinação de OCR), para que o
   interno as receba mesmo que algum módulo deste processo externo
   tenha sobrescrito $env: durante a execução.

<a id="4213a0b3-010c"></a>

## test/modules/Test.RunnerOuterLoop.psm1: Invoke-RunnerOuterCycle

Deliberadamente APÓS a limpeza de last_failure.json. A pausa por falha classifica
a partir desse arquivo; portanto, uma verificação anterior à limpeza deixaria o registro do
ciclo ANTERIOR no lugar. Se sua classe fosse transitória, um hospedeiro com
correção automática ativada encurtaria a pausa por armazenamento e voltaria ao mesmo
obstáculo a cada poucos minutos, em vez de aguardar a hora inteira.

Executar um ciclo completo apenas para descobrir no fim que seus resultados não podem ser
arquivados desperdiça o ciclo; esta verificação recusa a execução antes da inicialização, com uma projeção
baseada no custo real dos ciclos recentes.

<a id="4213a0b3-010d"></a>

## test/modules/Test.RunnerOuterLoop.psm1: Invoke-RunnerOuterCycle

break-active.json: escrito pela ação de sequência `break`
quando um ponto de interrupção cooperativo suspende o ciclo, e removido ao
retomar. Se o operador reiniciar apenas Start-TestRunner.ps1
enquanto uma interrupção estiver suspensa, o arquivo permanece e o Gate #1 da primeira etapa do
novo ciclo entende que uma interrupção ainda está ativa --
bloqueando o ciclo em um marcador inexistente. A inicialização do Status-server
também remove esse arquivo, mas o executor pode iniciar
sem o status service; a limpeza aqui mantém os dois caminhos de inicialização
coerentes. Isso não ocorre em um ciclo de verificação prévia: uma atualização arquiva por conta própria o
marcador de um executor interno recuperado e deixa intacto o de um interno sobrevivente.

<a id="4213a0b3-010e"></a>

## test/modules/Test.RunnerOuterLoop.psm1: Invoke-RunnerOuterCycle

Mesmo tempo de vida, contrato diferente: YURUNA_NONINTERACTIVE informa ao
filho que não há ninguém no console para responder a uma solicitação. A inicialização
usa `Process.Start` sem redirecionamento dos fluxos padrão; portanto, o interno
herda este terminal -- qualquer solicitação que ele apresente bloqueia todo o
hospedeiro até o watchdog encerrá-lo,
enquanto o painel continua verde. Os auxiliares de elevação (Initialize-Sudo-
Cache) leem esse valor e recusam solicitar entrada; o interno o estende ao git
e a Console.In em sua própria inicialização. A limpeza ocorre no finally pelo
mesmo motivo da sinalização de relançamento: um valor deixado em $env: faria uma
execução INTERATIVA posterior neste shell recusar silenciosamente solicitar entrada.

<a id="4213a0b3-010f"></a>

## test/modules/Test.RunnerOuterLoop.psm1: Invoke-RunnerOuterCycle

Iniciar o arquivador que esvazia a fila acumulada em seu PRÓPRIO processo independente, para que um
NAS lento ou ausente NUNCA atrase o próximo ciclo. O esvaziamento evita duplicação por conta própria
(arquivo de bloqueio de instância única), falha imediatamente se o compartilhamento estiver inacessível, copia
atomicamente todos os ciclos ainda não arquivados e não faz nada a menos que os três
caminhos do grupo estejam configurados. Uma falha de inicialização não é fatal. A forma de desvinculação reproduz
Start-StatusService.ps1 (entrada stdin vazia no Windows para que o filho não mantenha
conhost preso; nohup e grupo de processos próprio no macOS/Linux).

O modo MOVE é deliberadamente excluído aqui: ele exclui pastas locais, portanto precisa
executar de forma síncrona (abaixo), onde seu resultado ainda pode causar falha do ciclo; além disso,
uma cópia independente executada ao lado dele disputaria as mesmas pastas.

<a id="4213a0b3-0110"></a>

## test/modules/Test.RunnerOuterLoop.psm1: Invoke-RunnerOuterCycle

Aguardar o PROCESSO do encaminhador, não seu arquivo de bloqueio. O bloqueio é criado
bem depois do início da inicialização do próprio filho -- após importar módulos, obter o token do cofre,
ler o IP do proxy e percorrer as pastas de ciclos -- e três caminhos condicionais saem
sem adquiri-lo. Uma espera pela liberação observaria, portanto, "released"
imediatamente enquanto o filho ainda estivesse iniciando, e o movedor excluiria a
pasta do ciclo durante a leitura que essa espera deveria proteger. A saída do processo é
o único sinal que significa que todas as leituras terminaram.

Um tempo limite é tolerável, mas não silencioso: a pasta arquivada contém seu próprio
cycle.events.ndjson, portanto os eventos nunca são perdidos -- apenas sua chegada ao
Loki é adiada até que a coleta do agregador volte a alcançar o arquivo pelo
caminho alternativo de montagem do hospedeiro.

<a id="4213a0b3-0111"></a>

## test/modules/Test.RunnerOuterLoop.psm1: Invoke-RunnerOuterCycle

No ÚNICO hospedeiro em que o operador configurou o transporte pool.alert, entregar os
alertas CONSULTIVOS de degradação do grupo emitidos pelo agregador: ler o indicador yuruna_pool_alert_
active retido via HTTP, enfileirar transições de subida na fila do NAS poolStorage, entregar
pela extensão de notificação e mover para delivered/. A seleção é automática -- nenhuma ação
onde o transporte não está configurado. Tudo tem limites (HTTP -TimeoutSec tanto na
consulta do indicador QUANTO no POST do Resend, além de um limite de mensagens por ciclo) e nunca lança exceções,
portanto é seguro no laço externo INTERATIVO de pwsh puro (o contrato do gancho de fim de ciclo
que não bloqueia em solicitações e limita subprocessos). Executa NO PROCESSO para que o registro de entregas
do despachante (o canal de confirmação) seja legível; não é necessária uma inicialização independente.

<a id="4213a0b3-0112"></a>

## test/modules/Test.RunnerOuterLoop.psm1: Invoke-RunnerOuterCycle

Detecção de encerramento pelo watchdog: quando o interno sai com código diferente de zero E
o último sinal de atividade da etapa é mais antigo que o limite, a
causa quase certamente foi o watchdog (o código de saída é
o que Stop-Process -Force tiver produzido; o
caminho de falha da aplicação não pode executar após um SIGKILL/
TerminateProcess). Marcar a situação para que o operador não
perca tempo procurando uma falha da aplicação que nunca
aconteceu.

<a id="4213a0b3-0113"></a>

## test/modules/Test.RunnerOuterLoop.psm1: Invoke-RunnerOuterCycle

Um SIGKILL não deixa last_failure.json (o caminho de falha da
aplicação no interno não pode executar), portanto o mecanismo abaixo que encurta a pausa
por correção automática não tem o que classificar, e o ciclo passa diretamente
à pausa completa de espera por intervenção humana. Sintetizar um registro mínimo schema-v2
-- apenas quando o interno não tiver deixado nenhum -- com a classe 'wait_timeout'
já integrada, para que a nova tentativa automática limitada pelo registro
possa encerrar a pausa antes. A escrita é atômica para que um leitor nunca veja um
registro parcial; o orçamento persistente é identificado pela impressão digital da falha
e pela correção, portanto reiniciar o executor não zera a contagem de tentativas de
um travamento determinístico.

<a id="4213a0b3-0114"></a>

## test/modules/Test.RunnerOuterLoop.psm1: Invoke-OuterCycleDispatch

Colocar o caminho do script entre aspas duplas literais antes de ele chegar a
-ArgumentList. Start-Process junta os elementos da matriz com espaços SEM
adicionar aspas, portanto um caminho como "C:\Users\Yuruna Test\..." é dividido novamente por
CreateProcess, e o pwsh filho recebe -File C:\Users\Yuruna e sai com código 64
com: The argument 'C:\Users\Yuruna' is not recognized as the name of a
script file. O externo interpreta isso como um ciclo com falha, portanto um hospedeiro cujo caminho
contém um espaço nunca conclui um ciclo. É a mesma inclusão prévia de aspas das inicializações independentes
de esvaziamento/envio acima e de Start-StatusService.ps1.

<a id="4213a0b3-0115"></a>

## test/modules/Test.RunnerOuterLoop.psm1: Invoke-OuterCycleDispatch

-NonInteractive: este filho compartilha o terminal do operador (-NoNewWindow),
e um pwsh que perde ali seu contexto de script entra no laço de entrada do console,
cuja primeira ação é perguntar ao terminal a posição do cursor. Em um
terminal que outro processo também está lendo, essa consulta nunca recebe resposta,
e PowerShell responde a uma leitura de console com falha usando Environment.FailFast --
o processo morre imediatamente, no meio do ciclo. Um filho de ciclo não deve
solicitar entrada alguma; por isso, o laço de entrada é recusado em vez de tentar sobreviver a ele.
Todas as opções suportadas do operador são encaminhadas ao filho de cada ciclo, não
apenas -Cycle: uma opção omitida aqui -- um caminho de configuração personalizado,
-NoStatusService, -NoConfigGate, um intervalo entre ciclos ou nível de log diferente do padrão --
reverte silenciosamente ao padrão próprio de Invoke-TestCycleRunner.ps1 em cada
ciclo. ContainsKey protege cada uma para que um chamador (um teste unitário ou uma estrutura
State antiga) que omita uma chave mantenha o padrão do próprio script, em vez de
vincular explicitamente $null/0/vazio.

<a id="4213a0b3-0116"></a>

## test/modules/Test.RunnerOuterLoop.psm1: Invoke-OuterCycleDispatch

Um filho que morreu cedo, com código diferente de zero, sem sequer informar um resultado, não
executou um ciclo -- abortou durante a entrada. Contabilizar isso como FAIL do ciclo é uma
falsidade na direção mais custosa: aponta o operador aos testes
e ao painel por uma falha que precede ambos. O padrão observado é
um console que quebrou sob o processo (um segundo processo no mesmo terminal ou um
pty fechado), encerrando o filho em segundos e produzindo exatamente esta
assinatura: nenhum arquivo de resultado, saída diferente de zero e nenhum tempo para ter feito algo.

O critério é o limite, não apenas o código de saída: um ciclo que executou durante minutos e depois saiu
com código diferente de zero EXECUTOU, e sua falha é real e deve manter seu resultado. Apenas os
ciclos curtos a ponto de serem implausíveis são reclassificados, e são informados claramente como
uma situação própria, em vez de incluídos em qualquer um dos resultados.

<a id="4213a0b3-0117"></a>

## test/modules/Test.RunnerOuterLoop.psm1: Invoke-RunnerOuterLoop

Resultados transitórios, sem falha: aguardar e então entrar novamente. A espera é dividida para que
um Ctrl+C durante ela seja percebido em poucos segundos, em vez de apenas no fim.
'cycle-aborted' faz parte desses resultados: o ciclo nunca executou, portanto não há resultado
para imprimir nem algo em que o mecanismo de falha deva atuar. Aguardar e
entrar novamente é correto pelo mesmo motivo que em uma inicialização com falha --
a condição precede os testes e costuma ser momentânea.
'storage-full' deliberadamente NÃO faz parte dessa lista. Esses resultados usam uma
espera curta seguida de nova tentativa, apropriada para uma condição momentânea anterior aos
testes; um compartilhamento cheio não é momentâneo -- tentar de novo a cada 30 segundos gastaria
o dia redescobrindo que ninguém ainda excluiu nada. Ele segue
para o ramo de falha abaixo e usa a pausa completa, que termina antes apenas
com uma edição de configuração ou um novo commit: as duas coisas que plausivelmente podem alterá-lo.

<a id="4213a0b3-0118"></a>

## test/modules/Test.RunnerOuterLoop.psm1: Invoke-RunnerOuterLoop

3b. Falha -- pausar até que um novo commit de origem
    chegue ao repositório do framework OU um novo commit chegue a
    repositories.projectUrl OU o test.config.yml local
    seja editado OU a interface de status solicite uma reinicialização OU o
    limite seja atingido, consultando a cada FailureCommitPollSeconds.
    O laço de espera dorme em intervalos de 5 segundos para que Ctrl+C
    responda rapidamente (nosso tratador de eventos não consegue interromper
    Start-Sleep em esperas longas).

<a id="4213a0b3-0119"></a>

## test/modules/Test.RunnerOuterLoop.psm1: Invoke-RunnerOuterLoop

Gatilho 4: status-service /control/start-cycle a partir
da interface. O endpoint vê o runner.pid deste externo como
ativo e não inicia um substituto; sem esta
consulta, esse caminho deixaria o botão "Start cycle" da
interface sem resposta até o limite de recuo. Consumir a
sinalização aqui para que a próxima inicialização do interno não a acione novamente
(Debug-TestSequence e a limpeza de inicialização do interno também a consomem,
mas quanto mais perto o consumo estiver do despertar, menor será
a janela para uma reentrada por sinalização antiga).

<a id="4213a0b3-011a"></a>

## test/modules/Test.RunnerOuterLoop.psm1: Invoke-RunnerOuterLoop

Gatilho 5: correção automática condicionada (desativada por padrão). Para uma classe de falha que o
despachante de correção mapeia para uma nova tentativa claramente segura, não há motivo
para aguardar a pausa completa por commit humano; portanto, encerrá-la antes e deixar a próxima
inicialização tentar de novo. O orçamento de tentativas reside no registro de recuperação, identificado pela
impressão digital da falha, não neste processo: reiniciar o executor
não deve oferecer um novo conjunto de tentativas a uma falha transitória determinística, e um
ciclo aprovado é o que o zera. Tudo que o despachante não
classifica como claramente seguro mantém a pausa completa.
Apenas test.config.yml local. A substituição testCycle por grupo é
resolvida em Invoke-RunnerOuterCycle, que executa em um processo SEPARADO
no caminho distribuído; portanto, nenhuma de suas variáveis pode ser lida aqui -- nomear
uma vincula $null sobre o padrão do parâmetro, e a consulta interna
lança uma exceção a cada consulta periódica. Levar a substituição através dessa fronteira
exige o arquivo de resultado, não uma variável.

<a id="4213a0b3-011b"></a>

<a id="testmodulestestrunnerstatepsm1-adjacency-map-of-valid-transitions"></a>

## test/modules/Test.RunnerState.psm1: Mapa de adjacência das transições válidas

Mapa de adjacência das transições válidas. A última escrita na mesma
transição permanece; um caminho alternativo de falha a partir de qualquer estado vem das
transições sintéticas de recuperação na inicialização abaixo.

O laço saudável de espera do grupo entra em cada iteração em 'cycle-start'
(definido antes da coleta da intenção) e, ao obter desiredState=paused,
passa a 'paused', depois volta a 'cycle-start' na próxima consulta de 30s.
Ambas as arestas são legítimas e, por isso, constam do mapa -- caso contrário, cada
iteração de espera registrava dois avisos "not in the canonical adjacency map",
inundando o log externo durante toda a espera.

<a id="4213a0b3-011c"></a>

## test/modules/Test.RunnerWatchdog.psm1: Start-Watchdog

Aguardar o interno publicar inner.pid e o primeiro sinal de atividade.
Limite superior de 180 s: um hospedeiro sob carga pode levar bem mais de um minuto para
iniciar pwsh e importar os módulos do executor; desistir antes da hora
deixa todo o ciclo sem proteção, enquanto uma espera mais longa
não custa nada (o job apenas fica ocioso). Se o arquivo ainda
nunca aparecer, registrar e sair sem encerrar nada --
preferível a escolher um PID às cegas. O externo limpa ambos os arquivos
antes de iniciar o interno para que uma cópia antiga do ciclo
anterior não antecipe indevidamente o fim desta espera.

<a id="4213a0b3-011d"></a>

<a id="testmodulestestsequenceenginepsm1-invoke-sequences-body-and-wait-fortext--invoke-tapon-call"></a>

## test/modules/Test.SequenceEngine.psm1: Corpo de Invoke-Sequence e chamadas de Wait-ForText / Invoke-TapOn

O corpo de Invoke-Sequence e as chamadas de Wait-ForText / Invoke-TapOn
chamam funções de contrato (Get-VMScreenshot, Restart-VMConsole) que residem em
Yuruna.Host. Quando este módulo carrega em um processo sem outro caminho
para Yuruna.Host, chamar Initialize-YurunaHost aqui garante que o
contrato possa ser resolvido em todos os pontos de chamada do mecanismo de sequências.
O driver do hospedeiro é importado globalmente de forma forçada a cada chamada;
a verificação Get-Module omite apenas a importação do auxiliar compartilhado
Test.VMUtility quando esse módulo já está carregado.
<a id="4213a0b3-011e"></a>

<a id="testmodulestestsequenceenginepsm1-load-global-defaults-from-testconfigyml"></a>

## test/modules/Test.SequenceEngine.psm1: Carregar padrões globais de test.config.yml

Profundidade do buffer circular de capturas brutas de tela anteriores ao OCR, mantidas por VM (Wait-ForText).
Quando o convidado tem sucesso, o diretório do buffer é excluído; em caso de falha, toda a sequência é
preservada para que o link da captura de falha possa apontar aos momentos que antecederam o defeito.

A medida é em QUADROS, mas a escolha deve ser feita como uma duração: o leitor precisa
da janela entre as teclas que causaram uma falha e os quadros que
permanecem disponíveis para análise. Uma consulta faz uma captura de tela, uma passagem de OCR e uma
escrita de arquivo auxiliar além da espera pollSeconds -- cerca de 8 s de tempo real por
quadro na prática -- portanto, 20 quadros representam aproximadamente dois minutos e meio de histórico
do console, uma margem confortável sobre o tempo medido de uma troca de credenciais com várias solicitações e
o resultado que a segue, somados.
Poucos quadros cobrem bem menos de um minuto e removem as teclas que
explicam a falha antes mesmo de ela ser detectada.

O custo é de disco, nunca de memória: o buffer guarda CAMINHOS de arquivos, enquanto cada quadro em
disco é um PNG mais seu arquivo auxiliar de OCR (da ordem de 100 KB juntos). Um convidado
aprovado tem todo o diretório excluído; um convidado que FALHA mantém seus quadros
duas vezes -- aqui e na cópia feita junto ao log de falha -- e a rotação de logs de ciclos
move essas pastas para um conjunto histórico, em vez de excluí-las.
Assim, cada quadro extra é pago duas vezes, indefinidamente, e apenas pelos hospedeiros que
falham.

<a id="4213a0b3-011f"></a>

<a id="testmodulestestsequenceenginepsm1-progress-wrapper"></a>

## test/modules/Test.SequenceEngine.psm1: Invólucro de progresso

Sob `vmCommunication`, junto aos campos relacionados, não na raiz do arquivo: o
overlay do modelo é o esquema e DESCARTA toda chave que o modelo
não define; portanto, uma chave na raiz seria excluída do arquivo do operador
na próxima reconciliação, e a configuração reverteria silenciosamente ao
padrão incorporado no ciclo seguinte.
A verificação usa `$null -ne`, não a avaliação como verdadeiro/falso, porque 0 é um valor que o
operador pode querer; o consumidor o limita ao intervalo, em vez de lê-lo
como "não definido".

<a id="4213a0b3-0120"></a>

<a id="testmodulestestsequenceenginepsm1-action-type--typeandenter"></a>

## test/modules/Test.SequenceEngine.psm1: Ação: type / typeAndEnter

A navegação do foco de botões por teclas Tab é frágil: o foco inicial depende
do estado da animação de abertura, de elementos carregados de forma assíncrona e de mudanças no instalador,
portanto a quantidade "correta" de Tab varia. tapOn evita completamente o foco
-- aplica OCR à tela da VM, localiza a caixa delimitadora do botão e
sintetiza um clique do mouse no centro dessa caixa.

Contrato de coordenadas: a imagem capturada e o alvo do clique compartilham o
mesmo espaço de pixels. No Hyper-V, usamos PrintWindow na área cliente do vmconnect,
portanto imagem (x,y) == cliente vmconnect (x,y), e ClientToScreen converte
isso em uma sequência SetCursorPos + mouse_event.

<a id="4213a0b3-0121"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-TapOn

-Global: um -Force aninhado sem -Global remove Test.YurunaDir do
estado de sessão do script pai, quebrando chamadas posteriores de nível superior.
Apenas recuperação de remoção: Test.YurunaDir não mantém estado (Initialize-YurunaLogDir usa
o ambiente; $env:YURUNA_LOG_DIR sobrevive às reimportações), portanto analisar novamente o psm1 apenas
quando seu comando realmente não puder ser resolvido -- isto é, quando um -Force aninhado o removeu
-- não em todas as passagens do caminho frequente. Condicionar a Get-Command, NÃO a Get-Module: Get-Module
continua verdadeiro após uma remoção mover o módulo para outro escopo; portanto,
ignoraria justamente a reafirmação que este trecho deve fazer. (Os módulos com estado reimportados
nas proximidades -- OcrEngine/Log/Ssh -- são deliberadamente incondicionais: sua recarga com -Force
também zera registros/caches $script:, um efeito colateral que seria perdido com a condição.)

<a id="4213a0b3-0122"></a>

<a id="testmodulestestsequenceenginepsm1-action-tapon----ocr-located-mouse-click"></a>

## test/modules/Test.SequenceEngine.psm1: Ação: tapOn -- clique do mouse localizado por OCR

Persistir a saída de OCR deste quadro como raw_${stamp}.txt ao lado do
raw_${stamp}.png de que foi extraída. O arquivo de texto é o que o
comparador realmente viu -- essencial para diagnosticar regressões do tipo "deveria ter correspondido",
pois o .png do buffer circular, sozinho, obriga o leitor a
aplicar OCR novamente à imagem para descobrir por que o padrão não foi acionado.

AllowEmptyCollection: um parâmetro de coleção tipada [Parameter(Mandatory)]
rejeita entrada vazia com o erro enganoso "Cannot bind argument ...
because it is an empty string". O caso vazio ocorre quando
Test-CombinedOcrMatch não retorna EngineResults (nenhum provedor executou neste
quadro); não escrever é correto -- um arquivo auxiliar vazio apresentaria incorretamente
"nenhum mecanismo executou" como "os mecanismos executaram e não viram nada".

AllowEmptyString: o vinculador Mandatory do PowerShell enumera uma
List[string] tipada e valida cada elemento contra a verificação implícita de
string não vazia; portanto, uma lista que contém os separadores '' finais
que os chamadores acrescentam entre seções dos mecanismos falha com a mesma
mensagem "empty string". AllowEmptyString remove essa verificação por elemento;
AllowEmptyCollection remove a verificação da lista inteira.

<a id="4213a0b3-0123"></a>

## test/modules/Test.SequenceEngine.psm1: Wait-ForText

Comparar o padrão positivo apenas com as linhas do console que o convidado
imprimiu após o início desta etapa, ignorando tudo que a etapa anterior
deixou na tela. Usar em uma etapa cujo padrão é curto o suficiente
para ser satisfeito por texto sem relação já na tela -- uma classe que o
comparador tolerante não pode evitar, porque a mesma tolerância que permite a uma
solicitação sobreviver a caracteres perdidos e confundidos também permite que suas letras
sejam encontradas na ordem dentro de uma frase sobre outra coisa.

Quando a espera anterior repassou uma referência, a base é o quadro que ESSA
espera encontrou; assim, uma solicitação impressa em resposta ao que a etapa anterior
digitou é nova e pode corresponder, independentemente do intervalo entre consultas. Sem essa referência
-- a primeira etapa condicionada de uma sequência, ou uma cujo antecessor falhou --
a base passa a ser o primeiro quadro desta própria espera, ao custo de uma consulta: esse
quadro registra o que já estava presente, e apenas quadros posteriores podem corresponder.

Os padrões de falha deliberadamente NÃO são condicionados por isso. Seu papel é
perceber que a tela está em um estado a partir do qual o texto procurado nunca pode aparecer,
e esse estado costuma já estar na tela quando a etapa
começa -- por isso, continuam lendo o quadro inteiro.

<a id="4213a0b3-0124"></a>

## test/modules/Test.SequenceEngine.psm1: Wait-ForText

Padrões de falha: se QUALQUER um deles corresponder de forma aproximada ao OCR da tela,
abortar imediatamente a espera e retornar $false. O caso de uso canônico
é a saída "install_fail.crash" / "An error occurred.
Press enter to start a shell" do subiquity -- nesse ponto, o
padrão positivo (por exemplo, "Not listed?" da tela de login do GDM)
nunca aparecerá; portanto, consultar até $TimeoutSeconds
desperdiça até uma hora antes de o executor receber uma falha enganosa
"pattern not found". Ao encontrar uma correspondência, esta função também define
o sinal compartilhado entre módulos WaitForTextMatchedFailurePattern para que
o construtor do rótulo de falha do chamador possa mostrar *qual* padrão de falha
foi acionado, produzindo um aviso como
  waitForAndEnter: "Not listed?" -- matched failurePattern "install_fail.crash"
em vez da mensagem opaca de tempo limite.

<a id="4213a0b3-0125"></a>

## test/modules/Test.SequenceEngine.psm1: Wait-ForText

Padrões de falha que só têm significado durante os primeiros
$EarlyFailureSeconds da espera e depois deixam de ser avaliados.

O uso canônico é um shell REJEITANDO a linha de comando que acabou
de receber ("command not found", "No such file or directory"). Esse
resultado é emitido até um segundo após Enter e significa que nada chegou a
iniciar; portanto, o padrão positivo nunca pode aparecer, e todo o
tempo limite seria gasto comprovando isso. As mesmas strings também são saída
normal de um script que ESTÁ executando de forma saudável -- uma ferramenta de pacotes
que procura um binário opcional as imprime constantemente -- portanto, como
padrões de falha permanentes, abortariam boas execuções. A janela é
o que separa as duas interpretações: dentro dela, a única coisa que teve
tempo de responder foi o shell; fora dela, a resposta é o que a
carga executada estiver imprimindo. É por isso que isso não pode simplesmente ser incorporado a
$FailurePattern, cujas entradas são (corretamente) avaliadas durante
toda a espera.

<a id="4213a0b3-0126"></a>

## test/modules/Test.SequenceEngine.psm1: Wait-ForText

Qual dos dois caminhos de correspondência abaixo esta espera usará, pois apenas um
deles mede o comportamento do console. Uma espera restrita ao final (freshMatch) lê
os mesmos quadros, mas não executa a verificação de inundação nem o rastreador de conteúdo
estático; assim, os dois campos acima mantêm os valores definidos aqui durante toda a espera
-- e 0 / vazio são os MESMOS valores deixados por uma espera que mediu um console em movimento,
sem repetição. Publicar o par sem esta sinalização
convida justamente a interpretação que ele não pode sustentar: que algo examinou a
tela e a considerou saudável. O registro ocorre aqui, não nos retornos de falha,
para que seu escopo seja esta espera, exatamente como o dos campos que ele qualifica.

<a id="4213a0b3-0127"></a>

## test/modules/Test.SequenceEngine.psm1: Wait-ForText

Prazo de tempo real -- NÃO contador de iterações. Somar $PollSeconds a cada
passagem do laço pressuporia que toda iteração termina em $PollSeconds de
tempo real. Na prática, cada iteração faz uma captura de tela, OCR com tesseract
e escrita de arquivo auxiliar antes de Start-Sleep -Seconds $PollSeconds no
fim -- em um hospedeiro Hyper-V ocupado, isso acrescenta 5-25 s à espera; portanto,
um timeoutSeconds: 1800 configurado levaria 1-3 horas de tempo real para
expirar (e, multiplicado por retry maxAttempts, poderia exceder meio dia
antes de desistir). timeoutSeconds define o orçamento base de tempo real;
a autorrecuperação do OCR pode estender seu prazo em, no máximo,
min(timeoutSeconds, 120) segundos no total, para que um fluxo em recuperação
tenha tempo de fornecer um quadro novo.

<a id="4213a0b3-0128"></a>

## test/modules/Test.SequenceEngine.psm1: Wait-ForText

Importar os módulos necessários. A captura de tela usa o contrato Yuruna.Host
(Get-VMScreenshot) -- que se presume já carregado por
Initialize-YurunaHost do chamador. OcrEngine permanece em test/modules/ como
auxiliar entre hospedeiros. -Global é essencial: o laço de consulta abaixo chama
Test-CombinedOcrMatch (módulo Test.OcrMatch), que resolve
Get-EnabledOcrProvider / Invoke-OcrProvider pelo estado de sessão
global. Um -Force aninhado SEM -Global remove Test.OcrEngine do
escopo global (a classe de regressão por remoção de módulo,
feedback_module_force_import_evicts_global.md), portanto a próxima
chamada de Test-CombinedOcrMatch falha com "Get-EnabledOcrProvider is not
recognized".

<a id="4213a0b3-0129"></a>

## test/modules/Test.SequenceEngine.psm1: Wait-ForText

Buffer circular por VM de capturas brutas anteriores ao OCR. Persiste entre várias
chamadas de Wait-ForText durante uma execução do convidado, para que o caminho de falha possa mostrar
os momentos que antecederam o defeito. É limpo pelo executor ao fim do convidado em caso de sucesso;
em caso de falha, é preservado e copiado junto ao log de falha.
-Global nas reimportações com -Force: um -Force aninhado sem -Global
remove os módulos do estado de sessão do script pai; portanto, uma
chamada posterior de nível superior a Get-CycleScreenDir (ramo de sucesso de Invoke-GuestProvisionIteration,
observado em executores no mesmo processo no macOS) falha com
"term not recognized".
Apenas recuperação de remoção: Test.YurunaDir não mantém estado (Initialize-YurunaLogDir usa
o ambiente; $env:YURUNA_LOG_DIR sobrevive às reimportações), portanto analisar novamente o psm1 apenas
quando seu comando realmente não puder ser resolvido -- isto é, quando um -Force aninhado o removeu
-- não em todas as passagens do caminho frequente. Condicionar a Get-Command, NÃO a Get-Module: Get-Module
continua verdadeiro após uma remoção mover o módulo para outro escopo; portanto,
ignoraria justamente a reafirmação que este trecho deve fazer. (Os módulos com estado reimportados
nas proximidades -- OcrEngine/Log/Ssh -- são deliberadamente incondicionais: sua recarga com -Force
também zera registros/caches $script:, um efeito colateral que seria perdido com a condição.)

<a id="4213a0b3-012a"></a>

## test/modules/Test.SequenceEngine.psm1: Wait-ForText

Assinaturas por linha do console tal como estava no primeiro quadro
legível desta espera, mais a janela aplicada sobre elas. $FreshMatch
restringe as linhas contra as quais se compara um padrão pela POSIÇÃO na tela;
$SinceStepStart as restringe conforme tenham sido impressas pelo convidado durante esta
etapa. Quando solicitados juntos, os dois se compõem -- a janela aplica-se ao que
sobrevive à base -- portanto cada um apenas remove linhas do conjunto de
comparação, nunca acrescenta nenhuma. $null (não uma matriz vazia) significa "ainda não
registrado": uma tela lida como vazia é uma base legítima e não deve ser
capturada novamente na próxima consulta.

<a id="4213a0b3-012b"></a>

## test/modules/Test.SequenceEngine.psm1: Wait-ForText

Ação antecipada por tendência de degradação: as duas recuperações automáticas acima reagem a um
limite fixo. Quando a fonte já demonstrou instabilidade (houve uma reinicialização do console), reduzir
o limite de congelamento para detectar antes a próxima interrupção -- atuando sobre a
tendência, em vez de aguardar novamente a janela completa. E conceder ao prazo uma
prorrogação limitada por recuperação automática, para que uma fonte que ESTÁ se recuperando não seja encerrada
no meio da recuperação pelo prazo original (o falso ocr_timeout); o limite
mantém uma fonte inativa sob controle. Cada ação proativa emite um evento `degradation`
para que uma espera degradada, mas aprovada, possa ser consultada, em vez de ficar silenciosa.

<a id="4213a0b3-012c"></a>

## test/modules/Test.SequenceEngine.psm1: Wait-ForText

O OCR recebe a captura bruta como está -- sem pré-processamento. Não
reintroduzir um fluxo de linha vertical / escala de cinza / inversão / expansão de
contraste / escala 2x, nem uma etapa de comparação com o quadro anterior
que suprima pixels inalterados: ambos corrompem casos extremos
(serifas com suavização que se confundem, texto novo suprimido
quando os pixels ao redor também mudaram). Tesseract / WinRT OCR
/ macOS Vision lidam bem com capturas coloridas
na resolução nativa.
<a id="4213a0b3-012d"></a>

## test/modules/Test.SequenceEngine.psm1: Wait-ForText

Detecção de console inundado, e um TERCEIRO caso diferente
dos dois ramos ao redor. O ramo sem texto abaixo vê uma
fonte sem conteúdo; o detector de congelamento por hash de bytes,
mais abaixo, vê uma fonte que parou de mudar. Um console
que rola repetidamente a mesma linha de log não é nenhum dos dois: todos os quadros
diferem, portanto a fonte parece perfeitamente saudável, e todos os
quadros estão cheios de texto, portanto AnyText é verdadeiro -- enquanto o
padrão procurado já saiu da área
visível pela rolagem e nunca voltará a ela. Sem um nome
para essa situação, ela consome todo o tempo limite e é registrada como
um caso normal em que o padrão nunca foi impresso, direcionando o leitor
ao script do convidado que, na verdade, nunca foi alcançado.

Registrado, SEM ação: a espera ainda usa todo o seu
orçamento. Uma inundação pode parar, e abortar antes por uma
heurística trocaria uma resposta correta lenta por uma
incorreta rápida. A mudança é que a falha passa a identificar sua natureza.

<a id="4213a0b3-012e"></a>

## test/modules/Test.SequenceEngine.psm1: Wait-ForText

Verificação de padrão de falha (falha antecipada). Executa APÓS a verificação
de correspondência positiva, para que uma correspondência positiva vença o empate quando ambas aparecem em um
quadro. Usa $lastOcrText (a saída de OCR mais recente), para que a
assinatura não seja ocultada por uma falha de OCR na consulta atual.
O conjunto antecipado junta-se ao permanente apenas enquanto a janela está
aberta; assim, uma correspondência dentro dela é informada pelo mesmo sinal,
pela mesma captura de tela e pelo mesmo rótulo de falha de qualquer outro
padrão de falha -- a janela determina QUANDO um padrão é consultado,
nunca o que acontece após seu acionamento.

<a id="4213a0b3-012f"></a>

## test/modules/Test.SequenceEngine.psm1: Wait-ForText

O conjunto antecipado é comparado sem a estratégia de segmentos de Test-OCRMatch.
Seus elementos são frases curtas e comuns, e essa estratégia pergunta
apenas se cada palavra aparece em algum lugar da tela
-- algo que a própria saída de uma etapa saudável fornece por acaso assim
que imprime alguns KB de URLs ou caminhos. Um padrão de falha permanente
é escolhido pelo autor da etapa considerando o único script que ela executa
e mantém o comparador completo; estes são comparados com todos os convidados
do conjunto, portanto exigem evidência presente em uma única linha.

<a id="4213a0b3-0130"></a>

## test/modules/Test.SequenceEngine.psm1: Wait-ForText

Por quanto tempo o conteúdo do console permaneceu inalterado, no maior intervalo. Separa um
convidado que trabalhou o tempo inteiro de um parado em uma tela
ilegível, algo que o detalhe da inundação sozinho não consegue fazer: Get-ConsoleFloodVerdict
conta repetições DENTRO de um quadro, portanto uma parede congelada de texto que já passou
pela rolagem é lida como inundação, embora nada esteja se movendo.

Apenas o caminho de correspondência acumulada alimenta esse valor. Em uma correspondência restrita
ao final, $maxConsoleStaticSecs ainda contém seu valor inicial; é isso que a
sinalização de medição definida na entrada existe para declarar -- o valor escrito aqui
é uma observação apenas quando essa sinalização é verdadeira.

<a id="4213a0b3-0131"></a>

## test/modules/Test.SequenceEngine.psm1: Wait-ForText

Uma lista vazia de correspondências próximas abrange três telas sem relação: nenhuma janela estava
em vigor, a janela cobria o quadro inteiro ou o texto não estava em lugar
algum dele. Lida sozinha, é interpretada como a terceira situação. Registrar o conteúdo que a tela
DE FATO tinha e que mais se aproximava do padrão separa as situações; em um quadro curto demais
para uma janela ocultar algo -- um console parado em uma solicitação de login --
essa é a única evidência disponível. Deliberadamente não condicionado a
$FreshMatch: uma espera sem janela que atingiu o tempo limite quer a mesma
resposta e paga por ela uma vez, aqui, não no laço de consulta.

<a id="4213a0b3-0132"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-SequenceByName

Substituições de variáveis em cascata pelo planejador. Quando presentes, cada chave
deste mapa SUBSTITUI a entrada de mesmo nome no bloco
`variables:` do arquivo da sequência antes da expansão da etapa (o topo da cadeia
vence para toda a cadeia -- ver Test.SequencePlanner). Um mapa
vazio = invocação direta sem substituições do planejador, mantendo as variáveis
locais da sequência. Debug-TestSequence encaminha effectiveVariables de seu
planejador por meio de Invoke-TestSequenceChain.
Usar IDictionary (não [hashtable]) para que um [ordered]@{} do
planejador mantenha sua ordem de inserção durante a vinculação de parâmetros.
Uma conversão [hashtable] transformaria OrderedDictionary -> Hashtable
e perderia a ordem, fazendo o laço de substituição abaixo
processar, por exemplo, `currentPassword: ${ext:...(${username})}` ANTES de
`username: yauser1`. O marcador `${username}` não consegue
ser resolvido, e a string literal acaba sendo usada como chave do cofre.

<a id="4213a0b3-0133"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-SequenceByName

Linhas informativas passam por Write-Information, NÃO por Write-Output.
Write-Output emite no pipeline e, junto com `return (...)`
abaixo, incluiria essas strings na variável `$ok` do chamador --
transformando o booleano em @("Running...", "Sequence file...", $true/$false).
O `$ok -eq $false` do chamador ainda detecta um $false verdadeiro dentro
dessa matriz, mas um $null retornado (por exemplo, de um caminho de erro não tratado)
pareceria idêntico ao sucesso. Manter o pipeline limpo para que o
retorno seja estritamente [bool].

<a id="4213a0b3-0134"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence

Substituições de variáveis em cascata pelo planejador; ver Invoke-SequenceByName.
Nulo/vazio = usar literalmente o bloco `variables:` do próprio arquivo
da sequência. O executor de cadeias de Debug-TestSequence encaminha as
substituições do planejador.
Usar IDictionary (não [hashtable]) para que um [ordered]@{} do
planejador mantenha sua ordem de inserção durante a vinculação de parâmetros.
Uma conversão [hashtable] transformaria OrderedDictionary -> Hashtable
e perderia a ordem, fazendo o laço de substituição abaixo
processar, por exemplo, `currentPassword: ${ext:...(${username})}` ANTES de
`username: yauser1`. O marcador `${username}` não consegue
ser resolvido, e a string literal acaba sendo usada como chave do cofre.

<a id="4213a0b3-0135"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence

Inicializar logDir cedo para que o bloco catch possa escrever
diagnósticos; o diretório de runtime usado pelos caminhos de sinalização de pausa é resolvido abaixo. Invoke-Sequence
executa em um escopo de módulo filho quando um script de extensão de início de teste
o importa; portanto, o Import-Module global do executor pai não
se propaga até aqui -- cada auxiliar precisa ser reimportado neste caminho.
-Global nas reimportações com -Force: sem ele, a recarga aninhada
remove esses módulos do estado de sessão do script pai e
quebra chamadas posteriores de nível superior (ver falha de Get-CycleScreenDir).

<a id="4213a0b3-0136"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence

Apenas recuperação de remoção: Test.YurunaDir não mantém estado (Initialize-YurunaLogDir usa
o ambiente; $env:YURUNA_LOG_DIR sobrevive às reimportações), portanto analisar novamente o psm1 apenas
quando seu comando realmente não puder ser resolvido -- isto é, quando um -Force aninhado o removeu
-- não em todas as passagens do caminho frequente. Condicionar a Get-Command, NÃO a Get-Module: Get-Module
continua verdadeiro após uma remoção mover o módulo para outro escopo; portanto,
ignoraria justamente a reafirmação que este trecho deve fazer. (Os módulos com estado reimportados
nas proximidades -- OcrEngine/Log/Ssh -- são deliberadamente incondicionais: sua recarga com -Force
também zera registros/caches $script:, um efeito colateral que seria perdido com a condição.)

<a id="4213a0b3-0137"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence

Construir a tabela de variáveis: primeiro as incorporadas, depois as entradas definidas em YAML,
avaliadas IMEDIATAMENTE na ordem do arquivo (contrato completo:
docs/test-sequences.md#variable-substitution-rules -- o Markdown
é o contrato). ${ext:...} em um valor executa uma vez na definição;
portanto, fixar um valor gerado entre etapas é uma operação explícita,
visível no arquivo. As substituições do planejador (-EffectiveVariables)
SUBSTITUEM entradas YAML de mesmo nome; ${hostname} é inicializado a partir de
-VMName e sobrescrito pelo bloco variables: da sequência ou pela
cascata, quando declarado.

<a id="4213a0b3-0138"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence

Derivar automaticamente ${hostLabel}: o nome de máquina do convidado que o próprio console do convidado imprime,
que não é ${hostname}. ${hostname} usa o nome da VM por padrão, e um nome de VM
contém pontos -- test-guest.ubuntu.server.26-01 -- enquanto tanto agetty quanto uma
solicitação do shell imprimem apenas o primeiro rótulo, "test-guest". O nome completo
aparece no console em exatamente um lugar, o aviso /etc/issue; portanto, um
padrão construído a partir de ${hostname} corresponde apenas enquanto esse aviso está na
tela e deixa de corresponder assim que ele sai pela rolagem, embora a solicitação
que aguarda ainda esteja presente. Uma espera assim não consegue falhar
rapidamente: consome todo o seu orçamento e só é recuperada por uma nova tentativa que
redesenha o aviso.

A derivação ocorre após a mesclagem das substituições para acompanhar qualquer hostname
realmente em vigor, e apenas quando não definido, para que uma sequência ou cascata ainda
possa defini-lo diretamente.

<a id="4213a0b3-0139"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence

Canal de retorno para reiniciar o ciclo: o endpoint /control/start-cycle do status service
define esta sinalização enquanto encerra as VMs em andamento. O laço de intervalo
entre ciclos em Invoke-TestRunnerInnerLoop já interrompe ao vê-la, mas,
se a solicitação chegar enquanto um ciclo estiver executando etapas, o
laço de intervalo nunca a verá -- o ciclo segue precariamente por falhas de captura de tela
de VMs excluídas, e o pedido do operador para "reiniciar agora" nunca
se concretiza. Verificar aqui também faz o aborto acontecer de dentro de um
ciclo ativo: a exceção propaga-se por nova tentativa / sequência / executor e é
reconhecida pelo catch de ciclo do interno pelo prefixo da mensagem.

<a id="4213a0b3-013a"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence

Bloco compartilhado de espera por pausa. Usado tanto no início da sequência (Label='[sequence
start]') quanto no início de cada etapa (Label='[stepNum/Count]').
O escopo dinâmico resolve $stepPauseFlagFile e $writeCurrentAction
no escopo do chamador durante a invocação; portanto, o bloco de script não
precisa de parâmetros próprios para eles.

Esta barreira suspende o EXECUTOR, não o convidado: a VM é criada e iniciada
antes da sequência começar, portanto continua executando -- e imprimindo -- por
toda a duração da espera. Qualquer conteúdo que o convidado imprime uma vez e não repete
(uma confirmação durante a inicialização) pode, portanto, desaparecer enquanto o executor está parado aqui,
e a etapa que iria lê-lo retoma diante de uma tela que já
não o contém. As duas extremidades da espera são publicadas no fluxo de eventos
para que uma falha posterior possa ser interpretada como consequência dessa espera, em vez de como um convidado
que nunca imprimiu; ver docs/control-routes.md, "Pause and resume".

<a id="4213a0b3-013b"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence

Barreira de reinicialização do ciclo. Lança um marcador de fluxo de controle para que o
catch de ciclo do executor interno (ver Invoke-RunnerInnerCycle) possa evitar
mensagens de limpeza emergencial e pular o incremento de ConsecutiveCrashes
para este aborto esperado. A sinalização deliberadamente NÃO é
limpa aqui: o laço de intervalo entre ciclos após o ciclo a consumirá
na próxima consulta, mantendo intacto o caminho existente que "acorda antes do fim do intervalo".
Se o interno já passou pelo intervalo (isto é,
está executando ativamente esta sequência), a exceção propaga-se diretamente por
todos os quadros envolventes de nova tentativa / etapa / sequência até o
try/catch do ciclo.

O marcador é transportado TANTO como etiqueta Exception.Data quanto como
prefixo de mensagem 'YurunaCycleRestart:'. Os consumidores preferem a etiqueta
estruturada, que sobrevive a um reencapsulamento em que um `throw "wrapped: $_"` posterior
a removeria da mensagem; o prefixo permanece como alternativa para que qualquer
leitor que ainda compare pela mensagem encaminhe corretamente esse aborto.

<a id="4213a0b3-013c"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence

Barreira de saúde do laboratório: aguardar aqui enquanto um serviço do laboratório que este hospedeiro VINHA
alcançando deixa de responder, e retomar quando ele voltar. Um serviço
que nunca esteve acessível deliberadamente não causa espera -- ver
Test.LabHealth -- portanto um hospedeiro sem stash ainda falha rapidamente na
própria verificação prévia do chamador, em vez de parar no primeiro ciclo.

Protegida por Get-Command: um ponto de entrada cujo conjunto de módulos omite Test.LabHealth
executa sem essa barreira, que é o comportamento de todos os chamadores antes dela e
um modo de falha melhor que uma etapa incapaz de iniciar.

<a id="4213a0b3-013d"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence

Gate #1: pausa no nível da sequência e verificação de reinicialização do ciclo, antes de qualquer
trabalho por sequência. A pausa é verificada primeiro para que uma pausa iniciada pelo operador
que coincida com um clique de reinicialização ainda seja resolvida de forma previsível (a pausa
vence até ser liberada, então a sinalização de reinicialização é observada). A espera por saúde do laboratório
fica entre as duas: um operador que suspendeu o ciclo está presente
e tem prioridade sobre uma espera iniciada pela máquina; sondar novamente um laboratório que ninguém
está observando não produz nada.
A limpeza ocorre aqui, não junto aos outros campos de causa por sequência mais
abaixo: eles executam APÓS esta barreira, e a espera que esta barreira está prestes a registrar
é a mais relevante de informar -- termina com o convidado já inicializado e
uma etapa prestes a ler uma tela que avançou sem o executor.

<a id="4213a0b3-013e"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence

Os PNGs de depuração de takeScreenshot ficam sob test/status/captures/sequences/
(dados de execução ignorados pelo git, junto ao restante do estado do ambiente de testes,
de modo que limpar um hospedeiro exige apenas rm -rf status/*). O nome da sequência é
acrescentado como prefixo de cada arquivo em Save-DebugScreenshot; portanto, uma única
pasta plana mantém as capturas organizadas sem subdiretório por sequência.
Usar $PSScriptRoot como referência (este módulo fica em <TestRoot>/modules/);
$SequencePath não é confiável como referência do estado do ambiente de testes porque as sequências da árvore do projeto
ficam em <RepoRoot>/project/.../test/. O executor da cadeia usa
o caminho real de cada entrada com uma janela local StartStep/StopStep.

<a id="4213a0b3-013f"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence

Encapsulado como bloco de script para que o caso de ação `retry` (abaixo) possa chamá-lo
em sua matriz interna `steps:`, reutilizando toda a infraestrutura
por etapa: verificações de pausa, arquivo auxiliar currentAction, sinais de progresso,
expansão de variáveis, seleção de ação e registro PASS/FAIL. O bloco
resolve $vars, $writeCurrentAction, $waitWhilePaused,
$waitWhileLabHealthy, $HostType,
$VMName, $GuestKey, $logDir, $screenshotDir, $ShowSensitive e os
padrões $script:Default* no escopo da função envolvente pelas
semânticas de leitura de escopo dinâmico do PowerShell; o parâmetro $Steps oculta
o $steps externo dentro do bloco. Em uma falha de etapa, o bloco captura
o contexto no armazenamento compartilhado de falhas ($script:Fail) e retorna $false. O ponto de chamada EXTERNO
abaixo é que escreve last_failure.json, a captura de falha e
a pausa após a falha; portanto, uma falha transitória dentro de uma tentativa de repetição
nunca polui last_failure.json -- apenas uma falha com tentativas esgotadas
(ou uma falha sem repetição) o faz, após a chamada externa finalmente retornar.

<a id="4213a0b3-0140"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence

Atualizar runner.stepHeartbeat a partir do runspace para que o watchdog
externo possa detectar uma etapa que exceda testCycle.stepTimeoutSeconds.
NÃO fazemos essa atualização dentro do laço de consulta da própria
ação -- runner.heartbeat, acionado pelo conjunto de threads, já
comprova que o processo está ativo. Atualizar apenas nas
fronteiras entre etapas significa que o watchdog intervém se qualquer
etapa (waitForText com seu próprio prazo, execução ssh, bloco
retry) travar por mais tempo que o orçamento configurado.

<a id="4213a0b3-0141"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence

A visibilidade da etapa atual é deliberadamente controlada por Write-Progress
(via Write-ProgressTick abaixo), NÃO por um Write-Information aqui.
Um Write-Information no início da etapa passaria pelo proxy Yuruna.Log
e deixaria uma linha permanente tanto no terminal quanto na transcrição
do log -- então a linha de conclusão da etapa (com o tempo
decorrido) apareceria abaixo, em vez de substituí-la. Write-Progress
renderiza separadamente (barra flutuante) e desaparece automaticamente com
-Completed; assim, o log permanente na rolagem recebe exatamente uma entrada
por etapa (a conclusão).

<a id="4213a0b3-0142"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence

Despacho por etapa pelo registro. Test.SequenceAction permite que um verbo
registre um bloco de script Handler; a hashtable Context é a
superfície canônica de estado (sem capturar variáveis locais da função
pai em closures). Todos os verbos incorporados -- inclusive `retry` -- registram
um Handler.
Um erro de digitação em YAML (por exemplo, "tapButton" em vez de "tapOn") ou um verbo de
terceiros que registrou um FailureLabel sem Handler
aparece aqui como falha definitiva, para nunca passar silenciosamente.

<a id="4213a0b3-0143"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence

O registro de um verbo declara como ele classifica SUA PRÓPRIA falha, portanto
pertence apenas a uma linha que realmente falhou. Gravado em uma linha aprovada,
deixa `ok` como o único campo que separa uma falha real de
um registro estático, e toda busca grep, seletor Loki e filtro de painel
para uma classe passa a corresponder uma vez por etapa executada desse verbo --
todas aprovadas. Nada é perdido ao omiti-lo: actionVerb consta da
linha, e Get-SequenceAction o mapeia de volta ao mesmo registro
para um consumidor que queira saber como o verbo TERIA classificado uma
falha.

Os nomes verbDefault* expressam a outra metade: são os valores do
registro para o verbo, não uma leitura do que falhou aqui, enquanto
step_failure publica uma classificação real em failureClass /
severity / suggestedRecoveries -- uma classificação que um padrão de falha encontrado
ou um convidado inacessível pode afastar completamente do registro. Uma
chave para ambos faria uma junção entre as duas linhas comparar uma
medição com uma constante e chamá-las do mesmo campo.

<a id="4213a0b3-0144"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence

Evitar a armadilha da dupla remoção de invólucro: PowerShell retira tanto matrizes de um único
elemento QUANTO matrizes vazias da saída de pipeline de uma instrução if;
portanto, `[string[]]$x = if (...) { @(...) }` produz um escalar
para um valor de 1 elemento e $null para um valor vazio. A forma em duas etapas
abaixo inicializa primeiro com uma string[] vazia e então
sobrescreve apenas quando há entradas a materializar; qualquer
resultado serializa como matriz JSON e satisfaz a verificação de
matriz tipada do validador de esquema.

<a id="4213a0b3-0145"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence

Emitir uma linha estruturada por execução de etapa. stepName é a
`description:` BRUTA (antes da expansão) do YAML -- variáveis como
${vmName} deliberadamente NÃO são expandidas aqui, para que junções entre ciclos
por stepName continuem estáveis, embora vmName mude quando saveDiskSnapshot
renomeia a VM e contenha um segmento de ID do hospedeiro em um grupo. Usa step.action quando nenhuma
descrição está definida. Uma repetição emite seu intervalo envolvente e seu
resultado final, além dos filhos; os leitores contam apenas linhas de nível superior
ao somar trabalho e falhas finais.

<a id="4213a0b3-0146"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence

Construir um rótulo legível da etapa com falha (por exemplo, 'waitForText: "login prompt"').
Construtor canônico: Test.SequenceAction\Get-SequenceActionFailureLabel.
O bloco de script FailureLabel de cada verbo fica junto aos requisitos de
capacidade em Test.SequenceHandler.psm1 -- procurar
Register-SequenceAction. O ponto de chamada EXTERNO lê $script:Fail.Last-
Failure* abaixo para escrever last_failure.json e a captura de
tela da falha. Capturar aqui (e apenas retornar $false) impede que falhas
transitórias de tentativas deixem um last_failure.json antigo
para trás.

<a id="4213a0b3-0147"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence

Se um verbo de sinal de espera encerrou antes por um failurePattern,
anotar o rótulo da etapa para que o aviso ERROR do executor e o
JSON de falha por execução informem *por que* a etapa morreu, em vez do
genérico "pattern not found within Ns". O conjunto de verbos
que preenche esse sinal é declarado por verbo pela
sinalização UsesWaitSignals do registro (Register-SequenceAction); portanto, um
novo verbo de espera opta por isso em seu registro, em vez de editar
este ponto do mecanismo. Para outras ações, o sinal é $null e
o rótulo permanece inalterado.

<a id="4213a0b3-0148"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence

Captura do verbo interno para falhas por esgotamento de tentativas. O ramo de falha
por etapa em $invokeStepBlock sobrescreve $script:Fail.LastFailedAction com
o nome da ação da etapa EXTERNA (= 'retry') sempre que um Handler retorna
$false; isso reduz a classificação do verbo interno mais profundo
a 'retry_exhausted'. O Handler de retry captura o verbo interno
nesses campos ANTES de retornar, para que o emissor v2 abaixo possa
mostrar ambas as classes -- 'retry_exhausted' para a etapa externa,
mais a classe interna de que um mecanismo de correção autônomo precisa para escolher a
recuperação correta (um tempo limite de OCR pede uma correção diferente
de uma indisponibilidade de SSH).

<a id="4213a0b3-0149"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence

Construído após a captura acima, não antes: o registro nomeia os
artefatos de tela que esta falha deixou e só declara um que
já existe em disco e é mais recente que a etapa com falha; portanto, um registro construído
primeiro teria de descrever um quadro que ainda não existe.
New-SequenceFailureRecord lê os campos $script:Fail e retorna
tanto o dicionário ordenado de last_failure.json quanto o registro NDJSON step_failure
correspondente, para que o arquivo e o fluxo de eventos nunca divirjam. Ver
docs/failure-schema.md.

<a id="4213a0b3-014a"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence

YurunaCycleRestart é um marcador de fluxo de controle da barreira de reinicialização do ciclo
($checkCycleRestart), não uma falha real da sequência. O comentário
da barreira em Gate #2 promete que ele "se propaga até o try/
catch no nível do ciclo em Invoke-TestRunnerInnerLoop" -- lançar novamente antes que o tratador
genérico o transforme em Write-Warning + return $false, o que
deixaria control.cycle-restart sem consumo e faria a sinalização disparar novamente em toda
barreira [sequence start] de sequências posteriores. Preferir a etiqueta
estruturada Exception.Data (sobrevive a um reencapsulamento que removeria o prefixo
da mensagem); recorrer ao prefixo da mensagem para que um marcador sem etiqueta de um
caminho de lançamento antigo ainda seja relançado, em vez de contado como erro inesperado.

<a id="4213a0b3-014b"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence

Preservar diagnósticos do erro inesperado no MESMO formato schema-v2
emitido pelo caminho normal de falha acima. Sem isso, uma
exceção de qualquer Handler de verbo (ou da infraestrutura entre
etapas) rebaixa silenciosamente last_failure.json de v2 para uma carga v0 de
erro, removendo failureClass/severity/suggested
Recoveries -- exatamente os campos pelos quais um mecanismo de correção posterior
encaminha a situação. Quando $script:Fail.LastFailedAction já foi capturado pelo
ramo de falha por etapa, resolvemos sua entrada no registro; caso contrário,
usamos a classificação canônica 'unknown' (a mesma
alternativa que os caminhos por etapa acima usam quando um verbo não é resolvido),
para que o registro permaneça schema-v2 E passe na validação dos enums failureClass/severity
em Test.EventSchema. O erro inesperado continua distinguível
pelo rótulo de ação "engine crash: ...", pelo campo crashError e
pelo bloco .context.crash -- um valor separado de enum não tem peso no encaminhamento,
pois o despachante de correção já mapeia 'unknown' para
pausar e inspecionar.

<a id="4213a0b3-014c"></a>

<a id="testmodulestestsequenceenginepsm1-recursive-step-executor"></a>

## test/modules/Test.SequenceEngine.psm1: Executor recursivo de etapas

Registrado em módulos por hospedeiro com nomes no singular:
  Test.HostIO.HyperV.psm1   host.windows.hyper-v
  Test.HostIO.Utm.psm1      host.macos.utm
  Test.HostIO.Kvm.psm1      host.ubuntu.kvm
Cada módulo controla apenas suas chamadas de Register-HostIOProvider; os
corpos das funções (Send-KeyHyperV / Send-KeyVNC / Send-KeyUTM /
Send-KeyKvm / Send-TextHyperV / Send-TextVNC / Send-TextUTM /
Send-TextKvm / Send-ClickHyperV / Send-ClickUtm) ficam em
Test.Transport.psm1. A matriz de capacidades da inicialização lê
Get-HostIOProviderMatrix, para que o operador veja quais ações estão
integradas no hospedeiro atual antes de o ciclo começar. Ver docs/host-io.md.

<a id="4213a0b3-014d"></a>

<a id="testmodulestestsequenceenginepsm1-host-io-provider-registrations"></a>

## test/modules/Test.SequenceEngine.psm1: Registros de provedores de E/S do hospedeiro

Convenção dos blocos de script de rótulo de falha: $Context contém Step (etapa YAML
analisada), Vars (escopo de variáveis) e ExpandVariable (referência ativa a
Expand-Variable; nós a passamos para que o módulo de registro NÃO precise
importar Invoke-Sequence). Cada bloco lê $Context e retorna a
string do rótulo. Os requisitos de capacidade (HostIORequirement + OcrRequired)
ficam nas mesmas entradas do registro; Test.Capability os lê dali.

Ver ../../docs/test-sequences.md#handler-contract para a integração -Global do catálogo
de verbos incorporados e como ele coordena pelo armazenamento compartilhado
do estado de falha. -- Test.SequenceEngine.psm1

<a id="4213a0b3-014e"></a>

## test/modules/Test.SequenceFailureState.psm1: Initialize-SequenceFailureStateStore

Preenchido em qualquer espera que atingiu o tempo limite após ler algum texto: por mecanismo e
por padrão procurado, a linha no quadro final que mais se aproximou e o quanto
se aproximou. O campo de correspondências próximas acima fica vazio em três telas sem relação; portanto,
sozinho não pode dizer se havia algo parecido com o padrão;
este pode e, em um quadro menor que a janela final -- onde a janela
é incapaz de ocultar algo --, é a única evidência da tela no
registro. Três estados: entradas, uma matriz vazia de uma análise que comparou o
quadro e não encontrou nada parecido com o padrão, e $null quando não houve análise alguma --
uma espera que termina por um padrão de falha retorna no momento da correspondência, e uma
falha fora de uma espera não tem quadro. Apenas os dois primeiros dizem algo sobre
a tela, portanto o terceiro não deve chegar com a forma do segundo.

<a id="4213a0b3-014f"></a>

## test/modules/Test.SequenceFailureState.psm1: New-SequenceFailureRecord

Ambos os campos de console descrevem uma tela que algo examinou. Quando a espera
restringiu a correspondência ao final do console, nada fez isso: a verificação de inundação e o
rastreador de conteúdo estático nunca executaram; portanto, 0 / '' são valores iniciais, não
leituras -- e são exatamente os valores produzidos por um console saudável que
foi medido. $null mantém ambas as chaves presentes, indicando que a espera não examinou a tela;
assim, nenhum consumidor pode ler "o console estava se movendo" de uma medição que
nunca aconteceu. Um armazenamento sem sinalização alguma é tratado como medido, portanto um
registro construído a partir dele mantém a forma que já tinha.

<a id="4213a0b3-0150"></a>

## test/modules/Test.SequenceFailureState.psm1: New-SequenceFailureRecord

O encerramento antecipado de Wait-ForText por um padrão de bloqueio definitivo reclassifica a etapa.
As recuperações acompanham a classe: a sugestão do registro de verbos descreve
sua falha PADRÃO (um marcador de conclusão que nunca chegou, caso em que
vale tentar novamente), e um padrão de falha encontrado é o caso oposto --
o script do convidado anunciou sua própria falha, portanto uma nova tentativa apenas executa de novo um
comando que já se sabe que falha. Deixar a sugestão de nova tentativa do registro
no lugar aqui recomendaria repetir justamente a falha que não pode
se beneficiar disso.

<a id="4213a0b3-0151"></a>

## test/modules/Test.SequenceFailureState.psm1: New-SequenceFailureRecord

A sessão caiu enquanto o comando executava, portanto script_error do registro
descreve um script cujo resultado ninguém observou.
network_timeout é tanto o nome fiel quanto aquele em que atua uma retomada
com o estado existente no mesmo ambiente -- executar novamente a sequência a partir da última etapa boa
no mesmo convidado ativo é exatamente a resposta certa para um caminho que quebrou
durante a execução, e essa resposta é inacessível enquanto o registro diz script_error.
A ordem após a verificação do endereço é intencional: um endereço não resolvido é
a falha mais específica, e as duas não podem ser verdadeiras ao mesmo tempo --
o driver ssh retorna antes de conectar quando não tem endereço.

<a id="4213a0b3-0152"></a>

## test/modules/Test.SequenceFailureState.psm1: New-SequenceFailureRecord

Último na ordem das correções do lado do convidado, e essa ordem é o que
o torna seguro: este sinal é lido da saída enviada pelo convidado, portanto
alcançá-lo significa que a sessão se manteve e o invólucro respondeu. Os três
acima descrevem as formas de isso NÃO acontecer -- nenhum endereço, conexão interrompida,
uma execução cujo andamento ninguém pôde verificar -- e cada um é a falha mais específica
quando ambos podem parecer verdadeiros. O que resta é um convidado que executou o
invólucro e não recebeu conteúdo; portanto, nenhum script executou, e script_error do registro
nomeia algo que não existe.

<a id="4213a0b3-0153"></a>

## test/modules/Test.SequenceFailureState.psm1: New-SequenceFailureRecord

repro: um comando para copiar e colar que executa novamente a sequência com falha (e sua
cadeia de base) para reproduzir a falha de forma determinística. O comando
deliberadamente OMITE -StartStep: stepNumber é local ao arquivo (baseado em 1 dentro
deste arquivo de sequência), mas -StartStep de Debug-TestSequence é GLOBAL à cadeia;
portanto, um -StartStep ingênuo apontaria incorretamente a uma sequência folha cuja
base ainda não foi construída. A etapa local com falha é exposta como resumeFromStep
(consultivo; válido como -StartStep no caminho com estado existente / sem base). Contrato
em docs/failure-schema.md.
Remover caracteres que escapariam dos argumentos repro entre aspas duplas
('"', acento grave, '$') ou dividiriam a linha de comando (CR/LF). O repro é
mostrado para copiar e colar e para execução por um mecanismo de correção autônomo; portanto, um
nome de VM/convidado hostil ou malformado não deve se tornar um risco de execução.
Os identificadores normalmente não contêm aspas, portanto isso só altera nomes
patológicos; os campos de dados (sequenceName, vmName, guestKey) mantêm o valor real.
<a id="4213a0b3-0154"></a>

## test/modules/Test.SequenceFailureState.psm1: New-SequenceFailureRecord

Relativo ao diretório do ciclo, indicando onde os artefatos realmente ficam. A forma plana
na raiz que esses campos usavam era identificada apenas pelo nome da VM; portanto, todo ciclo
que falhava no mesmo convidado sobrescrevia os mesmos dois arquivos: uma referência lida
posteriormente poderia apontar à captura de um ciclo DIFERENTE, sem sinal
de que isso ocorreu, algo pior que um caminho que não aponta a nada.

Declarado apenas quando o artefato de origem foi escrito após o início da etapa
com falha. Ambas as origens são arquivos persistentes por VM na raiz do log, sobrescritos apenas
pelos verbos que leem uma tela; portanto, uma falha em um verbo que não lê
tela herda o que uma etapa anterior deixou -- e uma referência a isso
parece ser a tela desta falha, levando o leitor a procurar uma falha
que pertence a outra etapa. A fronteira é o INÍCIO da etapa, não
o instante da falha: todo artefato de uma falha é escrito antes do
registro que o descreve, portanto o instante rejeitaria todos eles. A
margem de 2 segundos absorve a granularidade dos timestamps do sistema de arquivos (FAT/exFAT arredondam
mtime para 2s), o único desvio que pode fazer uma escrita realmente recente parecer
mais antiga; um artefato desatualizado tem no mínimo uma etapa inteira de idade, portanto a margem
não o alcança. Sem uma fronteira de etapa registrada, ambos são declarados como
antes: nada se sabe de sua idade, e a ausência de avaliação não é
evidência de desatualização.

<a id="4213a0b3-0155"></a>

## test/modules/Test.SequenceFailureState.psm1: New-InfraFailureRecord

O estado do próprio hospedeiro no momento da recusa. Uma falha de provisionamento
é uma afirmação sobre a máquina, não sobre o convidado, e a
situação da memória da máquina não pode ser recuperada de nenhum outro dado mantido pelo ciclo
-- esses números existem apenas no instante da chamada. Incluído apenas
quando um driver realmente mediu; AUSENTE caso contrário, seguindo a mesma disciplina
das referências de evidência da tela, pois um bloco zerado seria lido
como uma máquina medida e encontrada vazia. O arquivo aninha a leitura, e o
evento a transporta em campos planos, como todo outro valor aninhado deste fluxo.

<a id="4213a0b3-0156"></a>

<a id="testmodulestestsequencehandlerpsm1-the-wrapper-prints-the-sentinel-for-two-different-events-and-only-it-can-tell"></a>

## test/modules/Test.SequenceHandler.psm1: O invólucro imprime o marcador para dois eventos diferentes, e só ele pode distingui-los

O invólucro imprime o marcador para dois eventos diferentes, e só ele pode
distingui-los: um script que EXECUTOU e saiu com código diferente de zero, e uma carga que nunca
foi entregue, de modo que nada executou. Ele já informa qual caso ocorreu no trecho entre parênteses que
acrescenta. Comparar apenas o marcador descarta isso, e o segundo evento então
chega como script_error do registro de verbos -- um script a depurar que nunca
existiu e uma classe excluída pelas listas de permissão de falhas transitórias; assim, a falha com
maior chance de desaparecer sozinha é a que nada tenta novamente.

Estes são os motivos de não execução que são SEGUROS para nova tentativa. Dois ficam deliberadamente
ausentes. "(exit N)" é o próprio status diferente de zero do script -- ele executou, e
script_error está correto. "(integrity mismatch -- refusing to run)" também nunca
executou, mas é uma recusa, não uma falta: os bytes obtidos não correspondiam ao
resumo criptográfico do hospedeiro, e uma nova tentativa é justamente a resposta que não deve ser recomendada
para isso. As strings reproduzem automation/fetch-and-execute.sh e são fixadas
contra ele por uma proteção contra divergência, o mesmo vínculo usado pelo próprio marcador.

<a id="4213a0b3-0157"></a>

<a id="testmodulestestsequencehandlerpsm1-the-shells-own-refusal-of-the-command-line-it-was-just-handed"></a>

## test/modules/Test.SequenceHandler.psm1: A recusa do próprio shell à linha de comando que acabou de receber

A recusa do próprio shell à linha de comando que acabou de receber. Diferentemente do
marcador acima -- que o invólucro imprime e que, portanto, comprova que o
invólucro EXECUTOU --, estas mensagens vêm do bash antes de qualquer execução nossa: o
interpretador nomeado na linha não existe, portanto nenhum script, invólucro ou
marcador aparecerá, e o marcador de conclusão é inalcançável desde o
primeiro segundo.

A forma como um comando digitado no console chega a esse estado é o transporte
de teclas: a linha é entregue com um evento de tecla por caractere a um convidado
cuja camada de entrada pode perder e reordenar eventos sob carga, e uma palavra de comando
que perde quatro caracteres é uma palavra de comando que não pode ser resolvida. Nada
antes disso consegue perceber o ocorrido, e nada depois consegue distingui-lo de
uma carga apenas lenta; por isso, vale ler diretamente a resposta do
shell.

Essas mensagens são comparadas APENAS dentro da janela antecipada de Wait-ForText (ver
$script:ShellRejectionWindowSeconds). Um script saudável pode procurar binários
ausentes ou testar deliberadamente entradas inválidas do shell; portanto, essas strings sozinhas
não comprovam falha na entrega do comando fora dessa janela.

<a id="4213a0b3-0158"></a>

## test/modules/Test.SequenceHandler.psm1: Resolve-WaitForTextStepParam

Restringir a correspondência positiva às linhas que NÃO estavam na tela
quando a espera começou. Uma solicitação cujo texto é uma subsequência do texto
acima dela -- "New password:" do PAM contra o aviso que informa
que a senha precisa ser alterada -- corresponde a esse aviso na primeira
consulta, e o verbo então responde a uma solicitação que o convidado não imprimiu:
a senha chega a um tty que o PAM ainda não colocou em modo sem eco,
aparece em texto claro, e a redigitação já não consegue corresponder. Apenas o texto
provocado pela própria etapa pode sustentar esse resultado. failurePatterns deliberadamente
NÃO são restringidos assim -- uma tela de erro é evidência
sempre que está visível, inclusive quando já estava visível na chegada.

<a id="4213a0b3-0159"></a>

<a id="testmodulestestsequencehandlerpsm1-verb-registrations"></a>

## test/modules/Test.SequenceHandler.psm1: Registros de verbos

Trecho final compartilhado dos verbos de entrada que digitam e depois pressionam Enter (inputTextAndEnter, waitForAndEnter,
passwdPrompt, fetchAndExecute): enviar $Text já expandido; em uma falha de Send-Text,
sair ANTES de consumir a espera (nenhum Enter é enviado); caso contrário, aguardar todo $DelaySeconds com
sinais de progresso e uma estabilização de 800ms, depois pressionar Enter. Retorna o resultado de Enter como
[bool] (ou $false quando Send-Text falha). Os chamadores mantêm sua própria linha de depuração "Typing ..."
-- o texto da mensagem e a regra de mascaramento sensível diferem por verbo -- e decidem
se retornam o resultado ou continuam (fetchAndExecute continua aguardando um
marcador de conclusão). $ShellEscape fica DESATIVADO para passwdPrompt, para que a senha seja digitada
literalmente, e ATIVADO para os verbos de comando/texto, conforme a chamada Send-Text de cada verbo.
Send-Text / Send-Key são qualificados para o despachante de Invoke-Sequence (os mesmos nomes
também existem nos módulos de E/S por hospedeiro importados aqui). Os sinais que usam apenas Write-Progress
não emitem nada no fluxo de saída, portanto o único retorno [bool] permanece sem contaminação.

<a id="4213a0b3-015a"></a>

## test/modules/Test.SequenceHandler.psm1: Invoke-BlindAnswer

Uma tela nomeada por esta etapa é uma tela na qual a resposta nunca deve ser digitada. Ambas
as metades do contrato sem leitura da solicitação são satisfeitas por um menu interativo tão
bem quanto pela solicitação que saiu pela rolagem para a qual foram escritas: um menu aguardando
uma tecla fica perfeitamente estático, e a tecla o navega; assim, o
console muda e parece ter consumido a entrada. Apenas a própria tela separa
os dois casos. Recusar custa apenas a recuperação -- a etapa ainda gasta
o restante de seu orçamento na espera solicitada -- portanto um padrão aqui
pode estar incorreto com segurança de uma forma que um failurePattern não pode. A comparação usa
-NoSegmentMatch para que um padrão de exclusão não dispare por suas próprias palavras espalhadas
em uma tela sem relação.

<a id="4213a0b3-015b"></a>

<a id="testmodulestestsequencehandlerpsm1-verb-registrations-1"></a>

## test/modules/Test.SequenceHandler.psm1: Registros de verbos

Limite opcional de tempo real para que um ciclo SEM SUPERVISÃO não fique preso aqui
para sempre: step.timeoutSeconds ou, na ausência dele, o global YURUNA_BREAK_MAX_SECONDS
limita a espera. Sem nenhum deles definido, a espera é efetivamente ilimitada --
o padrão interativo quando um operador está presente. No tempo limite, a
interrupção retoma automaticamente NO MESMO ESTADO (resumedVia='timeout'); o caminho abaixo de restauração
de snapshot pelo botão de continuação é deliberadamente ignorado nesse caso.
Analisar defensivamente o tempo limite opcional. Uma conversão simples [int] lança uma exceção para um
valor não numérico (por exemplo, um erro do operador como '5m' no campo de texto livre
YURUNA_BREAK_MAX_SECONDS, ou um step.timeoutSeconds inválido que o esquema não
restringe para break). O invólucro de despacho deste tratador tem finally, mas não
catch; portanto, uma exceção que escape ignoraria a proteção flexível/return-$false da interrupção
e abortaria o ciclo -- o oposto da proteção pretendida aqui contra bloqueio
sem supervisão. Usar 0 por padrão (espera interativa ilimitada) quando a análise não for possível.

<a id="4213a0b3-015c"></a>

<a id="testmodulestestsequencehandlerpsm1-verb-registrations-2"></a>

## test/modules/Test.SequenceHandler.psm1: Registros de verbos

A classe registrada é o PADRÃO -- a classificação da falha deste verbo quando nenhum
failPattern correspondeu. Isso é o marcador de conclusão que nunca chega, ou seja,
um wait_timeout; a causa comum é o script obtido travar em um espelho de pacotes
parado. Registrar 'pattern_matched_failure' aqui afirmava o
oposto: que o invólucro imprimiu sua etiqueta de falha. Nada a verificava novamente;
portanto, um simples tempo limite era informado como uma falha relatada pelo script, encaminhado a
pause_and_inspect ("uma nova tentativa automática apenas a acionaria novamente") e excluído da
retomada com estado existente -- transformando uma interrupção transitória na origem em um ciclo morto que exige
um operador. Build-SequenceFailureRecord ainda reclassifica para
pattern_matched_failure quando um padrão realmente corresponde; assim, esse caso mantém
seu próprio rótulo e seu encaminhamento sem nova tentativa.

<a id="4213a0b3-015d"></a>

<a id="testmodulestestsequencehandlerpsm1-verb-registrations-3"></a>

## test/modules/Test.SequenceHandler.psm1: Registros de verbos

Esta É a ação fetchAndExecute, portanto seu contrato fetch-and-execute
(automation/fetch-and-execute.sh) sempre se aplica: o
invólucro imprime "NONZERO SCRIPT EXIT:" em uma saída do filho diferente de zero.
Derivar a falha rápida da AÇÃO, nunca do texto literal de
waitPattern -- condicioná-la ao waitPattern (por exemplo, comparar
"FETCHED AND EXECUTED:") desativava silenciosamente essa detecção de erro em segundos
assim que alguém decorava ou reformulava o marcador de conclusão
visível ao usuário, deixando uma obtenção com falha consumir todo o tempo limite.
O marcador evita deliberadamente as palavras "fetch"/"execute"
(Test-OCRMatch é aproximado e, caso contrário, corresponderia à linha de comando ecoada
'fetch-and-execute.sh ...' na primeira consulta e faria
uma execução saudável falhar em ~4 s); "NONZERO" não pode colidir com um comando ou
com a saída normal do script. Uma etapa ainda pode substituir isso por failurePatterns.

<a id="4213a0b3-015e"></a>

<a id="testmodulestestsequencehandlerpsm1-verb-registrations-4"></a>

## test/modules/Test.SequenceHandler.psm1: Registros de verbos

A janela é a ÚNICA coisa que impede um marcador impresso por um
fetchAndExecute ANTERIOR de satisfazer este: freshMatch aqui é uma restrição
ao final, e nada mais -- não exige primeiro que o padrão
desapareça -- e as sequências reutilizam um marcador genérico de conclusão para
todas as etapas. Portanto, a janela não pode simplesmente ser ampliada: depois do ponto
em que o marcador da etapa anterior ainda fica dentro dela, uma etapa que nunca
executou informa sucesso, algo pior que a falha que a ampliação
evitaria.

Ela também não pode permanecer no padrão de waitForText. Qualquer coisa que o convidado
emita após o marcador -- um redesenho do console, uma listagem de conclusão, uma
linha tardia de daemon -- o empurra para fora e faz falhar uma execução que TEVE SUCESSO, e
a repetição seguinte executa de novo trabalho já realizado. Um
padrão moderado absorve um redesenho extra; uma sequência que limpa a tela
antes desta etapa não tem conteúdo antigo que possa confundir e pode aumentar com segurança
freshMatchTailLines tanto quanto sua própria saída exigir. O relatório de correspondências próximas
no tempo limite da espera nomeia esse ajuste e o valor a usar.

<a id="4213a0b3-015f"></a>

<a id="testmodulestestsequencehandlerpsm1-verb-registrations-5"></a>

## test/modules/Test.SequenceHandler.psm1: Registros de verbos

Falha rápida opcional baseada em OCR: quando `installerFailurePatterns` está
definido, aplicar periodicamente OCR à tela do convidado enquanto se aguarda SSH e
encerrar antes se algum padrão corresponder. Destina-se à saída
"install_fail.crash" / "Press enter to start a shell" do subiquity --
sem isso, uma instalação com erro só aparece após todo o
timeoutSeconds (~40 min nas sequências do Ubuntu Server), pois
sshd nunca inicia para satisfazer Wait-SshReady. Funciona junto à nova tentativa automática
com recuo exponencial yuruna_retry em Invoke-TestRunnerInnerLoop, para que
uma instabilidade transitória do instalador seja recuperada no próximo ciclo.

<a id="4213a0b3-0160"></a>

<a id="testmodulestestsequencehandlerpsm1-verb-registrations-6"></a>

## test/modules/Test.SequenceHandler.psm1: Registros de verbos

Test.OcrEngine + Test.YurunaDir + Test.Log ficam junto deste
módulo; Import-Module -Force custa pouco após o primeiro carregamento. -Global nos
três é essencial: um -Force aninhado SEM -Global remove o
módulo da sessão pai (global). Test-CombinedOcrMatch
(módulo Test.OcrMatch, chamado abaixo) resolve Get-EnabledOcrProvider
/ Invoke-OcrProvider pelo escopo global; portanto, remover Test.OcrEngine aqui
faz a análise OCR falhar (a classe de regressão por remoção de módulo,
feedback_module_force_import_evicts_global.md).

<a id="4213a0b3-0161"></a>

<a id="testmodulestestsequencehandlerpsm1-verb-registrations-7"></a>

## test/modules/Test.SequenceHandler.psm1: Registros de verbos

Desvinculado por padrão. A carga executa sob um supervisor no convidado
e sobrevive à sessão, portanto uma mudança de endereço exige reconexão em vez de perder
a etapa -- e, diferentemente de executar novamente, isso é correto para uma carga que
insere registros e depois verifica suas contagens, o que corresponde à maior parte do que
este verbo executa. `detach: false` desativa isso para uma etapa.

O token é derivado, não aleatório, e isso é essencial
por dois motivos: uma reconexão dentro da etapa conecta à mesma execução, e uma
retomada com estado existente que volta a esta etapa em um convidado ainda ativo
conecta ao trabalho já em andamento, em vez de iniciá-lo novamente.

<a id="4213a0b3-0162"></a>

## test/modules/Test.SequenceHandler.psm1: retry / recoverFromSnapshot

Preservar o que a tentativa com falha tinha na tela antes que as esperas da
próxima tentativa reciclem o buffer de quadros e sobrescrevam a
captura de falha por VM. Uma tentativa que depois tem sucesso
leva o ciclo inteiro à aprovação, e todo caminho que coleta
evidências é um caminho de falha do ciclo -- portanto, sem uma cópia feita
aqui, uma falha recuperada não pode ser reconstruída, por mais que
se repita. Condicionado à severidade hard: as classes soft são as que a
repetição existe para absorver, e copiar para elas
enterraria as capturas reais sob capturas rotineiras.

<a id="4213a0b3-0163"></a>

## test/modules/Test.SequenceHandler.psm1: retry / recoverFromSnapshot

O Hyper-V ARM64 pode travar ao iniciar tanto o instalador em execução
quanto o convidado instalado, com os processadores virtuais passando quase
todo o tempo fora do convidado. Uma reconexão do console não pode
alterar esse estado da VM; desligá-la e ligá-la a frio pode. Manter a recuperação
opcional, específica da plataforma e limitada a uma espera de login ou a um
travamento confirmado separadamente antes da confirmação do instalador.
Em particular, nunca reiniciar por um failurePattern do instalador,
uma inundação do console ou uma falha na solicitação de senha.

<a id="4213a0b3-0164"></a>

## test/modules/Test.SequenceHandler.psm1: retry / recoverFromSnapshot

Aguardar com recuo antes da próxima tentativa. Executar novamente de imediato
consome todas as tentativas em milissegundos e não dá tempo para uma falha
transitória (uma breve interrupção de rede, um serviço ainda iniciando)
desaparecer. Get-PollDelay inclui variação aleatória e um limite exponencial,
portanto também quebra a sincronização quando muitos convidados tentam de novo
ao mesmo tempo. Atualizar primeiro o sinal de atividade para que o watchdog permaneça
alinhado durante a espera (reproduz a atualização por tentativa
acima).

<a id="4213a0b3-0165"></a>

<a id="testmodulestestsequenceplannerpsm1-pull-in-resolve-sequencepath-and-read-sequencefile-from-the-engine-module"></a>

## test/modules/Test.SequencePlanner.psm1: Importar Resolve-SequencePath e Read-SequenceFile do módulo do mecanismo

Importar Resolve-SequencePath e Read-SequenceFile do módulo do mecanismo
para que os pré-requisitos sejam resolvidos da mesma forma que em Invoke-Sequence.

-Global é necessário: -Force sem -Global retira o módulo do mecanismo da
sessão global (ver a armadilha module-force-evict na memória do repositório). O
executor importa Invoke-Sequence na inicialização; se alguma importação posterior com -Force aqui
o remover, todo chamador que construiu uma referência de função, por exemplo a
Invoke-SequenceByName / Read-SequenceFile, perde a visibilidade.

<a id="4213a0b3-0166"></a>

<a id="testmodulestestsequenceresolvepsm1-a-snippet-is-a-named-reusable-list-of-steps-spliced-into-a-sequence-wherever"></a>

## test/modules/Test.SequenceResolve.psm1: Um trecho é uma lista nomeada e reutilizável de etapas inserida em uma sequência

Um trecho é uma lista nomeada e reutilizável de etapas inserida em uma sequência onde quer que
apareça uma etapa `{ snippet: <name> }` (inclusive dentro de retry.steps); assim, preâmbulos
comuns, como a preparação do login a frio com agetty, ficam em um único lugar, em vez de serem
copiados em todas as sequências de cargas de trabalho. As bibliotecas são arquivos `_snippets.yml` (um
mapa de nome -> matriz de etapas) que ficam junto às sequências: no framework,
`test/sequences/_snippets.yml`, e no projeto, `project/<...>/test/_snippets.yml`.
Entradas do projeto substituem entradas do framework de mesmo nome (reproduz
a organização em camadas de Resolve-SequencePath, em que o projeto prevalece);
duas bibliotecas do PROJETO que definam o mesmo nome constituem ambiguidade fatal. A expansão
executa dentro de Read-SequenceFile, para que todo consumidor (executor, planejador, desempenho, janelas
de etapas) veja as etapas já inseridas, sem integração específica em cada ponto de chamada.

<a id="4213a0b3-0167"></a>

## test/modules/Test.SequenceRunner.psm1: Resolve-TestSequencePlan

Quando a sequência de nível superior declara `requiresSnapshot: { id: <X> }`,
a cadeia termina em um saveDiskSnapshot que renomeia `test-<guestKey>`
-> <X>. Dois caminhos:

  COM ESTADO EXISTENTE: a VM persistida <X> existe E já tem o snapshot <X> em disco.
        Ignorar todas as sequências de pré-requisitos e executar apenas a sequência de nível superior contra
        <X>. O primeiro loadDiskSnapshot da sequência de nível superior reverte o disco.

  A FRIO: o snapshot não está presente. Percorrer a cadeia inteira. A VM de construção é
        criada com o nome test-<guestKey> (para que Remove-TestVMFiles
        possa remover uma construção a frio com falha); saveDiskSnapshot a renomeia
        para <X> no meio da cadeia, e as entradas seguintes operam em <X>. O
        laço por entrada abaixo detecta a renomeação e atualiza $VMName.

<a id="4213a0b3-0168"></a>

<a id="testmodulestestsequencevariablepsm1-variable-substitution-for-sequence-step-text-var-placeholders-and"></a>

## test/modules/Test.SequenceVariable.psm1: Substituição de variáveis no texto das etapas: marcadores ${var} e expressões de extensão

Substituição de variáveis no texto das etapas: marcadores ${var} e
expressões de extensão ${ext:area.Method(args)}. Ver
../../docs/test-sequences.md#variable-substitution-rules para as regras e
por que isso fica fora do mecanismo. -- Test.SequenceVariable.psm1
Ponto de código Unicode de uso privado usado como marcador para `$` após a
passagem prévia $$ -> marcador e antes da passagem posterior marcador -> $. A
área de uso privado do Unicode (U+E000-U+F8FF) é reservada para uso
específico da aplicação e praticamente nunca aparece em entrada legítima, portanto
pode atravessar com segurança a passagem de regex e voltar sem colidir com
algo que um usuário realmente digitou.

<a id="4213a0b3-0169"></a>

<a id="testmodulestestsequencevariablepsm1-extareamethodarg1-arg2-----inline-expression-form"></a>

## test/modules/Test.SequenceVariable.psm1: ${ext:area.Method(arg1, arg2, ...)} -- forma de expressão em linha

${ext:area.Method(arg1, arg2, ...)} -- forma de expressão em linha. ArgList
pode incluir marcadores ${var} aninhados, expandidos ANTES de a
extensão ser invocada. Cada chamada é despachada novamente -- não há
cache; portanto, ${ext:authentication.NewRandomPassword()} retorna um novo
valor a cada avaliação. Chamadas com efeitos colaterais
(por exemplo, Set-Password) ainda pertencem à ação dedicada `callExtension`;
${ext:...} destina-se a leituras que produzem valores. O parâmetro chama-se
ArgList (não Args) porque $Args é uma variável automática do PowerShell.

<a id="4213a0b3-016a"></a>

<a id="testmodulestestservicecensuspsm1-the-service-census-what-this-host-last-knew-about-each-managed-service"></a>

## test/modules/Test.ServiceCensus.psm1: O censo de serviços: o último estado conhecido de cada serviço gerenciado neste hospedeiro

O censo de serviços: o último estado conhecido de cada serviço gerenciado neste hospedeiro,
qual operação de ciclo de vida um operador solicitou por último e quem pode iniciar ou
parar um serviço agora.

Quatro coisas ficam aqui, e em nenhum outro lugar, todas sob a raiz privada de estado
($HOME/.yuruna/host-refresh, nunca dentro de uma árvore servida):

  * service-census.record -- um registro com soma de verificação e número de geração
    (Test.CriticalRecord), contendo evidências por serviço e a intenção explícita
    mais recente de iniciar/parar. Escrito apenas sob service-census.lock.
  * service-census.lock -- o bloqueio curto de mesclagem (nível CensusMerge). Nunca
    mantido enquanto se espera por um bloqueio mais longo, portanto não pode causar impasse em uma operação
    de serviço.
  * service-operation.<key>.lock -- um por serviço lógico (nível
    ServiceKey). Os scripts Start e Stop, a varredura de reinicialização e o trabalhador de atualização
    o adquirem, na ordem ordinal das chaves, antes de tocar em um serviço.
  * a tabela de capacidades -- quais usos das evidências do censo uma plataforma
    demonstrou suportar, como declaração pura.

Este módulo deliberadamente não nomeia comando algum capaz de emitir um Apple Event,
consultar o estado do hipervisor pelo canal de controle ou iniciar ou parar um
convidado: o sinalizador executa sua consulta a cada poucos segundos em um hospedeiro cujo canal
de controle pode ser justamente o que travou, e uma única chamada bloqueada ali
paralisaria os próprios anúncios do sinalizador. Os endereços vêm apenas do
resolvedor passivo da plataforma (Get-VMPassiveAddressContext,
Get-VMPassiveAddress, Get-PortMapTarget), resolvido por nome no momento da chamada,
e de arquivos. Uma análise estática deste arquivo fixa a regra.

Os timestamps são autoritativos como números ...UnixMs. Nada aqui analisa uma
string ISO de volta para tomar uma decisão: ConvertFrom-Json as transforma em valores DateTime
locais, e comparar esses valores varia com o fuso horário do hospedeiro
(feedback_datetime-compare-is-timezone-sensitive.md).

<a id="4213a0b3-016b"></a>

<a id="testmodulestestsingleflightlockpsm1-a-held-open-never-unlinked-cross-process-exclusive-lock"></a>

## test/modules/Test.SingleFlightLock.psm1: Um bloqueio exclusivo entre processos, mantido aberto e nunca desvinculado

Um bloqueio exclusivo entre processos, mantido aberto e nunca desvinculado. O identificador É
o mutex: um segundo Enter para o mesmo caminho falha enquanto este
identificador permanecer aberto, neste processo ou em qualquer outro, e a morte do processo
o libera automaticamente pela limpeza de identificadores do SO -- não há arquivo de
PID que possa ficar desatualizado nem desvinculação que dispute com uma limpeza concorrente de estado antigo.

Esta é a mesma forma OpenOrCreate + FileShare.None da qual o sinalizador de endereço
do hospedeiro já depende para hostaddress.beacon.lock. .NET implementa
FileShare.None com flock(LOCK_EX) no Unix, e qualquer outra abertura do arquivo
(mesmo apenas para leitura) adquire LOCK_SH; portanto, entra em conflito com o detentor
entre processos realmente separados, como exige um bloqueio de execução única. Uma
opção de ambiente (DOTNET_SYSTEM_IO_DISABLEFILELOCKING) desativa silenciosamente
esse bloqueio, portanto toda aquisição verifica por conta própria a exclusão
antes de informar que o bloqueio foi adquirido.

Ele NÃO é copiado do bloqueio de caching-proxy (Test.CachingProxyServiceLock
.psm1): esse bloqueio fecha seu fluxo exclusivo imediatamente após escrever
o PID, publica a identidade em um arquivo auxiliar separado e limpa um
detentor supostamente desatualizado excluindo arquivos -- nada disso é um bloqueio do SO que dure por toda
a operação, e sua limpeza forçada por idade de 21600 segundos permitiria roubar o bloqueio de um trabalhador
ativo. Este módulo mantém um identificador exclusivo do SO por
toda a operação do chamador e nunca limpa por idade: apenas um chamador
que consiga adquirir o bloqueio (comprovando que ninguém mais o detém) pode
limpar metadados antigos, via Clear-YurunaSingleFlightLock.

Os níveis ordenam aquisições aninhadas: o bloqueio de operação do hospedeiro mantido por toda a operação, depois
bloqueios de chave de serviço na ordem ordinal dos caminhos e então, no máximo, um bloqueio curto
(admissão, mesclagem do censo, barreira do executor). Uma solicitação que esperaria por um
bloqueio de maior duração enquanto mantém um mais curto é recusada sem tocar
no disco, impedindo que dois processos mantenham, cada um, o bloqueio pelo qual o
outro espera.

<a id="4213a0b3-016c"></a>

## test/modules/Test.SingleInstance.psm1: Stop-StaleRunner

A ÁRVORE, não o PID. Um executor inicia seu processo de ciclo, que inicia o
interno, e todos herdam o terminal (são iniciados com
-NoNewWindow). Encerrar apenas o executor deixa esses filhos vivos, mantendo
o console no qual o NOVO executor está prestes a escrever -- e dois processos em um
terminal não são um problema apenas visual: a consulta de posição do cursor de cada lado
(ESC[6n) tem sua resposta consumida pelo outro, portanto o texto de resposta vaza para
a saída como ";1R" isolado, e o lado que perguntou falha na leitura. PowerShell
responde a uma leitura de console com falha usando Environment.FailFast, que encerra o
processo imediatamente. O interno órfão também continua controlando VMs sem nada
que o supervisione.

TERM antes de KILL, e os filhos antes do pai: um pai encerrado primeiro
transfere seus filhos a init e perde o grupo que os teria alcançado.
O período de tolerância permite que o executor antigo restaure o terminal à
forma em que o encontrou; a varredura KILL posterior destina-se ao que ignorou TERM.

<a id="4213a0b3-016d"></a>

## test/modules/Test.SingleInstance.psm1: Write-RunnerPidFile

Contrato de escrita atômica para o par pidfile e arquivo auxiliar StartTime:
o leitor nunca deve ver um pidfile sem seu arquivo auxiliar, ou
recorre a regex de cmdline sobre uma identidade antiga e pode
atribuir incorretamente o processo. Sequência:

  1. Calcular startIso e escrever em um `.tmp` por PID junto a
     RunnerStartFile, para que o tmp de um executor concorrente não colida.
  2. CreateNew + FileShare.None no pidfile -- esta é a
     comparação e definição que decide a disputa.
  3. Ao vencer: Move-Item .tmp -> RunnerStartFile (renomeação atômica
     no mesmo volume NTFS / ext4 / APFS).
  4. Ao perder: excluir o .tmp órfão e retornar $false; o
     chamador trata isso da mesma forma que Get-RunnerInstanceState
     retornando 'OtherRunner'.

A única janela ainda desprotegida fica entre (2) e (3) --
aproximadamente uma chamada de sistema de renomeação.

<a id="4213a0b3-016e"></a>

<a id="testmodulestestsshpsm1-addresses-that-ssh-has-actually-authenticated-to-per-vm"></a>

## test/modules/Test.Ssh.psm1: Endereços nos quais ssh realmente autenticou, por VM

Endereços nos quais ssh realmente autenticou, por VM. Mantidos no escopo global pelo
mesmo motivo das substituições do usuário: o ambiente de testes reimporta este
módulo com -Force no meio do ciclo, e um registro em memória apagado nesse momento fica vazio
justamente enquanto ocorre uma mudança de endereço.

Este é o último recurso na descoberta de endereços, não o primeiro. Toda outra origem
é um relato sobre o convidado -- do agente, da base de concessões, da tabela
de vizinhos do kernel -- e cada uma pode não fornecer resposta. Um endereço comprovado é diferente
por natureza: ssh concluiu ali uma troca de chaves com o convidado. Isso não o torna
atual (o convidado pode ter mudado desde então), por isso só é consultado
quando todas as camadas de descoberta não responderam, onde hoje o ambiente de testes conecta pelo simples
nome da VM e falha dentro de getaddrinfo.

<a id="4213a0b3-016f"></a>

## test/modules/Test.Ssh.psm1: Get-GuestAddress

Caminho alternativo para uso independente de Test.Ssh (sem Yuruna.Host carregado),
para que usuários do cliente SSH (Wait-SshReady / Invoke-GuestSsh) funcionem mesmo quando
os chamadores esquecem de chamar Initialize-YurunaHost primeiro.

Deliberadamente apenas consultas de BAIXO CUSTO e, portanto, mais fracas que
Get-VMIp do driver: um convidado UTM em ponte é invisível para ambas
(sem agente, e o arquivo de concessões do NAT compartilhado não pode conter sua concessão) e
é encontrado apenas comparando o MAC do pacote na tabela ARP do hospedeiro --
o que exige uma varredura ICMP e é trabalho do driver do hospedeiro que este módulo
não deve duplicar. Um chamador que precise resolver um convidado em ponte
deve ter o driver no escopo; sem ele, o nome da VM é retornado,
e a própria resolução do ssh é o último caminho restante.

<a id="4213a0b3-0170"></a>

## test/modules/Test.Ssh.psm1: Get-SshReadinessFailureCause

Um endereço que nunca respondeu a NADA é uma falha diferente de um endereço ativo
cujo caminho quebrou, e os dois levam o leitor a máquinas diferentes.
Uma tabela de concessões pode conter vários endereços para um convidado -- um convidado reconstruído
recebe um novo, e as linhas antigas ficam até expirar -- portanto um endereço
pode ser descoberto, não estar expirado e pertencer a uma máquina que já não
existe. Isso não prova que a descoberta estava desatualizada, em vez de o caminho
estar quebrado; apenas diz que nada respondeu no endereço fornecido,
que é o ponto em que vale examinar a procedência do endereço
antes da rede.

<a id="4213a0b3-0171"></a>

## test/modules/Test.Ssh.psm1: Wait-SshReady

Caminho de falha. Classificar POR QUÊ antes de emitir diagnósticos, para que eles e
a orientação ao operador apontem à causa real.
Toda a emissão é Verbose: a falha de prontidão é soft (os chamadores recorrem à
camada do console, e o ciclo ainda passa), e o mesmo bloco de várias linhas
se repete em toda captura de diagnóstico de um convidado cujo sshd está inacessível.
O evento estruturado ssh_handshake_failed abaixo é o sinal persistente;
aumentar o nível de log quando realmente depurar uma negociação.
Escolher de qual sondagem vêm as palavras usadas para ler a causa, em vez de usar
o que chegou por último: a sondagem final costuma ser a encerrada no
prazo e, então, não contém resultado algum sobre o alvo.

<a id="4213a0b3-0172"></a>

## test/modules/Test.Ssh.psm1: Wait-SshReady

Mostrar a falha como evento NDJSON estruturado, para que um mecanismo de correção
autônomo encaminhe por `event=ssh_handshake_failed` sem precisar
analisar o fluxo Write-Warning por regex. `cause` é o discriminador
detalhado (ip_not_discovered vs auth_denied vs connection_refused
...) cujas correções diferem; `ipDiscovered` informa se a espera
chegou a ver um endereço real, e `ipAnswered`, se algo respondeu nele.
lastError contém a saída da sondagem final;
attempts / timeout definem se a barreira era limitada por tempo ou por tentativas.
Uma conta expirada pelo próprio convidado é uma falha de credenciais, não de
transporte, e as duas levam o leitor a máquinas diferentes. Registrá-la
na classe de transporte esconde a única linha da saída da sondagem que
nomeia a correção atrás de uma orientação para aguardar e tentar novamente, algo que não pode trocar
uma senha. Toda outra causa aqui é uma espera que esgotou o orçamento enquanto
o chamador recorre à camada do console; portanto, essas permanecem soft.

<a id="4213a0b3-0173"></a>

## test/modules/Test.Ssh.psm1: Invoke-GuestSsh

Get-GuestAddress responde com o nome da VM quando nada descobriu um
endereço. Esse marcador é avaliado como verdadeiro e tem a forma de um hostname; portanto, sozinho,
chega ao ssh como alvo e falha dentro de getaddrinfo -- um erro do resolvedor
que não informa nada sobre a falha real e que nenhuma mudança do lado do convidado consegue corrigir.
Falhas de descoberta normalmente duram menos de um segundo; portanto, resolver novamente em um laço limitado,
em vez de gastar a etapa com um cache desatualizado.

A cláusula Test-IpAddress sustenta todo o predicado: -VMName é
documentado como aceitando um endereço e, para esse chamador, a comparação
com o marcador é verdadeira em um endereço perfeitamente válido. Testar também a forma
é o que mantém esse caso fora da espera.

<a id="4213a0b3-0174"></a>

## test/modules/Test.Ssh.psm1: Invoke-GuestSsh

O modo independente muda o custo de uma tentativa. Uma nova execução recebe todo o
TimeoutSeconds porque reinicia o trabalho; uma conexão à execução existente não, porque
o trabalho esteve executando o tempo inteiro e o orçamento da etapa esteve
diminuindo com ele. Dar um novo orçamento completo a cada reconexão permitiria que uma etapa
declarada em 1800s ocupasse uma hora e meia em três reconexões. Portanto, o
prazo é calculado uma vez aqui, e cada reconexão é limitada pelo tempo
restante, enquanto a quantidade de reconexões é limitada apenas por esse prazo --
com uma mudança a cada dez minutos, um número pequeno e fixo de tentativas seria o que
se esgotaria primeiro.

<a id="4213a0b3-0175"></a>

## test/modules/Test.Ssh.psm1: Invoke-GuestSsh

Deixar o convidado limpar o que a sessão morta deixou antes
de conectar novamente. sshd só desmonta a sessão antiga quando seu próprio
mecanismo de manutenção de atividade desiste; até então, o comando da
tentativa anterior ainda executa -- executar novamente agora colocaria duas
cópias contra os mesmos bloqueios apt/dpkg e transformaria uma
interrupção recuperável em uma nova falha. A espera corresponde ao limite ClientAlive do
lado do convidado definido em host/vmconfig/ubuntu.server.base.user-data,
mais uma margem. Um convidado de uma imagem anterior a essa configuração limpa pelo
tempo limite TCP do kernel, muito além de qualquer espera que valha
gastar aqui; é para esse caso que existe -TransportRetryCount 0.

<a id="4213a0b3-0176"></a>

## test/modules/Test.Ssh.psm1: Invoke-GuestSsh

A saída do processo não implica EOF do pipe, e a limpeza da árvore de processos pode
bloquear dentro do runtime. O auxiliar compartilhado limita ambas independentemente.
ServerAliveInterval/CountMax são a única coisa que encerra uma sessão
cujo par deixou de responder: sem sinais de atividade no nível da aplicação, uma
conexão parcialmente aberta mantém a etapa até seu próprio tempo limite, o que, em uma
etapa longa de provisionamento, significa quase uma hora de um executor aparentemente saudável.
O limite de 15s x 4 concede um minuto inteiro de silêncio antes de desistir, muito
mais que qualquer breve interrupção à qual isso não deve reagir, e sshd responde
a um sinal de atividade independentemente do que o comando remoto está fazendo -- portanto,
um convidado ocupado nunca é confundido com um ausente. TCPKeepAlive continua ativo
como segundo caminho, no nível do kernel, para o mesmo resultado.

<a id="4213a0b3-0177"></a>

## test/modules/Test.Ssh.psm1: Invoke-GuestSsh

Nenhum marcador de saída. O supervisor anuncia-se antes de transmitir
qualquer coisa; portanto, uma linha de início ou conexão sem linha de saída significa que a sessão
terminou enquanto a execução ainda estava ativa -- o que, por construção, é uma perda de transporte,
independentemente do que ssh informou ou deixou de informar. Essa inferência
só está disponível aqui e vale mais que o texto da mensagem: com
LogLevel=ERROR, a própria explicação do cliente frequentemente está ausente, e
depender dela fazia uma etapa cuja carga estava aguardando ser informada como
falha do script do convidado.

Quando o marcador está ausente, apenas o fluxo do próprio supervisor é
classificado. Os bytes da carga chegam por stdout pelo contrato do supervisor;
portanto, mesclá-los esconde uma mensagem ssh de uma linha sob
quilobytes de saída de provisionamento -- e a regra de saída vazia que
detecta um 255 silencioso nunca consegue ser acionada.

<a id="4213a0b3-0178"></a>

## test/modules/Test.Ssh.psm1: Resolve-GuestDiagnosticAddress

A camada portátil, que funciona em todo hospedeiro: pedir ao driver para
alimentar o cache de vizinhos do hospedeiro e então repetir a consulta comum. A descoberta
de endereços de todo driver inclui uma leitura desse cache pelo MAC; portanto,
alimentá-lo é exatamente o que transforma uma consulta sem resposta em uma com resposta --
e ambas as metades são verbos do contrato, portanto isso não exige um ramo por hospedeiro.

Isso antes dependia de uma função exclusiva de UTM, tornando o resolvedor inteiro
inoperante nos outros dois hospedeiros: eles retornavam '' incondicionalmente, e a
sondagem de segunda chance construída sobre isso nunca podia recuperar nada.

<a id="4213a0b3-0179"></a>

## test/modules/Test.Ssh.psm1: Wait-YurunaServiceVmDaemon

Uma resposta vazia não é uma descoberta de que o convidado não tem endereço. A
espera continua sondando o último endereço conhecido -- inclusive o que o
chamador forneceu a partir do hipervisor -- portanto esquecê-lo aqui colocaria
"no guest address discovered yet, so nothing has been probed" na tela
enquanto uma sondagem executa contra um endereço conhecido a cada consulta. É a mesma
afirmação sem medição que este invólucro existe para remover, apenas invertida. Isso
também faria o texto da linha alternar a cada consulta quando a descoberta fosse
intermitente, inundando o log. Apenas um NOVO endereço substitui
o que já se tem.

<a id="4213a0b3-017a"></a>

<a id="testmodulesteststart-guestospsm1-generic-dispatcher-that-runs-a-caller-supplied-list-of-sequence-names"></a>

## test/modules/Test.Start-GuestOS.psm1: Despachante genérico que executa uma lista de nomes de sequência fornecida pelo chamador

Despachante genérico que executa uma lista de nomes de sequência fornecida pelo chamador
via Invoke-SequenceByName -- um ponto de entrada independentemente do SO
do convidado, no lugar dos scripts de extensão Test-Start.guest.*.ps1 por SO. O
planejador de ciclos deriva a lista de project/test/test.runner.yml
e dos campos de base por sequência.

Convenção de nomes (intencional):
    Nome do arquivo do módulo = "Test.<exported-cmdlet>.psm1"
Este arquivo exporta exatamente um cmdlet, `Start-GuestOS`; portanto, o nome do arquivo
é `Test.Start-GuestOS.psm1`. O hífen faz o nome-base parecer
um cmdlet -- essa é a FUNCIONALIDADE: `grep -l Test.Start-GuestOS` encontra
o único arquivo-fonte que define o bloco de mesmo nome no painel,
e o operador que segue o link a partir da interface de status chega ao
arquivo correto. Se adicionar um despachante irmão (por exemplo,
Start-GuestRepair), seguir a mesma forma: um cmdlet exportado,
nome do arquivo = "Test.<cmdlet>".

<a id="4213a0b3-017b"></a>

## test/modules/Test.Start-GuestOS.psm1: Start-GuestOS

Substituições de variáveis em cascata pelo planejador (Test.SequencePlanner ->
Invoke-Sequence). Encaminhadas a cada chamada de Invoke-SequenceByName
para que a substituição `variables.username` da carga de trabalho alcance a
base `start.*.yml`, apesar de a base declarar seu próprio
valor padrão.
IDictionary (não [hashtable]) preserva a ordem de inserção
[ordered]@{} do planejador durante a vinculação de parâmetros, para que
`${username}` seja resolvido antes de `${currentPassword}` no
laço posterior de expansão de Invoke-Sequence.

<a id="4213a0b3-017c"></a>

## test/modules/Test.Status.psm1: Reset-StatusDocumentForCycleStart

O status.json anterior não pode ser analisado -- preservar a cópia
corrompida sob um nome com timestamp, para que um operador (ou mecanismo de correção)
possa compará-la ao documento novo, em vez de encontrar apenas
contadores zerados silenciosamente. O timestamp tem precisão de milissegundos para
tolerar rotações no mesmo segundo (disputa entre escritas com
o status service). Emitir um evento NDJSON no ndjson do ciclo
atual, para que painéis / mecanismos de correção autônomos vejam
a lacuna explicitamente, em vez de inferi-la pela ausência de uma
entrada do histórico.

<a id="4213a0b3-017d"></a>

## test/modules/Test.Status.psm1: New-CycleHistoryEntry

Agregação por sequência, paralela a guestSummary. A tabela Recent
Cycles do painel renderiza um botão por sequência (as entradas
de test.runner.yml que este ciclo executou), cada um com link para a pasta
de resultados daquela sequência. Construída a partir de sequences[] ordenado do ciclo,
unido ao status por convidado e à URL da pasta já coletados em $guestSummary. A
ordem de status reproduz aggregateStatus do painel
(fail > running > pass > skipped > pending), para que o indicador da linha de sequência
corresponda ao cartão de sequência Latest Cycle. Uma sequência 1:1 aponta diretamente
à pasta por VM de seu convidado; uma sequência que se expande para >1 convidado
aponta à pasta do ciclo, para que toda subpasta de convidado continue acessível.

<a id="4213a0b3-017e"></a>

## test/modules/Test.Status.psm1: New-CycleHistoryEntry

Entradas do histórico têm seu PRÓPRIO instantâneo gitCommits, para que uma linha
escrita meses atrás ainda aponte aos commits corretos do framework e do projeto,
mesmo que o executor tenha recebido uma nova URL de repositório ou
adicionado/removido um clone de projeto desde então. O painel os renderiza como
SHAs com links separados por vírgula (framework primeiro, projeto depois).
cycleFolderUrl também é capturado, para que o link do identificador de ciclo na linha do histórico
sobreviva mesmo após o $Doc ativo avançar para o próximo ciclo.
totalDurationSeconds contém os segundos de tempo real do ciclo; o painel
já deriva isso de startedAt/finishedAt durante a renderização, portanto o
campo é adicional -- seu propósito é permitir que uma análise programática de tendência
(jq / Python) leia um número diretamente sem analisar novamente
timestamps ISO.

<a id="4213a0b3-017f"></a>

## test/modules/Test.Status.psm1: Write-StatusJson

Nome temporário único por escritor: os processos do executor e do status-service
gravam status.json; portanto, um "$File.tmp" fixo compartilhado
permite que Move-Item de um processo renomeie o temporário parcialmente escrito pelo outro.
Um sufixo PID+GUID mantém privado o temporário de cada escritor; a renomeação para
o caminho final permanece atômica. O sufixo termina em .tmp, para que as regras existentes
de limpeza/ignorar *.tmp continuem correspondendo.
Escrita atômica de temporário e renomeação pela primitiva compartilhada: garante ausência de BOM
(Set-Content -Encoding utf8 emite um em PS5.1, e um BOM inicial quebra
fetch().json() no navegador) e mantém a segurança de concorrência do nome temporário
por PID em um lugar. -Compress:$false preserva a forma formatada em disco;
-Depth 10 corresponde ao aninhamento do documento.

<a id="4213a0b3-0180"></a>

<a id="testmodulesteststatuspsm1-a-debug-testsequence-run-either-owns-statusjson-standalone-or-the-outermost"></a>

## test/modules/Test.Status.psm1: Uma execução de Debug-TestSequence controla status.json ou executa aninhada

Uma execução de Debug-TestSequence ou CONTROLA status.json (independente, ou a orquestração
mais externa), ou executa ANINHADA na árvore de processos de outra execução -- uma
etapa de ação do hospedeiro que chama novamente Debug-TestSequence.ps1 em um pwsh filho (por exemplo,
Set-Resource.ps1 distribuindo construções de convidados por estágio). Exatamente UM processo --
o mais externo -- controla o documento de nível superior (guests[]/sequences[]/history +
Reset/Initialize/Complete-Run). Uma execução aninhada NUNCA reinicia o documento: ela conecta
um nó ao mapa `nested` (nodeId -> nó) e atualiza APENAS seu próprio nó.

O controle é dividido por chave JSON: o proprietário escreve tudo EXCETO
`nested`; uma execução aninhada escreve APENAS `nested[<its id>]`. Ambos escrevem o
arquivo inteiro, portanto ambos fazem sua leitura-modificação-escrita sob um bloqueio compartilhado
do arquivo de status (Enter/Exit-StatusLock) -- o proprietário relê `nested` antes da gravação
(Write-StatusJson, condicionado a $script:PreserveNested), e um escritor aninhado
relê o documento inteiro antes de tocar em seu nó. Nenhum pode perder a seção do
outro. O único sinal "estou aninhado?" é o identificador herdado
$env:YURUNA_CYCLE_CONTEXT; sua ausência == proprietário independente.

<a id="4213a0b3-0181"></a>

## test/modules/Test.Status.psm1: Get-CycleContext

cycleStartUtc é publicado como texto e retorna como [DateTime]:
o leitor JSON promove qualquer valor com formato ISO-8601. Converter esse
objeto para [string] o renderiza na cultura atual do processo; portanto,
a chave de correlação que uma execução aninhada grava em seus eventos e nós de status
deixa de corresponder àquela escrita pelo proprietário -- as duas descrevem o
mesmo instante em duas notações diferentes, e toda junção por elas
retorna silenciosamente nada. Normalizar novamente no único ponto em que
a conversão ocorre, para que os chamadores continuem recebendo a string que publicaram.

<a id="4213a0b3-0182"></a>

## test/modules/Test.Tesseract.psm1: Invoke-TesseractOcr

--psm 6 é essencial: todos os modos de segmentação de página vizinhos
descartam silenciosamente texto em capturas de terminal. Justificativa completa,
modo a modo: docs/ocr.md#why-tesseract-runs-at---psm-6

Capturar stdout e stderr em uma única passagem. 2>&1 mescla stderr do tesseract
(mostrado como objetos ErrorRecord) ao fluxo de sucesso, para que uma
falha possa ser diagnosticada pelo stderr DESTA execução -- executar tesseract novamente para
obter stderr poderia divergir (a imagem pode ter mudado ou sido excluída
entre execuções) e duplica a inicialização do processo. $LASTEXITCODE sobrevive à
atribuição de variável (sem pipeline) e é capturado imediatamente.

$PSNativeCommandUseErrorActionPreference é fixado em $false neste escopo para que
uma saída de tesseract diferente de zero alcance o ramo explícito abaixo, em vez de
lançar uma NativeCommandExitException isolada que ignora a mensagem
de diagnóstico (a preferência é $false por padrão, mas um chamador ou perfil pode ativá-la
sob EAP=Stop; ver feedback_winget_self_upgrade_kills_running_pwsh para
a classe de proteção).

<a id="4213a0b3-0183"></a>

## test/modules/Test.Transport.psm1: Send-TextVNC

Empiricamente, o QEMU VNC do UTM NÃO ativa Shift automaticamente apenas pelo keysym
(por exemplo, `asterisk` chega como `8`, `bar` chega como `\`); portanto, precisamos
pressionar LShift por conta própria. 20ms pressionado / 10ms solto foi testado sem falhas
nos convidados suportados e corresponde à estabilização de Shift em códigos de varredura
agrupados de Send-TextHyperV. Se um convidado futuro apresentar regressão, o
aviso "VNC text send: failed" do log do ciclo é o gatilho -- uma
janela maior (por exemplo, 80/40) é a alternativa conservadora.
Movido para fora do try para que finally sempre possa referenciar $shiftSym.

<a id="4213a0b3-0184"></a>

## test/modules/Test.Transport.psm1: Send-TextVNC

Soltar o que ainda estava pressionado. Este trecho é alcançado quando o laço é interrompido
entre pressionar e soltar uma tecla -- um erro de transporte no meio do envio
ou Ctrl-C do operador (PowerShell também executa finally quando o pipeline
é interrompido). Não fazer nada aqui transforma uma falha de um caractere
em um console que repete automaticamente esse caractere até a VM ser
reconstruída. Melhor esforço: se o socket foi o que quebrou, essas escritas
também lançam exceções, e ignorá-las mantém a falha original --
já informada acima -- como a que o chamador vê.

<a id="4213a0b3-0185"></a>

<a id="testmodulestesttransportpsm1-utm-keystroke-transport-applescript-chords--jxacgevent-text"></a>

## test/modules/Test.Transport.psm1: Transporte de teclas UTM: combinações AppleScript e texto JXA/CGEvent

VNC (Connect-VNC + Send-TextVNC, o caminho usado pelo UTM) não funciona aqui.
Empiricamente, o QEMU gerenciado por libvirt no Ubuntu 24.04 aceita nossa conexão TCP
e emite sua saudação 'RFB 003.008', depois encerra a conexão
imediatamente após escrevermos a versão do cliente -- antes de qualquer negociação de autenticação ou
tipos de segurança. O QEMU do UTM não faz isso. Em vez de investigar a
diferença de negociação entre libvirt e QEMU independente, KVM evita VNC completamente.
O texto normalmente usa um único processo filho do Python do sistema, com execução
limitada, e uma única conexão libvirt; a ausência do interpretador ou da integração
Python com libvirt permite o fallback `virsh send-key`. Um envio por libvirt que
falhe ou seja interrompido nunca é repetido. Ambos os caminhos evitam as partes
variáveis de endereço de escuta, descoberta de porta e versão RFB do VNC.

O fallback `virsh send-key <domain> [keycode...]` aceita nomes de eventos de entrada
do Linux (KEY_A, KEY_LEFTSHIFT, KEY_ENTER, ...) e os envia como uma combinação
(todos pressionados simultaneamente, depois soltos). Ambos os caminhos de texto
enviam uma combinação por caractere; caracteres que exigem Shift tornam-se uma
combinação de 2 teclas. O caminho preferencial por libvirt usa valores numéricos
PS2-Char / PS2-Named; os caminhos de texto de fallback e de teclas nomeadas usam
KVM-Char / KVM-Named. Esses mapas ficam em Test.KeyCodeRegistry.

<a id="4213a0b3-0186"></a>

## test/modules/Test.Transport.psm1: Send-KeyKvm

Primeiro o mapa de combinações (KVM-Chord), depois o mapa de nomes (KVM-Named). Qualquer coisa
ausente de ambos passa literalmente, para que uma sequência possa escrever KEY_LEFTMETA,
KEY_F2 etc. diretamente.

`virsh send-key` pressiona simultaneamente todos os códigos de tecla posicionais e
os solta juntos; portanto, uma combinação é apenas uma lista de argumentos
com vários elementos -- deve ser EXPANDIDA como argumentos, não convertida em string, ou os dois nomes se reduzem
a um único argumento não reconhecido.

<a id="4213a0b3-0187"></a>

## test/modules/Test.Transport.psm1: Send-TextHyperV

Estabilização após o lote: linear na quantidade de caracteres até um teto. O
controlador PS/2 esvazia sua fila de forma assíncrona; portanto, sem uma espera, a
próxima ação (Enter, captura de tela) pode observar um campo parcialmente digitado.
Fórmula: min($DefaultSettleMs, $CharDelayMs * $charCount).
$DefaultSettleMs (padrão de 200 ms) é o teto empírico que
cobriu todos os esvaziamentos de solicitação de login medidos neste hardware;
ajustar por vmCommunication.settleMs de test.config.yml para convidados
que precisam de mais (agetty lento) ou menos (KVM/SeaBIOS, onde o
buffer é mais rápido).

<a id="4213a0b3-0188"></a>

## test/modules/Test.Transport.psm1: Send-TextUTM

Decodificação opcional no lado do shell. Quando ativada E Text contém caracteres
que precisam de Shift após o remapeamento do teclado numérico (letras maiúsculas e
pontuação com Shift diferente de '*' / '+'), reescreve Text como
um invólucro eval em duas etapas, para que a solicitação bash no convidado
decodifique os caracteres com Shift a partir de escapes \xNN. Desativada por padrão: em
solicitações de login/senha, não há shell para decodificar o invólucro,
portanto os chamadores nesses contextos (Send-Text via passwdPrompt) NÃO devem
passar essa opção.

<a id="4213a0b3-0189"></a>

<a id="testmodulestestvmutilitypsm1-testyurunadirpsm1-owns-envyuruna_runtime_dir--initialize-yurunaruntimedir"></a>

## test/modules/Test.VMUtility.psm1: Test.YurunaDir.psm1 controla $env:YURUNA_RUNTIME_DIR e Initialize-YurunaRuntimeDir

Test.YurunaDir.psm1 controla $env:YURUNA_RUNTIME_DIR + Initialize-YurunaRuntimeDir;
importar aqui para que Get-PortMapStatePath possa resolver o arquivo de estado mesmo quando
um chamador não inicializou todo o caminho do executor. -Global para que um chamador
que já importou Test.YurunaDir em sua própria sessão continue vendo
Initialize-YurunaRuntimeDir depois -- uma reimportação com -Force sem
-Global remove a vinculação do chamador para o escopo privado de Test.VMUtility,
exatamente o que quebrou Start-StatusService.ps1 com "Initialize-
YurunaRuntimeDir is not recognized".

<a id="4213a0b3-018a"></a>

<a id="testmodulestestvmutilitypsm1-releasing-a-lease-is-an-optimization-and-can-always-miss-the-bound-is-what"></a>

## test/modules/Test.VMUtility.psm1: Liberar uma concessão é uma otimização; o limite decide se uma concessão longa é tolerável

Liberar uma concessão é uma otimização e sempre pode falhar; o LIMITE é o que
decide se uma concessão longa é tolerável. O limite diz que um convidado solicita um
novo endereço apenas quando sua identidade é nova -- portanto, a forma de testá-lo é
reconstruir a mesma identidade e verificar se o mesmo endereço retorna.

Deliberadamente observado, não configurado. Uma vinculação presente e uma vinculação que o
servidor respeita parecem idênticas nos próprios arquivos do convidado, e apenas uma delas
impõe um limite a algo. Isso mede o resultado, que é a metade que não pode ser
simulada por uma configuração aparentemente correta.

<a id="4213a0b3-018b"></a>

## test/modules/Test.VMUtility.psm1: Remove-GuestVMQuietly

Ler o endereço ANTES da liberação: um convidado que acabou de devolver sua
concessão já não tem uma para informar; portanto, perguntar depois
não mediria nada justamente nos convidados que se comportaram corretamente.

Identificado pelo nome que a VM tem na DESMONTAGEM, a identidade mais próxima
disponível aqui, que não é exatamente aquela da qual o MAC é derivado
(essa é o hostname cloud-init declarado pela sequência, que esta
camada nunca vê). A aproximação é segura na direção
relevante: um convidado construído e promovido da mesma forma em cada ciclo termina com
o mesmo nome, portanto iguais são comparados com iguais. Quando um hostname é
compartilhado entre níveis de uma cadeia, vários nomes mapeiam para um endereço, e
cada um simplesmente é lido como limitado -- linhas extras, nenhum falso alarme. Chamadores
que CONHECEM a identidade de toda a vida da VM devem passá-la como -Identity.

<a id="4213a0b3-018c"></a>

## test/modules/Test.VMUtility.psm1: Update-StashServiceMarkerAddress

Um endereço candidato precisa ser COMPROVADO antes de ser anunciado. Nos
primeiros segundos de vida de uma VM recém-construída, o convidado ainda não concluiu
DHCP, e macOS registra toda concessão sob o nome enviado pelo convidado e
nunca limpa -- portanto, o arquivo de concessões ainda contém blocos registrados sob o nome
desta VM por suas encarnações anteriores. Get-VMIp então retorna o
endereço de um antecessor morto, sintaticamente perfeito, na rede local e
indistinguível de uma resposta boa. Aceitar a primeira resposta não vazia
consome todo o orçamento de consulta na primeira tentativa e publica a
encarnação anterior, à qual o link direto do painel aponta
pelo restante do ciclo.

Uma resposta de /healthz é o que separa os dois; portanto, a consulta continua
até que um candidato comprove ser um stash service. O endereço real aparece
em segundos após a concessão ser emitida.

<a id="4213a0b3-018d"></a>

## test/modules/Test.VMUtility.psm1: Update-StashServiceMarkerAddress

Apenas 'offsegment' recusa. 'unknown' (nenhuma rota resolvida, nenhuma máscara
disponível) não prova nada e não deve retirar um serviço em funcionamento, e
um laboratório cujo stash realmente fica em outra sub-rede roteada mantém seu
registro no grupo pelo próprio anúncio do daemon.

Resolvido ANTES de dizer qualquer coisa sobre publicar um endereço não confirmado,
porque em um hospedeiro fora do segmento nada é publicado --
anunciar que um endereço será divulgado sem confirmação e depois
retê-lo duas linhas mais adiante descreve um resultado que nunca acontece.

<a id="4213a0b3-018e"></a>

## test/modules/Test.VMUtility.psm1: Update-StashServiceMarkerAddress

Informado uma vez a cada ENTRADA do hospedeiro neste estado, não uma vez por atualização.
Um stash em uma rede privada do hipervisor entra neste ramo em toda
atualização durante a vida da VM -- no caminho por ciclo, isso é um
aviso a cada ciclo, para sempre, sobre uma condição que não mudou
e sobre a qual o operador nada pode fazer durante a execução. Repeti-lo
transforma um aviso real em algo que as pessoas ignoram.

A memória fica no marcador, porque o marcador já é o
arquivo de estado desta função e nada mais sobrevive entre execuções.
poolWithheld registra o resultado; a entrada nesse estado é novidade, o
estado estável posterior não.

<a id="4213a0b3-018f"></a>

## test/modules/Test.VMUtility.psm1: Update-StashServiceMarkerAddress

Informado AQUI, onde o endereço realmente está prestes a ser publicado, e apenas
sobre uma publicação que realmente acontece -- o ramo fora do segmento acima
retorna sem publicar nada, portanto um aviso de falta de confirmação ali
descreveria um resultado que nunca ocorre.

Uma vez por endereço, não uma vez por atualização: publicar um endereço que este hospedeiro
não pôde confirmar merece um aviso, e a atualização por ciclo repete
a mesma publicação não confirmada do mesmo endereço durante todo o tempo que o
daemon leva para ser construído. O endereço já estar no marcador significa que
isso foi informado na primeira publicação e nada mudou desde então.

<a id="4213a0b3-0190"></a>

## test/modules/Test.VMUtility.psm1: Wait-YurunaServiceVmEndpoint

Ainda não vinculado. Estender APENAS com evidência de que o convidado ainda
está trabalhando: cloud-init `running` ou `not started` permite uma extensão,
até o prazo máximo configurado. `done` interrompe a extensão do prazo, mas mantém
a espera dentro do orçamento restante para o daemon vincular sua porta;
os demais status não estendem o prazo.
ERROR de cloud-init é terminal, portanto parar, em vez de cumprir
todo o orçamento. Nada executa cloud-init novamente nesta inicialização: toda
consulta restante faz uma pergunta já respondida, e o
operador observa uma barra de progresso por até mais 45 minutos
antes de receber a informação que o convidado já sabia no segundo minuto. 'done'
deliberadamente continua aguardando -- o daemon ainda pode estar vinculando
sua porta nos segundos após cloud-init terminar.

<a id="4213a0b3-0191"></a>

<a id="testmodulestestwarmresumepsm1-a-checkpoint-names-the-step-that-failed-and-resuming-there-replays-it-against"></a>

## test/modules/Test.WarmResume.psm1: Um ponto de retomada nomeia a etapa que falhou, e retomá-la repete trabalho sobre o convidado parcialmente alterado

Um ponto de retomada nomeia a etapa que FALHOU, e retomá-la repete trabalho sobre
um convidado que essa etapa pode já ter alterado parcialmente: uma instalação que descompactou
antes de sua chamada de rede falhar, um script de dados iniciais que escreveu algumas linhas. A etapa é
elegível para retomada porque sua FALHA foi transitória, o que nada diz
sobre quanto trabalho já foi realizado. Repetir sobre esse resíduo é uma
execução diferente da descrita pela sequência.

loadDiskSnapshot é a única ação que torna conhecido novamente o estado do convidado,
portanto é o único lugar fiel para reiniciar: voltar ao mais recente antes do ponto de retomada
ou exatamente nele, e toda etapa posterior executa contra o estado para o qual foi
escrita. O custo é refazer as etapas intermediárias, a troca que a retomada
com estado existente já faz em relação a uma reconstrução completa a frio.

Sem uma fronteira antes do ponto de retomada ou exatamente nele, não há estado a restaurar.
O ponto de retomada é usado como está apenas quando a etapa com falha somente observa.
Uma etapa que altera estado, uma etapa não classificada ou uma verificação de segurança
indisponível recusa a retomada com estado existente, em vez de repetir sobre o resíduo da tentativa com falha.

<a id="4213a0b3-0192"></a>

<a id="testmodulestestwarmresumepsm1-replaying-the-failed-step-in-place-puts-a-second-run-on-top-of-whatever-the"></a>

## test/modules/Test.WarmResume.psm1: Repetir a etapa com falha no mesmo estado coloca uma segunda execução sobre o que a primeira deixou

Repetir a etapa com falha no mesmo estado coloca uma segunda execução sobre o que a
primeira deixou: um script obtido instalou pacotes e inicializou o estado das
ferramentas, texto digitado permanece parcialmente inserido em uma linha de comando, um snapshot foi salvo.
Ferramentas deliberadamente não idempotentes (o caso canônico é tofu recusar um diretório de trabalho
já inicializado) então falham sobre o resíduo,
não sobre o que interrompeu a tentativa original, e ESSA falha é
a informada.

Quais verbos podem ser repetidos sem dano é um fato sobre cada verbo; portanto, cada um
o declara onde se registra (Register-SequenceAction -ReplaySafety), e
este módulo apenas lê a declaração. Uma lista mantida aqui nomearia os verbos conhecidos quando
foi escrita; um verbo adicionado depois usaria por padrão "pode repetir". Um
verbo não declarado, não registrado ou ilegível é 'unclassified' e conta como
inseguro: para uma proteção, "não consegui determinar" fica do mesmo lado que "inseguro".

<a id="4213a0b3-0193"></a>

## test/modules/Test.YurunaDir.psm1: Get-YurunaHostId

Primeira escrita atômica, compartilhada com Get-PerfHostUuid neste mesmo host.uuid: dois
processos chegando ao primeiro uso juntos gerariam, cada um, um identificador DIFERENTE;
portanto, uma simples sobrescrita deixaria o hospedeiro com duas identidades. A própria criação é
o bloqueio -- FileMode.CreateNew é O_CREAT|O_EXCL no POSIX e CREATE_NEW no
Windows, portanto exatamente um chamador consegue criar o caminho, e todos os
outros adotam o que esse chamador escreveu. Um temporário seguido de renomeação não consegue garantir isso no
POSIX: [System.IO.File]::Move verifica o destino e depois renomeia;
portanto, os concorrentes que passam pela verificação juntos renomeiam com sucesso, o último fica
em disco, e todos os anteriores saem com um identificador que nunca foi persistido.
Uma falha real de persistência é fatal para o chamador (retornar $null, conforme o contrato
OUTPUTS), em vez de fornecer um identificador não persistido que a próxima chamada
silenciosamente geraria novamente como um identificador diferente.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Back to [Yuruna](../../README.md)
