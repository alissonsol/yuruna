<a id="42e5cdfd-0001"></a>

<a id="host-implementation-notes"></a>

# Notas de implementação do hospedeiro

Estas notas descrevem as restrições mantidas pelos drivers do hospedeiro, pelos
construtores de imagens e VMs e pelos iniciadores de serviços no hospedeiro. Os
scripts relacionados usam comentários locais curtos e apontam para cá quando a
explicação é mais longa. A ajuda pública de cada comando permanece junto dele,
e os modelos executáveis mantêm seus próprios comentários.

<a id="42e5cdfd-0002"></a>

<a id="shared-host-module-lifetime"></a>

## Tempo de vida do módulo compartilhado do hospedeiro

Aplica-se a:

- [host/macos.utm/modules/Yuruna.Host.psm1](../../host/macos.utm/modules/Yuruna.Host.psm1)
- [host/ubuntu.kvm/modules/Yuruna.Host.psm1](../../host/ubuntu.kvm/modules/Yuruna.Host.psm1)
- [host/windows.hyper-v/modules/Yuruna.Host.psm1](../../host/windows.hyper-v/modules/Yuruna.Host.psm1)

Os módulos de apoio em test/modules tornam-se acessíveis a partir dos corpos das
nossas funções; Export-ModuleMember, abaixo, determina quais das NOSSAS funções
ficam visíveis para a orquestração em test/. As exportações de Yuruna.Host.psm1
se sobrepõem às exportações de mesmo nome produzidas pelos módulos de apoio.
Esses módulos de dependência são importados com -Global: Yuruna.Host é reimportado
com -Force no meio do ciclo, e uma importação simples com -Force aqui entra no
escopo aninhado de Yuruna.Host e REMOVE a cópia global que outros módulos chamam
por nomes qualificados (por exemplo, Test.Ssh\Invoke-GuestSsh) --
feedback_module_force_import_evicts_global.

<a id="42e5cdfd-0003"></a>

## host/macos.utm/modules/Yuruna.Host.psm1: Start-UtmVM

Aplica-se a:

- [host/macos.utm/modules/Yuruna.Host.psm1](../../host/macos.utm/modules/Yuruna.Host.psm1)

Distinga as duas formas de ausência do pacote usando a consulta estruturada,
em vez do invólucro booleano que lança uma exceção: ainda estar registrado
significa que o UTM mantém um nome cujos arquivos desapareceram -- o chamador
chegou até aqui porque esse nome respondeu à verificação de reutilização.
Apontar apenas para o caminho faria o leitor procurar uma VM que nunca foi
criada, em vez do registro que precisa ser removido antes de criá-la. O estado
desconhecido recebe uma mensagem própria: não há fundamento para recomendar
"criar uma VM" nem "remover um registro" quando a consulta não conseguiu
determinar qual é a situação.

Resolva o display VNC antes de iniciar. O display é definido no pacote quando
a VM é CONSTRUÍDA, e todos os convidados de um mesmo tipo são construídos com
o mesmo nome de VM de teste. Assim, uma topologia que promove várias VMs para
fora desse espaço de nomes acaba com todas fixadas na mesma porta -- o QEMU
então recusa iniciar todas as VMs depois da primeira com
"Failed to find an available port: Address already in use". Prefira o display
derivado do nome ATUAL da VM (distinto para cada VM) e exclua os displays já
reservados pelos outros pacotes, para que uma colisão real de hash avance
para o próximo slot livre.

Essa gravação só chega ao QEMU para um pacote que o UTM ainda não carregou.
O UTM lê config.plist ao carregar uma VM e mantém essa cópia enquanto o
aplicativo permanece aberto; portanto, para uma VM já registrada, o arquivo
e a linha de comando divergem silenciosamente. Rename-VM faz a alocação
durável no intervalo em que mantém o UTM encerrado.

O resultado é decidido pelo estado e a operação é repetida, porque utmctl
retorna 0 em três situações distintas que não representam sucesso: uma
solicitação descartada pelo UTM enquanto ainda carrega o pacote, uma
solicitação que o UTM nunca executou (erro de Apple Event) e uma VM cujo QEMU
morreu logo após a inicialização. Informar qualquer uma delas como iniciada
faz uma VM inoperante percorrer toda uma sequência de etapas seguintes antes
que o problema seja percebido. O sintoma final -- um tempo limite de SSH ou
um convidado que falha numa asserção sobre um par que nunca iniciou -- não
identifica esta VM nem este motivo.

<a id="42e5cdfd-0004"></a>

## host/macos.utm/modules/Yuruna.Host.psm1: Assert-NoConcurrentUtmVm

Aplica-se a:

- [host/macos.utm/modules/Yuruna.Host.psm1](../../host/macos.utm/modules/Yuruna.Host.psm1)

Distinga "ausência de VM concorrente confirmada" de "não foi possível
verificar". Se UTM.app não responde (pressão de memória no hospedeiro -> tempo
limite de Apple Event, OSStatus -1712), utmctl list retorna vazio e a consulta
do conjunto em execução, abaixo, interpreta isso como "nada em execução" --
uma falsa liberação que permitiria a uma VM remanescente passar por essa
proteção. Informe a situação, em vez de liberá-la silenciosamente. Ainda
prosseguimos (retornar $false aqui bloquearia todos os ciclos num hospedeiro
cujo utmctl deixa de responder de modo intermitente); o aviso é o sinal, e
a consulta de encerramento por convidado é a outra proteção de reserva.

<a id="42e5cdfd-0005"></a>

## host/macos.utm/modules/Yuruna.Host.psm1: Get-VncScreenshot

Aplica-se a:

- [host/macos.utm/modules/Yuruna.Host.psm1](../../host/macos.utm/modules/Yuruna.Host.psm1)

Retângulo de quadro completo (o caso comum para uma
FramebufferUpdateRequest inicial após uma nova negociação): leia
diretamente em $fb, evitando o laço de cópia de cada linha em
PowerShell. Sem esse caminho rápido, um laço de 1080 linhas de
[Array]::Copy em PowerShell leva ~10 s num framebuffer de
1920x1080, porque cada iteração paga o custo de despacho de um
scriptblock -- os bytes chegam em <50 ms; o laço é o gargalo.

<a id="42e5cdfd-0006"></a>

## host/macos.utm/modules/Yuruna.Host.psm1: Resume-YurunaServiceVM

Aplica-se a:

- [host/macos.utm/modules/Yuruna.Host.psm1](../../host/macos.utm/modules/Yuruna.Host.psm1)

O UTM carrega sua biblioteca de modo assíncrono depois de iniciar, e utmctl
não consegue acessar uma VM até que isso termine -- uma inicialização
imediata receberia "not found" e seria descartada silenciosamente. A espera
abrange AMBOS os estados 'absent' (ainda não registrada novamente) e 'unknown'
(uma consulta que ainda não pôde ser lida -- o que uma conexão realmente
bloqueada também produz): somente uma leitura positiva de 'running' ou
'stopped' encerra a espera, e a inicialização só é tentada a partir de uma
leitura positiva de 'stopped', nunca de 'unknown'. Uma leitura para a qual
não restou tempo antes do prazo nunca substitui uma resposta já obtida.

<a id="42e5cdfd-0007"></a>

## host/macos.utm/modules/Yuruna.Host.psm1: Rename-VM

Aplica-se a:

- [host/macos.utm/modules/Yuruna.Host.psm1](../../host/macos.utm/modules/Yuruna.Host.psm1)

Derive novamente o display VNC para o NOVO nome aqui, enquanto o UTM está
encerrado. O UTM só lê o argumento -vnc de um pacote ao carregar a VM, e
carrega-a uma vez por inicialização do aplicativo: uma regravação feita
enquanto o UTM já mantém a VM altera o arquivo sem alterar a linha de comando
do QEMU; assim, o convidado ainda inicia no display com que foi carregado.
Esse reinício é o único momento em que o arquivo volta a ser a autoridade.
Isso importa porque os pacotes são construídos com um único nome de teste
por tipo -- toda VM promovida para fora desse espaço de nomes herda o mesmo
display, e somente a primeira consegue reservar a porta.

<a id="42e5cdfd-0008"></a>

## host/macos.utm/modules/Yuruna.Host.psm1: Restore-VMDiskSnapshot

Aplica-se a:

- [host/macos.utm/modules/Yuruna.Host.psm1](../../host/macos.utm/modules/Yuruna.Host.psm1)

A aplicação abaixo não pode disputar acesso com um processo auxiliar do
QEMU ainda ativo: ele mantém as tabelas L1/L2 do qcow2 na memória e grava
sua visão (não revertida) ao encerrar. Assim, `qemu-img snapshot -a` retorna
0, mas o convidado retoma o disco anterior à reversão -- "continua de onde
a última execução parou", em vez de iniciar do snapshot. Bloquear até o
desligamento real e a liberação do bloqueio torna essa reversão tão
determinística quanto a restauração de um checkpoint do Hyper-V. A operação
é executada incondicionalmente porque Get-VMState mapeia 'suspended'/'paused'
para 'stopped', mas esses estados ainda mantêm o bloqueio.

<a id="42e5cdfd-0009"></a>

## host/macos.utm/modules/Yuruna.Host.psm1: Send-Text

Aplica-se a:

- [host/macos.utm/modules/Yuruna.Host.psm1](../../host/macos.utm/modules/Yuruna.Host.psm1)

Importe uma vez e reutilize, como Send-Key abaixo. Reimportar com -Force em
cada chamada remove o Invoke-Sequence global (e seus módulos aninhados +
estado $script:) que o laço externo ainda chama
(feedback_module_force_import_evicts_global,
feedback_module_script_state_reset_by_force_reimport). Pagar esse custo em
cada tecla vai além da sobrecarga: isso altera repetidamente o estado do
módulo do qual se lê o argumento -HostType deste próprio driver; assim,
o ato de digitar pode desabilitar as teclas seguintes.

<a id="42e5cdfd-000a"></a>

## host/macos.utm/modules/Yuruna.Host.psm1: Send-Key

Aplica-se a:

- [host/macos.utm/modules/Yuruna.Host.psm1](../../host/macos.utm/modules/Yuruna.Host.psm1)

Use o despachante de Invoke-Sequence que leva o hospedeiro em conta: ele
resolve o nome da tecla pelo registro de códigos de teclas e escolhe o
backend VNC ou CGEvent.

Encaminhar um nome de tecla por Send-Text NÃO funciona: os mapas de
caracteres cobrem apenas ASCII imprimível; assim, todos os backends de texto
avisam e ignoram um caractere de controle como CR, enquanto a chamada ainda
informa sucesso -- uma tecla que silenciosamente não digita nada. Teclas
nomeadas e combinações com modificadores precisam seguir o caminho de teclas.

<a id="42e5cdfd-000b"></a>

<a id="hostmacosutmenable-testautomationps1-initialize-host-setup"></a>

## host/macos.utm/Enable-TestAutomation.ps1: Inicializar a configuração do hospedeiro

Aplica-se a:

- [host/macos.utm/Enable-TestAutomation.ps1](../../host/macos.utm/Enable-TestAutomation.ps1)

A inicialização compartilhada (importação de Test.HostContract + preparação
de sudo + instalação de powershell-yaml e PSScriptAnalyzer) fica em
automation/Yuruna.HostSetup.psm1. -SudoCacheReason mantém a solicitação de
sudo NO INÍCIO (antes das duas instalações da PSGallery, que num Mac recém-
instalado exigem uma longa espera silenciosa), com uma faixa de motivo
visível para que o operador saiba O QUE precisará de elevação antes de
consentir. Set-MacHostConditionSet prepara novamente abaixo e é idempotente;
quando chamado por install/macos.utm.sh (YURUNA_SUDO_PRIMED=1), ambos são
operações silenciosas sem efeito. Sem um operador, ninguém pode consentir
e não há download a aguardar; portanto, esse modo não solicita nenhum dos
dois: os módulos ausentes são informados, em vez de instalados, e nenhuma
solicitação de sudo é preparada.

<a id="42e5cdfd-000c"></a>

<a id="hostmacosutmremove-orphanedvmfilesps1-enumerate-registered-vms"></a>

## host/macos.utm/Remove-OrphanedVMFiles.ps1: Enumerar VMs registradas

Aplica-se a:

- [host/macos.utm/Remove-OrphanedVMFiles.ps1](../../host/macos.utm/Remove-OrphanedVMFiles.ps1)

utmctl retorna 0 mesmo quando não conseguiu consultar nada no UTM -- Apple
Events negados (comum em SSH, launchd ou qualquer processo do hospedeiro sem
permissão de Automation), uma solicitação que excedeu o prazo ou qualquer
outra falha de Apple Event. Ele apenas envia o erro a stderr e imprime o
cabeçalho sem linhas de dados. Este script então trataria TODOS os pacotes
como órfãos e -- com -Force -- excluiria todos eles, mesmo que o UTM ainda
tenha as VMs registradas. Interrompa a operação com uma mensagem clara.

A correspondência considera QUALQUER código OSStatus, em vez de alguns
códigos enumerados: o conjunto que pode aparecer aqui é aberto, deixar
passar um deles pode causar a exclusão de um disco de VM, e nenhum valor
OSStatus deve ser interpretado como "acreditar na lista vazia".

<a id="42e5cdfd-000d"></a>

<a id="hostmacosutmremove-orphanedvmfilesps1-why-utmctl-list-needs-a-uuid-anchored-parser"></a>

## host/macos.utm/Remove-OrphanedVMFiles.ps1: Por que utmctl list precisa de um analisador baseado em UUID?

Aplica-se a:

- [host/macos.utm/Remove-OrphanedVMFiles.ps1](../../host/macos.utm/Remove-OrphanedVMFiles.ps1)

Leia o UUID da VM em config.plist do pacote. utmctl list pode retornar
somente as VMs em execução; `utmctl status`, baseado em UUID, também funciona
para VMs paradas -- sem isso, uma VM de serviço parada (por exemplo,
caching-proxy-service) é classificada incorretamente como órfã e excluída
pelo caminho de limpeza com -Force.

`plutil -extract Information.UUID raw` (em vez de `-convert json`):
  * O UTM armazena o UUID em Information.UUID, e não numa chave do nível superior.
  * `-convert json` falha de imediato nesses pacotes porque config.plist
    contém um bloco <data> (MachineIdentifier) que JSON não consegue
    representar -- plutil retorna 1 e ConvertFrom-Json lança uma exceção.
    Isso faria toda a função retornar $null silenciosamente e deixaria a
    verificação de órfãos prosseguir, classificando incorretamente uma VM
    ativa como órfã.

<a id="42e5cdfd-000e"></a>

<a id="hostmodulesyurunadownloadagentpsm1-module-setup"></a>

## host/modules/Yuruna.DownloadAgent.psm1: Configuração do módulo

Aplica-se a:

- [host/modules/Yuruna.DownloadAgent.psm1](../../host/modules/Yuruna.DownloadAgent.psm1)

Cliente no hospedeiro para o serviço download-agent: encontre um agente,
consulte-o sobre uma imagem e obtenha os bytes que ele já mantém, em vez
de buscá-los na origem uma vez por hospedeiro.

Este arquivo segue duas regras estruturais, ambas essenciais:

  * Ele não importa NADA -- nem -Global, nem -Force, nem qualquer importação
    aninhada -- e exporta somente três funções com nomes únicos. Os drivers
    de cada hospedeiro envolvem Save-CachedHttpUri para injetar seu próprio
    resolvedor de cache, e os auxiliares de imagem resolvem esse invólucro
    PELO NOME. Assim, um módulo que reexportasse Save-CachedHttpUri
    (ou Test-DownloadAlreadyCurrent) e fosse importado depois de um driver
    ocuparia a posição na tabela de comandos, descartaria a closure de
    descoberta do cache e enviaria todos os downloads diretamente à origem,
    sem erro em lugar algum -- a classe de regressão sobre a qual as
    proteções no final do carregamento dos drivers avisam.
  * Nada aqui lança uma exceção para o chamador. A descoberta reduz-se a ''
    e o protocolo de solicitação, a uma cadeia de resultado, porque cada
    uma dessas chamadas precede uma execução de Get-Image cujo fallback é
    o caminho da origem. Um agente com problema deve custar uma linha de
    aviso, nunca um ciclo.

<a id="42e5cdfd-000f"></a>

## host/ubuntu.kvm/modules/Yuruna.Host.psm1: Invoke-Virsh

Aplica-se a:

- [host/ubuntu.kvm/modules/Yuruna.Host.psm1](../../host/ubuntu.kvm/modules/Yuruna.Host.psm1)

virsh passa sua saída por gettext -- estados dos domínios, rótulos dos
campos e textos de erro --, e os chamadores abaixo leem essas palavras.
Num hospedeiro cujo operador usa um locale diferente do inglês, "running"
chega traduzido, e toda comparação de estado responde 'unknown'
silenciosamente.

Use LC_MESSAGES, em vez de LC_ALL: ele fixa as palavras, mas mantém a
codificação e a ordenação no locale do operador, para que um nome com
acento ainda sobreviva à ida e volta. LC_ALL precisa ser limpo durante
a operação porque tem precedência sobre LC_MESSAGES -- um operador que
o exportasse receberia saída traduzida de qualquer modo.

<a id="42e5cdfd-0010"></a>

## host/ubuntu.kvm/modules/Yuruna.Host.psm1: New-VM

Aplica-se a:

- [host/ubuntu.kvm/modules/Yuruna.Host.psm1](../../host/ubuntu.kvm/modules/Yuruna.Host.psm1)

Alguns construtores de cada convidado iniciam o domínio por conta própria
-- um --import sem instrução em contrário e o par define+start usado pelos
instaladores ISO. Esses convidados chegam a Start-VM já em execução, e
seu retorno antecipado não deve ativar a captura, porque, para todos os
outros chamadores, a primeira solicitação de um domínio em execução já
ocorreu há muito tempo. Aqui isso não se aplica: o domínio iniciou há
poucos instantes, dentro da chamada acima. Este é, portanto, o último
ponto em que uma janela ainda pode conter seu primeiro DISCOVER. A operação
depende de o domínio estar de fato em execução; assim, um construtor que
o deixa definido e desligado tem a captura ativada por Start-VM -- ainda
mais cedo, antes de o convidado receber energia.

O código de saída da criação é restaurado depois: a leitura de estado e
a ativação executam suas próprias consultas virsh, e um chamador que
lesse $LASTEXITCODE depois desta função leria, em caso contrário, o
resultado do diagnóstico como se fosse o da criação.

<a id="42e5cdfd-0011"></a>

## host/ubuntu.kvm/modules/Yuruna.Host.psm1: Start-VM

Aplica-se a:

- [host/ubuntu.kvm/modules/Yuruna.Host.psm1](../../host/ubuntu.kvm/modules/Yuruna.Host.psm1)

Ative a janela de evidências de DHCP aqui, e somente aqui: o primeiro
DISCOVER do convidado chega segundos depois do firmware, antes de qualquer
etapa de sequência, de modo que nada posterior poderia abrir uma janela
que o contivesse. O caminho acima para uma VM já em execução deliberadamente
não ativa a captura -- essa transação já ficou no passado, e uma janela
aberta depois dela mostraria um trecho vazio para um convidado que fez a
solicitação, apresentando o oposto do que ocorreu.

O código de saída da inicialização é restaurado depois: a ativação executa
suas próprias consultas virsh, e um chamador que lesse $LASTEXITCODE depois
desta função leria, em caso contrário, o resultado do diagnóstico como se
fosse o da inicialização.

<a id="42e5cdfd-0012"></a>

## host/ubuntu.kvm/modules/Yuruna.Host.psm1: Remove-VM

Aplica-se a:

- [host/ubuntu.kvm/modules/Yuruna.Host.psm1](../../host/ubuntu.kvm/modules/Yuruna.Host.psm1)

Diretório de artefatos por VM (qcow2, seed.iso, autounattend.iso, nvram).
New-VM.ps1 coloca tudo em ~/yuruna/vms/<vmname>/. Esta operação é que
exclui o disco de cada VM; o virsh undefine acima apenas remove a definição
do domínio libvirt + o arquivo NVRAM rastreado.

Somente depois que o domínio tiver sido removido. Um domínio definido cujo
disco foi excluído é pior que um arquivo esquecido: a execução seguinte
encontra a VM "já existente", pula a criação, e todas as etapas do convidado
falham num domínio que não consegue iniciar. Os arquivos mantidos aqui
continuam pertencendo ao domínio sobrevivente, exatamente o que a varredura
de arquivos órfãos espera ignorar.

<a id="42e5cdfd-0013"></a>

## host/ubuntu.kvm/modules/Yuruna.Host.psm1: Get-KvmNeighborIp

Aplica-se a:

- [host/ubuntu.kvm/modules/Yuruna.Host.psm1](../../host/ubuntu.kvm/modules/Yuruna.Host.psm1)

Um convidado que muda de endereço deixa o endereço ANTIGO nesta tabela sob
o mesmo MAC, e o kernel não o remove -- ele passa para STALE e permanece
ali. Obter a primeira linha correspondente retorna, portanto, qualquer
entrada fornecida pela ordem do hash, com a mesma chance de ser o endereço
já abandonado pelo convidado ou o que ele usa agora. Em vez disso, todos
os candidatos são coletados e classificados: uma entrada REACHABLE foi
confirmada pelo kernel nos últimos segundos, enquanto STALE significa
apenas que ela foi válida em algum momento. Os empates são resolvidos por
um único ping com prazo limitado, porque duas entradas antigas não fornecem
informação para escolher entre elas, e consultar custa pouco.

<a id="42e5cdfd-0014"></a>

## host/ubuntu.kvm/modules/Yuruna.Host.psm1: Update-GuestNeighborCache

Aplica-se a:

- [host/ubuntu.kvm/modules/Yuruna.Host.psm1](../../host/ubuntu.kvm/modules/Yuruna.Host.psm1)

Um hospedeiro entre concessões fica sem IPv4 da rota padrão por alguns
segundos, e Get-HostIpv4Prefix não retorna nada. Essa janela não é motivo
para pular a varredura -- é a janela para a qual a varredura existe, porque
a mudança de endereço do hospedeiro é justamente quando a entrada de
vizinho do convidado está desatualizada e uma consulta está prestes a
falhar. A sub-rede não muda quando o endereço dentro dela muda; portanto,
o último prefixo usado por esse hospedeiro continua sendo o local correto
para procurar, e lembrá-lo transforma "sem varredura, sem endereço" numa
varredura que responde.

<a id="42e5cdfd-0015"></a>

## host/ubuntu.kvm/modules/Yuruna.Host.psm1: Get-VMIp

Aplica-se a:

- [host/ubuntu.kvm/modules/Yuruna.Host.psm1](../../host/ubuntu.kvm/modules/Yuruna.Host.psm1)

Somente os corpos dos níveis de tentativa. O executor compartilhado controla
a ordem, a regra de usar a primeira resposta e a descrição de cada nível,
para que esses aspectos não divirjam entre este driver e os outros dois.

Cada consulta lê o que precisa do conjunto $State, em vez das variáveis
locais desta função, e nenhuma delas é uma closure. Ambas as partes
importam: o executor chama uma consulta com `&`, o que a executa no estado
de sessão em que foi definida -- este módulo, para que Invoke-Virsh e os
seletores privados abaixo sejam resolvidos. GetNewClosure() vincularia
as variáveis locais, mas perderia essa resolução, porque a closure leva
o escopo chamador, em vez do escopo do módulo.

Primeiro o agente, depois os caches. O agente pergunta ao convidado quais
endereços ele possui AGORA, por um canal virtio-serial que não transporta
IP e, portanto, não pode ser afetado pela mudança de endereço à qual esta
operação precisa resistir. O banco de concessões e a tabela ARP/de vizinhos
são registros do que era válido antes; num convidado que acabou de mudar,
eles estão convictamente errados, em vez de simplesmente vazios -- o que
é pior, porque uma resposta errada encerra a sequência de tentativas tão
certamente quanto uma resposta correta.

É uma preferência, não uma autoridade: o canal exige um qemu-guest-agent
que tenha terminado de iniciar. Portanto, ele fica ausente durante toda a
janela de inicialização após cada restauração de snapshot, exatamente
quando um ciclo faz a maioria de suas consultas de endereço. Os níveis
de cache permanecem abaixo dele nessa janela, sem alteração.

<a id="42e5cdfd-0016"></a>

## host/ubuntu.kvm/modules/Yuruna.Host.psm1: Get-ExternalNetwork

Aplica-se a:

- [host/ubuntu.kvm/modules/Yuruna.Host.psm1](../../host/ubuntu.kvm/modules/Yuruna.Host.psm1)

Convenção do libvirt: a rede 'external' em bridge ($env:YURUNA_EXTERNAL_NETWORK
ou 'yuruna-external', se definida) é preferida quando existe; em caso
contrário, use a rede NAT interna 'default'. Os chamadores comparam o nome
retornado com a interface da VM de cache em Test-CacheVMOnExternalNetwork.

Somente redes ATIVAS são elegíveis: virt-install recusa uma rede inativa
durante a criação, e uma falha na construção da bridge pode deixar
'yuruna-external' definida, mas deliberadamente parada (consulte o ramo
de falha de reconstrução de New-YurunaExternalNetwork). Conectar um
convidado a essa rede o deixaria sem DHCP; por isso, um candidato definido,
mas inativo, é ignorado com uma indicação da correção necessária.

<a id="42e5cdfd-0017"></a>

<a id="hostubuntukvmmodulesyurunahostpsm1-external-network-helpers"></a>

## host/ubuntu.kvm/modules/Yuruna.Host.psm1: Auxiliares de rede externa

Aplica-se a:

- [host/ubuntu.kvm/modules/Yuruna.Host.psm1](../../host/ubuntu.kvm/modules/Yuruna.Host.psm1)

Interno. O motivo pelo qual $Iface não pode servir como porta de uplink de
uma bridge, ou '' quando pode. Somente Ethernet cabeada simples funciona:
dispositivos bond/vlan/tunnel precisam de suas próprias seções netplan
(declará-los sob ethernets: gera uma configuração incorreta ou é rejeitado),
e um nome com caracteres fora do conjunto seguro permitiria injeção no
yaml netplan gerado. O Wi-Fi é verificado separadamente pelos chamadores
(ele tem sua própria mensagem voltada ao operador).

Esta é a visão Linux/KVM da mesma decisão de "uplink incompatível com
bridge" que host.windows.hyper-v Test-WindowsUplinkNotBridgeable e
host.macos.utm Test-MacUplinkNotBridgeable tomam para seus hipervisores.
Os critérios diferem: uma bridge num hospedeiro Linux aceita Ethernet
USB normalmente (é ARPHRD_ETHER tipo 1, cabeada simples); portanto,
ao contrário do Hyper-V, USB não é um impedimento aqui.

Interno. Verdadeiro se, e somente se, NetworkManager realmente GERENCIA
$Nic -- e não apenas se o daemon NM está em execução. No Ubuntu Server,
o renderizador netplan usa systemd-networkd por padrão; portanto, NM pode
estar EM EXECUÇÃO e ainda gerenciar zero dispositivos: todas as NICs
mostram STATE 'unmanaged' em `nmcli device status`. Criar uma bridge com
nmcli adiciona os perfis de conexão normalmente, mas `nmcli connection up
<bridge>` falha com "Failed to find a compatible device for this
connection", e o cache recorre silenciosamente ao NAT. A escolha do
backend da bridge deve, portanto, depender do gerenciamento da NIC
desejada, e não da presença do daemon. O ponto de substituição $StatusLines
permite testar a classificação em unidades sem um nmcli ativo; quando
omitido, ele consulta `nmcli -t -f DEVICE,STATE device status` ao vivo.

<a id="42e5cdfd-0018"></a>

## host/ubuntu.kvm/modules/Yuruna.Host.psm1: Clear-YurunaExternalBridgeResidue

Aplica-se a:

- [host/ubuntu.kvm/modules/Yuruna.Host.psm1](../../host/ubuntu.kvm/modules/Yuruna.Host.psm1)

Proteções de segurança, além dos comentários: nunca remova algo que possa
estar sustentando a conectividade do hospedeiro.
  * $Nic subordinada a $BridgeName: essa bridge É o uplink do hospedeiro.
  * $Nic é, ela própria, uma bridge: o chamador resolveu a interface
    incorretamente (uma bridge netplan remanescente que mantém a rota
    padrão após um reinício chega aqui quando as verificações de
    reutilização foram puladas) -- excluí-la desconectaria o hospedeiro
    sem deixar nada que pudesse restaurar a conexão.
  * $BridgeName tem alguma OUTRA porta física ou mantém a rota padrão:
    ela é uma bridge ativa de alguém (por exemplo, a rota padrão mudou
    para uma segunda NIC entre execuções, enquanto a bridge ainda mantém
    a primeira subordinada) -- não é um resíduo.

4. Devolva a NIC a NetworkManager quando NOSSO resíduo netplan for o que
   deixou de gerenciá-la. O escopo é deliberado: se qualquer arquivo
   netplan RESTANTE fizer referência à NIC (a configuração cloud-init
   do Ubuntu Server ou um arquivo do operador), networkd é seu
   proprietário legítimo, e forçar NM sobre ela iniciaria exatamente a
   disputa entre dois daemons que a varredura pretende encerrar.
   `nmcli device set managed` é um estado apenas de execução, mas o
   'managed no' de uma execução anterior persiste pelo restante da
   inicialização e fixaria silenciosamente a escolha do backend em
   netplan nos hospedeiros que deveriam usar nmcli.

<a id="42e5cdfd-0019"></a>

## host/ubuntu.kvm/modules/Yuruna.Host.psm1: New-YurunaExternalNetwork

Aplica-se a:

- [host/ubuntu.kvm/modules/Yuruna.Host.psm1](../../host/ubuntu.kvm/modules/Yuruna.Host.psm1)

Se o operador (ou uma execução anterior) já colocou a NIC WAN numa
bridge, reutilize-a. Isso mantém em zero as alterações na rede do
hospedeiro: só precisamos definir a rede libvirt apontando para a bridge
existente. Nesse caso, $BridgeName torna-se uma sugestão sem efeito.
A interface da rota padrão também pode JÁ SER uma bridge (uma bridge
criada pelo netplan mantém a rota após um reinício) -- reutilize-a
diretamente; tratá-la como uma NIC a subordinar tentaria colocar a
bridge dentro dela mesma.

<a id="42e5cdfd-001a"></a>

## host/ubuntu.kvm/modules/Yuruna.Host.psm1: New-YurunaExternalNetwork

Aplica-se a:

- [host/ubuntu.kvm/modules/Yuruna.Host.psm1](../../host/ubuntu.kvm/modules/Yuruna.Host.psm1)

Escolha o backend da bridge conforme NetworkManager realmente GERENCIA
a NIC -- além de verificar se o daemon NM está em execução. No Ubuntu
Server, o renderizador netplan padrão é systemd-networkd; portanto, NM
pode estar em execução e não gerenciar nenhum dispositivo. nmcli então
cria os PERFIS da bridge, mas `nmcli connection up` falha com
"Failed to find a compatible device for
this connection", e o cache recorre silenciosamente ao NAT (a falha
exata que este ramo agora evita). netplan (systemd-networkd) é o backend
nativo nesse caso. Quando NM gerencia a NIC (hospedeiros de desktop ou
com renderização por NM), nmcli é correto; recorra a netplan se ainda
assim falhar, para que uma particularidade de plugin/versão não custe
a exposição na LAN + o dashboard do grupo.

<a id="42e5cdfd-001b"></a>

## host/ubuntu.kvm/modules/Yuruna.Host.psm1: New-YurunaBridgeViaNmcli

Aplica-se a:

- [host/ubuntu.kvm/modules/Yuruna.Host.psm1](../../host/ubuntu.kvm/modules/Yuruna.Host.psm1)

Registre qual perfil mantém $Nic atualmente -- isso é necessário duas
vezes: o encerramento do caminho de sucesso desabilita sua conexão
automática (para que, ao reiniciar, a bridge seja ativada, em vez de a
NIC isolada recuperar o IP da LAN e deixar a bridge sem sinal de
enlace), e os caminhos de falha o reativam, para que uma construção
com falha NUNCA deixe o hospedeiro sem rede. Ele NÃO é modificado antes
da ativação: a ativação explícita do perfil subordinado abaixo já
substitui um perfil ativo concorrente, e alterar a conexão automática
antes abre uma janela em que uma falha (ou encerramento inesperado)
deixa a NIC sem nenhum perfil que possa reconectá-la.

Ative o perfil da bridge. Isso cria a interface de bridge no kernel,
sob controle de NM, mas AINDA NÃO usa o sinal de enlace de $Nic --
ao contrário de uma interpretação tentadora, `nmcli c up <bridge>`
não subordina automaticamente as portas participantes. A bridge fica
ativa, mas sem uplink, até que o perfil subordinado seja ativado abaixo;
o DHCP na bridge inicia, excede o prazo em ~45 s com `ip-config-unavailable`
e se repete -- exatamente o modo de falha que deixa a VM de cache sem
IP quando este ramo é pulado.

Fundamental: ative explicitamente o perfil subordinado para que $Nic
seja de fato subordinada à bridge. A conexão automática desse perfil
NÃO basta quando outro perfil (netplan-<nic>, "Wired
connection N", etc.) já mantém $Nic -- NM não desativa automaticamente
um perfil ativo concorrente para atender à conexão automática de um
perfil subordinado. Um `nmcli c up $slaveConn` iniciado pelo usuário
substitui essa política: NM desativa o perfil em conflito, vincula $Nic
ao perfil subordinado, a bridge recebe o novo sinal de enlace e DHCP
tem sucesso. Este é o momento em que as sessões SSH por $Nic oscilam;
com o MAC clonado acima, a nova concessão DHCP deve manter o mesmo IP,
e o SSH se reconecta em poucos segundos.

<a id="42e5cdfd-001c"></a>

## host/ubuntu.kvm/modules/Yuruna.Host.psm1: New-YurunaBridgeViaNetplan

Aplica-se a:

- [host/ubuntu.kvm/modules/Yuruna.Host.psm1](../../host/ubuntu.kvm/modules/Yuruna.Host.psm1)

Se NetworkManager gerencia a NIC atualmente (este caminho também serve
como fallback após uma construção nmcli com falha num hospedeiro NM),
transfira a NIC ANTES de aplicar. A regra udev NM_UNMANAGED gerada pelo
netplan só entra em vigor no próximo evento do dispositivo. Na janela
entre `netplan apply` reiniciar systemd-networkd e NM perceber a mudança,
os dois daemons configuram a NIC: networkd tenta subordiná-la, enquanto
NM reativa nela seu perfil -- e a bridge acaba sem uplink, de modo que
os convidados nunca veem uma oferta DHCP. `nmcli device set
managed no` libera o dispositivo imediatamente (somente em execução;
a regra udev torna isso persistente), e desabilitar a conexão automática
no perfil vinculado impede NM de recuperá-lo no próximo reinício.

Reversão local: devolva o hospedeiro exatamente ao estado anterior,
para que um retorno $false nunca deixe uma configuração netplan
parcialmente aplicada (uma configuração antiga é o que faz o caminho
nmcli da PRÓXIMA execução falhar com "no
compatible device"). `netplan apply` -- além de apenas gerar -- é
essencial: gerar só regrava arquivos em /run, e o systemd-networkd EM
EXECUÇÃO mantém a visão carregada da NIC como subordinada à bridge e
sem DHCP até receber a instrução de reler. Num hospedeiro que usa apenas
networkd (o público principal deste backend), aplicar é a única operação
que devolve a NIC à configuração netplan original remanescente e restaura
seu DHCP; sem isso, uma construção com falha deixa o hospedeiro sem
endereço até uma aplicação manual ou um reinício.

<a id="42e5cdfd-001d"></a>

## host/ubuntu.kvm/modules/Yuruna.Host.psm1: Test-CacheVMOnExternalNetwork

Aplica-se a:

- [host/ubuntu.kvm/modules/Yuruna.Host.psm1](../../host/ubuntu.kvm/modules/Yuruna.Host.psm1)

Segue a semântica do contrato Hyper-V: verdadeiro se, e somente se, a VM
de cache tem seu próprio IP roteável na LAN -- os consumidores da LAN
podem acessá-la diretamente, sem portproxy no hospedeiro no caminho.
No KVM, isso equivale a "<source network='...'/> da VM NÃO é a rede NAT
'default'". 'yuruna-external' (bridge), qualquer YURUNA_EXTERNAL_NETWORK
definida pelo usuário ou uma bridge personalizada são elegíveis; somente
a NAT interna 'default' (192.168.122/24, apenas no hospedeiro sem um
encaminhador de porta) não é.

<a id="42e5cdfd-001e"></a>

## host/ubuntu.kvm/modules/Yuruna.Host.psm1: Assert-Virtualization

Aplica-se a:

- [host/ubuntu.kvm/modules/Yuruna.Host.psm1](../../host/ubuntu.kvm/modules/Yuruna.Host.psm1)

Ter libvirtd ativo não significa que ESTE processo consiga acessá-lo.
Um usuário adicionado a 'libvirt' por usermod -aG só recebe o grupo em
seu conjunto efetivo depois de entrar novamente na sessão -- e, em
sistemas systemd-logind com sessões de usuário persistentes, até sair
e entrar de novo no desktop frequentemente NÃO atualiza as sessões de
terminal existentes. Sem essa verificação, o executor passa por
Assert-Virtualization, gasta ~8 minutos baixando ISOs e só ENTÃO falha
dentro de New-VM.ps1 com a linha literal "Permission denied" de libvirt-sock.

<a id="42e5cdfd-001f"></a>

<a id="hostubuntukvmmodulesyurunahostpsm1-dhcp-evidence-capture"></a>

## host/ubuntu.kvm/modules/Yuruna.Host.psm1: Captura de evidências de DHCP

Aplica-se a:

- [host/ubuntu.kvm/modules/Yuruna.Host.psm1](../../host/ubuntu.kvm/modules/Yuruna.Host.psm1)

Informe por que a evidência de DHCP está ausente. A captura é ativada em
cada inicialização de VM e copiada apenas no caminho de falha; portanto,
um ciclo que termina sem dhcp.capture.txt não permite distinguir uma
janela que nunca foi ativada de uma gravação recusada -- justamente o
ciclo em que alguém procura esse arquivo. A situação é informada em
duas superfícies porque nenhuma delas é completa sozinha: o aviso chega
ao console e à transcrição do processo, mas não ao fluxo de eventos
do próprio ciclo; o evento de degradação aparece junto do artefato
ausente, mas é descartado silenciosamente quando não há pasta de ciclo aberta.

<a id="42e5cdfd-0020"></a>

<a id="hostubuntukvmenable-testautomationps1-libvirt-services-and-default-network"></a>

## host/ubuntu.kvm/Enable-TestAutomation.ps1: Serviços libvirt e rede padrão

Aplica-se a:

- [host/ubuntu.kvm/Enable-TestAutomation.ps1](../../host/ubuntu.kvm/Enable-TestAutomation.ps1)

A execução dessas etapas depende de root estar acessível AGORA, nunca
de quem iniciou a execução. Somente install/ubuntu.kvm.sh executa esses
comandos antecipadamente; os demais chamadores não o fazem. Assim, uma
condição baseada na identidade do chamador deixa libvirtd desabilitado
nesses hospedeiros enquanto afirma que um invólucro já cuidou disso.

Reexecutá-los depois de o invólucro bash já tê-los executado é seguro:
systemctl enable --now, virsh net-start e virsh net-autostart são todos
idempotentes, e pagar esse custo é o preço de não adivinhar. Todas as
chamadas usam `sudo -n`; assim, uma credencial não preparada resulta
num código de saída, em vez de numa solicitação de senha num terminal
cuja saída está sendo capturada.

<a id="42e5cdfd-0021"></a>

<a id="hostubuntukvmenable-testautomationps1-status-service-lan-reachability"></a>

## host/ubuntu.kvm/Enable-TestAutomation.ps1: Acesso de Status-service pela LAN

Aplica-se a:

- [host/ubuntu.kvm/Enable-TestAutomation.ps1](../../host/ubuntu.kvm/Enable-TestAutomation.ps1)

Start-StatusService escuta em http://*:<port>/ (todas as interfaces), mas
um firewall do hospedeiro descarta silenciosamente TCP de entrada nas
interfaces que não são loopback quando não há regra de permissão --
assim, localhost responde, enquanto o serviço pool-aggregator (e o
navegador do operador) excede o prazo, e o hospedeiro desaparece do
dashboard do grupo. O caminho Windows abre esse acesso em
Set-WindowsHostConditionSet; faça aqui o equivalente com ufw para que
um hospedeiro Ubuntu também fique acessível. Esta é a correção
PERSISTENTE: um hospedeiro cujo executor está parado nunca reexecuta
a inicialização de status de cada ciclo; portanto, a autorreparação
de status-service não pode atuar ali -- a regra definida uma vez na
configuração inicial é o que persiste. A porta vem de test.config.yml
(8080 por padrão), a mesma fonte lida por Start-StatusService. Sem efeito
quando ufw está inativo ou ausente.

<a id="42e5cdfd-0022"></a>

<a id="hostubuntukvmenable-testautomationps1-host-clock"></a>

## host/ubuntu.kvm/Enable-TestAutomation.ps1: Relógio do hospedeiro

Aplica-se a:

- [host/ubuntu.kvm/Enable-TestAutomation.ps1](../../host/ubuntu.kvm/Enable-TestAutomation.ps1)

libvirt inicializa o relógio de cada convidado a partir deste hospedeiro
ao ligar; assim, um hospedeiro com horário incorreto inicia todas as VMs
com o mesmo erro, e o cliente NTP do próprio convidado ajusta o relógio
para a hora real alguns segundos após a inicialização -- em plena
inicialização dos serviços desse convidado. Num convidado Kubernetes,
isso deixa pods Running que nunca ficam Ready e todos os NodePort
recusando conexões, sem nada que aponte para um relógio como causa. Os
caminhos Windows e macOS fazem isso dentro de Set-*HostConditionSet;
este hospedeiro não tem um equivalente, então a mesma chamada fica aqui.

<a id="42e5cdfd-0023"></a>

<a id="hostubuntukvmenable-testautomationps1-pool-storage-mount-point"></a>

## host/ubuntu.kvm/Enable-TestAutomation.ps1: Ponto de montagem do armazenamento do grupo

Aplica-se a:

- [host/ubuntu.kvm/Enable-TestAutomation.ps1](../../host/ubuntu.kvm/Enable-TestAutomation.ps1)

O grupo networkStorage (test.config.yml) monta um compartilhamento SMB em
localPath. O executor de testes funciona SEM PRIVILÉGIOS; quando localPath
fica sob um diretório pai pertencente a root (por exemplo,
/mnt/ypool-nas sob /mnt 0755 root:root), o próprio New-Item de
Connect-YurunaPoolStorage não consegue criar o diretório, e a montagem
nem chega a ser tentada -- um NAS acessível que silenciosamente nunca
replica. Crie o ponto de montagem antecipadamente aqui, onde este script
de configuração do hospedeiro pode obter elevação, pertencendo ao
executor, para que o caminho de montagem sem privilégios já o encontre
presente e gravável. O auxiliar mount.cifs vem de cifs-utils
(install/ubuntu.kvm.sh).

<a id="42e5cdfd-0024"></a>

<a id="hostubuntukvmremove-orphanedvmfilesps1-delete-orphaned-vm-artifacts"></a>

## host/ubuntu.kvm/Remove-OrphanedVMFiles.ps1: Excluir artefatos órfãos de VM

Aplica-se a:

- [host/ubuntu.kvm/Remove-OrphanedVMFiles.ps1](../../host/ubuntu.kvm/Remove-OrphanedVMFiles.ps1)

Uma precaução adicional: verificar se o libvirt não passou a gerenciar o domínio
entre a varredura inicial e a exclusão efetiva.
A assinatura de item não encontrado abaixo é um texto do gettext, portanto as palavras precisam
ser fixadas; caso contrário, a verificação nunca encontra uma correspondência em um hospedeiro em outro idioma --
isso não exclui nada que não deveria, mas recusa toda
limpeza e deixa o operador com um aviso por órfão e sem uma maneira
de agir. LC_ALL é removida da chamada porque tem precedência sobre
LC_MESSAGES.

<a id="42e5cdfd-0025"></a>

<a id="hostubuntukvmsync-hostconfigurationps1-guest-address-discovery-readiness"></a>

## host/ubuntu.kvm/Sync-HostConfiguration.ps1: Prontidão para a descoberta de endereços dos convidados

Aplica-se a:

- [host/ubuntu.kvm/Sync-HostConfiguration.ps1](../../host/ubuntu.kvm/Sync-HostConfiguration.ps1)

Quais etapas de descoberta deste driver conseguem responder é determinado pela configuração
do hospedeiro, não pela infraestrutura de testes: a etapa de concessões exige que o libvirt seja o servidor DHCP
da rede do convidado, e a etapa do agente exige o qemu-guest-agent dentro
do convidado. Quando ambas são estruturalmente silenciosas, a descoberta depende inteiramente de uma
leitura passiva do cache de vizinhos do hospedeiro -- que expira, portanto as consultas começam
a falhar intermitentemente, e uma falha aparece para o operador como um erro de resolução
de nomes do ssh que não explica nenhum desses fatores.

Relatar isso aqui transforma um problema diagnosticado ao longo de muitos ciclos
malsucedidos em uma linha da saída de configuração.

<a id="42e5cdfd-0026"></a>

<a id="hostwindowshyper-vmodulesyurunahostpsm1-module-setup"></a>

## host/windows.hyper-v/modules/Yuruna.Host.psm1: Configuração do módulo

Aplica-se a:

- [host/windows.hyper-v/modules/Yuruna.Host.psm1](../../host/windows.hyper-v/modules/Yuruna.Host.psm1)

Caminho das ADK Deployment Tools. O '10' é a versão principal do ADK, não a versão
do Windows -- ajuste-o se outro ADK estiver instalado.

O ADK instala o Oscdimg uma vez por arquitetura -- amd64, arm64 e x86 estão
todos presentes após uma única instalação, tanto em um hospedeiro ARM64 quanto em um x64 --
portanto, o subdiretório é uma escolha, não uma constante. Fixar amd64 funciona em
ARM64, silenciosamente, por meio da camada de emulação x64, e é justamente isso que torna
difícil perceber a escolha incorreta: uma ISO de inicialização faz parte do caminho de cada convidado criado por
este driver, e ela continuaria funcionando até encontrar um hospedeiro em que essa
camada não estivesse disponível. Prefira a compilação nativa e mantenha as demais como
alternativas, para que até uma instalação parcial do ADK ofereça uma cópia executável.

<a id="42e5cdfd-0027"></a>

## host/windows.hyper-v/modules/Yuruna.Host.psm1: Resolve-OscdimgPath

Aplica-se a:

- [host/windows.hyper-v/modules/Yuruna.Host.psm1](../../host/windows.hyper-v/modules/Yuruna.Host.psm1)

A ferramenta fica sob uma raiz exclusiva do Windows. Fora do Windows, não há uma unidade C:
na qual Join-Path possa construir um caminho candidato, portanto ele falha e fornece
um caminho nulo à sondagem abaixo -- e Test-Path com um valor nulo gera um erro que um
chamador executado com ErrorActionPreference 'Stop' transforma em uma falha
de carregamento do módulo. Isso é executado durante a importação, portanto o módulo inteiro acaba
não sendo carregado, e cada consumidor relata um comando ausente em vez de uma
ferramenta ausente. Usa-se RuntimeInformation em vez de $IsWindows: esta última é
indefinida no PowerShell 5.1, em que -not $IsWindows é verdadeiro justamente na
plataforma para a qual esse caminho existe.

<a id="42e5cdfd-0028"></a>

## host/windows.hyper-v/modules/Yuruna.Host.psm1: Get-CacheVmCandidateIp

Aplica-se a:

- [host/windows.hyper-v/modules/Yuruna.Host.psm1](../../host/windows.hyper-v/modules/Yuruna.Host.psm1)

O KVP pode emitir IPv4 e IPv6. O v4 roteável pela rede permanece primeiro porque
os encaminhadores de portas usados adiante aqui são netsh portproxy v4tov4; as entradas
v6 também são mantidas para que os chamadores que lidam com v6 (SSH, TCP genérico)
continuem a vê-las. Endereços de loopback e de enlace local de ambas as famílias são excluídos.

Mantém-se um filtro no próprio local em vez de encaminhá-lo por
Select-YurunaRoutableAddress: este ponto precisa de toda a LISTA remanescente de
candidatos para classificá-los em relação aos resultados ARP abaixo, e o auxiliar compartilhado
deliberadamente responde com um único endereço. A regra de rejeição aplicada é a
mesma; altere ambas em conjunto.

<a id="42e5cdfd-0029"></a>

## host/windows.hyper-v/modules/Yuruna.Host.psm1: Get-OrCreateYurunaExternalSwitch

Aplica-se a:

- [host/windows.hyper-v/modules/Yuruna.Host.psm1](../../host/windows.hyper-v/modules/Yuruna.Host.psm1)

2. QUALQUER vSwitch existente do tipo External: reutilize-o em vez de
criar um segundo External redundante na mesma NIC. O Hyper-V
permite apenas um vSwitch External por adaptador físico, portanto uma
chamada indiscriminada de New-VMSwitch sobre um switch existente derruba o
original (interrupção de rede + toda VM existente no switch antigo
é desconectada). Em hospedeiros nos quais o operador criou previamente um
vSwitch External com outro nome (por exemplo, 'External',
'LAN-Bridge'), respeitamos essa escolha e retornamos seu nome. Essa mesma
invariante explica por que um switch External cuja bridge está degradada
é recusado aqui em vez de cair no caminho de criação.

<a id="42e5cdfd-002a"></a>

## host/windows.hyper-v/modules/Yuruna.Host.psm1: Start-WindowsCachingProxyServiceForwarder

Aplica-se a:

- [host/windows.hyper-v/modules/Yuruna.Host.psm1](../../host/windows.hyper-v/modules/Yuruna.Host.psm1)

-RedirectStandardInput com um arquivo vazio: sem um redirecionamento explícito
de stdin, o encaminhador desacoplado herda o identificador de stdin do console
pai, e o conhost do Windows não consegue terminar
quando o shell pai sai -- mantendo a janela de
PowerShell do operador em um estado de fechamento pendente até que o encaminhador
seja encerrado. Passar 'NUL' / '\\.\NUL' é rejeitado pelo
resolvedor de caminhos de Start-Process (ele acrescenta o cwd ao início e a
abertura de FileStream subjacente falha), portanto usamos um arquivo
sentinela vazio persistente no diretório de estado do encaminhador.

<a id="42e5cdfd-002b"></a>

## host/windows.hyper-v/modules/Yuruna.Host.psm1: Get-HyperVScreenshot

Aplica-se a:

- [host/windows.hyper-v/modules/Yuruna.Host.psm1](../../host/windows.hyper-v/modules/Yuruna.Host.psm1)

Detecta o sintoma de "headless host": o WMI retorna uma
miniatura válida, mas todos os pixels estão pretos porque o
DWM do hospedeiro não está desenhando ativamente a GPU sintética. O relato é feito
UMA VEZ por processo para que um ciclo longo de Start-TestRunner
não encha o log com a mesma mensagem a cada etapa.
Usa-se Verbose, não Warning: a alternativa PrintWindow/vmconnect
abaixo recupera um framebuffer utilizável, portanto um hospedeiro sem interface gráfica
continua passando -- aumente o nível do log para ver a
orientação de solução de problemas quando o OCR começar a exceder o tempo limite.

<a id="42e5cdfd-002c"></a>

## host/windows.hyper-v/modules/Yuruna.Host.psm1: Rename-VM

Aplica-se a:

- [host/windows.hyper-v/modules/Yuruna.Host.psm1](../../host/windows.hyper-v/modules/Yuruna.Host.psm1)

Uma NIC que ainda mantém o endereço derivado do nome ANTIGO está mantendo o
endereço desse NOME, não o do convidado, e o nome está sendo liberado --
deixá-lo ali faz com que todo convidado promovido para fora desse slot termine com um único
endereço em um único switch. Qualquer outro endereço foi fixado durante a criação à
identidade que este convidado conserva por toda a vida: alterá-lo faz uma nova solicitação DHCP para um convidado cujo próprio
estado já registra o endereço que ele possui, e nenhuma reinicialização resolve isso.
Somente o primeiro adaptador é considerado: uma segunda interface precisa de um segundo
endereço DISTINTO, e -VMName gravaria este endereço em ambas. O Hyper-V aceita
hexadecimal puro, sem separadores.

<a id="42e5cdfd-002d"></a>

<a id="hostwindowshyper-vmodulesyurunahostpsm1-dhcp-evidence-capture"></a>

## host/windows.hyper-v/modules/Yuruna.Host.psm1: Captura de evidências DHCP

Aplica-se a:

- [host/windows.hyper-v/modules/Yuruna.Host.psm1](../../host/windows.hyper-v/modules/Yuruna.Host.psm1)

O diagnóstico de rede do lado do convidado só consegue dizer "no lease". Se o
DISCOVER chegou a sair do convidado, desapareceu ao atravessar o vSwitch ou o uplink, ou
saiu e nunca recebeu resposta, isso só é visível no caminho dos pacotes do hospedeiro --
e cada uma dessas situações aponta para uma máquina diferente. O pktmon registra todos os
componentes atravessados por um pacote, portanto o ponto de descarte fica no artefato, e o
formato pcapng mantém os dados (client-id, xid) para identificar qual identidade fez a solicitação.

O pktmon permite UMA sessão por sistema, portanto cada início limpa a sessão que
o precedeu, e a captura é exclusiva de DHCP (portas 67/68) em um pequeno log
circular: uma sessão que nunca é interrompida -- um fluxo que inicia uma VM e nunca
a remove -- permanece limitada em vez de crescer com o tempo de atividade.

<a id="42e5cdfd-002e"></a>

## host/windows.hyper-v/modules/Yuruna.Host.psm1: Get-BestHostIp

Aplica-se a:

- [host/windows.hyper-v/modules/Yuruna.Host.psm1](../../host/windows.hyper-v/modules/Yuruna.Host.psm1)

Vincular uma NIC a um vSwitch External move o próprio endereço LAN do hospedeiro dessa
NIC para `vEthernet (<switch>)`, portanto, na topologia que esta
infraestrutura constrói, a resposta correta é SEMPRE um adaptador vEthernet.
Excluir todos os vEthernet -- a maneira óbvia de manter de fora as vNICs internas e
NAT (Default Switch, WSL) -- portanto descarta a única resposta
correta e acaba escolhendo qualquer adaptador NAT instalado por outro hipervisor:
um endereço que é resolvido localmente, não responde a nada e nunca muda,
o que é indistinguível de um hospedeiro que não está se movendo.

Um vEthernet é admitido por qualquer um de dois critérios independentes, e o
segundo mantém isso funcionando quando o primeiro não pode ser consultado:
Get-VMSwitch exige direitos de administrador do Hyper-V, e nem todo chamador os
possui, enquanto a rota padrão pode ser consultada por qualquer pessoa e está no
adaptador voltado à LAN, seja qual for o seu nome.

<a id="42e5cdfd-002f"></a>

<a id="hostwindowshyper-vremove-orphanedvmfilesps1-elevation-gate"></a>

## host/windows.hyper-v/Remove-OrphanedVMFiles.ps1: Verificação de elevação

Aplica-se a:

- [host/windows.hyper-v/Remove-OrphanedVMFiles.ps1](../../host/windows.hyper-v/Remove-OrphanedVMFiles.ps1)

Todo caminho abaixo exige privilégios de Administrator (Get-VMHost, Get-VM, Get-VMHardDiskDrive),
portanto a execução é recusada AQUI -- antes do aviso de operação destrutiva e da varredura
de imagens base -- em vez de após o operador ter lido "THIS CANNOT BE UNDONE" para uma
execução que não pode prosseguir. Usa-se Write-Warning, não Write-CleanupMessage: o módulo
ainda não foi importado, e -Quiet não deve suprimir o motivo da saída 1. Nem
Write-Error nem '#requires -RunAsAdministrator' serviriam: Remove-TestVMFiles.ps1
invoca isso no mesmo processo sob $ErrorActionPreference='Stop', em que qualquer um deles
abortaria a desmontagem do pai em vez de retornar uma saída 1 controlada.

<a id="42e5cdfd-0030"></a>

<a id="hostyurunahostcontractpsm1-virtualization-repair"></a>

## host/Yuruna.Host.Contract.psm1: Reparo da virtualização

Aplica-se a:

- [host/Yuruna.Host.Contract.psm1](../../host/Yuruna.Host.Contract.psm1)

O primeiro verbo é uma sondagem limitada e somente de leitura que retorna um registro
versionado (state/reason/started/timedOut/observedUtc/elapsedMs mais
evidências da plataforma), diferente do simples [bool] de Assert-Virtualization
acima: um chamador que decide se deve interromper o hipervisor precisa distinguir
um cliente ausente de uma permissão negada e de um tempo limite
real, não apenas obter sim ou não. O segundo inicia somente um serviço do hipervisor
que o próprio driver observa inequivocamente como parado, imediatamente antes de
agir, e recusa qualquer situação que não possa determinar; um chamador independente
do hospedeiro invoca ambos pelo mesmo nome em todas as plataformas.

<a id="42e5cdfd-0031"></a>

<a id="testservicestart-cachingproxyservicevmps1-preflight"></a>

## test/service/Start-CachingProxyServiceVM.ps1: Verificação prévia

Aplica-se a:

- [test/service/Start-CachingProxyServiceVM.ps1](../../test/service/Start-CachingProxyServiceVM.ps1)

A partir deste ponto, Start-CachingProxyServiceVM é executado SEM INTERVENÇÃO -- ele não deve parar
para uma solicitação interativa. Tudo que exige conhecimento do operador é
apresentado e resolvido AQUI, no início:
  * uma alteração na rede do hospedeiro (a bridge 'yuruna-external') é descrita
    antecipadamente por Get-YurunaExternalNetworkPlan, antes de qualquer ação;
  * o sudo é preparado uma vez, com os motivos, para que nenhuma etapa volte a pedir autenticação;
  * requisitos obrigatórios (/dev/kvm, libvirtd) são verificados para que uma execução inviável
    pare AGORA com uma explicação clara em vez de falhar em um ponto avançado
    da Etapa 3 (virt-install) após baixar uma imagem durante vários minutos.

<a id="42e5cdfd-0032"></a>

<a id="testservicestart-cachingproxyservicevmps1-bridge-plan----does-the-bridge-step-perturb-host-networking"></a>

## test/service/Start-CachingProxyServiceVM.ps1: Plano da bridge -- a etapa da bridge interfere na rede do hospedeiro?

Aplica-se a:

- [test/service/Start-CachingProxyServiceVM.ps1](../../test/service/Start-CachingProxyServiceVM.ps1)

Prepare o sudo UMA VEZ, agora, com os motivos -- para que a limpeza do proxy do hospedeiro (Etapa 1)
e, no Linux, as chamadas `sudo nmcli` da bridge (Etapa 1.5) nunca peçam autenticação
no meio da execução. Initialize-SudoCache é idempotente e silencioso quando o cache
já está válido ou não é necessária elevação (por exemplo, ao executar como root).
A limpeza do proxy do hospedeiro na Etapa 1 exige root, mas o mecanismo difere por
plataforma -- indique o mecanismo real para que a caixa de solicitação explique por que ESTE hospedeiro
está pedindo autenticação. O macOS limpa o proxy do sistema por networksetup; o Linux edita
/etc/environment + a configuração de proxy do apt. (O Windows ignora inteiramente o sudo,
portanto esse texto nunca é exibido nele.) Primeiro construa o motivo base como um escalar
e depois envolva-o em @(), para que o += posterior acrescente elementos em vez de concatenar uma
string a um array de um único elemento que não esteja envolvido.

<a id="42e5cdfd-0033"></a>

<a id="testservicestart-cachingproxyservicevmps1-remove-existing-vm"></a>

## test/service/Start-CachingProxyServiceVM.ps1: Remover a VM existente

Aplica-se a:

- [test/service/Start-CachingProxyServiceVM.ps1](../../test/service/Start-CachingProxyServiceVM.ps1)

Encerre quaisquer encaminhadores TCP remanescentes do lado do hospedeiro, provenientes do caminho
de NAT compartilhado descontinuado (subprocessos pwsh forwarder.<port>.pid sob
$HOME/yuruna/image/caching-proxy-service). Com a VM de cache conectada por bridge, esses
encaminhadores não são mais necessários -- e, se continuarem em execução em
0.0.0.0:3128, entrariam em conflito com qualquer pessoa que depois definisse
YURUNA_CACHING_PROXY_SERVICE_IP=<host-lan-ip> apontando de volta para este Mac.
Nenhuma ação é realizada em uma instalação nova. Stop-CachingProxyServiceVM.ps1 também chama isso
de maneira simétrica.

<a id="42e5cdfd-0034"></a>

<a id="testservicestart-cachingproxyservicevmps1-host-status-service-bootstrap"></a>

## test/service/Start-CachingProxyServiceVM.ps1: Inicialização de status-service do hospedeiro

Aplica-se a:

- [test/service/Start-CachingProxyServiceVM.ps1](../../test/service/Start-CachingProxyServiceVM.ps1)

O bloco de criação cloud-init da VM de cache busca o código-fonte do coletor e do analisador
na árvore de trabalho LOCAL do hospedeiro (http://<host>:<port>/yuruna-repo/) em vez
do espelho público no github -- este repositório é a fonte de verdade. Isso exige
que o status service esteja em execução neste hospedeiro quando o convidado for criado (~20-35 min após
o início da primeira inicialização). Inicie-o agora (desacoplado; ele persiste após a saída deste script) para que uma
recriação independente do cache busque o código-fonte local. Respeita statusService.enabled;
se estiver desabilitado, a criação do convidado recorre ao github (o coletor pode estar ausente,
mas os painéis Grafana incorporados ainda são implantados).

<a id="42e5cdfd-0035"></a>

<a id="testservicestart-cachingproxyservicevmps1-start-the-host-status-service"></a>

## test/service/Start-CachingProxyServiceVM.ps1: Iniciar o status service do hospedeiro

Aplica-se a:

- [test/service/Start-CachingProxyServiceVM.ps1](../../test/service/Start-CachingProxyServiceVM.ps1)

A VM de cache monta ystash-nas (para a varredura dos hospedeiros de Extension) e ypool-nas
usando credenciais que busca na inicialização E a cada hora neste serviço por TLS
mútuo, para que uma senha NAS alterada chegue à VM em execução sem recriação (a correção
para a desatualização causada por incorporar as credenciais uma única vez). O mTLS limita o acesso às VMs criadas por ESTE hospedeiro --
cada uma carrega um certificado de cliente assinado pela Config CA deste hospedeiro. Desacoplado; persiste
após este script. Faz o possível: se falhar, o convidado recorre à credencial
incorporada (a alteração apenas não será propagada até que o serviço esteja disponível). Respeita
configService.enabled (padrão true).

<a id="42e5cdfd-0036"></a>

<a id="testservicestart-cachingproxyservicevmps1-start-the-host-config-service"></a>

## test/service/Start-CachingProxyServiceVM.ps1: Iniciar o serviço de configuração do hospedeiro

Aplica-se a:

- [test/service/Start-CachingProxyServiceVM.ps1](../../test/service/Start-CachingProxyServiceVM.ps1)

A garantia acima faz o possível: Start-ConfigService apenas AVISA (nunca
falha) quando sua porta nunca fica disponível, portanto verifique isso AQUI, antes que a Etapa 3 crie
a VM. New-VM emite o certificado de cliente mTLS da VM de cache a partir da Config CA DESTE hospedeiro
(que este serviço inicializa) e o incorpora à imagem de inicialização; a VM então busca
suas credenciais ystash-nas/ypool-nas neste endpoint na inicialização. Um serviço
INDISPONÍVEL durante a criação é a causa silenciosa de uma VM de cache que incorpora materiais mTLS VAZIOS,
nunca monta ystash-nas e mostra um painel "Extension hosts" vazio.
Apresente o problema agora (de forma explícita) em vez de deixar que o operador o descubra depois.

<a id="42e5cdfd-0037"></a>

<a id="testservicestart-cachingproxyservicevmps1-register-and-start-the-utm-vm"></a>

## test/service/Start-CachingProxyServiceVM.ps1: Registrar e iniciar a VM UTM

Aplica-se a:

- [test/service/Start-CachingProxyServiceVM.ps1](../../test/service/Start-CachingProxyServiceVM.ps1)

Dispensa automaticamente o aviso modal do UTM "this VM uses custom QEMU arguments which is
potentially dangerous". A VM de cache executa o backend QEMU com
-vnc AdditionalArguments (guest.caching-proxy-service/config.plist.template), portanto
o UTM condiciona toda inicialização a essa confirmação -- o que bloquearia
esta ativação sem intervenção até que uma pessoa clicasse em Continue. O UTM não oferece
uma maneira de suprimi-la (é uma verificação de segurança deliberada), portanto reutilize o mesmo
watchdog osascript que Start-UtmVM usa no caminho de Start-TestRunner.
Garanta que o módulo de hospedeiro do macOS (que exporta o watchdog) esteja carregado --
Get-Image / New-VM das Etapas 2/3 executam importações com -Force que podem remover a
cópia carregada pela Etapa 1 (feedback_module_force_import_evicts_global); somente
reimporte quando a função realmente estiver ausente para não provocar
uma sequência desnecessária de importações aninhadas.

Em um pacote recém-importado, `utmctl start` pode retornar 0 no nível RPC
enquanto o UTM ainda está finalizando a ingestão do pacote, e a solicitação
de início é descartada silenciosamente -- a VM permanece em 'stopped'. Verifique a
transição analisando a saída de `utmctl status` e repita a tentativa algumas vezes.
`utmctl status` imprime um dos valores: started / paused / stopped / suspended.

A correspondência usa uma lista de PERMISSÃO para o único estado que significa "running". Uma
lista de negação dos estados sabidamente ruins parece equivalente até o UTM relatar
algo que a lista não menciona, e então isso é interpretado como sucesso:
'suspended' é uma VM cuja RAM foi gravada em disco e cuja CPU
não está executando, o que passa em um teste "not stopped, not paused" apesar de ser
tão inutilizável quanto 'stopped'. Tudo após este ponto -- uma varredura de descoberta de 15
minutos, seguida pelo que quer que espere pelo serviço dentro do
convidado -- então gasta todo o seu orçamento em uma VM que não está em execução.

As duas palavras aceitas são o par aceito por Confirm-UtmVMStarted, portanto esta
verificação e a do contrato do hospedeiro não podem discordar sobre o significado de estar em execução. Uma
lista mais restrita aqui seria um risco próprio: um estado que o auxiliar compartilhado considera
em execução e este não considera resulta em uma ativação que falha enquanto a VM está ativa.

O código de saída retorna com a saída à qual pertence, nunca
a partir de $LASTEXITCODE, que uma etapa posterior do pipeline ou uma chamada nativa
pode deixar descrevendo outro comando. Uma chamada que excedeu o tempo limite,
foi interrompida ou truncada conta como ausência de resposta (-1). O stderr é
lido junto com stdout, portanto um status recusado (Apple Events negado imprime
"Error from event: ... OSStatus error -1743") é visto como texto,
e nunca corresponde a uma palavra de estado, portanto nunca é interpretado como
o estado da VM.

O estado observado é indicado pelo nome porque os estados possíveis exigem coisas diferentes
do operador: 'stopped' é uma inicialização que nunca ocorreu,
'suspended' é uma VM que iniciou e depois foi salva em disco por
algo mais nesta máquina, e 'paused' é uma VM deliberadamente mantida parada.
Um status que nunca respondeu é um quarto caso próprio -- utmctl se comunica com
o UTM por Apple Events, que um hospedeiro que não tenha concedido Automation
nega imediatamente -- portanto isso é relatado como silêncio em vez de ser apresentado
como um estado que o UTM nunca informou.

<a id="42e5cdfd-0038"></a>

<a id="testservicestart-cachingproxyservicevmps1-configure-shared-nat-forwarding"></a>

## test/service/Start-CachingProxyServiceVM.ps1: Configurar o encaminhamento de NAT compartilhado

Aplica-se a:

- [test/service/Start-CachingProxyServiceVM.ps1](../../test/service/Start-CachingProxyServiceVM.ps1)

Identifique a VM de cache pelo MAC de seu pacote via ARP -- NÃO pelo nome de hospedeiro
do DHCP. Um cache recriado reutiliza o nome 'yuruna-caching-proxy-service',
portanto /var/db/dhcpd_leases acumula blocos desatualizados com o mesmo nome de
predecessores excluídos; uma consulta por nome feita antes que ESTA VM
conclua o DHCP se fixa no IP de um predecessor inativo, e os encaminhadores
então criam túneis para um endereço em que nada está escutando (protege contra a classe de regressão
de descoberta por concessão desatualizada). A VM está no UTM Shared NAT
(192.168.64.0/24), com o hospedeiro como gateway, portanto envia ARP ao hospedeiro
e aparece em `arp -an`; Resolve-UtmGuestIpByMac também espera pelo
squid em :$httpPort, portanto o IP que retorna é um endereço servido pelo squid.

A descoberta por MAC/ARP acima pode levar minutos -- mais que a validade de ~5-min
do sudo preparada na Etapa 0. Add-PortMap inicia o encaminhador :80
(abaixo de 1024) por `sudo -E pwsh`; com a validade expirada,
esse sudo pede uma senha de forma ASSÍNCRONA no TTY,
concorrendo com a saída deste script sem contexto (o operador vê um
simples "Password:" no meio da ativação). Revalide o sudo agora, com um
motivo claro, para que o encaminhador privilegiado faça a vinculação silenciosamente. Faz o possível:
uma preparação recusada apenas ignora o encaminhador :80 (uma conveniência de certificado
CA para a LAN remota); todo o restante continua sendo ativado.

`utmctl ip-address` não funciona para VMs Apple Virtualization
("Operation not supported by the backend"). A VM de cache está
conectada por bridge à NIC LAN do hospedeiro (config.plist.template,
VZBridgedNetworkDeviceAttachment), portanto sua concessão DHCP fica na
mesma /24 em que está o hospedeiro. Identificamos NOSSA VM pelo MAC com o qual o
pacote foi criado (aleatório por pacote, gravado em
config.plist por guest.caching-proxy-service/New-VM.ps1) e consultamos seu IP
na tabela ARP do hospedeiro -- nunca pelo "first :3128 we find on the
LAN", o que se fixaria sem dificuldade no yuruna-caching-
proxy de outro hospedeiro que obtivesse DHCP antes do nosso. Corresponde ao contrato
restrito de Test-CachingProxyServiceAvailable: somente caches que nos pertencem.

Identifique NOSSA VM pelo MAC do pacote via ARP (Resolve-UtmGuestIpByMac):
o pacote é novo (a Etapa 3 acabou de criá-lo), portanto seu MAC de config.plist
é inequivocamente o usado pela VM de cache na inicialização. O auxiliar
faz uma varredura ICMP da /24 para preencher o cache ARP, encontra nosso MAC e
espera pelo squid em :$httpPort antes de retornar -- nunca pelo "first :3128
we find", o que se fixaria no cache de outro hospedeiro que obtivesse DHCP primeiro.
É o mesmo auxiliar usado pelo ramo Shared-NAT, portanto ambos os caminhos compartilham uma
única implementação testada.

<a id="42e5cdfd-0039"></a>

<a id="testservicestart-cachingproxyservicevmps1-step-6-macos-bridged----tear-down-legacy-host-side-forwarders"></a>

## test/service/Start-CachingProxyServiceVM.ps1: Etapa 6: macOS com bridge -- encerrar encaminhadores legados do lado do hospedeiro

Aplica-se a:

- [test/service/Start-CachingProxyServiceVM.ps1](../../test/service/Start-CachingProxyServiceVM.ps1)

Persista o IP LAN da VM de cache para que os provisionadores de convidados e o
caminho rápido do status service não precisem redescobri-lo. O
hospedeiro acessa o cache diretamente na LAN (mesma /24); os provisionadores de convidados
incorporam o certificado CA em base64, buscando-o por
`curl http://<cacheIp>/yuruna-squid-ca.crt` a partir do hospedeiro.

A reimportação é obrigatória após Initialize-YurunaHost da Etapa 5:
docs/workarounds.md#nested-non-global-import-evicts-a-callers-view-of-a-module

<a id="42e5cdfd-003a"></a>

<a id="testservicestart-cachingproxyservicevmps1-linux----re-query-the-cache-vm-ip-for-persistence--summary"></a>

## test/service/Start-CachingProxyServiceVM.ps1: Linux -- consultar novamente o IP da VM de cache para persistência e resumo

Aplica-se a:

- [test/service/Start-CachingProxyServiceVM.ps1](../../test/service/Start-CachingProxyServiceVM.ps1)

Exposição à LAN. Em uma rede com bridge 'yuruna-external' (ou qualquer rede que não seja a padrão),
a VM tem seu próprio IP LAN e os consumidores remotos a acessam
diretamente em $cacheIp. Na rede NAT 'default', a VM é
acessível somente pelo hospedeiro, portanto Add-PortMap instala encaminhadores
ativados por socket do systemd (systemd-socket-proxyd), e os clientes LAN acessam o cache
no IP LAN do HOSPEDEIRO. Veja Add-PortMap em host/ubuntu.kvm/modules/
Yuruna.Host.psm1 para saber por que se usa encaminhamento por socket em vez de DNAT
do nftables: a própria cadeia de encaminhamento do libvirt rejeita entrada com DNAT para seus
convidados NAT, e contornar isso depende do backend do firewall.

O PAINEL do grupo não funciona neste caminho NAT, e o encaminhador
não pode fazê-lo funcionar: systemd-socket-proxyd origina novamente cada
conexão a partir do hospedeiro, portanto o squid registra UM IP de cliente (o gateway
NAT 192.168.122.1) para toda a LAN. O pool-aggregator-service
descobre hospedeiros pelo IP real de cliente no log do squid, portanto não descobre
nenhum, e http://<this-host>:3000/d/yuruna-pool/yuruna-hosts mostra
"No data". Um serviço de proxy de cache que apenas armazena em cache (convidados do mesmo hospedeiro)
funciona bem com NAT; a visualização do grupo com vários hospedeiros precisa da VM de cache conectada por BRIDGE para que
o squid veja os IPs reais dos clientes (as VMs de cache macOS UTM / Hyper-V são
conectadas por bridge, e é por isso que seus painéis de grupo são preenchidos).

<a id="42e5cdfd-003b"></a>

<a id="testservicestart-cachingproxyservicevmps1-windows----discover-the-cache-vm-and-expose-its-ports-to-the-lan"></a>

## test/service/Start-CachingProxyServiceVM.ps1: Windows -- descobrir a VM de cache e expor suas portas à LAN

Aplica-se a:

- [test/service/Start-CachingProxyServiceVM.ps1](../../test/service/Start-CachingProxyServiceVM.ps1)

Exponha as portas da VM de cache à LAN do hospedeiro para que clientes remotos possam
acessar o squid (:3128 / :3129), o Apache (:80 servindo yuruna-squid-ca.crt)
e o Grafana (:3000). Os convidados locais no Default Switch já acessam
a VM diretamente (a sub-rede NAT 172.25.x.x é visível a partir do hospedeiro e
de todo convidado Hyper-V nesse switch), portanto este portproxy acrescenta exposição
à LAN sem alterar o caminho dos convidados locais -- eles continuam apontando
para o IP privado da VM. A lista de portas corresponde à chamada
Add-PortMap de Start-TestRunner.ps1; listas diferentes entram em conflito porque
a função executa Clear-AllCachingProxyServicePortMapping primeiro. Exige
elevação; caso contrário, Add-PortMap avisa e não faz nada.

Se a VM de cache estiver em um vSwitch External, ela terá seu próprio IP
LAN via DHCP, e os clientes remotos a acessarão diretamente -- o squid vê
os IPs reais dos clientes no nível TCP, sem precisar de um encaminhador do lado do hospedeiro.
Remova quaisquer regras de netsh portproxy / firewall remanescentes de um
ciclo anterior com Default-Switch para que não reescrevam o tráfego por NAT
para um caminho host:port desatualizado. Na alternativa Default-Switch,
configure o netsh portproxy como antes -- o IP Helper em modo kernel é
o único caminho acessível pela LAN neste hospedeiro Hyper-V (o encaminhador
pwsh em modo de usuário é descartado silenciosamente por Defender / EDR /
WFP independentemente das regras -- veja docs/caching.md).

<a id="42e5cdfd-003c"></a>

<a id="testservicestart-cachingproxyservicevmps1-report-the-service-state"></a>

## test/service/Start-CachingProxyServiceVM.ps1: Relatar o estado do serviço

Aplica-se a:

- [test/service/Start-CachingProxyServiceVM.ps1](../../test/service/Start-CachingProxyServiceVM.ps1)

Wi-Fi/NAT compartilhado: o cache está em $cacheIp (192.168.64.x). No macOS 26
UTM vmnet-shared, toda VM ingressa em uma única bridge (192.168.64.1), e os convidados
roteiam diretamente entre si, portanto ESTE hospedeiro E uma VM de teste iniciada no
mesmo Mac acessam o cache em $cacheIp sem variável de ambiente e sem
encaminhador do lado do hospedeiro -- o convidado o descobre automaticamente. Os encaminhadores pwsh
em $cacheLanIp existem SOMENTE para hospedeiros remotos da LAN e fazem o possível:
qualquer ciclo que execute Remove-PortMap (uma execução de teste, uma
reinicialização de status-service) os encerra, portanto $cacheLanIp não é um
endereço confiável em estado estável.

<a id="42e5cdfd-003d"></a>

<a id="testservicestart-statusserviceps1-module-setup"></a>

## test/service/Start-StatusService.ps1: Configuração do módulo

Aplica-se a:

- [test/service/Start-StatusService.ps1](../../test/service/Start-StatusService.ps1)

Duas inicializações do mesmo runtime não devem se intercalar: uma inicialização que encontre um servidor
ainda sem responder o interpreta como inativo, e o caminho normal então o encerra. O
bloqueio de inicialização as serializa. Ele fica na raiz de estado privada, identificado pelo
runtime, porque o diretório do runtime é servido e metadados de bloqueio ali
seriam públicos, e para que os listeners de duas cópias de trabalho nunca esperem um pelo outro.
A inicialização normal espera por um tempo limitado e depois prossegue sem o bloqueio (uma
inicialização que nunca ocorre é pior que a condição de corrida); a inicialização segura para atualização
recusa a execução, porque sua promessa inteira é não interferir em nada.

O bloqueio é um identificador aberto mantido por este processo. A inicialização normal é
invocada com & dentro do executor interno de longa duração, portanto um identificador que permanecesse aberto após
este script bloquearia toda inicialização posterior durante a vida desse processo:
cada saída abaixo o libera primeiro, e o trap o libera em qualquer
erro não capturado, deixando o erro se propagar sem alteração (inclusive a exceção
identificada de conflito de porta).

<a id="42e5cdfd-003e"></a>

<a id="testservicestart-statusserviceps1-startup-serialization-and-the-refresh-safe-outcome"></a>

## test/service/Start-StatusService.ps1: Serialização da inicialização e resultado seguro para atualização

Aplica-se a:

- [test/service/Start-StatusService.ps1](../../test/service/Start-StatusService.ps1)

O servidor desacoplado incorpora a here-string de ~1.5 KLOC (e os módulos
que importa na inicialização) em seu estado em memória. Os arquivos em test/status/
são servidos do disco a cada solicitação, portanto alterações no frontend NÃO exigem
reinicialização; apenas uma mudança no código da infraestrutura exige. Persistimos o
SHA do HEAD da infraestrutura em server.sha na inicialização e o comparamos aqui, para que
o ciclo sem mudanças do executor interno (o caso comum) não faça nada
em vez de executar um encerramento de 1 s + uma reinicialização de vários segundos. A indisponibilidade no início do ciclo
cai de "a cada ciclo" para "somente quando `git pull` realmente obtém
algo que afeta o servidor".

<a id="42e5cdfd-003f"></a>

<a id="testservicestart-statusserviceps1-check-for-an-existing-server"></a>

## test/service/Start-StatusService.ps1: Verificar a existência de um servidor

Aplica-se a:

- [test/service/Start-StatusService.ps1](../../test/service/Start-StatusService.ps1)

Resolve conflitos de porta causados por servidores desacoplados órfãos não rastreados.
Por que isso é necessário e o contrato de despacho de Test.PortOwner.psm1:
https://yuruna.link/42d38664

-Elevate: assume a porta mesmo quando seu detentor é alguém que esta conta não consegue encerrar.
Nesse caso, o detentor quase sempre é um status service que esta mesma infraestrutura de testes
deixou como ROOT durante uma execução anterior com sudo -- invisível para um
lsof sem privilégios e imune a um kill sem privilégios. Devolver isso na forma de instruções faz
o operador concluir uma limpeza causada pela infraestrutura de testes e que ela mesma pode realizar; ela já
tem a autorização (ou pode pedi-la uma vez). Cada alvo é identificado quando é
encerrado, e este processo, seus ancestrais e o pid 1 nunca são candidatos.

A inicialização segura para atualização não assume nada: qualquer porta ocupada é relatada, e
o caso de privilégio é distinguido de um detentor real pelo mesmo motivo pelo qual o
caminho normal os distingue.

Recuse e faça a recusa SE PROPAGAR. Um simples `exit 1` aqui apenas
definiria $LASTEXITCODE para a invocação pelo operador de chamada executada pela verificação compartilhada
(`& $StartScript`), portanto o ciclo pai continuaria sem um servidor de
status -- a armadilha de ciclo cego contra a qual isso protege. Lance uma exceção
identificada: Start-YurunaStatusServiceIfEnabled reconhece a identificação
e aborta o ponto de entrada de forma limpa; uma execução independente sai com código diferente de zero quando
a exceção não é capturada. A detecção é independente do sistema operacional (sondagem de vinculação HttpListener), portanto
isso funciona de maneira idêntica no macOS/UTM, Ubuntu/KVM e Windows/Hyper-V.

<a id="42e5cdfd-0040"></a>

<a id="testservicestart-statusserviceps1-ensure-repourl-is-set-in-statusjson"></a>

## test/service/Start-StatusService.ps1: Garantir que repoUrl esteja definido em status.json

Aplica-se a:

- [test/service/Start-StatusService.ps1](../../test/service/Start-StatusService.ps1)

server.heartbeat: o servidor não lê mais isso; remova-o para que quem inspeciona
não pense que ele ainda tem uma função essencial.
Caminhos legados diretamente em test/status/ e no antigo
test/status/track/ (agora test/status/runtime/): disposições mais antigas no disco
colocam server.pid, runner.pid, status.json, server.err,
current-action.json, control.*-pause, .status-service.ps1 nesses
locais. Uma atualização da cópia de trabalho pode deixá-los não rastreados (não mais
ignorados por .gitignore), enchendo `git status`. Remova-os em toda inicialização para que
as execuções do operador terminem com um diretório de status limpo.
A inicialização segura para atualização ignora essa varredura: ela remove o arquivo auxiliar de interrupção e
o sinalizador de continuação, dos quais um executor pausado ainda precisa.

<a id="42e5cdfd-0041"></a>

<a id="testservicestart-statusserviceps1-clean-up-leftovers-from-older-layouts"></a>

## test/service/Start-StatusService.ps1: Limpar resíduos de disposições anteriores

Aplica-se a:

- [test/service/Start-StatusService.ps1](../../test/service/Start-StatusService.ps1)

O rodapé da interface lê isso para mostrar endereços acessíveis. Endereços de loopback
(127.0.0.1, ::1) são excluídos -- não servem para clientes remotos.

Formato do arquivo:
  * Sem endereços  -> uma única linha "No IP addresses detected"
  * Com endereços  -> até duas linhas:
      linha 1: IPv4, separados por vírgulas (omitida se não houver)
      linha 2: IPv6, separados por vírgulas (omitida se não houver)

Separe IPv4/IPv6 para que a interface renderize duas linhas curtas em vez de uma sequência
longa. O arquivo é sobrescrito a cada invocação de Start-StatusService para que
entradas desatualizadas de um hospedeiro ou uma rede anterior não sejam preservadas.

<a id="42e5cdfd-0042"></a>

<a id="testservicestart-statusserviceps1-detect-host-type"></a>

## test/service/Start-StatusService.ps1: Detectar o tipo de hospedeiro

Aplica-se a:

- [test/service/Start-StatusService.ps1](../../test/service/Start-StatusService.ps1)

macOS: as chamadas Remove-PortMap na região de mapeamento de portas abaixo limpam TUDO,
portanto encerram todo encaminhador do lado do hospedeiro -- e encerrar o encaminhador :80 de propriedade
de root que Start-CachingProxyServiceVM criou no caminho Shared-NAT
exige sudo. Sem tratamento, isso dispara uma solicitação simples "[sudo] password for ..." em um ponto avançado
da execução, inclusive no caminho sem intervenção a cada ciclo. Detecte a condição
exata e anuncie o motivo AGORA, para que a solicitação nunca seja uma surpresa e
um hospedeiro sem esse encaminhador nunca receba o pedido. Reflete a mesma detecção em
Stop-CachingProxyServiceVM.ps1; autocontido (pidfile + /bin/ps), sem importação.

<a id="42e5cdfd-0043"></a>

<a id="testservicestart-statusserviceps1-announce-the-forwarder-teardowns-sudo"></a>

## test/service/Start-StatusService.ps1: Anunciar o sudo necessário para encerrar o encaminhador

Aplica-se a:

- [test/service/Start-StatusService.ps1](../../test/service/Start-StatusService.ps1)

Este script é chamado NO MESMO PROCESSO por todas as quatro ativações de serviço
(Start-YurunaStatusServiceIfEnabled), e elas têm sua saída
capturada por quem quer que as tenha iniciado -- install/setup.ps1, um ciclo do executor.
Uma solicitação de senha ali fica invisível: o texto vai para um log, e a
execução espera uma tecla que ninguém sabe que deve pressionar. Portanto, quando o chamador tiver
declarado a execução não interativa, faça a sondagem com -n e relate em vez de
pedir autenticação. O gatilho é um encaminhador de propriedade de root de uma ativação
anterior, ou seja, precisamente o caso de nova execução, e é por isso que isso ocorre nas
máquinas menos capazes de responder.

<a id="42e5cdfd-0044"></a>

<a id="testservicestart-statusserviceps1-probe-proxy-cache---envyuruna_runtime_dircaching-proxy-servicetxt"></a>

## test/service/Start-StatusService.ps1: Sondar o cache do proxy -> $env:YURUNA_RUNTIME_DIR/caching-proxy-service.txt

Aplica-se a:

- [test/service/Start-StatusService.ps1](../../test/service/Start-StatusService.ps1)

-Quiet: esta sondagem DECORA o banner do painel com a URL do cache
quando existe um cache. A ausência é um estado normal -- e é o estado
GARANTIDO quando o chamador é Start-CachingProxyServiceVM.ps1,
que inicia este serviço na etapa imediatamente anterior à criação do
cache. Emitir um aviso ali e dizer ao operador para apontar
YURUNA_CACHING_PROXY_SERVICE_IP para um cache remoto descreve um problema
que ninguém tem. A própria sondagem de inicialização do executor continua explícita: a ausência de um
cache ali custa silenciosamente todos os downloads do ciclo.

Resolva PRIMEIRO o cache configurado pelo operador. A sondagem consulta somente
$Env:YURUNA_CACHING_PROXY_SERVICE_IP e o próprio arquivo de estado da VM de cache deste
hospedeiro -- nunca vmStart.cachingProxyIp -- e essa variável de ambiente é
publicada pela verificação de proxy de cache do ciclo. Um status service iniciado por
qualquer coisa que não seja um ciclo em execução, portanto, faz a sondagem sem nenhuma das fontes
definidas, não encontra nada e relata como ausente um cache remoto que está ativo e
servindo. O mesmo arquivo é a origem do link Dashboards, portanto a
resposta errada também remove o link no momento em que o operador vai
procurá-lo. A resolução aqui aplica a mesma precedência e a mesma
aceitação de :3128 aplicada pelo ciclo, para que o banner indique o cache que o
ciclo usaria -- ou permaneça em silêncio quando nada responder.

Mapeamento de portas para que o banner da página de status relate o mesmo
estado que a saída de console de Start-TestRunner.
Add-PortMap despacha por plataforma pelo driver do hospedeiro
(netsh portproxy no Hyper-V, encaminhadores TcpListener
desacoplados no macOS/UTM). Ambos os canais leem
o mesmo caching-proxy-service.txt para que banner e console permaneçam
sincronizados.

Windows: as listas de portas dos chamadores DEVEM corresponder -- Add-PortMap
executa Clear-AllCachingProxyServicePortMapping primeiro (netsh limpa tudo), portanto
qualquer porta omitida aqui seria removida. macOS: os pidfiles por porta
permitem que cada chamador gerencie seu próprio subconjunto de forma independente; nenhuma correspondência
é necessária. A alternativa do macOS inclui a porta 80 e o Grafana em 3000; o
caminho do cache conectado por bridge usa diretamente o endereço da VM.

Ramo de cache externo: quando $Env:YURUNA_CACHING_PROXY_SERVICE_IP
está definido, Test-CachingProxyServiceAvailable retorna a URL remota, e
o próprio hospedeiro remoto expõe todas as suas portas. Ignore inteiramente
o portproxy/encaminhador local -- o link do painel
aponta diretamente para o IP remoto.

O tratamento externo abaixo remove os encaminhadores deste
hospedeiro, portanto só pode ser executado quando o endpoint for
INEQUIVOCAMENTE diferente deste hospedeiro. 'local': o endpoint é o próprio
conjunto de encaminhadores deste hospedeiro à frente de sua VM de cache sob NAT --
removê-lo corta os listeners que acabaram de responder à
sondagem (autoencerramento). 'unknown': lacunas transitórias na enumeração
das NICs devem ser tratadas como locais, porque um
veredito 'external' errado encerra os encaminhadores, enquanto
um veredito 'local' errado apenas reafirma um mapeamento de porta.

Initialize-YurunaHost já foi chamado acima; Add-PortMap /
Remove-PortMap / Get-BestHostIp agora podem ser resolvidos por Yuruna.Host.

Serialize todo o bloco de classificação e gravação em relação à
atualização por ciclo do executor e à ativação de um
caching-proxy-service. Add-PortMap limpa tudo primeiro, portanto dois gravadores cujas
listas de portas sejam diferentes removem os mapeamentos netsh, as regras de firewall
e os encaminhadores um do outro; e um encaminhador instalado à frente de
um cache conectado por BRIDGE substitui o caminho direto da LAN por NAT do kernel,
perdendo o IP de origem do cliente registrado pelo squid. Tente uma vez com a
mesma política usada pelo executor: um detentor ativo controla os mapeamentos durante
seu próprio trabalho, e a próxima inicialização os reaplica.

IP de destino do mapeamento de portas do cache local: no Windows,
Test-CachingProxyServiceAvailable retorna o IP direto
da VM (o Hyper-V Default Switch é acessível a partir do
hospedeiro), portanto a análise funciona. No macOS, a URL é
http://192.168.64.1:3128 -- a URL do gateway VZ
usada pelos convidados, NÃO a VM de cache. Fornecer 192.168.64.1
a Start-CachingProxyServiceForwarder faria o
encaminhador criar um túnel para seu próprio socket de escuta (ciclo
consigo mesmo: as aceitações TCP funcionam, nada chega ao squid,
e subiquity vê "Connection failed [IP: 192.168.64.1
3128]" e recorre à instalação offline). Leia
o IP real da VM no arquivo de estado de yuruna-caching-proxy-service
gravado por Start-CachingProxyServiceVM.ps1.

Alternativa do macOS: a inicialização do status service seleciona as portas 80 e 3000, além dos
remapeamentos configurados dos proxies HTTP e HTTPS. Cada porta tem seu próprio pidfile,
portanto atualizar uma não remove as outras. O caminho normal de cache conectado por bridge
remove os encaminhadores do hospedeiro e usa o endereço LAN da VM de cache.
Windows: todas as portas em uma única lista -- netsh limpa tudo primeiro.
No Windows, todos os mapeamentos de portas do caching-proxy-service são repetidos na lista de cada
chamador porque Add-PortMap limpa primeiro o estado netsh e de firewall do Yuruna;
omitir qualquer um aqui o removeria a cada reinicialização de status-service.

Caminho rápido External-vSwitch do Windows: quando a VM de cache
está conectada por bridge à LAN (com seu próprio IP roteável), os clientes
remotos a acessam diretamente, e o squid vê os
IPs reais dos clientes no nível TCP. Remova quaisquer mapeamentos netsh
anteriores para que o caminho alternativo host:port não
reescreva silenciosamente uma rota paralela por NAT.
Test-CacheVMOnExternalNetwork de Yuruna.Host procura
qualquer vSwitch do tipo External no Windows; no macOS,
sempre retorna $true porque a VM de cache está conectada por bridge do QEMU.

O mapeamento de portas HTTP/HTTPS difere entre plataformas na
alternativa Default-Switch (veja Start-TestRunner.ps1
para a justificativa completa): o macOS usa um encaminhador pwsh +
PROXY v1 (IPs reais da LAN); o Windows usa netsh
portproxy simples porque o caminho do listener em modo de usuário é
inacessível pela LAN neste hospedeiro (o squid registra o
IP do lado NAT -- veja docs/caching.md).
A alternativa do macOS inclui :80 para que a página inicial da VM permaneça acessível;
seu caminho normal de cache conectado por bridge não precisa de uma vinculação privilegiada no hospedeiro.
Os valores das portas vêm das variáveis de ambiente YURUNA_CACHING_PROXY_SERVICE_*_PORT
(padrões 3128 / 3129).

O conjunto de portas expostas (incluindo a saída contínua de 9302 do caching-proxy-parser-service)
vem de Get-CachingProxyServiceExposedPort para que
não possa divergir da lista de instalação de Start-CachingProxyServiceVM;
Add-PortMap limpa tudo primeiro, portanto uma porta removida fica
indisponível na reinstalação. O macOS remapeia apenas as duas portas que o
operador abre manualmente: Grafana e 80 -- onde
fica a página inicial da VM de proxy de cache e, portanto,
para onde aponta o link Dashboards abaixo.
Sem 80, esse link não acessa nada a partir de um hospedeiro Mac.

A porta 80 na VM de proxy de cache serve a página inicial dessa VM:
um índice dos painéis Grafana e dos serviços de extensão,
cada um com link apenas onde é realmente acessível.
Deliberadamente NÃO é um link direto para dentro do Grafana -- essa página é uma
aplicação de página única, portanto um navegador antigo que não consiga executá-la chega
a uma tela em branco sem alternativa, enquanto a
página inicial é HTML simples renderizado no servidor que informa o que
existe e permite ao operador escolher.

runtime/host-network.txt (o banner renderizado pela página de status) e
runtime/host-network.json (o registro anunciado por host.registration.json) são
servidos pelo manipulador /runtime/* abaixo como qualquer outro arquivo de runtime, e são
gravados por exatamente um responsável: a verificação de rede dos convidados no início do ciclo do executor.
Essa verificação é a única que observa o estado do switch do hospedeiro uma vez por
ciclo, portanto somente ela pode avançar a contagem de ciclos consecutivos do par. Um
segundo gravador aqui reabriria um banner que a verificação acabara de limpar ou
congelaria a contagem no valor observado pela última inicialização do serviço -- este
serviço dura muito tempo e reinicia com frequência muito menor que a execução dos ciclos.

<a id="42e5cdfd-0045"></a>

<a id="testservicestart-statusserviceps1-detached-server-launch"></a>

## test/service/Start-StatusService.ps1: Início do servidor desacoplado

Aplica-se a:

- [test/service/Start-StatusService.ps1](../../test/service/Start-StatusService.ps1)

Grave o script do servidor em um arquivo e inicie-o com -File em vez de
codificá-lo em base64 na linha de comando. O script do servidor ultrapassou
~23 KB de código-fonte, que se tornam ~61 KB quando codificados em base64(UTF-16LE) --
isso, somado ao caminho de pwsh.exe (nas instalações pela Windows Store, pwsh é resolvido
para um caminho Microsoft.PowerShell_*_8wekyb3d8bbwe\pwsh.exe de 100+ caracteres),
faz a linha de comando ultrapassar o limite de 32,767 caracteres do CreateProcess do Windows.
A falha aparece como um erro de Start-Process com a mensagem
"The filename or extension is too long", que é pouco clara e fácil de
interpretar como um problema de caminho. -File evita inteiramente o limite de tamanho:
pwsh lê o script do disco em vez da linha de comando.
Remova o script de servidor gerado anteriormente (.status-service.ps1) e seu
log stdout (server.out) para que uma atualização não deixe uma cópia desatualizada e enganosa
no diretório do runtime, que alguém inspecionando poderia confundir com o servidor ativo.
Isso é executado antes de o script atual ser gravado abaixo.

O corpo do servidor acima é uma here-string: ESTE processo só o analisa como
texto, e o filho desacoplado é o primeiro a analisá-lo como código. Portanto, um
erro de sintaxe que sobreviva aos escapes -- "$var:" (dois-pontos imediatamente após um
nome de variável são interpretados como um qualificador de escopo), um `" que se transforme em uma simples
aspa -- não causa nada durante a gravação e encerra o filho na primeira linha.
Sem esta verificação, o operador não vê nada disso: a inicialização "tem sucesso", a
sondagem de prontidão abaixo consome todo o seu orçamento, e o relato indica a PORTA,
direcionando a investigação à propriedade da porta quando o defeito real é um erro de digitação no
arquivo gerado. Analise-o aqui, onde o erro é preciso e imediato.

O redirecionamento explícito de stdio no Windows é OBRIGATÓRIO para a continuidade
do executor externo. Sem -RedirectStandardOutput / -RedirectStandardError,
este processo neto herda os identificadores de console do pai. A cadeia
é: Start-TestRunner.ps1 cria modules/Invoke-TestRunnerInnerLoop.ps1 com
Start-Process -NoNewWindow (console compartilhado); o executor interno aqui cria
o status service de longa duração, que, sem redirecionamento explícito,
também herda esses identificadores compartilhados. Quando o ciclo interno termina e
WaitForExit() do externo retorna, o processo neto ainda mantém os
identificadores de console abertos -- o que, no Windows, pode manter o
Start-Process -Wait do externo preso após a saída real do interno, produzindo
o sintoma de "[outer cycle N] outer runner back in control" nunca
aparecer em outer.log, embora o interno tenha emitido claramente sua
linha final cycleDelaySeconds-wait-complete. Redirecionar para arquivos
dá ao processo neto identificadores dedicados e rompe a cadeia.

-RedirectStandardInput com um arquivo vazio real é obrigatório no
Windows: sem um redirecionamento explícito de stdin, o filho desacoplado
herda o identificador de stdin do console pai, e o conhost não consegue terminar
quando o pwsh pai sai, deixando a janela de PowerShell do operador
em estado de fechamento pendente por vários segundos ou indefinidamente. Passar
'NUL' / '\\.\NUL' NÃO funciona porque Start-Process passa o valor
por Resolve-Path, que acrescenta o diretório atual ao início, e então
a abertura de FileStream subjacente falha no caminho inválido cwd\NUL. O
ramo macOS abaixo obtém o mesmo efeito por '</dev/null' na
invocação bash -- o redirecionamento do bash aceita o nome do dispositivo
diretamente, portanto nenhum arquivo sentinela é necessário ali.

No macOS/Linux, desacople o status service da tarefa de terminal do shell
do executor de testes. `bash -c` executa um shell NÃO interativo, portanto o controle de tarefas está
desligado, e um simples `&` deixa o processo em segundo plano no grupo
de processos do chamador: a saída desse shell então demora porque sua tarefa de terminal
ainda tem um membro ativo. `set -m` liga o controle de tarefas para este shell,
portanto `&` coloca o servidor em seu PRÓPRIO grupo de processos (o bash usa setpgid).
`nohup` ignora SIGHUP, e stdin/stdout/stderr são redirecionados para fora do
tty, portanto o servidor permanece ativo após o chamador de forma limpa. (O macOS não tem `setsid`,
portanto uma nova sessão não está disponível aqui -- um novo grupo de processos mais
nohup é o que o desacopla da saída do chamador.)

<a id="42e5cdfd-0046"></a>

<a id="testservicestart-statusserviceps1-verify-server-started"></a>

## test/service/Start-StatusService.ps1: Verificar se o servidor iniciou

Aplica-se a:

- [test/service/Start-StatusService.ps1](../../test/service/Start-StatusService.ps1)

Anunciador do endereço do hospedeiro. Os convidados resolvem um hospedeiro que mudou de endereço pelo diretório do grupo,
e esse diretório só pode estar tão atualizado quanto os dados que chegam até ele: sua própria
descoberta acompanha o log de acesso do squid, que depende somente de solicitações e, portanto, atrasa justamente
quando mais importa -- um hospedeiro aparece ali quando ele ou seus convidados fazem solicitações pelo
proxy, portanto, entre ciclos, a visão expira e ainda indica o endereço
que o hospedeiro acabou de deixar. Esta é a metade por envio ativo.

Só é criado depois que a porta responde. O anunciador divulga ESTE serviço; um
anúncio de um endereço em que nada é servido seria pior que nenhum, e a
sondagem acima é o que distingue os dois casos.

Desacoplado em vez de usar um temporizador dentro do servidor: esse processo espera
indefinidamente pela próxima solicitação (só acorda antecipadamente para terminar um corpo de solicitação
que esteja lendo), portanto não tem um ponto de execução periódica.
É o mesmo padrão do encaminhador de envio do grupo. Instância única por seu próprio bloqueio, portanto
a chamada de Start-StatusService a cada ciclo não pode acumular anunciadores; uma falha na criação
não é fatal, exatamente como qualquer outro ponto de integração do grupo que faz o possível.

-NonInteractive tem uma função essencial, não é decorativo: um cmdlet chamado sem um
parâmetro Mandatory SOLICITA uma entrada, e uma solicitação em um processo desacoplado sem
console nunca retorna. Isso transforma toda essa classe de falhas de um travamento silencioso
em uma exceção registrada e capturada pelo arquivo de erros.

<a id="42e5cdfd-0047"></a>

<a id="testservicestart-statusserviceps1-host-address-beacon"></a>

## test/service/Start-StatusService.ps1: Anunciador do endereço do hospedeiro

Aplica-se a:

- [test/service/Start-StatusService.ps1](../../test/service/Start-StatusService.ps1)

Verifique se um anunciador já está em execução ANTES de criar outro, em vez
de criá-lo e deixar seu próprio bloqueio rejeitar o processo
excedente. O anunciador acompanha server.pid em vez de um identificador de processo,
portanto um que exista antes desta reinicialização continua anunciando o serviço
iniciado aqui, e nada precisa ser criado -- enquanto a própria criação
não é isenta de efeitos colaterais: os arquivos de redirecionamento abaixo são abertos
pelo PAI, portanto um anunciador ativo que ainda os mantenha abertos faz
Start-Process lançar uma exceção antes de o novo processo chegar ao bloqueio.
Isso transforma o caso normal de cada ciclo em uma exceção, e é
por isso que uma falha real na criação precisa ser distinguida desse caso aqui.

Uma sondagem de ABERTURA, não Test-Path: o anunciador exclui o arquivo em uma
saída limpa, portanto um arquivo de bloqueio que sobreviva a um encerramento forçado não indica um detentor e
não deve impedir o próximo anunciador.

<a id="42e5cdfd-0048"></a>

<a id="testservicestart-statusserviceps1-display-connection-info"></a>

## test/service/Start-StatusService.ps1: Exibir informações de conexão

Aplica-se a:

- [test/service/Start-StatusService.ps1](../../test/service/Start-StatusService.ps1)

Um chamador que acabou de iniciar este serviço não deveria precisar adivinhar seu endereço.
O serviço de controle do grupo publica um marcador que seus chamadores leem; sem algo
equivalente aqui, uma sondagem recorre à constante com a qual foi configurada
e pode gastar todo o seu tempo limite em um hospedeiro em que este serviço nunca foi executado.

Gravado como seu próprio arquivo em vez de usar os auxiliares de marcador de serviço
de extensão: eles são identificados por uma área de extensão que tem um manifesto de serviço
por trás, e o status service é infraestrutura do lado do hospedeiro em vez de uma
extensão. Reutilizar esse mecanismo significaria declará-lo como uma extensão.

<a id="42e5cdfd-0049"></a>

<a id="testservicestart-statusserviceps1-publish-where-this-service-can-be-reached"></a>

## test/service/Start-StatusService.ps1: Publicar onde este serviço pode ser acessado

Aplica-se a:

- [test/service/Start-StatusService.ps1](../../test/service/Start-StatusService.ps1)

O servidor se vincula a http://*:$Port para que o socket esteja em todas as interfaces, mas um
firewall do hospedeiro DESCARTA silenciosamente o TCP de entrada em interfaces que não sejam loopback sem uma
regra de permissão -- portanto a sondagem localhost acima passa, enquanto um navegador da LAN (e o
serviço pool-aggregator) excede o tempo limite. AUTORREPARO que faz o possível: garanta a regra de permissão quando
esta inicialização tiver privilégios (administrador do Windows / root|sudo no Linux); caso contrário, avise com a
orientação de correção duradoura somente quando for possível determinar inequivocamente que há bloqueio.
-NonInteractive impede que uma inicialização sem privilégios solicite entrada e fique travada; um
estado indeterminado (por exemplo, não poder consultar ufw sem privilégios) permanece silencioso -- a configuração
do hospedeiro (Enable-TestAutomation) é o responsável duradouro, o que importa para um hospedeiro
cujo executor esteja parado e, portanto, nunca repita esta inicialização por ciclo.
A inicialização segura para atualização não edita o firewall: uma alteração de regra é configuração
do hospedeiro, e o listener que ela restaura era acessível antes.

<a id="42e5cdfd-004a"></a>

<a id="testservicestop-cachingproxyservicevmps1-clear-an-abandoned-bring-up-lock"></a>

## test/service/Stop-CachingProxyServiceVM.ps1: Limpar um bloqueio de ativação abandonado

Aplica-se a:

- [test/service/Stop-CachingProxyServiceVM.ps1](../../test/service/Stop-CachingProxyServiceVM.ps1)

Parar o serviço É a ação de reinicialização do estado feita pelo operador, portanto ela é responsável pela recuperação
de um caching-proxy-service.lock que permaneça adquirido indevidamente. Isso não se corrige sozinho: um .ps1
é executado dentro do pwsh do chamador, portanto uma ativação que saia sem liberar o bloqueio
registra o shell interativo de longa duração do operador como detentor -- esse shell
continua ativo, a limpeza de estado obsoleto durante a aquisição nunca ocorre, e todo Start posterior é
recusado ("Another caching-proxy-service bring-up holds the lock").
Um detentor realmente ATIVO DE OUTRO PROCESSO (uma recriação real em outro processo, ainda
dentro do limite de idade) é apenas relatado: Stop não deve tomar seu bloqueio.
Isso é feito PRIMEIRO -- antes que o encerramento altere a VM -- para que o aviso chegue ao
operador enquanto abortar ainda tiver baixo custo.
O diretório do runtime corresponde exatamente a $envSidecarDir de Start-CachingProxyServiceVM.ps1;
a alternativa do próprio módulo é o diretório temporário, que NÃO é onde Start grava.
Protegido por Get-Command, assim como Invoke-TestRunnerInnerLoop.ps1 protege suas chamadas de bloqueio, para que
um conjunto parcial de módulos retorne ao comportamento anterior (nenhuma ação) em vez de gerar erro.

<a id="42e5cdfd-004b"></a>

<a id="testservicestop-cachingproxyservicevmps1-clear-an-abandoned-caching-proxy-service-bring-up-lock"></a>

## test/service/Stop-CachingProxyServiceVM.ps1: Limpar um bloqueio abandonado de ativação do caching-proxy-service

Aplica-se a:

- [test/service/Stop-CachingProxyServiceVM.ps1](../../test/service/Stop-CachingProxyServiceVM.ps1)

Simétrico a Test-CachingProxyService.ps1 -SetHostProxy. Executa INCONDICIONALMENTE
e usa Remove-HostProxy (limpeza definitiva) em vez do antigo
Clear-HostProxy (captura e restauração a partir de $HOME/.yuruna/host-proxy.backup.json).
A limpeza definitiva é o modelo correto aqui: qualquer variável de ambiente HTTP_PROXY/HTTPS_PROXY
ou string ProxyServer do WinINet deixada após Stop-CachingProxyServiceVM está, por
definição, apontando para uma VM de cache que estamos encerrando -- restaurar
o que havia antes apenas deixa um IP desatualizado para o próximo ciclo.
Isso é feito primeiro para que uma falha ao encerrar a VM não deixe o hospedeiro
apontando para um proxy inativo pelo restante da sessão.
No macOS, networksetup exige root -- o preâmbulo de sudo acima garante
que já tenhamos privilégios elevados quando isso for executado.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Voltar para [Yuruna](../../README.md)
