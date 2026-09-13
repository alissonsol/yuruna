<a id="420f54a5-0001"></a>

# Scripts de instalação

Um instalador de bootstrap por hospedeiro. Cada um é idempotente, pede
elevação uma única vez com um aviso antecipado e clona o repositório em
`~/git/yuruna` (ou `%USERPROFILE%\git\yuruna` no Windows).

Por padrão, o clone acompanha o branch `main`, de modo que o hospedeiro
**atualiza automaticamente o framework a cada ciclo de teste**. Para
congelar um hospedeiro em uma versão fixa, veja **Fixar em um release** abaixo.

Habilitar o hospedeiro para testes do Yuruna (ajustes de suspensão de
vídeo / bloqueio de tela / grupo de armazenamento) intencionalmente NÃO é
feito automaticamente. Execute [setup.ps1](../../../install/setup.ps1) após a instalação --
veja **Configuração guiada** abaixo -- ou, apenas para as configurações do
hospedeiro, `host/<platform>/Enable-TestAutomation.ps1`.

| Hospedeiro | Instalador | Notas de configuração |
|------|-----------|-------------|
| macOS UTM | [macos.utm.sh](../../../install/macos.utm.sh) | [macOS UTM ...](../../../host/macos.utm/README.md) |
| Windows Hyper-V | [windows.hyper-v.ps1](../../../install/windows.hyper-v.ps1) | [Windows Hyper-V ...](../../../host/windows.hyper-v/README.md) |
| Ubuntu KVM/libvirt | [ubuntu.kvm.sh](../../../install/ubuntu.kvm.sh) | [Ubuntu KVM/libvirt ...](../../../host/ubuntu.kvm/README.md) |

<a id="420f54a5-0002"></a>

## Configuração guiada

O instalador acima coloca os pacotes e o repositório na máquina. O
[setup.ps1](../../../install/setup.ps1) percorre o resto do caminho -- até um **hospedeiro
autônomo** ou um **laboratório** em funcionamento -- perguntando apenas o
que não consegue inferir:

```
pwsh install/setup.ps1                    # interactive
pwsh install/setup.ps1 -WhatIf            # print the ordered task list, change nothing
pwsh install/setup.ps1 -AnswerFile a.yml  # unattended, same code path
pwsh install/setup.ps1 -logLevel Debug    # everything the run and its children can say
```

| Modo | O que ele configura |
|------|-----------------|
| **Hospedeiro autônomo** (Standalone host) | Uma máquina que executa os testes sozinha: configurações do hospedeiro, armazenamento, o caching-proxy-service e o serviço stash. |
| **Laboratório** (Lab) | Um beacon ao qual outras máquinas se juntam: armazenamento compartilhado, o caching-proxy-service, os serviços stash e pool-control, este hospedeiro inscrito e um grupo `default`. |

O armazenamento é uma das perguntas, não uma suposição: **esta máquina**
(compartilhamentos SMB locais, o padrão no modo autônomo), **um
compartilhamento NAS existente** (montado, nunca criado -- configure antes o
compartilhamento e `networkStorage.*`) ou **nenhum**, que existe apenas no
modo autônomo e dispensa o armazenamento compartilhado e o serviço stash.

Ele não instala nada e não clona nada -- ele orquestra os scripts que já
fazem cada tarefa. O armazenamento é configurado **antes** das VMs de
serviço nos dois modos, porque o serviço stash sai com código 1 sem ele e o
caching-proxy-service incorpora o armazenamento na seed do seu convidado no
momento da compilação.

Reexecutar é seguro: cada etapa detecta o que já está feito e a pula, então
uma execução interrompida no meio é retomada bastando executá-la de novo.
No Windows, toda a execução eleva privilégios uma única vez, logo no
início. Uma execução guiada termina gravando o arquivo de respostas que
usou, para que a próxima máquina possa ser configurada da mesma forma.

Toda execução -- inclusive as prévias -- é registrada em
`test/status/log/setup.<yyyy.MM.dd.HH.mm>.log`: cada pergunta, a resposta
adotada e se alguém a escolheu, cada etapa e seu resultado, a linha de
comando e o código de saída de cada script filho, e o relatório final. A
configuração informa o nome do arquivo no início e no fim. Os scripts
filhos continuam imprimindo no console em vez de no log, para que seus
prompts permaneçam visíveis; no Windows, a reexecução elevada continua no
mesmo arquivo.

O log recebe tudo isso independentemente do que diga `-logLevel` -- o nível
decide quanto disso também chega ao terminal e quanto os scripts filhos
dizem ali. É a [cascata compartilhada](../../loglevels.md): de `Error` a
`Debug`, obtida de `logLevel:` em `test/test.config.yml` quando o parâmetro
é omitido, e repassada a todos os scripts que a execução inicia --
incluindo os construtores de imagem e de VM de cada convidado -- de modo
que `-logLevel Debug` é a configuração indicada para um bring-up que falhou
em algum ponto dentro de um script filho.

Para saber o que é um laboratório e como os hospedeiros entram em um, veja
[docs/lab-operator.md](../../lab-operator.md).

<a id="420f54a5-0003"></a>

### Devolvendo uma máquina ao estado original

O [test/lab/Disable-TestAutomation.ps1](../../../test/lab/Disable-TestAutomation.ps1)
restaura as configurações do hospedeiro que o `Enable-TestAutomation` alterou, a
partir da captura que o Enable gravou antes de alterar qualquer coisa:

```
pwsh test/lab/Disable-TestAutomation.ps1 -WhatIf        # show what would be restored
pwsh test/lab/Disable-TestAutomation.ps1
pwsh test/lab/Disable-TestAutomation.ps1 -StopServices  # also stop the service VMs
```

Ele reverte apenas configurações. Pacotes, módulos do PSGallery, concessões
TCC do macOS, o cofre de credenciais, repositórios e imagens clonados e
tudo o que o questionário de armazenamento gravou são **relatados, na
maioria das vezes com o comando a executar** em vez de removidos --
desmontar tudo isso em um "desativar configurações" é uma surpresa. Em um
hospedeiro habilitado por uma compilação anterior à captura, só é removido o que
é comprovadamente nosso -- a regra de firewall da porta de status e a regra
ICMP do Yuruna no Windows, a regra `ufw` da porta de status no Ubuntu, e
**absolutamente nada no macOS**, que não acrescenta objetos próprios. Todas
as demais configurações são deixadas intactas e apenas relatadas, porque
restaurar um padrão adivinhado continua sendo uma mudança que ninguém
pediu.

Ele se recusa a executar enquanto um executor de testes for dono do
diretório de runtime do hospedeiro. Detalhamento completo em
[docs/operator.md](../../operator.md#putting-the-machine-back).

<a id="420f54a5-0004"></a>

## One-liners remotos

Cada one-liner acrescenta `?nocache=<timestamp>` incondicionalmente. A
instalação acontece uma única vez por hospedeiro novo, e um instalador
desatualizado em cache é o pior tipo de desatualização (o operador não
tem como perceber, e reexecutar a partir do README é o caminho de
recuperação documentado). Para o cache-buster `YurunaCacheContent`,
válido para todo o sistema e honrado por todos os OUTROS one-liners do
Yuruna (fetch-and-execute, instalações de carga de trabalho no
convidado), veja [docs/caching.md](../../caching.md).

**macOS UTM** (cole no Terminal):

```
/bin/bash -c "$(curl -fsSL "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/macos.utm.sh?nocache=$(date +%Y%m%d%H%M%S)")"
```

**Windows Hyper-V** (cole no PowerShell ou no Windows PowerShell; ele
mesmo eleva privilégios):

```
irm "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/windows.hyper-v.ps1?nocache=$(Get-Date -Format yyyyMMddHHmmss)" | iex
```

**Ubuntu KVM/libvirt** (cole no Terminal):

```
bash <(curl -fsSL "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/ubuntu.kvm.sh?nocache=$(date +%Y%m%d%H%M%S)")
```

A linha do Ubuntu usa substituição de processo (`bash <(curl ...)`) em vez
do formato `bash -c "$(curl ...)"` do macOS. Ambas chegam ao mesmo script,
mas a substituição de processo o mantém como um argumento de arquivo real
para o bash, o que contorna um caso limite de stdin/prompt do sudo em que
alguns terminais do Ubuntu tropeçam.

> Os one-liners acima são o **caminho de conveniência** e são **NÃO
> VERIFICADOS** por construção (um único pipe executa os bytes antes que
> qualquer coisa possa checá-los). Eles buscam a referência móvel
> `refs/heads/main`, e o clone resultante **acompanha `main` e se atualiza
> automaticamente a cada ciclo** (veja **Fixar em um release** abaixo).
> Para uma instalação com assinatura verificada, prefira o caminho
> **verificado** abaixo.

<a id="420f54a5-0005"></a>

## Fixar em um release (desativar a atualização automática)

Para congelar um hospedeiro no release atual -- a versão que está no arquivo
`VERSION` do repositório no momento da instalação -- adicione `-PinVersion`
(Windows) / `PIN_VERSION=1` (macOS, Ubuntu).

**Pela web (fixado):**

macOS UTM:

```
PIN_VERSION=1 /bin/bash -c "$(curl -fsSL "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/macos.utm.sh?nocache=$(date +%Y%m%d%H%M%S)")"
```

Windows Hyper-V (um `irm | iex` em pipe não aceita parâmetros, então crie
um scriptblock a partir dos bytes obtidos e passe o switch):

```
& ([scriptblock]::Create((irm "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/windows.hyper-v.ps1?nocache=$(Get-Date -Format yyyyMMddHHmmss)"))) -PinVersion
```

Ubuntu KVM/libvirt:

```
PIN_VERSION=1 bash <(curl -fsSL "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/ubuntu.kvm.sh?nocache=$(date +%Y%m%d%H%M%S)")
```

**Localmente, a partir da pasta `install/` (fixado):**

```
# Windows
.\install\windows.hyper-v.ps1 -PinVersion

# macOS  (env var or flag, equivalent)
PIN_VERSION=1 bash install/macos.utm.sh
bash install/macos.utm.sh --pin-version

# Ubuntu  (env var or flag, equivalent)
PIN_VERSION=1 bash install/ubuntu.kvm.sh
bash install/ubuntu.kvm.sh --pin-version
```

Para fixar em um *outro release específico* em vez do que vem embutido
neste instalador, passe a tag diretamente: `-YurunaBranch 2026.06.20` /
`YURUNA_BRANCH=2026.06.20`.

<a id="420f54a5-0006"></a>

## Instalação verificada (release assinado)

> Disponível para **tags** de release publicadas. Os artefatos de
> assinatura (`install.sha256.sig`, `install/keys/`) são publicados pela
> primeira vez no release `2026.06.12`; para uma tag anterior, use
> os one-liners de conveniência acima.

Um release com tag publica, ao lado de cada instalador:

- `install/install.sha256` -- o SHA-256 dos três instaladores, e
- `install/install.sha256.sig` -- uma assinatura RSA destacada desse manifesto,

verificáveis com a chave pública incluída
`install/keys/yuruna-release-signing.pub` (`.pem` para o `openssl`, `.xml`
para o Windows PowerShell). Isso protege contra um CDN/mirror comprometido
ou uma referência movida -- não apenas contra corrupção no mesmo canal.
**Confirme primeiro a impressão digital da chave por um canal
independente** (veja [install/keys/README.md](../../../install/keys/README.md)):

```
SHA-256(DER public key) = 14fce044df5de1ebbac6fdeae8d4f87abac618393f06e32748b7ef4571c5c337
```

**Windows Hyper-V** (PowerShell 5.1+; usa .NET, sem ferramentas extras):

```
$base='https://raw.githubusercontent.com/alissonsol/yuruna/refs/tags/2026.09.13'; $t=Join-Path $env:TEMP 'yuruna-install'; New-Item -ItemType Directory -Force $t|Out-Null
'install/windows.hyper-v.ps1','install/install.sha256','install/install.sha256.sig','install/keys/yuruna-release-signing.pub.xml'|%{ irm "$base/$_" -OutFile (Join-Path $t (Split-Path $_ -Leaf)) }
$k=New-Object System.Security.Cryptography.RSACryptoServiceProvider; $k.FromXmlString((Get-Content "$t\yuruna-release-signing.pub.xml" -Raw))
if(-not $k.VerifyData([IO.File]::ReadAllBytes("$t\install.sha256"),'SHA256',[IO.File]::ReadAllBytes("$t\install.sha256.sig"))){throw 'SIGNATURE INVALID -- do not run'}
$h=(Get-FileHash "$t\windows.hyper-v.ps1" -Algorithm SHA256).Hash.ToLower(); if(-not(Select-String -Path "$t\install.sha256" -SimpleMatch $h)){throw 'INSTALLER HASH MISMATCH -- do not run'}
& "$t\windows.hyper-v.ps1"
```

**macOS UTM / Ubuntu KVM** (usa o `openssl`, presente em ambos):

```
BASE='https://raw.githubusercontent.com/alissonsol/yuruna/refs/tags/2026.09.13'; S=install/macos.utm.sh   # or install/ubuntu.kvm.sh
t=$(mktemp -d); for f in "$S" install/install.sha256 install/install.sha256.sig install/keys/yuruna-release-signing.pub.pem; do curl -fsSL "$BASE/$f" -o "$t/$(basename "$f")"; done
openssl dgst -sha256 -verify "$t/yuruna-release-signing.pub.pem" -signature "$t/install.sha256.sig" "$t/install.sha256" || { echo 'SIGNATURE INVALID -- do not run'; exit 1; }
grep -qF "$(sha256sum "$t/$(basename "$S")" | cut -d' ' -f1)" "$t/install.sha256" || { echo 'INSTALLER HASH MISMATCH -- do not run'; exit 1; }
bash "$t/$(basename "$S")"
```

A assinatura destacada é produzida no momento do release pelo
`tools/Update-YurunaReleasePins.ps1`.

Cada link na tabela acima leva ao README específico do hospedeiro, com as etapas
pós-instalação (participação em grupos, configurações de protetor de tela,
concessões TCC, etc.).

<a id="420f54a5-0007"></a>

## GitHub CLI (`gh`)

Cada instalador também instala a [GitHub CLI](https://cli.github.com/)
como uma de suas etapas de pacotes (`GitHub.cli` via winget no Windows,
`brew install gh` no macOS, o repositório apt `cli.github.com` no Ubuntu).
O binário chega ao PATH, mas fica sem autenticação -- execute

```
gh auth login
```

uma vez por hospedeiro. O instalador não tem como fazer isso: a autenticação
exige um fluxo web interativo (ou colar um token de acesso pessoal) que o
operador precisa conduzir.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Última revisão: 2026.09.13

Voltar para [Yuruna](../../../README.md)
