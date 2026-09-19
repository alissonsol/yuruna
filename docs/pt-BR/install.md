<a id="429fb30b-0001"></a>

# Scripts de instalação do Yuruna -- fundamentação

Este arquivo reúne a fundamentação essencial dos três instaladores de
bootstrap:

- [install/windows.hyper-v.ps1](../../install/windows.hyper-v.ps1)
- [install/macos.utm.sh](../../install/macos.utm.sh)
- [install/ubuntu.kvm.sh](../../install/ubuntu.kvm.sh)

Os scripts permanecem deliberadamente pequenos -- cada seção aqui
corresponde a um divisor `# --- REGION: Section name` no corpo do script.
A única linha `# --- REGION: https://yuruna.link/429fb30b` perto
do topo de cada instalador é o ponto de entrada do operador para este
documento; a partir dali, navegue até a seção correspondente ao divisor
acima do código em estudo.

As âncoras permanentes usam a chave do documento mais um sufixo hexadecimal
de quatro dígitos, como `https://yuruna.link/42xxxxxx-yyyy`. Elas permanecem
estáveis quando um título é reformulado.

A mesma convenção `# --- REGION: https://yuruna.link/42xxxxxx-yyyy` é
usada por [memory.md](../memory.md), [definition.md](../definition.md),
[vmconfig.md](../vmconfig.md) e [network.md](../network.md).

---

<a id="429fb30b-0002"></a>

## Todos os hospedeiros (fundamentação compartilhada)

<a id="429fb30b-0003"></a>

### Log de instalação

Cada instalador espelha stdout+stderr em um arquivo de log e no
terminal, para que uma falha no meio da instalação possa ser inspecionada
depois. Os instaladores de shell usam um FIFO e um `tee` em segundo plano
(em vez de `exec > >(tee ...)`) para que o caminho de EXIT possa esperar o
tee esvaziar o buffer, mantendo o arquivo completo mesmo em uma saída
abrupta -- um tee por substituição de processo fica órfão e pode ser morto
antes de esvaziar sua escrita com buffer de bloco. O log é gravado no
local padrão por usuário -- `~/Library/Logs/Yuruna` no
macOS, o diretório de estado `$XDG_STATE_HOME/yuruna/logs`
(padrão `~/.local/state/yuruna/logs`) no
Ubuntu -- recorrendo a `${TMPDIR:-/tmp}`.

No Windows o modo de falha é diferente: a reexecução elevada roda em uma
janela de console SEPARADA que desaparece no instante em que o script
termina ou morre, sem deixar nada na tela para ler. O instalador registra
cada etapa elevada em um arquivo sob um local padrão e descobrível
(`%ProgramData%\Yuruna\logs`, recorrendo a `%TEMP%`). O caminho é gerado UMA vez
e repassado por todas as reexecuções via `-LogPath`, de modo que a linha
impressa antes da reexecução com UAC nomeia exatamente o arquivo que a
janela elevada escreve, e cada etapa acrescenta a esse mesmo arquivo.

<a id="429fb30b-0004"></a>

### Categorias de resultado e o armazenamento de fatos

O `install/setup.ps1` classifica cada etapa em uma de cinco categorias, e
o relatório final imprime todas as cinco:

- **Done** -- a etapa fez seu trabalho e nada ficou pendente.
- **Skipped** -- o operador recusou a etapa. Esta categoria é a que mais
  importa: uma instalação que silenciosamente deixa de fazer algo é lida
  como uma instalação que já fez aquilo.
- **Blocked** -- a etapa não pôde ser executada porque algo de que ela
  precisa falhou. Mantida separada de Skipped para que uma cascata nunca
  seja lida como uma decisão -- uma etapa bloqueada por uma falha anterior
  é um fato diferente sobre a máquina do que uma etapa que o operador
  recusou.
- **Warned** -- o meio-termo para o qual as outras quatro não têm espaço:
  a etapa fez seu trabalho e algo que ela não pode corrigir sozinha
  continua pendente (uma concessão de TCC exige encerrar o terminal; um
  Mac sem tampa nunca expõe todas as proteções do pmset). Sem ela, as
  únicas codificações honestas restantes são um PASS que esconde a
  condição e um FAIL sem caminho para o verde.
- **Failed** -- a etapa foi tentada e não funcionou.

Ao lado das categorias, um armazenamento de fatos registra o que as
etapas posteriores têm permissão de assumir. Cada fato tem TRÊS valores
de propósito: `ok`, mais as duas maneiras pelas quais um fato pode estar
ausente -- `declined` (ninguém pediu por ele) e `failed` (tentado, não
funcionou). Um booleano colapsa esses dois, e o colapso imprime "a
prerequisite failed" para uma execução em que o operador escolheu não ter
a coisa.

<a id="429fb30b-0005"></a>

### Divisão em dois repositórios

O instalador é distribuído em DOIS repositórios que compartilham o mesmo
script:

- público `https://github.com/alissonsol/yuruna`       (o clone funciona sem autenticação)
- privado `https://github.com/alissonsol/yurunadev`    (o clone exige autenticação no GitHub)

A cópia de cada repositório aponta o padrão de `$YurunaRepo` /
`$YURUNA_REPO` para sua PRÓPRIA URL, de modo que o comando de uma linha
`irm | iex` (ou `curl | bash`) clona o repositório de onde o operador
baixou o script. Ambas as constantes permanecem definidas
independentemente de qual cópia é executada, para que a lógica de checkout
existente abaixo possa reconhecer o remoto do qual uma execução anterior
clonou -- e pular um pull que ficaria travado esperando por credenciais do
GitHub que esta execução não tem.

<a id="429fb30b-0006"></a>

### Fixação de release + integridade assinada

`VERSION` (CalVer puro, `YYYY.MM.DD`) é a fonte da verdade para as releases.
No momento da release, o `tools/Update-YurunaReleasePins.ps1` regenera
`install/install.sha256`, o assina (`install/install.sha256.sig`, RSA-4096),
executa o gate ASCII/sem-BOM como pré-condição obrigatória e atualiza a única
tag ainda fixada em uma URL -- o caminho de download verificado do README --
de modo que o trabalho por release seja apenas: atualizar `VERSION`, rodar o
script, criar a tag. Os instaladores não carregam versão embutida; eles leem
`VERSION` no momento da instalação.

O PADRÃO do clone permanece no branch móvel `main`, então uma instalação
normal **atualiza o framework automaticamente a cada ciclo** (o `git pull
--ff-only` por ciclo do executor avança o branch de rastreamento). Para
congelar um hospedeiro na release atual, passe `-PinVersion` (Windows) /
`PIN_VERSION=1` ou `--pin-version` (macOS, Ubuntu): após clonar, o
instalador lê o arquivo `VERSION` do repositório e faz o checkout dessa tag
como HEAD destacado, que o pull por ciclo deixa intocado (sem upstream ->
no-op). Um `-YurunaBranch <tag>` / `YURUNA_BRANCH=<tag>` explícito fixa em
qualquer release específica.

Os comandos de uma linha por conveniência permanecem em `refs/heads/main`
(mais recente, NÃO VERIFICADO). O caminho de instalação **verificado** --
baixar o instalador + `install.sha256` + `.sig` + a chave pública
empacotada, verificar a assinatura (`openssl` no macOS/Linux, .NET no
Windows PowerShell), depois o hash, depois executar -- está documentado em
[install/README.md](../../install/README.md); a impressão digital da chave de
assinatura está em [install/keys/README.md](../../install/keys/README.md).

<a id="429fb30b-0007"></a>

### Tolerância a uma referência de tag com prefixo v

As tags canônicas de release do Yuruna são **CalVer puro** (`YYYY.MM.DD`,
sem `v`), e a ferramenta de release (`tools/Update-YurunaReleasePins.ps1`)
valida `VERSION` como CalVer puro e se recusa a criar uma variante com `v`.
Um humano, uma ferramenta ou um argumento `-YurunaBranch` /
`YURUNA_BRANCH=` ainda pode pedir a forma errada, e uma referência com
prefixo `v` não resolve quando existe apenas a tag CalVer pura.

Por isso, cada instalador passa a referência solicitada por um resolvedor
(`Resolve-YurunaRef` / `resolve_yuruna_ref`) antes de clonar ou fazer
checkout:

- Uma referência que não tem formato CalVer (`main`, um nome de branch)
  passa inalterada -- não há variante a tentar.
- Uma referência em formato CalVer que resolve no remoto é preferida como
  foi digitada.
- Uma referência em formato CalVer que NÃO resolve, mas cuja variante com
  `v` alternado resolve, é trocada pela variante com um aviso, de modo que
  a divergência se autocorrige em vez de fazer o clone falhar.
- Quando nenhuma das formas resolve, o instalador avisa que a tag da
  release fixada provavelmente ainda não foi publicada (`VERSION` e a
  fixação do instalador ficaram à frente da tag) e retorna a referência
  inalterada, para que a falha nomeie a causa real. A saída de emergência
  do operador é `-YurunaBranch main` / `YURUNA_BRANCH=main`.

Nos instaladores de shell, o resolvedor retorna a referência na **stdout**,
então todo aviso é escrito na stderr -- caso contrário o texto do aviso
seria capturado em `YURUNA_BRANCH` junto com a referência.

<a id="429fb30b-0008"></a>

### O repositório de desenvolvimento acompanha o main mais recente

O repositório privado de desenvolvimento (`yurunadev`) só recebe tag na
release semanal, então no meio da semana seu padrão de CalVer fixado não
resolve para nada. Quando o basename do remoto de destino é `yurunadev` e o
operador **não** fixou uma referência explicitamente, o instalador
acompanha `main` (código mais recente) em vez da tag de release. Por isso
cada instalador registra logo no início se a referência foi fornecida
explicitamente (`$script:YurunaBranchExplicit` / `YURUNA_BRANCH_EXPLICIT`),
em vez de comparar com o valor padrão depois; um pedido explícito
sempre vence esse fallback.

<a id="429fb30b-0009"></a>

### Preflight de requisitos de sistema

Linhas de base testadas:

- Hospedeiro Windows: 32 GB de RAM, 512 GB livres no drive do sistema, Windows 11
  Pro/Enterprise/Education ou Windows Server com Hyper-V em AMD64 ou
  ARM64, 16+ núcleos físicos.
- Hospedeiro macOS: 32 GB de RAM, 512 GB livres, macOS 26+ em arm64, 16+ núcleos.
- Hospedeiro Ubuntu: 32 GB de RAM, 512 GB livres, Ubuntu 26+ em amd64, 16+ núcleos.

Qualquer coisa abaixo disso é permitida, mas NÃO TESTADA -- o script
pergunta ao operador antes de prosseguir, para que um hospedeiro abaixo das
especificações não queime uma hora de instalações só para falhar no
primeiro ciclo de testes. A contagem de núcleos físicos é a exceção no
Windows: ela é reportada como recomendação e nunca pergunta nada, porque um
hospedeiro abaixo de 16 executa o harness corretamente, apenas mais devagar, e
nenhuma máquina Windows ARM64 chega a 16. Fora isso, a verificação é
silenciosa quando todos os requisitos são atendidos. No Windows ela é
controlada por `-SkipPreflight` para que as reexecuções internas (elevação
por UAC, bootstrap PS5->PS7) não perguntem de novo.

<a id="429fb30b-000a"></a>

### Pare os processos do Yuruna em execução antes de atualizar

As reexecuções do instalador precisam poder atualizar no lugar os pacotes
instalados e o repositório. Uma execução de testes ou um serviço de status
do Yuruna ativo brigaria com a atualização pela árvore de trabalho e pela
porta 8080. O instalador força a parada do executor externo, do pwsh
interno de cada ciclo e do servidor HTTP de status desacoplado, e então
ESPERA que eles saiam antes que a atualização do repositório renomeie o
checkout para o lado -- a renomeação falha enquanto qualquer um deles ainda
mantiver um handle dentro da árvore.

Os alvos são coletados de três canais, unidos para que um serviço seja
capturado mesmo quando um dos canais o perde:

1. Os arquivos de PID que o próprio executor/servidor escrevem
   (`runner.pid`, `inner.pid`, `server.pid` sob o diretório de runtime).
   São autoritativos e legíveis mesmo quando a linha de comando do
   processo não é -- no Windows, um executor iniciado sob outra conta (por
   exemplo, um usuário dedicado "Yuruna Test") reporta um
   `Win32_Process.CommandLine` VAZIO para o instalador, então a varredura
   por linha de comando (canal 2) silenciosamente o ignora; o arquivo de
   PID não.
2. Correspondência de padrão na linha de comando -- captura um executor
   ad-hoc iniciado fora do diretório de runtime gerenciado, cuja
   localização do arquivo de PID não pode ser prevista. Os padrões:
   `Start-TestRunner.ps1`, `Invoke-TestRunnerInnerLoop.ps1`,
   `Debug-TestSequence.ps1`, `Start-StatusService.ps1`, mais o nome de
   script gerado do servidor desacoplado, `.status-service.ps1`, que NÃO
   contém "Start-StatusService.ps1".
3. O dono que está escutando na porta de status (a porta configurada mais
   o padrão 8080), para que a porta 8080 seja liberada mesmo se o serviço
   de status tiver sido iniciado de outra maneira.

A espera cobre apenas os PIDs efetivamente parados, não todos os
candidatos. Um candidato que já havia sumido, ou que a validação de
identidade (abaixo) rejeitou, nunca sai por conta do instalador. A porta
8080 é o caso comum: quando ela é mantida pelo `http.sys` em nome de um
listener hospedado por driver, o canal 3 reporta o processo System (pid 4)
como seu dono -- esperar por ele é uma parada garantida de 20 segundos
terminando em um aviso que nomeia um processo que ninguém pode nem deve
parar.

No Windows, todo alvo é encerrado junto com toda a sua árvore de filhos
via `taskkill /T /F`. `/F` é um TerminateProcess forçado -- NÃO o Ctrl+C
suave de console que um `taskkill` simples (ou um `^C` acidental) envia,
que apenas coloca o executor no desligamento gracioso "sair após o ciclo
atual". Esse caminho gracioso pode levar muitos minutos (um ciclo completo
de VM) para realmente sair, e prende o checkout todo esse tempo -- a exata
falha "a instalação prossegue enquanto o executor ainda está de pé" contra
a qual esta etapa protege.

<a id="429fb30b-000b"></a>

### Validação de identidade do PID antes de encerrar

Os PIDs candidatos são deduplicados, o próprio PID do instalador é
descartado, e cada sobrevivente tem sua identidade validada antes que algo
seja encerrado: apenas PIDs cujo executável é um interpretador PowerShell
(`pwsh` / `powershell`) são parados, porque todo alvo real -- o executor
externo, o executor interno de cada ciclo, o serviço de status desacoplado
-- é um processo PowerShell.

Duas maneiras pelas quais um PID inocente chega à lista de candidatos:

- Um arquivo de PID deixado por uma execução que travou guarda um inteiro
  bruto que o kernel pode ter RECICLADO desde então para um processo não
  relacionado; encerrar essa correspondência (no Windows, `taskkill /T /F`
  em toda a sua árvore) derrubaria um processo inocente.
- Nos caminhos de inicialização `bash <(...)` / `-c "<script>"`, o próprio
  texto do script do instalador carrega os nomes de padrão `.ps1` em argv,
  então um padrão de `pgrep -f` pode corresponder a ESTE instalador ou ao
  seu subshell de keepalive do sudo. Encerrar essa correspondência poderia
  ceifar o `tee` do próprio log do instalador (SIGPIPE sem nenhum trap de
  PIPE instalado -- o instalador morre) ou seu keepalive do sudo.

Restringir pelo nome do executável fecha os dois casos: `pwsh` para todo
alvo real; `bash` / `tee` / `sleep` / ... para tudo que NÃO deve ser
tocado. Os instaladores bash leem `ps -o comm=` -- o nome do executável,
NÃO o argv, que o caminho de inicialização contamina com os nomes dos
padrões -- usando `-ww` para que o `ps` do BSD/macOS não trunque a saída
quando nenhum TTY está anexado (a classe de armadilha
`feedback_bsd_ps_args_truncation`). Um `comm` vazio para um pid VIVO
significa que o `ps` não conseguiu reportá-lo; o pid é mantido em vez de
desabilitar silenciosamente a parada (uma degradação para o comportamento
anterior à validação). Isso espelha a verificação de identidade de PID do
lado PowerShell (a proteção de pid obsoleto do `Start-TestRunner.ps1`).

<a id="429fb30b-000c"></a>

### Preservar a VM yuruna-caching-proxy-service

A VM de cache (`yuruna-caching-proxy-service`) guarda dezenas
de GB de conteúdo `.deb` / `.iso` pré-buscado, acumulado ao longo dos
ciclos de teste. O instalador nunca para VMs do Hyper-V (nenhum `Stop-VM` /
`Remove-VM` em qualquer instalador), então o cache sobrevive às
reexecuções por padrão.

A etapa de parada de processos acima também não alcança as VMs: no Windows
cada VM roda sob um processo worker `vmwp.exe` cujo pai é o serviço de
gerenciamento do Hyper-V (`vmms`), e não um filho do executor, então o
encerramento da árvore de processos do `taskkill /T` nunca a alcança. No
macOS e no Ubuntu, os domínios do UTM / libvirt também não são filhos do
executor, e esses instaladores não emitem nenhuma parada/destruição de
domínio (o encerramento do UTM no macOS é controlado separadamente pela
preservação do cache, abaixo).

No macOS a detecção usa dois sinais: uma sonda de conexão TCP ao IP do
cache registrado na porta 3128 (autoritativa, independente de Apple Events)
e uma análise de fallback do `utmctl status` que trata todo status incerto
como "preservar". A sonda é o sinal que sobrevive a uma inicialização não
gráfica (SSH, sem Apple Events). O `utmctl status` sozinho não basta: por
SSH ele responde `utmctl could not reach UTM`, e ler isso como "não está
rodando" encerra o UTM e deixa a varredura de bundles órfãos apagar o cache.

Se o cache estiver rodando OU se seu estado for incerto, o instalador do
macOS pula a atualização do cask do UTM, para que uma janela de UTM
encerrado não permita que a varredura de bundles órfãos apague o spool
Squid de vários GB.

<a id="429fb30b-000d"></a>

### Renomeação de diretório que continua sendo uma renomeação

O `Move-Item` degrada uma renomeação de diretório que falha em uma cópia
recursiva seguida de exclusão -- é assim que ele suporta movimentações
entre volumes. Apontado para um checkout que está aberto, ele copia parte
da árvore (`.git` incluído) para o nome de destino, apaga os originais que
copiou e então falha no primeiro arquivo que não consegue tocar: uma árvore
de trabalho destruída, reportada como "the item is in use". Por isso, toda
movimentação de diretório no instalador do Windows passa por
`Move-YurunaDirectory`, um wrapper fino sobre
`[System.IO.Directory]::Move`, que é uma renomeação e nada mais -- ou ele
tem sucesso, ou lança uma exceção com ambos os caminhos exatamente como
estavam. Todo destino é irmão de sua origem, então a restrição de mesmo
volume do `[System.IO.Directory]::Move` nunca se aplica.

<a id="429fb30b-000e"></a>

### Checkout não mantido aberto

O resgate de não-ff abaixo precisa renomear o checkout para o lado, e no
Windows um diretório não pode ser renomeado enquanto algum processo mantém
um handle dentro dele -- na maioria das vezes um shell parado dentro da
árvore (seu diretório de trabalho a prende), ou um editor ou uma janela do
Explorer com a pasta aberta. Essa falha só apareceria depois das
instalações via winget, da habilitação do Hyper-V e do backup de
`test/status` -- minutos de espera por um surpreendente aborto "item is in
use". O instalador do Windows sonda isso logo no início com a mesma
operação que o resgate usa -- uma renomeação para o irmão
`<dir>.locktest` -- e, se passar, renomeia de volta, sem perturbar nada.

Além de nunca copiar (a sonda renomeia através de `Move-YurunaDirectory`;
veja [Renomeação de diretório que continua sendo uma renomeação](#renomeação-de-diretório-que-continua-sendo-uma-renomeação)),
duas propriedades impedem que a sonda custe mais do que ela reporta.

**Ela tira o diretório de trabalho do PROCESSO de dentro da árvore, não
apenas a localização do PowerShell.** Um processo mantém um handle aberto
em seu próprio diretório atual, e esse handle prende todos os pais contra
renomeação. O `Set-Location` move apenas a localização do PowerShell; o
diretório de trabalho no nível do SO com o qual o processo foi iniciado
permanece onde está, e a reexecução elevada o herda. Como a maneira
documentada de rodar o instalador é de dentro do checkout
(`install\windows.hyper-v.ps1`), mover apenas a localização do PowerShell
deixa o instalador como o único processo bloqueando sua própria
atualização -- uma falha autoinfligida em toda execução.
`[System.IO.Directory]::SetCurrentDirectory` no diretório pai do checkout
o libera.

**Uma sonda que falha avisa; ela não aborta.** Só o resgate por reclone
precisa da renomeação. Um checkout que outra coisa mantém aberto ainda se
atualiza normalmente via `git pull`, então a sonda reporta a condição e a
instalação continua; o caminho de resgate reporta a própria falha se algum
dia for alcançado.

Na entrada, a sonda também repara um `<dir>.locktest` que uma execução
interrompida deixou para trás, em qualquer uma das formas que ele pode
ter: o checkout inteiro sob o nome da sonda (renomeado para o lado, nunca
renomeado de volta) é renomeado de volta, e uma árvore dividida entre os
dois nomes é mesclada de volta sobre o checkout e a sonda é removida. Os
dois lados de uma divisão são disjuntos, exceto pelos arquivos cuja cópia
teve sucesso e cuja exclusão não teve, e esses são idênticos byte a byte.
Esse reparo roda ANTES do retorno antecipado "sem `.git`, nada a mover",
porque qualquer uma das formas pode deixar o próprio `.git` do lado da
sonda -- e um checkout sem `.git` é lido como nunca clonado, o que manda o
caminho de atualização para um `git clone` sobre um diretório não vazio.

<a id="429fb30b-000f"></a>

### Puxar do remoto do repositório local, não do padrão do script

Para um checkout existente, o instalador puxa de qualquer remoto do qual o
repositório local foi clonado -- não do padrão `$YurunaRepo` /
`$YURUNA_REPO` que esta cópia do instalador distribui. Uma execução
anterior pode ter clonado o OUTRO repositório (o checkout público `yuruna`
funciona para todos; o checkout privado `yurunadev` precisa de autenticação
no GitHub) e não podemos migrar silenciosamente a árvore local do operador
para um remoto diferente.

Se o remoto local for `yurunadev`, demonstre acesso antes do `git fetch`:
o `git ls-remote` falha rápido em 401/403, poupando o operador de um
prompt de credenciais travado ou de uma transcrição de erro que parece que
o harness de testes quebrou quando faltava apenas autenticação. O pull é
pulado (não o resto da instalação), para que um contribuidor em uma sessão
instável ou não autenticada ainda consiga continuar iterando com o último
código bom conhecido em disco. `GIT_TERMINAL_PROMPT=0` falha rápido diante
de credenciais ausentes em vez de bloquear o instalador em um prompt
interativo `Username:`.

<a id="429fb30b-0010"></a>

### Backup e reclone em um pull não-ff

Quando o `git pull --ff-only` não consegue avançar o repositório local
(alterações não commitadas, commits divergentes, HEAD destacado), o script
move o checkout existente para o lado como um `<dir>.backup.<stamp>` com
data e hora e reclona do zero, em vez de deixar um estado meio atualizado.
O bloco de resumo final exibe o caminho do backup em destaque para que o
operador possa salvar edições locais antes de apagá-lo. O estado de runtime
de `test/status` já foi capturado no TEMP pelo bloco de preservação acima,
então o histórico de ciclos sobrevive a esse caminho.

<a id="429fb30b-0011"></a>

### Renormalizar as quebras de linha sob .gitattributes

O `.gitattributes` (commitado na raiz do repositório) trava LF para todo
tipo de texto que um convidado Linux lê -- `*.sh`, `*.yml`, `user-data`,
`meta-data`, etc. Adicionar o `.gitattributes` NÃO reescreve os arquivos
que já estão na árvore de trabalho: sem esta etapa, um desenvolvedor que
clonou com `core.autocrlf=true` continua com o `fetch-and-execute.sh` em
disco como CRLF, o serviço de status do hospedeiro serve esses bytes fielmente ao
convidado, e o bash do convidado engasga com `$'\r': command not found` na
linha 2. O instalador força uma reconstrução única da árvore de trabalho a
partir do índice, para que cada arquivo pegue as regras de `eol=`.

`core.autocrlf=input` também é fixado no repositório LOCAL, para que
qualquer arquivo futuro adicionado sem uma regra correspondente no
`.gitattributes` ainda evite CRLF no commit. A configuração local vence a
global; a mudança não toca os outros repositórios do usuário.

O `.gitconfig.yuruna` (versionado na raiz do repositório) é incluído via
`include.path = ../.gitconfig.yuruna` para os padrões de `pull.rebase` +
`rebase.autoStash`, de modo que o `git pull` aqui faça rebase em vez de
criar commits de merge. O `include.path` pode ter múltiplos valores, então
a inclusão é adicionada de forma idempotente em vez de sobrescrever o que
mais o operador possa ter incluído.

Se a árvore de trabalho tiver alterações não commitadas, apenas o índice é
renormalizado (`git add --renormalize .`), para que o instalador não
atropele as edições locais. Caso contrário, o índice é esvaziado e o `git
reset --hard HEAD` reconstrói cada arquivo sob o `.gitattributes` atual.

<a id="429fb30b-0012"></a>

### Preservar o estado de runtime de test/status na atualização do clone

Reexecutar o instalador em um hospedeiro que vem executando ciclos de teste não
pode perder o histórico do dashboard, as transcrições de log de cada ciclo
nem o estado do diretório de runtime (`status.json` com `history[]`,
`runner.gating.json`, `runner.quarantine.json`, `runner.pid`, flags de
controle). Nada disso é rastreado pelo git -- conforme o `.gitignore`, todo
subdiretório sob `test/status/` é ignorado como estado de runtime. O bloco
de clone/atualização/renormalização deixa os arquivos não rastreados em paz
(`git rm -r --cached . && git reset --hard HEAD` só toca os arquivos
rastreados), mas o instalador reforça esse contrato com um snapshot e uma
restauração explícitos, para que uma
regressão futura na lógica de renormalização, ou uma exclusão manual de
`$YurunaDir` entre tentativas, não possa apagar silenciosamente semanas de
histórico de ciclos.

Todo o estado de runtime do harness fica sob `test/status/<sub>/`:
`runtime/`, `perf/`, `log/`,
`extension/`, `captures/`, `ssh/`. O instalador preserva todos os
subdiretórios, para que o histórico de ciclos, o JSONL de perf, o estado do
cofre, as capturas de treinamento/sequência e o par de chaves SSH gerado
sobrevivam todos a um clone/atualização.

<a id="429fb30b-0013"></a>

### A redefinição para a linha de base remove as VMs test-*

Uma instalação é uma operação de retorno à linha de base. Os processos do
serviço de status + executor são encerrados antes (`stop_yuruna_processes` /
`Stop-YurunaProcess`); suas VMs não. O `test/Remove-TestVMFiles.ps1`
enumera as VMs que correspondem ao prefixo `test-` e para + remove cada uma.
A VM `yuruna-caching-proxy-service` NÃO corresponde a esse prefixo e é
preservada. Uma falha aqui não é fatal -- um auxiliar de hipervisor travado
ou um arquivo de imagem bloqueado em uma VM não pode bloquear o resto da
instalação. A etapa roda DEPOIS da atualização do repositório, para que
usemos a versão recém-puxada do script e de seus módulos de driver de hospedeiro.

No Ubuntu, a ativação de grupo exige cuidado: `usermod -aG libvirt $USER`
adiciona o usuário a `/etc/group`, mas o conjunto de grupos efetivo do
shell ATUAL foi amostrado no login e não incluirá `libvirt` até um novo
login ou um `newgrp`, então o `virsh` falha com "Permission denied" em
`/var/run/libvirt/libvirt-sock` logo na primeira vez após a adição ao
grupo. Por isso a limpeza roda sob `sg libvirt` -- veja
[sg libvirt para a limpeza da primeira execução](#sg-libvirt-para-a-limpeza-da-primeira-execução).

<a id="429fb30b-0014"></a>

### Varredura de artefatos de root — o que uma execução com sudo deixa para trás

Os pontos de entrada se recusam a rodar como root, mas recusar só impede a
PRÓXIMA execução como root -- isso não faz nada quanto à máquina que uma
execução ANTERIOR já alterou, e esse estado é silencioso, duradouro e
parece bug de outra pessoa. Por isso o `install/setup.ps1` faz uma
varredura atrás dele através de
[`test/modules/Test.RootArtifact.psm1`](../../test/modules/Test.RootArtifact.psm1).

| Artefato | Como ele engana |
|---|---|
| Arquivos sob `test/status` pertencentes ao root | Os diretórios continuam graváveis pelo operador, então criar um arquivo NOVO ainda funciona e só a sobrescrita de um existente falha -- aparecendo como um erro de permissão vindo do código que por acaso o tocou primeiro, nomeando um arquivo json de runtime em vez da execução com sudo que o criou. |
| Um serviço de status ou de configuração ainda escutando como root | Seu socket é invisível para um `lsof` sem privilégios, então a porta é lida como "livre mas impossível de reservar" e toda subida posterior recusa em uma porta que nada parece segurar. |
| Imagens base e bundles de VM sob o home do root | O hipervisor roda como o operador e não consegue alcançá-los, então são puro desperdício -- dezenas de GB dele. |
| Montagens SMB dos compartilhamentos de grupo/stash sob o home do root | No macOS, uma segunda montagem de um compartilhamento que o kernel já mantém é recusada com "File exists", o que o caminho de montagem reporta como falha de credenciais. |

A detecção nunca pergunta e nunca eleva: tudo é ou legível sem privilégios
ou sondado com `sudo -n`, que falha em vez de perguntar. Apenas o
`Clear-YurunaRootArtifact` eleva, e apenas por classe, após consentimento.

Exclusivo de Unix por construção. O setup do Windows roda elevado de
propósito, e uma execução elevada no Windows escreve arquivos que a conta
do operador ainda pode modificar, então não existe armadilha equivalente a
varrer.

<a id="429fb30b-0015"></a>

### Enable-TestAutomation.ps1 NÃO é executado automaticamente

O `host/<platform>/Enable-TestAutomation.ps1` é a etapa explícita de adesão
que transforma uma máquina em um hospedeiro de testes do Yuruna (suspensão do
monitor, protetor de tela, edições de registro de bloqueio de tela, ajustes
do grupo de armazenamento, concessões de Acessibilidade / Gravação de Tela
no macOS). Essas são mudanças de política do hospedeiro que o operador pode não
querer, então ficam para invocação manual após a instalação.

<a id="429fb30b-0016"></a>

### Instalação do powershell-yaml

O `powershell-yaml` é exigido pelo `Resolve-CyclePlan` e por todo leitor de
YAML no harness. O pwsh 7 NÃO o distribui, e o preflight do
`test/Invoke-TestProject.ps1` falha rápido com "powershell-yaml is not
installed" se o módulo estiver ausente -- o atrito de todo bootstrap em
hospedeiro novo. Cada instalador instala o `powershell-yaml` (escopo CurrentUser,
`-Force -AllowClobber` para confiar automaticamente na PSGallery em uma
máquina nova). O `Install-PowerShellYamlIfMissing` (definido em
[test/modules/Test.HostGit.psm1](../../test/modules/Test.HostGit.psm1)
e reexportado via `Test.HostContract`) ainda é chamado a partir do
`Enable-TestAutomation.ps1` como rede de segurança para bootstraps com
clone manual.

---

<a id="429fb30b-0017"></a>

## Windows Hyper-V

<a id="429fb30b-0018"></a>

### Restrição de apenas ASCII

O `install/windows.hyper-v.ps1` é invocado a partir de um Windows recém
instalado, onde o `pwsh.exe` ainda não existe, via `irm <url> | iex` a
partir do único shell que vem na caixa: o Windows PowerShell 5.1. O
`Invoke-RestMethod` do PS 5.1 NÃO remove um BOM UTF-8 inicial. Quando a
string da resposta é enviada por pipe para o `iex`, o caractere BOM
(`U+FEFF`) se torna o primeiro token de análise e o parser do PS 5.1 deixa
de reconhecer `param()` como construção de topo de script, falhando na
linha `[CmdletBinding()]` com `Unexpected attribute 'CmdletBinding'`.

A invocação direta como arquivo funciona de qualquer jeito -- tanto o
PS 5.1 quanto o pwsh lidam com arquivos prefixados por BOM em disco -- mas
o caminho `irm | iex` é o ponto de entrada documentado do instalador e ele
PRECISA funcionar. Por isso todo comentário, string, here-doc e
identificador no arquivo do instalador PRECISA permanecer em ASCII simples
de 7 bits. Sem travessões, sem aspas tipográficas, sem caracteres de
desenho de caixa. Se uma edição futura introduzir conteúdo não ASCII,
substitua-o por um equivalente ASCII (por exemplo, `--` em vez de um
travessão) em vez de adicionar um BOM.

Também registrado em
[memory.md](../memory.md#why-the-bootstrap-installer-must-stay-ascii-only).

<a id="429fb30b-0019"></a>

### Padrão de param() + compatibilidade com irm | iex

O bloco `[CmdletBinding()]` + `param()` está na linha 29 (depois dos
cabeçalhos `<#PSScriptInfo #>` e `<# .SYNOPSIS #>`). O `iex` do PS 5.1
aceita `param()` como construção de topo de script SOMENTE quando a entrada
não tem BOM inicial e `param()` está posicionado depois dos blocos de ajuda
baseada em comentários. Ambas as condições são restrições sobre o layout de
bytes do arquivo, não sobre a sintaxe do PowerShell.

<a id="429fb30b-001a"></a>

### Materialização com uma única busca

Sob `irm | iex` não existe `$PSCommandPath`, então as reexecuções de
elevação e de PS7 fariam cada uma um NOVO download do instalador a partir
da referência móvel -- passadas extras não verificadas, duas delas no
contexto elevado. Em vez disso, o instalador busca a fonte UMA vez para um
arquivo temporário sem BOM e reexecuta via `-File`, de modo que todo filho
roda a partir daquele único arquivo com um `$PSCommandPath` real e nunca
baixa de novo. O arquivo temporário é escrito fielmente byte a byte a
partir da resposta do IRM (não do `ScriptBlock.ToString()`, cuja fidelidade
de ida e volta no PS 5.1 não é verificada), de modo que os bytes
materializados correspondam ao instalador canônico.

Antes de materializar, o instalador varre os temporários de materialização
obsoletos deixados por uma execução anterior que travou -- apenas
temporários com mais de uma hora, para que a proteção por idade nunca toque
o temporário recente de uma execução concorrente.

<a id="429fb30b-001b"></a>

### Autoelevação e bootstrap de PS5 -> PS7

Todo script do Yuruna que precisa de elevação diz isso logo no início, em
vez de surpreender o usuário no meio do caminho. Depois de um portão de
preflight `Test-SystemRequirement`, o script se autoeleva via
`Start-Process -Verb RunAs` se ainda não estiver rodando como
Administrador. A reexecução preserva o shell do qual o usuário partiu --
`powershell.exe` no PS 5.1, `pwsh.exe` no PS 7+ -- para que uma sessão
pwsh não seja silenciosamente rebaixada para o Windows PowerShell ao
cruzar a fronteira do UAC.

Para o caminho de entrada `irm | iex`, o script baixado não tem
`$PSCommandPath`, e o próprio `iex` não repassa argumentos ao código
invocado. O manipulador de reexecução reconstrói um bootstrap equivalente
ao `iex` que baixa o script de novo e o invoca via
`[scriptblock]::Create(...)` com `-SkipPreflight`, para que o filho elevado
não pergunte de novo a verificação de requisitos.

Se o shell elevado ainda for PS 5.x, o bloco de bootstrap do PS7 instala o
`Microsoft.PowerShell` via winget, atualiza o PATH para que o `pwsh.exe`
resolva nesta mesma sessão, e reexecuta o script sob o pwsh. O filho herda
o token elevado, então não há um segundo prompt de UAC. O bloco de
bootstrap do PS7 precisa permanecer compatível com PS 5.1 (sem `?.` / `??`
/ ternário / operadores de encadeamento) -- o arquivo inteiro é analisado
de antemão, e mesmo um único token exclusivo do PS 7 impediria o arquivo
de carregar no 5.1 antes que esta verificação pudesse rodar.

Return (não exit) é usado em todo ponto de reexecução. Um `exit` no nível
superior do script encerra o processo PowerShell hospedeiro, o que fecharia
o próprio shell do usuário quando o script é invocado via `irm | iex` no
console não administrativo dele.

<a id="429fb30b-001c"></a>

### Fixação de winget --source winget

Sem `--source winget` em toda chamada, o winget busca em todas as fontes
registradas (incluindo a msstore) e falha duro quando uma delas tem um
certificado de servidor obsoleto ou não confiável, mesmo que o pacote
tenha sido encontrado na fonte `winget` confiável. Visto na prática como:

```
Failed when searching source: msstore
0x8a15005e : The server certificate did not match any of the
             expected values.
```

Quando isso acontece, o winget se recusa a escolher uma fonte
automaticamente e aborta com "Please specify one of them using the
`--source` option to proceed." A fixação contorna a desambiguação.

<a id="429fb30b-001d"></a>

### Chamada direta ao DISM.exe, não Get-/Enable-WindowsOptionalFeature

`Get-WindowsOptionalFeature` / `Enable-WindowsOptionalFeature` despacham
para o provedor DISM via COM, e em algumas sessões do pwsh 7 a classe COM
não resolve, com `Class not registered` (HRESULT `0x80040154`). Isso
encerra o script nas reexecuções; e quando o
`-ErrorAction SilentlyContinue` silencia o erro na primeira execução, o
`$feature` retornado se torna `$null` e a etapa de habilitação é pulada sem
que o usuário perceba, deixando o Hyper-V desligado. O `DISM.exe` é uma
ferramenta Win32 simples, sem dependência de COM, e é o que os cmdlets
encapsulam internamente.

<a id="429fb30b-001e"></a>

### Verificação cruzada do "Enabled" do DISM com a presença do vmms

O `DISM /Enable-Feature` muda o State para `Enabled` imediatamente, mas os
*componentes* do Hyper-V (serviço `vmms`, `virtmgmt.msc`) só são
implantados depois que o reinício pendente acontece. Em uma segunda
passada antes desse reinício, o `/Get-FeatureInfo` ainda diz `Enabled`
mesmo que nada funcione de fato -- e o harness de testes falharia ao
iniciar o `virtmgmt.msc` com "file not found". O instalador cruza o
`Enabled` do DISM com a presença de `vmms` e `virtmgmt.msc`; se algum
estiver faltando, o script trata como recém-habilitado e define
`$script:RestartNeeded`, para que o caminho "RESTART REQUIRED" do bloco
finally dê ao usuário uma mensagem clara.

<a id="429fb30b-001f"></a>

### try/catch/finally com banner de resumo

Todo caminho de instalação (sucesso, falha, reinício pendente) é envolvido
em um único `try/catch/finally`. A janela de administrador criada pelo
`Start-Process -Verb RunAs` fecha no instante em que o script sai, e sem o
envoltório qualquer falha (código de saída do DISM, winget diferente de
zero, um throw de um módulo chamado) fecharia a janela antes que o usuário
pudesse ler a mensagem. O bloco finally imprime um resumo claro de
SUCCESS / FAILED / RESTART REQUIRED e -- no caminho de sucesso -- automatiza
a passagem para uma janela pwsh nova com as orientações de NEXT STEPS.

Não existe `exit 1` no ramo de falha. Isso encerraria o processo PowerShell
hospedeiro, fechando a própria janela do usuário quando ele invocou o
script diretamente. Cair através do bloco finally deixa o usuário no prompt
do seu shell.

<a id="429fb30b-0020"></a>

### Janela de passagem com EncodedCommand

Todas as orientações de NEXT STEPS vivem dentro do banner de boas-vindas da
janela pwsh criada. O console de administrador em que este script está
rodando foi criado pelo bloco de autoelevação via
`Start-Process -Verb RunAs` e fecha no momento em que retornamos, então
qualquer coisa que enviemos com `Write-Output` DEPOIS dessa saída
desaparece antes que o usuário possa ler.

A janela de passagem é iniciada via `pwsh -NoExit -EncodedCommand <base64>`
para contornar todas as armadilhas de quoting de shell no processo criado.
O pwsh.exe espera o payload base64 como bytes UTF-16LE (Unicode). Se a
janela de passagem não abrir, as mesmas orientações são impressas no
console de administrador com um `Start-Sleep` de 60 segundos para manter a
janela legível (sem `Read-Host`, para que um Enter acidental não possa
encerrar tudo antes da hora).

<a id="429fb30b-0021"></a>

### Test-SystemRequirement é silencioso em caso de sucesso

O preflight do Windows só imprime algo quando alguma coisa está abaixo da
linha de base, então um operador em uma máquina testada não recebe ruído
extra. Ele usa `Get-CimInstance` (mais portátil que WMI) e converte
`TotalVisibleMemorySize` (KB) em GB via `/ 1MB`.

<a id="429fb30b-0022"></a>

### Verificação de escala de exibição

O OCR do Tesseract em capturas de tela de VM degrada quando o monitor do
hospedeiro escala acima de 100%. O vmconnect renderiza o framebuffer do
convidado através do compositor com escala de DPI; o bitmap ampliado
derrota a segmentação do Tesseract -- o `waitForText` expira silenciosamente
em um texto que um humano lê sem problema. O Windows 11 recém instalado
(HiDPI, 4K) vem com 125-150% por padrão, então essa armadilha atinge hospedeiros
novos na primeira vez que rodam um ciclo.

O preflight do instalador em
[install/windows.hyper-v.ps1](../../install/windows.hyper-v.ps1)
(`Test-DisplayScaling`) é **apenas de aviso** -- ele nunca bloqueia a
instalação. Ele lê três fontes de registro que podem sobrescrever o padrão
de 100%:

- `HKCU\Control Panel\Desktop\PerMonitorSettings\<display-id>\DpiValue`
  (escala por monitor; Windows 10/11). O valor é um deslocamento a partir
  de `RecommendedDpiValue` -- 100% mapeia para `-recommended`
  independentemente da escala recomendada do próprio monitor. Cada passo é
  +25%.
- `HKCU\Control Panel\Desktop\LogPixels` (fallback de DPI para todo o
  sistema, para processos sem consciência por monitor). O padrão é 96
  (= 100%).
- `HKCU\Software\Microsoft\Accessibility\TextScaleFactor` ("Tamanho do
  texto" do Windows 11 -- independente da escala de exibição; 100 a 225).

Valores REG_DWORD podem ser assinados (o DpiValue costuma ser negativo). O
instalador usa a mesma reinterpretação de bits UInt32->Int32 que a função
de reset do módulo -- um cast simples para `[int]` em valores com o bit
mais significativo ligado lança `OverflowException`.

A ação de reset correspondente vive em
[test/modules/Test.HostContract.psm1](../../test/modules/Test.HostContract.psm1)
`Set-WindowsHostConditionSet`, chamada por
[host/windows.hyper-v/Enable-TestAutomation.ps1](../../host/windows.hyper-v/Enable-TestAutomation.ps1).
Ela escreve 100% nas três fontes e emite linhas de status por monitor via
`Write-Information`. O script Enable-TestAutomation define
`$InformationPreference = 'Continue'` para que essas mensagens cheguem ao
operador (sem isso elas ficam silenciosas, e o próprio cabeçalho do script
mentiria sobre "informar cada ação"). As mudanças entram em vigor depois
que o operador sai e entra de novo na sessão (ou reinicia) --
`Set-WindowsHostConditionSet` emite um lembrete via `Write-Warning` quando
algum valor foi alterado.

O leitor do lado da instalação e o reset do lado do módulo duplicam
deliberadamente a lógica das três fontes em vez de compartilhar uma função
de módulo: o preflight de instalação roda **antes** de o repositório ser
clonado, então ele não pode fazer `Import-Module Test.HostContract`. O
conhecimento compartilhado está nesta seção, não no código.

---

<a id="429fb30b-0023"></a>

## macOS UTM

<a id="429fb30b-0024"></a>

### Pré-requisito do Xcode CLT para o Homebrew

O instalador espera o `xcode-select -p` ter sucesso em um laço de sondagem
porque o `xcode-select --install` dispara um prompt gráfico que o operador
precisa dispensar. Pular isso deixaria o Homebrew incapaz de compilar
qualquer fórmula que só exista em código-fonte.

<a id="429fb30b-0025"></a>

### Detecção de arquitetura do Homebrew

O `brew shellenv` fica em `/opt/homebrew/bin/brew` no Apple Silicon e em
`/usr/local/bin/brew` no Intel. O instalador sonda os dois e faz `eval` do
correto, para que as etapas seguintes vejam o `brew` no PATH
independentemente da CPU.

<a id="429fb30b-0026"></a>

### Reparo de propriedade do Homebrew em ambiente multiusuário

Uma conta de usuário macOS nova em um hospedeiro onde o Homebrew foi instalado
por outra conta herda um `/opt/homebrew` com propriedade mista E
(frequentemente) sem diretório `.git` (Homebrew instalado por tarball).
Toda operação brew subsequente então falha de vez (`not writable`,
`Can't create brew update lock`) ou despeja a cascata de
`fatal: not in a git directory` +
`update-report should not be called directly!` disparada pelo autoupdate
interno do Homebrew dentro de todo `brew install` / `brew upgrade`.

O instalador repara o prefixo na execução atual, em vez de pedir ao
operador que conserte à mão. As credenciais de sudo já estão em cache do
`sudo -v` anterior, então o reparo é silencioso em um hospedeiro instalado
corretamente -- o teste de gravabilidade encurta o caminho para um no-op.

O reparo é disparado por qualquer um de três sinais: a raiz do prefixo não
gravável; nenhum diretório `.git` sob o prefixo (Homebrew instalado por
tarball -- independente de permissões, mas em um hospedeiro multiusuário isso se
correlaciona fortemente com subdiretórios de propriedade mista da
instalação anterior parcial); ou qualquer subdiretório padrão de destino
de escrita não gravável -- uma única verificação de gravabilidade na raiz
do prefixo não pega problemas em subdiretórios como
`etc/bash_completion.d`, `lib/pkgconfig` ou as árvores de
man/completion/locale em `share/*`, então o instalador amostra diretamente
os destinos de escrita de instalação/atualização do brew.

<a id="429fb30b-0027"></a>

### Encerrar o UTM antes da atualização do cask, preservar o cache se estiver rodando

O `brew upgrade --cask utm` exige o UTM fechado. O instalador encerra o UTM
graciosamente via AppleScript (`tell application "UTM" to quit`) e recorre
ao `pkill` se ele se recusar. Se a VM caching-proxy-service estiver rodando
(veja [Preservar a VM yuruna-caching-proxy-service](#preservar-a-vm-yuruna-caching-proxy-service)),
a atualização do cask do UTM é pulada nesta execução; ela é atualizada na
próxima reexecução, quando o cache estiver parado (ou quando o operador
encerrar o UTM manualmente).

<a id="429fb30b-0028"></a>

### brew_ensure_formula vs brew_ensure_cask

O PowerShell é distribuído como fórmula do brew em alguns taps e como cask
em outros. O instalador tenta primeiro a fórmula via `brew_ensure_formula
powershell`; se isso falhar, ele recorre a `brew_ensure_cask
powershell`. Qualquer um dos caminhos deixa o `pwsh` no PATH para as etapas
seguintes.

<a id="429fb30b-0029"></a>

### Pisos de versão são reparados, não reportados

O `automation/Yuruna.Requirement.yml` guarda o piso de cada ferramenta que
o instalador gerencia. A execução confere as ferramentas contra ele, repara
o que está abaixo e confere de novo -- duas vezes -- antes que qualquer
coisa chegue ao resumo final. Um operador a quem se pede corrigir uma
versão à mão ao fim de um instalador que segurou o root a execução inteira
está sendo convidado a fazer o trabalho do instalador.

Duas formas explicam quase todo Mac que termina abaixo de um piso, e
nenhuma delas é visível no que o `brew upgrade` imprime:

- **fórmulas keg-only.** O Homebrew instala o `curl` sob
  `$(brew --prefix curl)` e deliberadamente não o linka, então o nome
  continua resolvendo para a cópia da Apple -- que nunca avança além do que
  veio com o SO. O `brew install curl` sozinho não muda nada do que o
  `curl --version` diz.
- **uma ferramenta instalada duas vezes.** O build do PowerShell da
  Microsoft (o cask) e a fórmula do Homebrew avançam de forma
  independente, e o `pwsh` resolve para o diretório que vier primeiro no
  PATH. O `brew upgrade` então tem sucesso, execução após execução, contra
  um keg que nada de fato executa.

Um piso é julgado pelo que a ferramenta imprime quando é invocada PELO
NOME, então os dois casos são reparados da mesma forma: encontrar a cópia
mais nova que este Mac carrega e fazer o nome resolver para ela. O link vai
para `PATH_LINK_DIR` (`/usr/local/bin`) pelo mesmo motivo que o do
`utmctl` -- o `/etc/paths` padrão o lista, então o executor, o serviço de
status e um `ssh host command` veem todos a mesma ferramenta. Uma cópia
linkada pelo Homebrew que seja mais antiga que a melhor é deslinkada
(`brew unlink`; o keg continua instalado), porque o `brew shellenv` coloca
o bin do brew à frente de `/usr/local/bin` e ela continuaria vencendo. Um
pin só é removido para uma fórmula que já esteja falhando um piso. Um
arquivo real ocupando o caminho do link é movido para o lado com data e
hora, nunca apagado.

A segunda passada existe para a única escalada que precisa que uma primeira
tentativa tenha falhado: adicionar o build do PowerShell que ainda não está
instalado. AES-GCM é uma propriedade do runtime, e não uma ferramenta
própria, então ele é reparado junto com o PowerShell e se resolve com ele.
O que duas passadas não conseguirem alcançar é reportado JUNTO com o
binário para o qual o nome resolve -- um piso que nenhum build alcança e
uma cópia mais nova escondida atrás de uma mais antiga no PATH são lidos de
forma idêntica sem isso.

<a id="429fb30b-002a"></a>

### As permissões de TCC continuam manuais

O TCC do macOS (Privacidade e Segurança -> Acessibilidade, Gravação de
Tela) exige um clique humano nos Ajustes do Sistema -- nenhum script (nem
mesmo com sudo) consegue alternar a Acessibilidade para outro processo. O
instalador imprime o caminho dos Ajustes do Sistema no banner de NEXT STEPS
em vez de tentar automatizar.

<a id="429fb30b-002b"></a>

### Anúncio do sudo + keepalive

Todo script do Yuruna que precisa de elevação diz isso logo no início. O
instalador prepara o sudo uma única vez, para que o instalador do Homebrew
e os pós-instaladores dos casks reutilizem todos o mesmo timestamp. Um
keepalive em segundo plano reexecuta `sudo -n true` a cada 30s para que o
timestamp não expire no meio da instalação enquanto o brew faz suas
próprias chamadas internas de sudo.

O `|| true` no keepalive é essencial: sob `set -e` (topo do arquivo), uma
falha transitória de `sudo -n true` -- por exemplo, uma breve disputa pelo
lock do timestamp enquanto o pós-instalador do brew/cask roda seu próprio
sudo -- mataria o subshell.

Um único trap de `EXIT` (`yuruna_install_cleanup`) libera o keepalive do
sudo E qualquer backup temporário de test/status em todo caminho de saída:
conclusão normal, Ctrl-C, aborto por `set -e`.

<a id="429fb30b-002c"></a>

### Ativar o PATH do Homebrew no shell do chamador

O instalador roda em seu próprio subshell, então `brew`, `pwsh` e `git` do
Homebrew ainda não são visíveis para o shell em que o usuário colou o
comando curl. O banner de NEXT STEPS diz a ele para abrir uma nova janela
do Terminal ou rodar `eval "$($BREW_PREFIX/bin/brew shellenv)"` para
corrigir a sessão atual.

---

<a id="429fb30b-002d"></a>

## Ubuntu KVM/libvirt

<a id="429fb30b-002e"></a>

### Trap de ERR + rastreamento de _yuruna_step

Sob `set -euo pipefail` o shell encerra silenciosamente no primeiro comando
com retorno diferente de zero, deixando o operador sem meio de ver por que
uma sonda falhou (por exemplo, depois de "Refreshing apt index").

O `log()` registra a fase atual em `$_yuruna_step`. O trap `ERR` dispara
antes da saída e imprime a localização (`$BASH_LINENO[0]`), o comando
(`$BASH_COMMAND`) e o status de saída capturado. A próxima falha é
acionável em vez de silenciosa.

<a id="429fb30b-002f"></a>

### Preflight de virtualização da CPU (vmx/svm)

A aceleração KVM exige Intel VT-x ou AMD-V. O preflight obrigatório faz
grep de `vmx|svm` em `/proc/cpuinfo` -- sem aceleração o harness de testes
é inutilizável, então o instalador se recusa a queimar tempo com trabalho
de apt/repositório quando o hospedeiro não pode hospedar VMs. Em hospedeiros aarch64,
onde o `/proc/cpuinfo` não expõe `vmx`/`svm`, a verificação delega para a
asserção pós-instalação de `/dev/kvm` no preflight final.

<a id="429fb30b-0030"></a>

### Atualizar o índice do apt ANTES de sondar por qemu-system-<arch>-hwe

Em uma imagem nova, o cache do apt pode ainda não saber que a variante
`-hwe` existe, e a sonda cairia para o pacote base mesmo com a HWE
disponível. O `apt-get update -q` (um quiet, não `-qq`) mantém visíveis os
avisos do apt e os erros de conectividade. Com `-qq`, um mirror travado ou
uma falha de verificação de assinatura aborta o script sem nenhuma saída,
tornando a saída silenciosa "logo depois de Refreshing apt index"
impossível de diagnosticar sem reexecutar com `-x`.

<a id="429fb30b-0031"></a>

### Divisão do qemu-kvm no Ubuntu 26.04 (resolute)

`qemu-kvm` é um pacote VIRTUAL a partir do Ubuntu 26.04 -- o apt se recusa
a escolher automaticamente entre `qemu-system-<arch>` e
`qemu-system-<arch>-hwe`. O instalador usa por padrão a variante GA (não
HWE): ela puxa o `ubuntu-virt`, que é o MESMO guarda-chuva do qual o resto
dos nossos pacotes (`libvirt-daemon-system`, `libvirt-clients`, `ovmf`,
`qemu-utils`, `virtinst`) depende. A variante `-hwe` depende de
`ubuntu-virt-hwe`, que *Conflicts* com `ubuntu-virt`, então qualquer
tentativa de usar `-hwe` mantendo o resto da pilha no ramo GA produz um
erro de "two conflicting assignments" do apt. Sobrescrita pelo operador:
`YURUNA_QEMU_PKG=qemu-system-x86-hwe` para tentar o `-hwe` mesmo assim,
assim que um LTS futuro distribuir libvirt e ovmf `-hwe` correspondentes.

<a id="429fb30b-0032"></a>

### apt com simulação primeiro

O instalador roda o solucionador do apt em modo `--simulate` PRIMEIRO. Se
existir um conflito de dependências -- por exemplo, o qemu `-hwe` puxando
`ubuntu-virt-hwe` contra o `ubuntu-virt` do resto da pilha -- ele aparece
aqui ANTES de começarmos a instalar qualquer coisa, com o mesmo
diagnóstico "X depends Y but it is not going to be installed" que a
instalação real emitiria. O `set -e` + o trap de ERR significam que uma
saída diferente de zero do apt-get imprime o bloco de aborto nomeando esta
etapa.

<a id="429fb30b-0033"></a>

### Atualização do osinfo-db a partir do pagure

O `osinfo-db` distribuído pelo apt no Noble pode ser anterior ao lançamento
do Ubuntu 24.04, então o `virt-install --osinfo list` pode não incluir
`ubuntu24.04` mesmo depois de o pacote apt estar instalado. Os scripts por
convidado já recorrem a `linux2022` quando a variante precisa está
faltando, mas o operador fica melhor servido com o ajuste apropriado do
hipervisor.

Atualização upstream de melhor esforço: raspar
`releases.pagure.org/libosinfo/` em busca do `osinfo-db-YYYYMMDD.tar.xz`
mais recente, baixá-lo e importá-lo para todo o sistema via
`osinfo-db-import --local` (que escreve em `/usr/local/share/osinfo`, onde
o libosinfo busca incondicionalmente no Ubuntu). Qualquer falha (sem rede,
pagure.org fora do ar, tarball malformado) emite uma linha de `warn` e
segue em frente.

A busca de variante usa uma correspondência por regex contra a saída de
`virt-install --osinfo list`. Cada linha é `<canonical-id>, <alias1>
<alias2>` -- então um `grep -qx 'ubuntu24.04'` ingênuo nunca corresponde,
porque a linha na verdade é `ubuntu24.04, ubuntunoble`. O
`osinfo_has_variant` remove a cauda de aliases antes de fazer a
correspondência exata -- uma correspondência exata ingênua mascara o
sucesso da importação upstream e mantém o aviso sendo impresso
perpetuamente.

<a id="429fb30b-0034"></a>

### PowerShell via apt ou tarball conforme a arquitetura

x86_64 recebe o `powershell` do repositório apt da Microsoft (a fonte
canônica). aarch64 não tem pacote apt, então o instalador recorre ao
tarball do PowerShell sob `/opt/microsoft/powershell/7` com um symlink
`/usr/local/bin/pwsh`. Ambos os caminhos deixam o `pwsh` no PATH para as
etapas seguintes. O caminho do tarball resolve a release estável mais
recente seguindo o redirecionamento de `/releases/latest` (o PowerShell
publica tarballs linux-x64 e linux-arm64, além de `hashes.sha256`, para
toda release GA), então o aarch64 acompanha a mesma versão atual que o
caminho apt instala; defina `PWSH_VERSION` para fixar uma release
específica em uma compilação reproduzível ou sem acesso à rede.

Esses dois caminhos só rodam quando o `pwsh` está AUSENTE, porque rodam
antes de o checkout existir e o piso de comparação vive dentro dele. Um
pwsh que tenha chegado de outra maneira -- o snap `powershell` da Canonical
é o caso comum, um tarball desempacotado à mão é o outro -- não é,
portanto, instalado por nada aqui, e presença não é a pergunta que um piso
faz. Assim que o repositório está em disco, a execução lê o piso do
PowerShell em `automation/Yuruna.Requirement.yml` e eleva o interpretador
até ele: pede-se primeiro ao snapd que atualize um PowerShell que ele
possua, de modo que o hospedeiro mantenha a procedência que seu operador
escolheu, e só um canal que não consiga alcançar o piso cai para as fontes
apt e tarball acima. Essas ficam sob `/usr/local/bin`, que o PATH padrão
coloca à frente de `/snap/bin`, então a cópia mais nova vence o nome sem
que a mais antiga seja removida. Uma fonte que desiste encerra a tentativa
de atualização, não a instalação -- o hospedeiro ainda tem um interpretador
funcional, e o resumo final carrega a versão em que ele ficou preso.

<a id="pisos-de-versão-em-um-host-ubuntu"></a>

<a id="429fb30b-0035"></a>

### Pisos de versão em um hospedeiro Ubuntu

O PowerShell é a única ferramenta da lista de pisos do Ubuntu cujas fontes
vão à frente do archive, e por isso a única que o instalador consegue
elevar. git, python3, curl, tesseract e qemu-img chegam ao hospedeiro apenas
através do `apt`, cujo teto é o Candidate do archive: um archive LTS
congela seus números de versão no lançamento e depois carrega apenas
correções retroportadas, então o `apt-get install` em um pacote já atual
não muda nada e nenhuma reexecução pode mudar mais. Os pisos deles são,
portanto, definidos como o que aquele archive distribui, conforme a regra
de seleção registrada em `automation/Yuruna.Requirement.yml` -- um piso
acima disso reportaria um defeito em uma máquina corretamente
provisionada, em toda execução, sem que nada pudesse resolvê-lo. Um piso
aqui diz que o hospedeiro está provisionado, não que ele está atualizado; o
Ubuntu também retroporta correções de segurança sem mover o número
upstream, então o nível de patch é uma questão separada desta verificação.

<a id="429fb30b-0036"></a>

### ACL de travessia do libvirt-qemu em $HOME

As imagens de nuvem do Ubuntu 24.04 criam `/home/<user>` com modo 0750, o
que impede o usuário `libvirt-qemu` (uid 64055, gid kvm), que executa os
processos qemu dos convidados, de atravessar `$HOME` para alcançar os
arquivos de disco das VMs. O `virt-install` então falha com "Cannot access
storage file ... Permission denied". O instalador aplica a ACL POSIX
apenas de travessia (`setfacl -m u:libvirt-qemu:--x "$HOME"`) logo no
início, para que o operador não descubra isso na primeira vez que o
`New-VM.ps1` rodar.

O preflight final verifica se o `libvirt-qemu` consegue de fato alcançar
arquivos sob `$HOME` criando um arquivo de sonda com `mktemp` (modo 0644 --
o padrão 0600 do `mktemp` sempre falharia na leitura entre usuários,
independentemente da travessia) e então `sudo -u libvirt-qemu test -r
<probe>`. O teste isola a questão da travessia de diretório da questão do
modo do arquivo.

<a id="429fb30b-0037"></a>

### Rede default do libvirt -- iniciar + autostart

A rede NAT `default` (`192.168.122.0/24`) é distribuída pelo
`libvirt-daemon-system`, mas começa desabilitada. O instalador garante que
ela esteja com autostart + no ar, para que o `virt-install` possa anexar
convidados sem um `virsh net-start` manual.

<a id="429fb30b-0038"></a>

### Preflight final — toda verificação é um requisito obrigatório

Até a seção de preflight, o instalador APLICOU configuração. O preflight
VERIFICA se o hospedeiro de fato chegou ao estado de que o
`Start-TestRunner.ps1` precisa. O script coleta todas as falhas para que o
operador veja a lista completa de pendências de uma vez, em vez de
corrigir-e-reexecutar N vezes. Uma instalação parcial é pior que nenhuma
instalação -- execuções subsequentes veem "parece configurado" e pulam
etapas que as teriam reaplicado.

As verificações cobrem: `kvm-ok`, o dispositivo de caractere `/dev/kvm`, a
participação em grupos em `/etc/group` (o conjunto de grupos obsoleto do
shell pai é problema do operador, exposto como uma dica de NEXT STEPS), os
serviços systemd `libvirtd` + `virtlogd` ativos, o usuário de sistema
`libvirt-qemu` presente, a rede `default` do libvirt rodando + com
autostart, a ACL de travessia de `$HOME` do `libvirt-qemu` funcionando na
prática, o construtor de seed do cloud-init (`genisoimage` ou
`cloud-localds`), o `pwsh` no PATH, o `virt-install` no PATH, as variantes
do osinfo-db que os scripts por convidado pedem, o firmware UEFI
específico da arquitetura (`ovmf` / `qemu-efi-aarch64`), swtpm +
swtpm_setup, e o GitHub CLI no PATH.

<a id="429fb30b-0039"></a>

### GitHub CLI via repositório apt cli.github.com

O `gh` não está fixado em uma versão atual no archive padrão do Ubuntu. O
instalador segue a instalação recomendada pelo cli.github.com via
repositório apt: keyring sob `/etc/apt/keyrings`, fonte do repositório sob
`/etc/apt/sources.list.d`, e então `apt-get install gh`. Idempotente nas
reexecuções -- um keyring ou arquivo de lista de fontes existente resulta
em no-op. O binário fica no PATH, mas sem autenticação -- rode
`gh auth login` uma vez por hospedeiro.

<a id="429fb30b-003a"></a>

### sg libvirt para a limpeza da primeira execução

A limpeza do `Remove-TestVMFiles.ps1` roda logo depois de `usermod -aG
libvirt $USER`, então o conjunto de grupos do shell atual ainda não inclui
`libvirt` e uma chamada direta de `pwsh -File` herdaria o conjunto de
grupos obsoleto e falharia com "Permission denied" em
`/var/run/libvirt/libvirt-sock`. O `sg libvirt -c "pwsh ..."` roda um
subshell com libvirt como grupo suplementar efetivo, o que funciona no
instante em que `/etc/group` tem a participação -- sem exigir novo
login.

O `getent group libvirt` lê `/etc/group`, que o `usermod -aG` acabou de
atualizar. Não use `id -nG` aqui: ele reflete o conjunto de grupos vivo e
obsoleto DESTE shell e forçaria o fallback de pwsh direto na primeira
execução.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Última revisão: 2026.09.18

Voltar para [Yuruna](../../README.md)
