<a id="429f3d06-0001"></a>

<a id="vmconfig-topic-reference"></a>

# Referência dos tópicos de vmconfig

Este arquivo reúne a justificativa de cada linha não trivial nos
artefatos `vmconfig/` de cada convidado (`user-data`, `meta-data`,
`autounattend.xml`). Os arquivos user-data continuam curtos -- cada tópico
se resume a uma linha:

```
# --- REGION: https://yuruna.link/429f3d06-0003
```

O semi-GUID aponta para um cabeçalho `### <topic name>` aqui e permanece estável
quando o texto do cabeçalho é alterado ou traduzido.

Os tópicos são genéricos (uma explicação cobre todos os convidados em todos os hospedeiros);
os subitens tratam das exceções exigidas por um convidado ou hospedeiro específico.

A VM **caching-proxy-service** tem sua própria seed do cloud-init
(`host/vmconfig/caching-proxy-service.base.user-data`), cujos apontadores de justificativa
usam destinos semi-GUID permanentes; a justificativa de cada bloco está em
[Tópicos da seed do Caching-proxy-service](#caching-proxy-service-seed-topics).
Tudo que vem antes dessa seção trata do user-data compartilhado dos *convidados*.

---

<a id="429f3d06-0002"></a>

<a id="how-user-data-is-rendered"></a>

## Como user-data é renderizado

Três plataformas de hospedeiro (Hyper-V, KVM, UTM) instalam Ubuntu Server ou
Amazon Linux 2023 em uma VM recém-criada, usando a fonte de dados NoCloud
do cloud-init. A ISO de seed que elas geram contém um arquivo `user-data`
renderizado por tipo de convidado a partir de uma base compartilhada, um overlay por hospedeiro e uma
tabela de substituições por ciclo. O fluxo de renderização fica em
[`automation/Yuruna.CloudInitTemplate.psm1`](../../automation/Yuruna.CloudInitTemplate.psm1).

Sem esse fluxo, cada um dos seis scripts `New-VM.ps1`
(3 plataformas x {Ubuntu Server 24, Ubuntu Server 26}) conteria um arquivo
`vmconfig/user-data` quase idêntico (~240 linhas cada), uma cadeia de
600 caracteres de `.Replace(...).Replace(...)...` para 11
marcadores e uma operação base64 para cada script auxiliar no convidado. Uma correção
aplicada a uma cópia deixa as outras cinco divergentes -- a classe de armadilha das "três cópias paralelas
de user-data" na memória de contribuição do workspace.

Cada `host/<host>/guest.<guest>/New-VM.ps1` combina a base compartilhada
`host/vmconfig/<guest>.base.user-data` com seu overlay por hospedeiro (por meio de
`New-CloudInitUserData`) e substitui estes marcadores antes de
entregar o resultado a `genisoimage` (KVM), `hdiutil makehybrid`
(macos.utm) ou à fonte de dados NoCloud do cloud-init (Hyper-V):

| Marcador | Origem | Observações |
|---|---|---|
| `HOSTNAME_PLACEHOLDER` | parâmetro `-Hostname`, recorrendo a `-VMName` quando vazio | Torna-se `identity.hostname` (autoinstall) ou o nome de máquina para AL2023 / caching-proxy-service. Uma sequência o define ao declarar `variables.hostname`, que o planejador propaga para `New-VM`; sem isso, o convidado recebe o nome da VM. Um nome de máquina fixado diverge do nome da VM, e a consulta `name=` em `dhcpd_leases` do UTM usa o nome que o convidado cadastrou: blocos ainda registrados sob o nome da VM pertencem a antecessores, portanto uma consulta apenas pelo nome da VM retorna um endereço inativo, em vez de falhar explicitamente. Por isso, a descoberta lê o nome fixado na ISO de seed do pacote, tenta esse nome primeiro e rejeita concessões fora de uma sub-rede ativa de interface do hospedeiro. |
| `INSTANCE_ID_PLACEHOLDER` | parâmetro `-VMName` | Apenas meta-data. Deliberadamente NÃO é o nome de máquina: o cloud-init trata um instance-id alterado como uma nova instância, e duas VMs podem legitimamente compartilhar um nome de máquina fixado. |
| `USERNAME_PLACEHOLDER` | parâmetro `-Username` (padrão por convidado; veja `Test.Ssh\Get-GuestSshUser`) | Conta criada pelo autoinstall (Ubuntu Server 24.04) ou pelo bloco `users:` do cloud-init (AL2023). O mesmo nome aparece em `passwd --expire`, `sudoers.d/90-yuruna-<user>` e nas sequências de interface gráfica. |
| `HASH_PLACEHOLDER` | `Yuruna.Common\ConvertTo-Sha512CryptHash` (encapsula `openssl passwd -6 -- <vault-password>`) | Formato SHA-512 (`$6$`). A senha em texto simples vem de `Get-Password -Username <user>` no cofre persistente de autenticação (`test/status/extension/authentication/vault.yml`). O KVM respeita `$YURUNA_GUEST_PASSWORD` como alternativa ao cofre em execuções avulsas de desenvolvimento. O separador `--` preserva senhas que começam com hífen; veja "Hash de senhas: armadilha do hífen inicial em argv" abaixo. |
| `PLAINTEXT_PASSWORD_PLACEHOLDER` | A mesma origem acima (caminho AL2023) | Usado em `chpasswd:` para AL2023, onde o módulo do cloud-init aceita o formato de texto simples e força sua expiração no primeiro login (padrão de chpasswd: `expire: true`). |
| `SSH_AUTHORIZED_KEY_PLACEHOLDER` | `test/status/ssh/yuruna_ed25519.pub` (gerado automaticamente se ausente) por meio de `Test.Ssh\Get-YurunaSshPublicKey` | Uma única linha ed25519; inserida em autoinstall.ssh.authorized-keys (Ubuntu) e no bloco `users:` do cloud-init para o usuário de teste (AL2023). É a mesma chave usada para autenticação pelo caminho de diagnóstico após falhas (`Test.Diagnostic\Invoke-RemoteDiagnosticsKeySsh`) -- arquivos de chave por hospedeiro o quebrariam silenciosamente. |
| `APT_PROXY_BLOCK_PLACEHOLDER` | Construído por hospedeiro por New-VM.ps1 | Bloco `apt:` de várias linhas. Substituído por substring (sem reconhecer tokens), portanto a cadeia literal NÃO DEVE aparecer em nenhum outro lugar do arquivo. |
| `CACHING_PROXY_URL_PLACEHOLDER` | parâmetro `-CachingProxyServiceUrl` | Cadeia vazia quando nenhum caching-proxy-service está acessível; nesse caso, os blocos `if [ -n ... ]` de user-data não fazem nada. |
| `CA_CERT_BASE64_PLACEHOLDER` | Todos os três hospedeiros -- CA obtida pelo hospedeiro e incorporada em base64 | Vazio quando a obtenção da CA falha; então, o apt por HTTPS ignora o cache. |
| `YURUNA_STATUS_SERVICE_IP_PLACEHOLDER` | Descoberta do IP do hospedeiro por melhor esforço | Torna-se `/etc/yuruna/host.env` e a entrada `yuruna-host` de `/etc/hosts`. |
| `YURUNA_STATUS_SERVICE_PORT_PLACEHOLDER` | `test/test.config.yml:statusService.port` (padrão 8080) | O mesmo. |
| `YURUNA_RETRY_LIB_BASE64_PLACEHOLDER` / `YURUNA_VERSIONS_BASE64_PLACEHOLDER` / `YURUNA_FAE_BASE64_PLACEHOLDER` / `YURUNA_NETWORK_BASE64_PLACEHOLDER` / `YURUNA_HOST_LOCATE_BASE64_PLACEHOLDER` | Preenchidos automaticamente por `Get-YurunaGuestScriptBase64` | Os cinco auxiliares de convidado `automation/*.sh`, incorporados como entradas `write_files` em base64. As seeds também instalam o lançador `yfe` em `/usr/local/bin/yfe`. |
| `YURUNA_HOST_ID_PLACEHOLDER` | Preenchido automaticamente a partir de `$env:YURUNA_RUNTIME_DIR/host.uuid` | A identidade do hospedeiro que um convidado informa quando precisa reencontrar um hospedeiro cujo endereço mudou. Vazio quando o laboratório não tem diretório de grupo, resultado que é suportado. Um chamador que já resolveu o ID (as seeds de VMs de serviço) o informa e tem prioridade. |
| `YURUNA_CACHING_PROXY_SERVICE_IP_PLACEHOLDER` | Preenchido automaticamente a partir de `$env:YURUNA_CACHING_PROXY_SERVICE_IP` | O mesmo caminho de localização; vazio quando a variável não está definida. |
| `YURUNA_GITHUB_REPO_PLACEHOLDER` / `YURUNA_GITHUB_REF_PLACEHOLDER` / `GH_TOKEN_PLACEHOLDER` / `YURUNA_FRAMEWORK_URL_PLACEHOLDER` / `YURUNA_PROJECT_URL_PLACEHOLDER` | Preenchidos automaticamente por `Get-YurunaGitHubSource` sobre `-RepoRoot` | O identificador do repositório e o commit HEAD do checkout servido por este hospedeiro, o token que permite abri-lo quando privado e as URLs dos clones de framework/projeto que um convidado sem acesso ao hospedeiro ainda precisa. Campos vazios significam "nenhuma alternativa pelo GitHub é possível"; modelos que não contêm esses tokens nunca os consomem. |

As linhas marcadas como *Preenchidas automaticamente* são preenchidas pelo próprio `New-CloudInitUserData`,
portanto um `New-VM.ps1` só as explicita em `-Replacement` para substituir o
valor que o módulo resolveria.

<a id="429f3d06-0003"></a>

<a id="three-stage-rendering"></a>

### Renderização em três etapas

| Etapa | Função | Entradas | Saída |
|---|---|---|---|
| 1. **Combinar** | `Merge-CloudInitUserData` | base compartilhada + overlay por hospedeiro (um de `hyperv` / `kvm` / `utm`) | Modelo resolvido com as âncoras substituídas, ainda contendo tokens `*_PLACEHOLDER` |
| 2. **Codificar em base64** | `Get-YurunaGuestScriptBase64` | `<RepoRoot>/automation/{yuruna-retry.sh,yuruna-versions.sh,fetch-and-execute.sh,yuruna-fetch-context.sh,yuruna-network.sh,yuruna-host-locate.sh}` | `@{ RetryLib = '<base64>'; VersionsLib = '<base64>'; FetchAndExecute = '<base64>'; FetchContext = '<base64>'; NetworkLib = '<base64>'; HostLocate = '<base64>' }` |
| 3. **Resolver** | `Resolve-CloudInitPlaceholder` | Modelo combinado + tabela hash de substituições | Cadeia final de user-data |

`New-CloudInitUserData` é o invólucro chamado por cada `New-VM.ps1`
por convidado -- ele encadeia as três etapas, preenche automaticamente as entradas
base64 dos scripts de convidado e as entradas de identidade do hospedeiro e origem no GitHub listadas
acima e, opcionalmente, grava o resultado em `-OutputPath` (veja "Codificação da
saída" abaixo).

<a id="429f3d06-0004"></a>

<a id="placeholder-safety-net"></a>

### Proteção contra marcadores não resolvidos

`Resolve-CloudInitPlaceholder` percorre a tabela hash do chamador e
aplica `.Replace(name, value)` a cada entrada. Após a substituição,
examina o resultado em busca de qualquer token `<NAME>_PLACEHOLDER` restante e lança uma exceção
com os nomes problemáticos.

Isso detecta erros de digitação ao criar a VM -- uma entrada esquecida na tabela hash do
chamador ou um novo marcador para o qual nenhum chamador fornece um valor --, em vez
de deixar um marcador literal chegar ao convidado e falhar
durante o autoinstall com um diagnóstico confuso.

<a id="429f3d06-0005"></a>

<a id="files-on-disk"></a>

### Arquivos em disco

| Arquivo | Papel |
|---|---|
| `host/vmconfig/ubuntu.server.base.user-data` | A base compartilhada -- igual para Ubuntu Server 24 e 26. Contém linhas de âncora como `# === YURUNA_OVERLAY_NETWORK ===`, substituídas pelo combinador. |
| `host/vmconfig/ubuntu.server.hyperv.overlay.yml` | Overlay por hospedeiro: lista de bloqueio de `hv_balloon` + fixação do framebuffer `hyperv_fb`. |
| `host/vmconfig/ubuntu.server.kvm.overlay.yml` | Overlay por hospedeiro: comando inicial para impedir o apagamento do VT + `consoleblank=0` + linha de comando GRUB segura para framebuffer. |
| `host/vmconfig/ubuntu.server.utm.overlay.yml` | Overlay por hospedeiro: bloco `network:` que fixa DHCP IPv4 e recusa RA IPv6. |
| `host/vmconfig/amazon.linux.2023.base.user-data` | A base compartilhada de AL2023. Usa `runcmd:` do cloud-init (AL2023 inicia uma imagem de nuvem pré-compilada, em vez de executar um autoinstall no estilo Ubuntu), com seu próprio conjunto de âncoras. |
| `host/vmconfig/amazon.linux.2023.hyperv.overlay.yml` | Overlay de AL2023 por hospedeiro (Hyper-V). |
| `host/vmconfig/amazon.linux.2023.kvm.overlay.yml` | Overlay de AL2023 por hospedeiro (KVM): runcmd de `consoleblank=0`. |
| `host/vmconfig/amazon.linux.2023.utm.overlay.yml` | Overlay de AL2023 por hospedeiro (UTM). |
| `automation/yuruna-retry.sh`, `automation/yuruna-versions.sh`, `automation/fetch-and-execute.sh`, `automation/yuruna-network.sh`, `automation/yuruna-host-locate.sh` | Scripts auxiliares do convidado incorporados à seed como entradas `write_files` em base64. `yuruna-versions.sh` contém as versões fixadas das dependências e é carregado por `yuruna-retry.sh`. `yuruna-host-locate.sh` decide de onde o convidado obtém o código, portanto é incorporado à seed, em vez de baixado. |

<a id="429f3d06-0006"></a>

<a id="overlay-anchor-contract"></a>

### Contrato das âncoras de overlay

Cada linha de âncora na base tem o formato
`# === YURUNA_OVERLAY_<NAME> ===`. O conjunto de âncoras varia conforme o tipo de convidado
(autoinstall ou `runcmd:` em imagem pré-compilada):

**Ubuntu Server** -- seis âncoras: as quatro abaixo mais `HOST_AGENT_PKG` e
`LATE_HOST_AGENT`, para os pontos de inserção do pacote do agente do hospedeiro
e dos comandos tardios:

| Âncora | Finalidade | Uso pelos overlays |
|---|---|---|
| `NETWORK` | Bloco network: por hospedeiro | Todos os hospedeiros (DHCP baseado em MAC); UTM também recusa RA IPv6 |
| `EARLY_COMMANDS` | Comandos anteriores à instalação | Todos os hospedeiros (reduzir a saída do kernel e parar o temporizador tmpfiles-clean); KVM também impede o apagamento do VT |
| `GRUB_PRE_CONSOLE_QUIET` | Particularidades do kernel antes do bloco `console-quiet` | Hyper-V (`hv_balloon`+`hyperv_fb`), KVM (`consoleblank`) |
| `GRUB_POST_CONSOLE_QUIET` | Particularidades do kernel após o bloco `console-quiet` | Apenas KVM (`nomodeset` seguro para framebuffer) |

**Amazon Linux 2023** -- três âncoras:

| Âncora | Finalidade | Uso pelos overlays |
|---|---|---|
| `RUNCMD_CONSOLEBLANK` | Bloco `runcmd:` que fixa `consoleblank=0` | Apenas KVM |
| `RUNCMD_QUIET_LOGLEVEL` | Bloco `runcmd:` para particularidades de quiet/loglevel na linha de comando do kernel | por hospedeiro, conforme necessário |
| `POWER_STATE` | Diretiva `power_state:` (reiniciar/desligar após a primeira inicialização) | por hospedeiro, conforme necessário |

O arquivo de overlay usa o mesmo formato de linha de âncora em seus cabeçalhos
de seção; as linhas
entre um cabeçalho e o seguinte (ou o fim do arquivo) são o conteúdo
de substituição. Um conteúdo vazio exclui a linha de âncora por completo.

Âncoras não representadas no overlay são um erro fatal -- uma ausência silenciosa
deixaria o marcador literal no user-data final e confundiria
o cloud-init.

<a id="429f3d06-0007"></a>

<a id="output-encoding"></a>

### Codificação da saída

`New-CloudInitUserData -OutputPath <file>` grava UTF-8 sem BOM e
com quebras de linha LF. cloud-init >= 22 tolera `\r\n`, mas convidados mais antigos falham
com heredocs de shell sensíveis a CR no bloco `late-commands` renderizado, portanto
a saída somente com LF é a escolha duradoura.

---

<a id="429f3d06-0008"></a>

<a id="topic-order-in-user-data"></a>

## Ordem dos tópicos em user-data

Late-commands (autoinstall) e runcmd (NoCloud) são executados sequencialmente. A
ordem abaixo respeita três dependências reais; todo o restante é uma
convenção para facilitar a comparação por diff das três variantes de hospedeiro de cada convidado:

1. `wget no_proxy` DEVE preceder o download de fetch-and-execute e o
   wget de fuso horário -- ambos usam `/etc/wgetrc`.
2. `update-grub` DEVE vir depois de todos os arquivos complementares `99-yuruna-*.cfg`.
3. `umount /cdrom` + `losetup -D` DEVEM ser os últimos late-commands
   (ubuntu.server.24 e .26 -- veja "Finalização silenciosa da reinicialização após a instalação" abaixo).

Ordem recomendada (um convidado pode omitir os tópicos que não se aplicam):

1. Cache do apt: persistir o proxy
2. Limitar systemd-networkd-wait-online
3. Forçar a troca de senha no primeiro login
4. Limite de tempo da sessão de login
5. Sudo sem senha para o usuário do ambiente de testes
6. Desabilitar swap
7. Desabilitar MOTD
8. I/O inseguro do dpkg *(Hyper-V)*
9. Lista de bloqueio de hv_balloon *(Hyper-V)*
10. Fixação do framebuffer hyperv_fb *(Hyper-V)*
11. Console framebuffer de AL2023 *(amazon.linux.2023)*
12. consoleblank na linha de comando do kernel *(KVM ubuntu.server.24)*
13. Console silencioso
14. update-grub
15. Console: reter getty até que o cloud-init sinalize a conclusão *(ubuntu.server.24)*
16. Coordenadas do hospedeiro Yuruna
17. wget no_proxy
18. Instalar a biblioteca yuruna
19. Fuso horário por geolocalização de IP e NTP
20. Finalização silenciosa da reinicialização após a instalação *(ubuntu.server.24)*
21. Reinicialização do hospedeiro sem interface gráfica após colapso do framebuffer *(Hyper-V amazon.linux.2023)*

---

<a id="429f3d06-0009"></a>

<a id="topics"></a>

## Tópicos

<a id="429f3d06-000a"></a>

<a id="apt-proxy-block"></a>

### Bloco de proxy do apt

`apt.proxy` (com escopo -- não o `proxy:` de nível superior) encaminha apenas `apt`/`apt-get`
pelo caching-proxy-service local. O escopo importa: `proxy:` de nível superior também
exporta `http_proxy`/`https_proxy` para o ambiente de late-commands, o que quebra
`wget https://...` com proxies que recusam CONNECT e encaminharia
a consulta ao status-service do hospedeiro pelo cache.

`New-VM.ps1` injeta o bloco em `APT_PROXY_BLOCK_PLACEHOLDER` com
`geoip: false` e um espelho `primary` fixado; a linha `proxy:` é
omitida quando nenhum caching-proxy-service está acessível. Fixar primary e desabilitar
geoip evita a consulta HTTPS a `geoip.ubuntu.com`, que, caso contrário, acrescenta
segundos à escolha do espelho.

`primary:` (não o modelo `sources_list:` do curtin): o squashfs do servidor
já contém um Deb822 `/etc/apt/sources.list.d/ubuntu.sources` apontando
para o arquivo de pacotes, e `modifymirrors` do curtin reescreve essa URI no lugar,
portanto uma fixação de `primary:` produz uma única origem totalmente reescrita, e o apt
obtém os índices uma vez. Um bloco `sources_list:`, por sua vez, grava uma *segunda*
configuração do apt ao lado do `ubuntu.sources` existente, duplicando cada obtenção de
índice por suíte em noble; no curtin de resolute (snap subiquity 7227), ele aborta
`subiquity/Mirror/cmd-apt-config` com saída 1 e entra em um shell de recuperação.

`String.Replace()` usa substrings, portanto o token literal
`APT_PROXY_BLOCK_PLACEHOLDER` não deve aparecer em nenhum outro comentário: o
YAML de várias linhas seria inserido no lugar errado, e o subiquity
retornaria silenciosamente ao instalador interativo.

<a id="429f3d06-000b"></a>

<a id="why-server-iso-over-desktop-iso"></a>

### Por que usar a ISO de servidor em vez da ISO de desktop

O esquema `autoinstall:` do cloud-init exige a ISO de **servidor** do Ubuntu;
a ISO de desktop usa Ubiquity (ou seu sucessor), que não tem um
mecanismo equivalente de instalação sem supervisão. O framework de testes controla
o provisionamento anexando uma seed NoCloud (user-data + meta-data), e
apenas o subiquity da ISO de servidor a lê. A seleção da imagem ocorre
em `Get-Image.ps1` por hospedeiro.

<a id="429f3d06-000c"></a>

<a id="chpasswd-list-schema"></a>

### Esquema de lista de chpasswd

*(amazon.linux.2023)*

```
chpasswd:
  list: |
    USERNAME_PLACEHOLDER:PLAINTEXT_PASSWORD_PLACEHOLDER
```

Mantenha o formato `list:` (obsoleto), em vez do esquema mais recente
`users:`/`type: text`. O cloud-init de AL2023 interpreta `list:` corretamente
no modo de texto simples; com `users:`/`type: text`, a senha de `ec2-user`
não foi aceita nos testes (o cloud-init não a aplicou ou
a armazenou em um formato que `login(1)` não conseguia validar), e a sequência de login
pela interface gráfica então repete a caixa de diálogo de senha incorreta. O aviso de obsolescência
é apenas visual. O padrão `chpasswd.expire: true` do cloud-init se aplica, portanto
o diálogo de senha atual/nova/confirmação no primeiro login ainda aparece.

NÃO acrescente espaços após `USERNAME_PLACEHOLDER:` -- eles se tornam parte da senha.

<a id="429f3d06-000d"></a>

<a id="unlocked-account-needs-plain_text_passwd"></a>

### Conta desbloqueada precisa de plain_text_passwd

*(seeds de serviços: caching-proxy-service, download-agent-service,
pool-control-service, stash-service)*

`plain_text_passwd` é combinado com `lock_passwd: false` e deve ficar na
mesma entrada `users:`. O cloud-init procura uma senha NESSE BLOCO
quando recebe a solicitação de não bloquear a conta; o bloco `chpasswd` é executado em um
módulo posterior e não satisfaz essa verificação. Sem isso, cada inicialização
registra `Not unlocking password ... no 'passwd' provided` como um
erro recuperável e informa `extended_status: degraded`, que então
recebe qualquer pessoa que lê os diagnósticos do convidado para uma falha não relacionada. O
valor é o mesmo aplicado por `chpasswd`, portanto a credencial efetiva
não muda.

<a id="429f3d06-000e"></a>

<a id="ssh_authorized_keys-at-top-level"></a>

### ssh_authorized_keys no nível superior

*(amazon.linux.2023)*

`ssh_authorized_keys:` no nível superior (em vez de sob um bloco `users:`)
impede que o cloud-init mescle ou descarte silenciosamente a chave quando o
nome de usuário corresponde ao usuário padrão da distribuição (`ec2-user`).

<a id="429f3d06-000f"></a>

<a id="pass-through-user-data-silence-ssh-fingerprints"></a>

### user-data repassado: suprimir impressões digitais SSH

*(autoinstall, ubuntu.server.24)*

```
user-data:
  no_ssh_fingerprints: true
  ssh:
    emit_keys_to_console: false
```

O subiquity copia esse bloco para o sistema instalado; o cloud-init o consome
na primeira inicialização. Dois ajustes são alterados:

- `no_ssh_fingerprints: true` desabilita `cc_ssh_authkey_fingerprints`
  (a tabela ci-info "Authorized keys for user UBUNTU").
- `ssh.emit_keys_to_console: false` desabilita `cc_keys_to_console`
  (os blocos `BEGIN SSH HOST KEY FINGERPRINTS` / `BEGIN SSH HOST KEY KEYS`
  despejados por `/dev/kmsg`, que o getty `tty1` exibe
  independentemente do estado de login e que concorrem com o login da primeira inicialização).

Esses ajustes são distintos de `autoinstall.ssh` acima (a configuração SSH do
subiquity no instalador), que mantém `authorized-keys` / `install-server`
intactos.

<a id="429f3d06-0010"></a>

<a id="lvm-sizing-policy"></a>

### Política de dimensionamento do LVM

```
storage:
  layout:
    name: lvm
    sizing-policy: all
```

`sizing-policy: all` substitui o padrão de servidor do subiquity (`scaled`),
que aloca apenas ~50% do PV ao LV raiz em discos <50 G e
apenas ~12.5% em discos >200 G. Sem isso, o sistema de arquivos
ephemeral-storage do nó em um qcow2 de 64 G fica em ~14 GiB e atinge
o limite de remoção do kubelet durante o teste do site.

<a id="429f3d06-0011"></a>

<a id="empty-interactive-sections"></a>

### interactive-sections vazio

*(autoinstall)*

Desabilita todas as etapas interativas, para que a instalação seja totalmente sem supervisão.
A confirmação incondicional "Continue with autoinstall?" do subiquity
ainda aparece; a primeira etapa da sequência de teste pela interface gráfica a usa como ponto
de correspondência.

<a id="429f3d06-0012"></a>

<a id="disable-vt-blanking-on-the-live-installer-kernel"></a>

### Desabilitar o apagamento do VT no kernel LIVE do instalador

*(KVM ubuntu.server.24, early-commands do autoinstall)*

```
early-commands:
  - setterm --blank 0 --powersave off --cursor on > /dev/tty1 2>/dev/null || true
```

O arquivo complementar GRUB `99-yuruna-consoleblank.cfg` cobre o sistema
INSTALADO, mas, durante a fase de autoinstall, o kernel da ISO live-server
herda o padrão do kernel (`consoleblank=600` = 10 min). Qualquer período sem atividade
>10 min durante obtenção de pacotes pelo apt / particionamento apaga o framebuffer
VGA no meio da instalação; `virt-viewer` mostra preto E
`virsh screenshot` (screendump QMP) retorna PPMs pretos dos quais o tesseract
não consegue extrair texto por OCR -- a etapa "wait for ${vmName} login:" do ambiente de testes então não consegue
distinguir a instalação de um travamento. `early-commands` são executados "assim que o
instalador inicia, antes de procurar dispositivos de bloco e de rede" (referência de
autoinstall do Ubuntu), portanto isso ocorre antes de qualquer período de 10 minutos sem atividade
terminar. É uma preocupação apenas do KVM; inofensiva em `hyperv_fb` do Hyper-V e em
virtio-gpu de Apple Virtualization.

<a id="429f3d06-009c"></a>

### Impedir que o timer de limpeza de arquivos temporários dispare no instalador LIVE

*(todos os overlays de hipervisor, ubuntu.server.24 e .26, early-commands do autoinstall)*

```
early-commands:
  - systemctl stop systemd-tmpfiles-clean.timer 2>/dev/null || true
```

O `systemd-tmpfiles-clean.timer` do instalador live dispara 15 minutos
após a inicialização, e o systemd dá ao serviço uma montagem de
credenciais sob `/run/credentials/`. A cada etapa em chroot, o curtin faz
um bind mount do `/run` live, uma montagem compartilhada, em
`/target/run`, então a montagem de credenciais se propaga para baixo de
`/target/run`. Quando o timer dispara com uma etapa em chroot aberta, a
limpeza do curtin não consegue desmontar `/target/run` ("target is busy",
código de saída 32). A instalação então aborta em `install-grub` ou
`final-kernel-configuration` com "An error occurred. Press enter to start
a shell", cerca de 15 minutos após a inicialização do instalador. O
`mounts-at-failure.txt` enviado mostra
`/target/run/credentials/systemd-tmpfiles-clean.service` ainda montado.
O ambiente do instalador é descartado ao fim da instalação, então parar
o timer não custa nada; o sistema instalado mantém o seu.

<a id="429f3d06-0013"></a>

<a id="apt-cache-persist-proxy"></a>

### Cache do apt: persistir o proxy

Gravação redundante de segurança de `/target/etc/apt/apt.conf.d/99yuruna-apt-cache`,
para que as chamadas apt-get após a instalação passem pelo mesmo caching-proxy-service usado pelo subiquity
na instalação. `[ -n "$CACHING_PROXY_URL_PLACEHOLDER" ]` interrompe o bloco quando
nenhum cache está configurado, deixando-o inofensivo em hospedeiros sem um.

O bloco `if` também habilita o cache HTTPS ao confiar na CA do squid
e apontar `Acquire::https::Proxy` para o listener ssl-bump em `:3129`:

- **Todos os três hospedeiros:** o construtor de VMs do hospedeiro obtém a CA
  antes de renderizar o seed, reutilizando uma CA persistida para esse hospedeiro
  de cache se a obtenção ao vivo falhar. Os bytes chegam incorporados em base64
  por `CA_CERT_BASE64_PLACEHOLDER`. Um marcador vazio ignora este bloco de
  confiança/proxy do apt. As configurações posteriores de proxy HTTPS no ambiente
  e a restrição de saída direta continuam válidas, portanto um convidado sem CA
  precisa do autorreparo da CA pelo script de atualização antes que o HTTPS com
  ssl-bump possa funcionar.

<a id="429f3d06-0014"></a>

<a id="enforce-proxy-egress"></a>

### Impor a saída pelo proxy

Força TODO o HTTP/HTTPS público a passar pelo cache. Variáveis de ambiente de proxy para todo o sistema
(PAM, `/etc/profile.d`, `DefaultEnvironment` do systemd), além de um
REJECT do iptables para acesso direto a 80/443, cobrem aplicativos que ignoram
`http_proxy` (snap, alguns binários Go, atualizadores automáticos de navegadores). RFC1918
e link-local continuam acessíveis, para que o cache, o status service yuruna-host
e os serviços da LAN continuem funcionando. Condicional a um
`CACHING_PROXY_URL_PLACEHOLDER` não vazio -- sem cache, as regras são
ignoradas e o tráfego segue diretamente.

Os três destinos de variáveis de ambiente atendem a leitores diferentes: `/etc/environment`
para PAM (sessões interativas, cron, ssh); `/etc/profile.d` para shells de
login (bash + zsh); `DefaultEnvironment` do systemd para daemons iniciados
antes de qualquer login de usuário (cron, snapd, docker, serviços personalizados). As variantes em maiúsculas
e minúsculas são emitidas porque algumas ferramentas leem apenas um formato.

`iptables-persistent` carrega `/etc/iptables/rules.v4` na inicialização por meio de
`netfilter-persistent.service` (Before=network-pre.target). O postinst do pacote deb
perguntaria "save current rules?"; `debconf-set-selections`
suprime a pergunta. O acesso público a 80/443 é bloqueado com `REJECT
--reject-with icmp-port-unreachable` (não DROP), para que o aplicativo que falha
mostre um erro claro em `dmesg`/`strace`/`journalctl`, em vez de
ficar esperando o prazo limite de conexão. IPv6 está fora do escopo: `rules.v6` reproduz
loopback+conntrack, para que netfilter-persistent tenha um arquivo válido para carregar
(caso contrário, ele avisa na inicialização), e OUTPUT IPv6 padrão continua ACCEPT.

<a id="pin-ipv4-dhcp-refuse-ipv6-ra"></a>

<a id="429f3d06-0015"></a>

<a id="pin-ipv4-only-dhcp-refuse-ipv6-router-advertisements"></a>

### Fixar DHCP apenas IPv4 e recusar anúncios de roteadores IPv6

Âncora: `pin-ipv4-dhcp-refuse-ipv6-ra`

O bloco `network:` de autoinstall no
`host/vmconfig/ubuntu.server.utm.overlay.yml` fixa `enp0s1` em
`dhcp4: true; dhcp6: false; accept-ra: false; dhcp-identifier: mac; critical: true`.
Os overlays Hyper-V e KVM correspondem aos nomes `en*` e `eth*` e fixam
`dhcp-identifier: mac` e `critical: true` sem aplicar a política de RA IPv6
do UTM. `critical: true` impede que o kernel expire o endereço pelo seu
próprio relógio enquanto a concessão ainda é válida; veja
[Why the DHCP address is pinned as critical](../network.md#4220a755-000b).

Apenas o backend QEMU do macOS precisa disso: em
QEMU + `-netdev vmnet-shared`, a implementação VMnet do hospedeiro envia anúncios de
roteadores IPv6 que `systemd-networkd` interpreta como eventos CHANGE
da interface. O `NetworkController` do subiquity trata cada CHANGE como
uma atualização de modelo, dispara `_send_update` e nunca passa da detecção
de rede -- a instalação trava com o framebuffer exibindo continuamente:

```
start:  subiquity/Network/_send_update: CHANGE enp0s1
finish: subiquity/Network/_send_update: CHANGE enp0s1
```

para sempre. O backend Apple Virtualization não emite esses RAs, portanto
a detecção automática do subiquity é segura ali. Os convidados Hyper-V e KVM
também não recebem esse fluxo de RAs; seus overlays mantêm a política IPv6
nativa e fixam as concessões DHCP IPv4 pelo MAC.

<a id="429f3d06-0016"></a>

<a id="cap-systemd-networkd-wait-online"></a>

### Limitar systemd-networkd-wait-online

```
[Service]
ExecStart=
ExecStart=/lib/systemd/systemd-networkd-wait-online --any --timeout=15
```

O padrão de `networkd-wait-online` do Ubuntu 24.04 é "aguardar que TODAS as
interfaces sejam roteáveis, sem prazo limite". `--any --timeout=15` significa "QUALQUER
interface roteável OU 15s, o que acontecer primeiro" -- o que o ambiente de testes precisa.
A execução do cloud-init na primeira inicialização depende transitivamente de
`network-online.target`, portanto um wait-online travado provoca uma
falha do cloud-init ou minutos de atraso antes do login.

- **Hyper-V Default Switch:** o caminho IPv6 acaba se resolvendo, mas
  lentamente -- visível como
  `Job systemd-networkd-wait-online.service/start running ([TIME] / no limit)`.
- **Apple VZ Shared NAT (UTM):** os RAs IPv6 esperados pelo rastreador nunca
  chegam; sem o limite, o serviço bloqueia para sempre.
- **NAT 'default' do libvirt (KVM):** pode travar à espera de RAs IPv6 e
  atrasar o cloud-init por meio de `network-online.target`.

<a id="429f3d06-0017"></a>

<a id="password-hashing-argv-leading-dash-trap"></a>

### Hash de senhas: armadilha do hífen inicial em argv

*(todo `New-VM.ps1` de hospedeiro que constrói `HASH_PLACEHOLDER`)*

`ConvertTo-Sha512CryptHash` em `automation/Yuruna.Common.psm1` é o
auxiliar compartilhado para calcular o hash da senha do autoinstall / cloud-init. Ele chama:

```
& openssl passwd -6 -- $Plaintext
```

O marcador de fim de opções `--` é **essencial** e não deve ser
removido:

- `New-RandomPassword` de `test/extension/authentication/default.psm1`
  usa um alfabeto que inclui `-`
  (`a-z A-Z 0-9 !@#$%^&*()-_=+`) para todos os caracteres exceto o primeiro,
  que é alfanumérico; assim, uma senha gerada nunca começa com `-`. Uma senha
  já existente no cofre ou fornecida por um operador ainda pode começar com `-`.
  Observado em uma execução real: o cofre produziu `-4aWj*CRw`.
- Sem `--`, `openssl passwd -6 -4aWj*CRw` interpreta `-4aWj*CRw` como um
  sinalizador de opção desconhecido, exibe `passwd: Use -help for summary` em stderr,
  não grava nada em stdout e termina com saída diferente de zero. O ciclo então grava um
  hash VAZIO no user-data do cloud-init, e o convidado inicia
  sem senha funcional -- só é possível recuperá-lo pelo console.
- Com `--`, o token com prefixo de hífen é um operando, e o openssl calcula seu hash
  corretamente.

A mesma armadilha se aplica a qualquer chamador que passa texto simples do cofre a uma
ferramenta de linha de comando. Use uma destas opções:

- Passe o texto simples APÓS `--` (por exemplo, `chpasswd -- "$user:$pw"`, embora
  o formato de entrada padrão do chpasswd, `echo "$user:$pw" | chpasswd`, seja preferível --
  ele também mantém o texto simples fora de argv); ou
- Passe o texto simples pela entrada padrão (`-stdin` no openssl, o padrão no
  chpasswd, `SSHPASS`/`-e` no sshpass).

Blocos `chpasswd:` `list: |` dentro do `user-data` do cloud-init NÃO são
afetados: o escalar de bloco literal repassa o `-` inicial
intacto, e o cloud-init envia os pares `user:password` para `chpasswd` pela
entrada padrão, sem envolver a interpretação de argv. Portanto, o caminho do convidado AL2023 --
que substitui texto simples diretamente em `chpasswd.list:`, em vez de
calcular um hash -- é seguro por construção.

<a id="429f3d06-0018"></a>

<a id="force-first-login-password-change"></a>

### Forçar a troca de senha no primeiro login

*(ubuntu.server.24)*

```
- curtin in-target --target=/target -- passwd --expire USERNAME_PLACEHOLDER
```

**ESSENCIAL**: a rotação `Current password:` /
`New password:` / `Retype:` da sequência de teste depende de o usuário ter
expiração de senha forçada. A cadeia do cofre em
[`test/extension/authentication/default.psm1`](../../test/extension/authentication/default.psm1)
pressupõe que o sistema operacional solicite a troca no primeiro login. `USERNAME_PLACEHOLDER`
vem de `-Username` (padrão por convidado; veja
`Test.Ssh\Get-GuestSshUser`). Isso corresponde ao
padrão do cloud-init de AL2023 (`chpasswd.expire: true`), portanto o primeiro login da sequência de teste
pela interface gráfica dispara o mesmo diálogo Current/New/Retype em todos os
hospedeiros suportados.

<a id="429f3d06-0019"></a>

<a id="login-session-budget"></a>

### Limite de tempo da sessão de login

```
sed -i -E "/^[#[:space:]]*LOGIN_TIMEOUT/d" /etc/login.defs && echo "LOGIN_TIMEOUT 180" >> /etc/login.defs
```

`/etc/login.defs LOGIN_TIMEOUT` limita todo o fluxo de autenticação
(`Password:` inicial e Current/New/Retype em uma conta expirada).
Com o padrão de 60s, o ambiente de testes baseado em OCR pode esgotar esse tempo em um
hospedeiro ocupado: cada prompt custa 1 captura de tela + uma execução de tesseract + uma cadeia
send-key do virsh, ~10s/etapa em 4 prompts, mais margem. 180s fornece ~3x
de folga. O `sed` remove qualquer entrada existente (comentada ou não) antes
de acrescentar a nova, portanto a alteração é idempotente.

O invólucro `bash -c` existe porque o interpretador YAML do cloud-init trata
a expressão regular sem aspas `/^[#[:space:]]*LOGIN_TIMEOUT/d` como um caminho; colocá-la entre aspas
dentro de `bash -c` a mantém como um único argumento de shell.

<a id="429f3d06-001a"></a>

<a id="passwordless-sudo-for-harness-user"></a>

### Sudo sem senha para o usuário do ambiente de testes

```
echo "USERNAME_PLACEHOLDER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-yuruna-USERNAME_PLACEHOLDER
chmod 440 /etc/sudoers.d/90-yuruna-USERNAME_PLACEHOLDER
chown root:root /etc/sudoers.d/90-yuruna-USERNAME_PLACEHOLDER
```

`USERNAME_PLACEHOLDER` é substituído por `New-VM.ps1` a partir de `-Username`
(padrão por convidado; por exemplo, `yauser1` para amazon.linux.2023, `yuuser24` para
ubuntu.server.24, `yuuser26` para ubuntu.server.26, `ywuser1` para
windows.11). Os convidados Ubuntu incluem a versão principal no sufixo, para que
24.04 e 26.04 não colidam em logs compartilhados; outros convidados usam o
formato `y[aw]user1`, fácil de localizar por grep. O ambiente de testes usa esse usuário dedicado,
em vez dos padrões das imagens de nuvem `ubuntu` / `ec2-user`, para
facilitar buscas por grep e suportar o futuro multiusuário declarado em um
manifesto.

A carga de trabalho controlada por SSH chama `/usr/local/lib/yuruna/fetch-and-execute.sh`
sem TTY, portanto qualquer prompt do sudo bloquearia a execução. O arquivo complementar usa o
formato padrão de `sudoers.d` (modo 440, proprietário root:root), para que `visudo -c`
o aceite.

<a id="429f3d06-001b"></a>

<a id="disable-swap"></a>

### Desabilitar swap

```
sed -i '/ swap / s/^/#/' /target/etc/fstab
curtin in-target --target=/target -- systemctl mask swap.target
```

As VMs de teste têm RAM suficiente para que paginação nunca seja desejável, e um
swap-target travado durante o desligamento acrescenta segundos a cada ciclo. Comente a
entrada de fstab E mascare `swap.target`, para que nem a inicialização comum nem um
`swapon -a` posterior a habilitem novamente.

<a id="429f3d06-001c"></a>

<a id="mask-snapd-seeded"></a>

### Mascarar a inicialização da seed do snapd

```
curtin in-target --target=/target -- systemctl mask snapd.seeded.service
```

`snapd.seeded.service` executa `snap wait system seed.loaded` e usa
`WantedBy=multi-user.target`, portanto o prompt de login do getty não pode aparecer
até que o snapd termine de inicializar sua seed -- mesmo quando nenhum snap está
instalado. Custo medido em um novo ciclo ubuntu.server.24:

```
$ systemd-analyze blame | head -5
25.399s snapd.seeded.service
 1.339s cloud-config.service
 1.196s cloud-init.service
  781ms cloud-init-local.service
  663ms systemd-resolved.service

$ systemd-analyze
Startup finished in 821ms (kernel) + 29.851s (userspace) = 30.672s
```

83% do tempo de inicialização do espaço de usuário foi gasto em uma inicialização de snapd que nada
consome. Mascare apenas a espera pela seed, NÃO `snapd.service` / `snapd.socket`:
isso remove a barreira da inicialização e mantém `snap install` sob demanda
disponível aos scripts de carga de trabalho por ativação de socket.

<a id="429f3d06-001d"></a>

<a id="disable-motd"></a>

### Desabilitar MOTD

```
chmod -x /target/etc/update-motd.d/*
mkdir -p /target/etc/default && test -f /target/etc/default/motd-news && sed -i 's/^ENABLED=1/ENABLED=0/' /target/etc/default/motd-news || echo 'ENABLED=0' > /target/etc/default/motd-news
```

Os scripts de `update-motd.d` e `motd-news` produzem muitas linhas de saída no
primeiro login (avisos legais, "[N] updates can be installed immediately",
publicidade da Canonical). Eles fazem a tela avançar além do prompt
`Password:` antes que o ambiente de testes de OCR possa reconhecê-lo E poluem a saída padrão de todas as sessões
SSH. Remover o bit de execução e desabilitar
`motd-news` elimina ambos os efeitos.

<a id="429f3d06-001e"></a>

<a id="dpkg-unsafe-io"></a>

### I/O inseguro do dpkg

*(Hyper-V)*

```
# /etc/dpkg/dpkg.cfg.d/99-yuruna-unsafe-io
force-unsafe-io
```

O dpkg executa fsync em cada arquivo descompactado antes de renomeá-lo para seu destino. Em um disco
virtual, cada uma dessas operações se torna uma viagem de ida e volta para descarregar dados, e o custo de descompactação passa
a acompanhar a quantidade de arquivos, em vez de seu tamanho: um pacote de 13 kB com dez arquivos
pode custar tanto quanto um grande. Um convidado observado durante a instalação mostra `dpkg` no
estado `Ds+`, bloqueado em `jbd2_log_wait_commit`, com a thread de journal
`jbd2/dm-0-8` acima do próprio `dpkg` no ranking de CPU do convidado. O controle
é o SDK .NET, que extrai um volume comparável por um arquivo tar, sem
dpkg nem fsync, e não fica mais lento nas mesmas condições.

`force-unsafe-io` remove apenas o fsync anterior à renomeação. O commit
do banco de dados de status e a fase de configuração ainda sincronizam, portanto isso encurta a descompactação e mantém
o restante -- é uma correção para a diferença entre uma execução tranquila e uma com disputa de recursos,
não para o tempo mínimo.

A contrapartida é a durabilidade em caso de falha durante operações de pacotes: um convidado que perde
energia durante a descompactação pode retornar com um arquivo parcialmente gravado, onde o dpkg
teria garantido uma versão ou a outra. Isso é aceitável aqui porque
esses convidados são reprovisionados pelo instalador a cada ciclo. Convém
saber que um convidado restaurado por `loadDiskSnapshot` herda o que sua última
parada deixou, portanto uma base capturada de uma VM encerrada à força apresenta
um risco um pouco maior de perder o final de uma gravação do que antes.

Emitido pelo overlay Hyper-V, em vez da base compartilhada, portanto alcança os
convidados Hyper-V em ambas as arquiteturas de hospedeiro e não alcança KVM nem UTM. A
arquitetura deliberadamente não é o critério: este laboratório também executa convidados aarch64 em
UTM, portanto um teste `uname -m` alteraria a durabilidade em uma família de hospedeiros
que não se beneficia disso.

O nome do arquivo não contém ponto de propósito -- o dpkg ignora fragmentos em
`dpkg.cfg.d` cujos nomes contêm um, o que desabilitaria isso silenciosamente.

<a id="429f3d06-001f"></a>

<a id="hv_balloon-denylist"></a>

### Lista de bloqueio de hv_balloon

*(Hyper-V)*

```
# /etc/modprobe.d/denylist-hv-balloon.conf
blacklist hv_balloon
```

As notificações de pressão de memória do driver balloon sintético inundam o
console e poluem o OCR. O
arquivo não tem efeito em KVM/QEMU e macOS UTM, onde `hv_balloon` nunca
é carregado -- ele é mantido para preservar, entre hospedeiros, a simetria do formato de runcmd / write_files.

<a id="429f3d06-0020"></a>

<a id="hyperv_fb-framebuffer-pin"></a>

### Fixação do framebuffer hyperv_fb

*(Hyper-V)*

```
# Ubuntu Server 24.04: /etc/default/grub.d/99-yuruna-hyperv-fb.cfg
GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT} video=hyperv_fb:1024x768"

# AL2023: grubby --update-kernel=ALL --args="video=hyperv_fb:1024x768"
```

Quando o monitor do hospedeiro Windows é desconectado, `vmconnect` mostra
o convidado Linux como um pequeno retângulo preto no canto superior esquerdo de uma
janela que, fora isso, é branca: a GPU sintética não tem EDID da tela do hospedeiro para
negociar no modo sem interface gráfica, portanto `hyperv_fb` usa um
framebuffer de tamanho quase zero. Fixar uma resolução faz o
driver no convidado usá-la independentemente do estado da tela do hospedeiro.

- **Ubuntu Server 24.04:** o arquivo complementar em `/etc/default/grub.d/` é adicional
  -- combina-se com os arquivos complementares `consoleblank` e `console-quiet`
  sem sobrescrevê-los.
- **AL2023:** contém grub2 sem o invólucro `update-grub`; `grubby`
  grava `/boot/grub2/grub.cfg` diretamente e é a forma usual em AL2023. A
  lista de sinalizadores é deduplicada, portanto repetir com o mesmo argumento não
  altera nada. AL2023 é uma imagem de nuvem pré-compilada (sem reinicialização do instalador), portanto
  o kernel em execução ainda tem a linha de comando ANTIGA aqui -- veja o
  tópico "Reinicialização do hospedeiro sem interface gráfica" para conhecer a reinicialização condicional que aplica
  o novo argumento.

<a id="429f3d06-0021"></a>

<a id="enable-sshd-on-first-boot"></a>

### Habilitar sshd na primeira inicialização

*(amazon.linux.2023)*

```
systemctl enable --now sshd || true
```

`sshd.service` de AL2023 está instalado, mas não habilitado por padrão na
imagem de nuvem. O ambiente de testes controla o convidado por SSH depois que a sequência de teste pela interface gráfica
termina seu fluxo de login, portanto o serviço deve estar ativo antes
de essa transferência para SSH ocorrer.

<a id="429f3d06-0022"></a>

<a id="al2023-framebuffer-console"></a>

### Console framebuffer de AL2023

*(amazon.linux.2023)*

```
systemctl enable --now getty@tty1.service || true
chvt 1 2>/dev/null || true
bash -c 'setterm --blank 0 --powersave off --cursor on > /dev/tty1 2>/dev/null || true'
# KVM only:
bash -c 'command -v grubby >/dev/null 2>&1 && grubby --update-kernel=ALL --args="consoleblank=0" || true'
```

As imagens de nuvem de AL2023 fixam a linha de comando do kernel em `console=ttyS0` e deixam
`getty@tty1.service` mascarado, portanto o framebuffer VGA capturado por
`virsh screenshot` / `vmconnect` permanece silencioso, e o ambiente de testes de OCR pela interface gráfica
nunca vê um prompt `login:`. A correção:

1. Habilite e inicie `getty@tty1`, para que um `agetty` grave `login:` em
   `/dev/tty1`.
2. `chvt 1` força fbcon a tornar `tty1` o VT ativo (sem essa
   etapa, fbcon continua em `tty0`, e a saída do getty fica em buffer, mas nunca é
   exibida).
3. `setterm --blank 0 --powersave off` mantém o framebuffer ativo
   DURANTE a sessão atual de cloud-init (sequência de escape única, por VT -- NÃO
   sobrevive a uma recriação do getty nem a um `chvt` para outro VT e
   de volta).
4. *(Apenas KVM)* `grubby --args="consoleblank=0"` torna essa política de não apagamento
   determinante no nível do kernel para todas as inicializações seguintes.
   O padrão `consoleblank=600` (10 min) causa o sintoma "virt-viewer perdeu
   o VNC depois de um tempo e o OCR parou de funcionar" em execuções longas de
   teste.

Em um hospedeiro ARM64, `console=ttyS0` não é apenas silencioso: identifica um
dispositivo que o convidado não tem, pois a UART ali é a SBSA PL011,
`ttyAMA0`. Um console serial ligado a `ttyS0` permanece vazio, qualquer que seja o resultado da
inicialização, deixando o framebuffer como único canal, a menos que a
linha de comando nomeie a porta certa --
[host-hyperv.md](../host-hyperv.md#the-converted-arm64-image-does-not-boot).
Por isso o overlay Hyper-V escolhe a porta dentro do instalador: `ttyAMA0`
quando ele roda em aarch64, `ttyS0` nos demais casos, tanto para o argumento
`console=` do kernel quanto para o encaminhamento do journald, de modo que a
captura da COM1 carregue o relato do próprio convidado sobre um silêncio em
qualquer das duas arquiteturas.

UTM omite esse bloco por completo: sua janela de exibição lê o console
serial diretamente, sem depender do framebuffer.

<a id="429f3d06-0023"></a>

<a id="gnome-auto-open-terminal-on-login"></a>

### GNOME: abrir o terminal automaticamente no login

*(amazon.linux.2023)*

```
mkdir -p /etc/xdg/autostart
cat > /etc/xdg/autostart/open-terminal.desktop << 'DESKTOP'
[Desktop Entry]
Type=Application
Name=Open Terminal
Exec=ptyxis --new-window
X-GNOME-Autostart-enabled=true
NoDisplay=true
DESKTOP
```

O desktop GNOME de AL2023 inicia uma sessão vazia, sem janela de
terminal, mas o ambiente de testes de OCR pela interface gráfica controla o convidado digitando em um
terminal visível. Uma entrada `.desktop` de inicialização automática XDG em
`/etc/xdg/autostart/` inicia `ptyxis --new-window` em cada login
gráfico, para que um terminal esteja na tela quando o ambiente de testes começa seu
fluxo de login e digitação. `NoDisplay=true` mantém o lançador fora do
menu de aplicativos, mas preserva a inicialização automática, e
`X-GNOME-Autostart-enabled=true` a habilita novamente para GNOME.

<a id="429f3d06-0024"></a>

<a id="consoleblank-kernel-cmdline"></a>

### consoleblank na linha de comando do kernel

*(KVM ubuntu.server.24)*

```
# /etc/default/grub.d/99-yuruna-consoleblank.cfg
GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT} consoleblank=0"
```

O padrão do kernel `consoleblank=600` (10 min) apaga o framebuffer
VGA quando está ocioso. Sintoma: a janela de `virt-viewer` para de atualizar
("parece que a conexão VNC caiu"), E `virsh screenshot` (screendump
QMP -- independente do cliente VNC) começa a produzir PPMs
pretos. Ambos falham juntos porque o framebuffer VGA do convidado alimenta
os dois. Fixe `consoleblank=0` na linha de comando do kernel para que TODAS as inicializações (e
todos os VTs) herdem o não apagamento, independentemente de quais chamadas `setterm` do espaço de usuário
sobrevivam.

Específico de KVM: a variante Hyper-V usa `hyperv_fb:1024x768` em seu lugar, e
virtio-ramfb de macos.utm não se apaga da mesma forma.

<a id="429f3d06-0025"></a>

<a id="console-quiet"></a>

### Console silencioso

```
# Ubuntu Server 24.04: /etc/default/grub.d/99-yuruna-console-quiet.cfg
GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT} quiet loglevel=3 systemd.show_status=no rd.systemd.show_status=no"

# AL2023: grubby --args="quiet loglevel=3 systemd.show_status=no rd.systemd.show_status=no"
```

O prompt `Current password:` de `passwd` deixa o cursor no fim da linha,
sem quebra de linha final. Na primeira inicialização, unidades que terminam tarde (seed do
snapd, `cloud-final` etc.) e mensagens printk `KERN_INFO`/`NOTICE`
continuam gravando linhas `[ OK ] ...` em `/dev/console`, sobrescrevendo o prompt
antes da captura de OCR; o ambiente de testes então vê a linha de
status e nunca reconhece `Current password:`.

- `quiet loglevel=3` eleva o limiar do console printk do
  padrão 4 (`KERN_WARNING`) para 3 (`KERN_ERR`), suprimindo as mensagens comuns de
  inicialização; os erros ainda aparecem.
- `systemd.show_status=no rd.systemd.show_status=no` silencia os avisos
  `[ OK ] Started ...` / `[FAILED]` do systemd tanto no initrd quanto no
  sistema principal.
- `quiet` costuma já estar na linha de comando padrão -- tanto
  `update-grub` quanto `grubby` deduplicam, portanto repetir não altera nada.

<a id="console-fb-safe"></a>

<a id="429f3d06-0026"></a>

<a id="console-bochs-drm-framebuffer-safety-kvm"></a>

### Console: segurança do framebuffer bochs-DRM (KVM)

Âncora: `console-fb-safe`

```
# host/vmconfig/ubuntu.server.kvm.overlay.yml (YURUNA_OVERLAY_GRUB_POST_CONSOLE_QUIET)
- |
  cat > /target/etc/default/grub.d/99-yuruna-fb-safe.cfg << 'GRUBCFG'
  GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT} nomodeset console=tty0 console=ttyS0,115200"
  GRUBCFG
```

A classe de armadilha bochs-DRM do KVM provoca um oops do kernel em
`ovl_iterate_merged` e uso intenso de CPU em `drm_fb_helper_damage_work` no
instalador live-server de resolute quando o vídeo padrão q35+UEFI controla
o subiquity. O kernel da fase de instalação não pode ser acessado externamente
(`--extra-args` de virt-install exige `--location`, não `--cdrom`), mas
fixar `nomodeset` no kernel *instalado* impede que a mesma armadilha
ocorra nas inicializações seguintes controladas pelo ambiente de testes. `nomodeset` desabilita
KMS, portanto nenhum driver DRM é carregado; o console serial fornece um canal de diagnóstico
que não depende do framebuffer.

<a id="429f3d06-0027"></a>

### update-grub

```
- curtin in-target --target=/target -- update-grub
```

Gera novamente `/boot/grub/grub.cfg`, para que os arquivos complementares GRUB acima
(`99-yuruna-hyperv-fb.cfg`, `99-yuruna-consoleblank.cfg`,
`99-yuruna-console-quiet.cfg`, `99-yuruna-fb-safe.cfg`) tenham efeito na
reinicialização após a instalação, e deve vir DEPOIS de todos eles. AL2023 não contém
o invólucro `update-grub`; `grubby` faz o mesmo trabalho diretamente e é
chamado por argumento acima.

<a id="429f3d06-0028"></a>

<a id="console-hold-getty-until-cloud-init-signals-done"></a>

### Console: reter getty até que o cloud-init sinalize a conclusão

*(ubuntu.server.24)*

```
# /etc/systemd/system/getty@.service.d/override.conf
[Service]
ExecStartPre=-/usr/bin/cloud-init status --wait
```

Os avisos de ciclo de vida `running 'modules: final'` / `finished` do cloud-init
chegam ao console por `/dev/kmsg` (timestamps no estilo do
kernel `[ 44.688245] cloud-init[1065]:`) incondicionalmente -- diferentemente do
par `cc_keys_to_console`/`cc_ssh_authkey_fingerprints`, nenhum
ajuste de cloud-config os silencia. Na primeira inicialização, esses avisos chegam DEPOIS que
getty desenhou `login:`, portanto o nome de usuário digitado e o prompt
`Password:` subsequente de `login(1)` ficam divididos pela saída de cloud-init, e o
OCR não consegue reconhecer `Password:`.

`cloud-init status --wait` é o contrato que o cloud-init expõe para
"aguarde até eu terminar"; o `-` inicial impede que um cloud-init em situação anormal
bloqueie getty para sempre. O arquivo complementar fica no modelo
(`getty@.service.d/`), portanto cobre `tty1` e qualquer outro getty
criado por `systemd-getty-generator`.

`[Unit] After=cloud-final.service` não basta: trata apenas da ordenação
(sem `Wants`/`Requires`) e perde uma disputa em ~5% das inicializações rápidas. Quando
`getty.target` é alcançado ANTES que `cloud-final.service` entre na
transação do systemd, a tarefa `getty@tty1` enfileirada é descartada silenciosamente, e
a VM fica para sempre em "Finished cloud-final.service", sem prompt de login
(cloud-init issue #2158, lp #1804957). `status --wait` em
`ExecStartPre` evita a disputa.

<a id="429f3d06-0029"></a>

<a id="yuruna-host-coordinates"></a>

### Coordenadas do hospedeiro Yuruna

```
mkdir -p /etc/yuruna
cat > /etc/yuruna/host.env <<EOF
YURUNA_STATUS_SERVICE_IP=YURUNA_STATUS_SERVICE_IP_PLACEHOLDER
YURUNA_STATUS_SERVICE_PORT=YURUNA_STATUS_SERVICE_PORT_PLACEHOLDER
EOF
grep -q yuruna-host /etc/hosts || echo "YURUNA_STATUS_SERVICE_IP_PLACEHOLDER yuruna-host" >> /etc/hosts
```

Dois artefatos gravados para o laço de iteração de desenvolvimento:

- `/etc/yuruna/host.env` -- os scripts de convidado carregam esse arquivo para preferir o
  status service local ao GitHub. `Test-YurunaHost.ps1` é a
  verificação dentro do convidado que confirma se essas coordenadas ainda são válidas.
- Entrada `yuruna-host` em `/etc/hosts` -- um nome estável que sobrevive à mudança de endereços por DHCP
  durante a sessão do convidado.

- **Hyper-V Default Switch:** o IP do hospedeiro muda entre reinicializações do hospedeiro.
  Reconstrua o convidado se `Test-YurunaHost.ps1` falhar depois de uma reinicialização do hospedeiro.
- **'default' do libvirt (KVM):** o gateway é estável em
  `192.168.122.1` -- não é necessário reconstruir.

<a id="429f3d06-002a"></a>

<a id="host-address-refresh-timer"></a>

### Temporizador de atualização do endereço do hospedeiro

```
[Unit]
After=network.target NetworkManager-wait-online.service systemd-networkd-wait-online.service
Before=network-online.target
[Service]
Type=oneshot
TimeoutStartSec=30
ExecStart=/usr/local/lib/yuruna/yuruna-host-locate.sh
[Install]
WantedBy=network-online.target
---
[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=5s
```

As coordenadas do hospedeiro em `/etc/yuruna/host.env` são configuradas
inicialmente ao criar a VM com `New-VM`. `fetch-and-execute.sh` resolve novamente
um endereço inacessível no início de cada etapa, deixando um intervalo aberto: uma etapa que
executa por muitos minutos pode ver o endereço do hospedeiro mudar durante sua execução e não ter
como reencontrá-lo. O temporizador fecha esse intervalo para tudo que nunca passa
pelo caminho de obtenção -- os scripts do próprio projeto, os pontos de verificação de desempenho,
os envios de logs --, que leem o mesmo `host.env`.

As VMs de serviço (`pool-control-service`, `download-agent-service`,
`stash-service`, `caching-proxy-service`) são as que mais precisam disso: são
provisionadas uma vez e depois executam por semanas, portanto acumulam mudanças de endereço que um convidado de
teste reconstruído a cada ciclo nunca vê, e ninguém digita nelas.

Uma frequência de um minuto é viável porque `yuruna-host-locate` consulta a
coordenada que o convidado já tem antes de consultar o diretório do grupo:
enquanto o endereço continua válido, cada execução custa uma viagem de ida e volta na LAN e nenhuma
gravação. Um `oneshot`, em vez de um daemon -- nenhum estado permanece entre as execuções,
e um oneshot não pode ficar travado. `TimeoutStartSec=30` é a proteção para o dia
em que um dos próprios limites de tempo de relógio do resolvedor deixar de funcionar, para que um resolvedor que
não termina nunca bloqueie a inicialização.

A unidade é ordenada *dentro* da barreira `network-online.target`, em vez de
depois dela. Tudo no convidado que precisa do hospedeiro aguarda esse alvo, portanto
terminar antes dele garante que esses consumidores nunca leiam um endereço
desatualizado -- sem que esta unidade nomeie um único deles, que é justamente o
objetivo dessa indireção. A linha `After=` lista ambas as implementações de wait-online,
porque ordenar em relação a uma unidade ausente não tem efeito; assim, uma
linha cobre a que a imagem contém e ainda executa com um endereço disponível,
em vez de antes de o DHCP responder.

Fonte: [`automation/yuruna-host-locate.sh`](../../automation/yuruna-host-locate.sh),
[`host/vmconfig/pool-control-service.base.user-data`](../../host/vmconfig/pool-control-service.base.user-data).

<a id="429f3d06-002b"></a>

### wget no_proxy

```
cat >> /etc/wgetrc <<EOF
no_proxy = YURUNA_STATUS_SERVICE_IP_PLACEHOLDER
EOF
```

Proteção redundante para a consulta ao status-service do hospedeiro. `apt:proxy` do subiquity
(ou o ambiente de AL2023) pode vazar como `http_proxy` para o
sistema instalado. Sem `no_proxy`, um `fetch-and-execute.sh` no convidado
que não tenha `--no-proxy` encaminha a consulta `/livecheck` pelo
caching-proxy-service, que não consegue alcançar o endereço NAT do hospedeiro
(Hyper-V Default Switch / default do libvirt / Apple VZ Shared NAT), e
recorre silenciosamente ao GitHub.

DEVE vir ANTES do download de fetch-and-execute e do wget de fuso horário
(ambos dependem do mesmo `/etc/wgetrc`).

<a id="429f3d06-002c"></a>

<a id="install-yuruna-lib"></a>

### Instalar a biblioteca yuruna

```
write_files:
  - path: /usr/local/lib/yuruna/yuruna-retry.sh
    encoding: base64
    content: YURUNA_RETRY_LIB_BASE64_PLACEHOLDER
    permissions: '0644'
  - path: /usr/local/lib/yuruna/fetch-and-execute.sh
    encoding: base64
    content: YURUNA_FAE_BASE64_PLACEHOLDER
    permissions: '0755'
```

(ou, em `late-commands:` do autoinstall do Ubuntu, o mesmo corpo gravado por
`printf '%s' "PLACEHOLDER" | base64 -d > /target/usr/local/lib/yuruna/...`.)

Todos os cinco auxiliares `automation/*.sh` são instalados no diretório canônico
`/usr/local/lib/yuruna/` de todos os convidados suportados:

- `yuruna-retry.sh` -- carregado por todos os scripts de provisionamento de convidados para
  `apt_retry` / `dnf_retry` / `curl_retry`. Veja
  [Definição da biblioteca de repetição yuruna](https://yuruna.link/4220a755-0003).
- `yuruna-versions.sh` -- as versões fixadas das dependências, carregadas por sua vez
  por `yuruna-retry.sh`.
- `fetch-and-execute.sh` -- o ponto de chamada do ambiente de testes; os
  YAMLs de sequências de teste o chamam como
  `/usr/local/lib/yuruna/fetch-and-execute.sh <relative/path/script.sh>`.
  O próprio ambiente de testes fornece o SHA-256 esperado do script, e o buscador
  recusa executar sem um; uma execução manual informa `E_SHA` (veja
  [Fornecimento manual do digest](../../guest/README.md#supplying-the-digest-by-hand)).
- `yuruna-network.sh` -- diagnóstico de rede do convidado e liberação de concessões
  DHCP.
- `yuruna-host-locate.sh` -- resolve novamente o endereço do status-service
  do hospedeiro. Incorporado à seed, em vez de baixado, porque é ele que decide de onde
  o convidado obtém o código.

As seeds de Ubuntu e Amazon Linux também instalam o lançador `yfe` em
`/usr/local/bin/yfe` a partir de `YURUNA_FETCH_CONTEXT_BASE64_PLACEHOLDER`.

Eles são lidos pelo `New-VM.ps1` no hospedeiro ao construir a seed,
codificados em base64 e incorporados como conteúdo `write_files:` do cloud-init, portanto
estão em disco antes que qualquer script de provisionamento execute. Única fonte de
verdade: `automation/` no repositório do framework.

<a id="429f3d06-002d"></a>

<a id="timezone-via-ip-geolocation-and-ntp"></a>

### Fuso horário por geolocalização de IP e NTP

```
timedatectl set-ntp true
TZ=$(wget -qO - --timeout=10 "http://ip-api.com/line?fields=timezone")
[ -n "$TZ" ] && timedatectl set-timezone "$TZ"
```

Melhor esforço: em caso de falha (sem `wget`/`curl`, sem rede, API inativa),
exibe um aviso `Yuruna => Timezone sync failed` em stderr e prossegue
com UTC.

- **ubuntu.server.24:** baseado em wget.
- **amazon.linux.2023:** baseado em curl (AL2023 contém curl por padrão, mas não
  wget na imagem de nuvem).

<a id="429f3d06-002e"></a>

<a id="quiet-post-install-reboot-teardown"></a>

### Finalização silenciosa da reinicialização após a instalação

*(ubuntu.server.24)*

```
- umount -lf /cdrom || true
- losetup -D || true
```

O subiquity mantém `/cdrom` (ISO de autoinstall), e o snapd mantém os loops de
squashfs; `systemd-shutdown` não consegue desvinculá-los a tempo e registra mensagens apenas visuais
`[FAILED] Failed unmounting cdrom` + `Could not detach loopback
/dev/loopN` na transição instalação->reinicialização. Executar estes comandos a partir
do instalador (último late-command, sobre `/cdrom`, NÃO
`/target/cdrom`) elimina as referências antes de reiniciar.

`-lf` = lazy-force; ambos usam `|| true`, pois qualquer um já pode não ter
efeito, e uma saída diferente de zero aqui faria toda a instalação falhar.

DEVEM ser os dois últimos late-commands.

<a id="429f3d06-002f"></a>

<a id="error-commands-installer-log-upload"></a>

### Envio de logs do instalador por error-commands

*(ubuntu.server.24, ubuntu.server.26)*

```
error-commands:
  - <PUT subiquity / curtin / cloud-init logs to the host status service>
```

Executa no ambiente do instalador live quando o subiquity aborta a
instalação. Envia por POST os arquivos de curtin / cloud-init / falhas ao endpoint
`/log-upload/` do status service do hospedeiro, para que a falha subjacente (`apt-get`
com saída 100, espelho 5xx, divergência de soma de hash) apareça no painel, em vez
de ser perdida quando o instalador entra em um shell.

- `--no-proxy` / `--noproxy '*'`: ignoram qualquer proxy apt que possa
  ser, ele próprio, a causa da falha.
- Falhas por arquivo são ignoradas (`|| true`), para que um envio inválido não
  oculte o próximo.
- `HOST_IP` / `HOST_PORT` incorporados a partir de `YURUNA_STATUS_SERVICE_IP_PLACEHOLDER` /
  `YURUNA_STATUS_SERVICE_PORT_PLACEHOLDER`; se qualquer um estiver vazio, o bloco
  termina antecipadamente com 0 (não há destino para o envio).

Organização dos conjuntos de arquivos no status service:
`installer-fail/<hostname>/<UTC-timestamp>/<file>`.

Capture `mounts-at-failure.txt` antes que as consultas de rede ou os envios atrasem
a investigação. Ele registra os IDs e a propagação das montagens do instalador, os nomes dos processos
e seus canais de espera, referências de processos a `/target` (incluindo IDs de montagem
dos descritores de arquivo e montagens relevantes no namespace de cada processo que mantém referências), a
árvore de montagem de destino, namespaces de montagem e candidatos de `fuser` /
`lsof` para `/target/run`. Ele nunca desmonta sistemas de arquivos nem encerra os processos que
mantêm referências a eles. Os argumentos e ambientes dos processos são omitidos. As consultas em todo o sistema de arquivos
também podem informar usuários de outra montagem bind do mesmo sistema de arquivos;
correlacione-os com os IDs de montagem e as referências dos processos antes de atribuir a causa.

Cada consulta tem prazo limite de três segundos, período de tolerância de um segundo para encerramento e
limite de 128 KiB de saída retida. Ferramentas ausentes, saídas diferentes de zero, truncamento e
prazos excedidos são registrados no snapshot; se `timeout` não estiver disponível, as consultas são
ignoradas. Nenhum pacote é instalado no caminho de falha. A captura ocorre
depois que o instalador aborta, portanto um processo que mantinha referências temporariamente pode já ter terminado.

Capture o snapshot de rede antes de tentar qualquer envio de arquivo. Os logs comuns
do instalador podem estar ausentes, enquanto o estado das rotas ainda distingue um convidado
que perdeu sua rota padrão de uma rota disponível cujo endpoint remoto
recusou a conexão ou não respondeu a tempo. Envie também `curtin-errors.tar`: o curtin pode preservar
seus logs úteis apenas nesse arquivo quando os arquivos nomeados separadamente
nunca foram gravados.

O hook de erro também exibe `/log/installer-fail/<hostname>/<UTC-timestamp>/` no
console. Esses envios são separados da pasta de diagnóstico do convidado no ciclo
e continuam úteis quando esse diagnóstico excede o prazo. Abra diretamente o
conjunto de arquivos indicado para obter os snapshots e `curtin-errors.tar`.

<a id="429f3d06-0030"></a>

<a id="headless-host-reboot-on-framebuffer-collapse"></a>

### Reinicialização do hospedeiro sem interface gráfica após colapso do framebuffer

*(Hyper-V amazon.linux.2023)*

```
power_state:
  delay: now
  mode: reboot
  message: "Yuruna: rebooting to apply video=hyperv_fb:1024x768 cmdline (headless host)."
  condition: ["/bin/sh", "-c", "test -f /run/yuruna-needs-reboot"]
```

AL2023 é uma imagem de nuvem pré-compilada (sem reinicialização do instalador), portanto, após a
etapa `grubby --args="video=hyperv_fb:1024x768"`, o kernel em execução ainda
tem a linha de comando ANTIGA: o framebuffer da primeira inicialização continua como um pequeno retângulo
preto, e a sequência de teste baseada em OCR não vê nada.

Uma consulta runcmd anterior no arquivo verifica
`/sys/class/graphics/fb0/virtual_size` e só executa `touch` em
`/run/yuruna-needs-reboot` quando a largura é `< 800`, portanto um hospedeiro com
monitor conectado (já exibindo corretamente) dispensa a reinicialização, e a
primeira captura de `login:` da sequência de teste ocorre na primeira inicialização.

O ciclo de vida por instância do cloud-init impede que isso execute novamente nas inicializações
seguintes, mesmo se o arquivo sentinela for recriado: `cc_power_state_change`
é marcado como concluído para a instância após sua primeira execução bem-sucedida.

<a id="429f3d06-0031"></a>

<a id="universe-packages-go-in-late-commands-not-packages"></a>

### Pacotes de universe vão em late-commands, não em `packages:`

Um pacote que fica em `universe`, em vez de em `main`, é instalado pela seção
`late-commands` do autoinstall, por meio de
`curtin in-target --target=/target -- apt-get install`, nunca acrescentando seu
nome à lista `packages:`. O espaço de overlay para esse pacote fica
deliberadamente vazio, com um comentário que explica isso; por esse motivo, uma âncora vazia ali
não é um esquecimento.

**Uma falha na obtenção por `packages:` é fatal.** O curtin informa
saída 100 de `system-install --download-only`, o subiquity aborta, e o convidado nunca
chega a um prompt de login -- toda a compilação é perdida por um pacote que geralmente é
uma otimização (`qemu-guest-agent` melhora a descoberta de endereço; o convidado ainda
é provisionado sem ele). Um late-command que falha é tolerado com `|| true`,
portanto a compilação termina e a capacidade se degrada.

**Os dois caminhos nem sequer resolvem as mesmas origens.** `packages:` é
processado pelo ambiente do instalador, com o que estiver habilitado naquele
momento; `curtin in-target` resolve usando as origens do sistema de DESTINO, que
incluem `universe`. Essa diferença não é teórica: `iptables-persistent` também é
um pacote de universe e instala pelo caminho in-target em hospedeiros onde
o mesmo nome em `packages:` não é resolvido.

A consequência para a etapa de habilitação: um late-command que apenas habilita uma unidade
(`systemctl enable qemu-guest-agent.service`) tolera a falha pelo mesmo
motivo, pois abortar a fase de late-command faz toda a instalação falhar, enquanto
a falta de um agente opcional apenas encaminha a descoberta ao próximo nível.

---

<a id="429f3d06-0032"></a>

<a id="caching-proxy-service-seed-topics"></a>

## Tópicos da seed do Caching-proxy-service

Esta seção reúne a justificativa de cada bloco não trivial do cloud-init
em
[`host/vmconfig/caching-proxy-service.base.user-data`](../../host/vmconfig/caching-proxy-service.base.user-data) --
a seed que constrói a VM **caching-proxy-service** do Yuruna (cache SSL-bump do squid +
registro OCI pull-through do zot + a pilha de observabilidade Prometheus / Grafana / Loki
+ o coletor pool-aggregator-service). O arquivo user-data continua enxuto:
cada tópico se resume a um apontador de uma linha, como:

```
# See https://yuruna.link/429f3d06-0033
```

O semi-GUID aponta para o cabeçalho `### <topic name>` correspondente nesta
seção sem depender do texto em inglês do cabeçalho.

A documentação aborda o cache por três ângulos:

- Os [Tópicos](#topics) de convidados acima -- justificativa do user-data compartilhado dos convidados; o
  cache aparece ali apenas como uma preocupação do *cliente* (bloco de proxy do apt, confiança na CA,
  imposição da saída pelo proxy).
- [caching.md -> referência do operador](../caching.md#caching-proxy-service--test-harness-operator-reference) -- o operador / as conexões
  (atendimento a clientes remotos, despacho por mapeamento de portas, promoção do proxy do hospedeiro): *usar*
  o cache, enquanto esta seção trata de como a VM de cache é *construída*.
- [caching.md](../caching.md) -- conceitos de SSL-bump do squid, refresh_pattern e
  YurunaCacheContent referenciados no squid.conf incorporado.

Os comentários que ficam *dentro* dos artefatos implantados (as diretivas de squid.conf,
o reescritor Python incorporado, os scripts de shell runcmd, as unidades systemd) permanecem
em seus arquivos -- eles são enviados ao convidado e lidos ali ao depurar
a VM em execução. Esta seção cobre a justificativa estrutural no nível de cloud-init.

Os tópicos seguem o fluxo de cima para baixo do user-data (chaves de cloud-config, depois
`write_files`, depois `runcmd`), para que o arquivo e esta seção possam ser lidos lado a lado.

<a id="429f3d06-0033"></a>

<a id="squid-cache-hostname-vs-template-name"></a>

### Nome de máquina do Squid-cache e nome do modelo

```
hostname: yuruna-caching-proxy-service
```

O nome de máquina no sistema operacional permanece sincronizado com o nome da VM / domínio
libvirt do hipervisor (`yuruna-caching-proxy-service`). A renomeação ocorre apenas AQUI -- o
diretório `guest.caching-proxy-service/` da árvore de fontes e o nome do arquivo de imagem mantêm o
token `caching-proxy-service`, pois identificam o tipo de convidado /
modelo, não a VM em execução. Essa separação impede uma sequência de renomeações por todo o
repositório quando a VM em execução é renomeada.

<a id="429f3d06-0034"></a>

<a id="users-replace-cloud-image-default-with-a-per-vm-admin-account"></a>

### Usuários: substituir o padrão da imagem de nuvem por uma conta de administrador por VM

Substitua o usuário padrão `ubuntu` da imagem de nuvem do Ubuntu por `caching-proxy-service-admin`. Um bloco `users:` SEM `- default` suprime inteiramente a criação de ubuntu -- apenas os usuários listados são incluídos em /etc/passwd. Cada família de VM recebe seu PRÓPRIO nome de administrador (`caching-proxy-service-admin`, `download-agent-service-admin`, `pool-control-service-admin`, `stash-admin`), para que suas entradas no cofre permaneçam independentes: com um nome compartilhado, o cofre contém uma senha, e a VM construída mais recentemente invalida a credencial de console das outras. `caching-proxy-service-admin` recebe:
- Sudo sem senha (esta VM é uma máquina de depuração em uma rede privada).
- A chave SSH do ambiente de testes yuruna para `ssh caching-proxy-service-admin@<cache-ip>` sem senha.
- lock_passwd: false, para que chpasswd abaixo possa definir uma senha aleatória conhecida para o acesso alternativo pelo console (o console da VM no hospedeiro), enquanto cloud-init não terminou e SSH ainda não está ativo.

<a id="429f3d06-0035"></a>

<a id="grafana-apt-repo-inline-gpg-key"></a>

### Chave GPG incorporada do repositório apt do Grafana

Repositório Grafana OSS: chave ASCII-armored incorporada (keyserver.ubuntu.com é intermitentemente pouco confiável; uma chave incorporada evita falhas em cascata durante a atualização de pacotes). Rotacione obtendo-a novamente de https://apt.grafana.com/gpg.key quando o Grafana publicar uma nova chave (verifique a impressão digital B53A E77B ADB6 30A6 8304 6005 963F A277 1045 8545).

<a id="429f3d06-0036"></a>

<a id="package-squid-openssl-not-squid"></a>

### Pacote squid-openssl, não squid

squid-openssl: compilação vinculada ao OpenSSL. O pacote padrão `squid` do Ubuntu é compilado SEM --with-openssl (divisão dos pacotes Debian por licenciamento OpenSSL e GPL), portanto seu interpretador de http_port rejeita `ssl-bump`, `tls-cert=` etc. com um FATAL "Bungled" ao carregar a configuração, e squid.service nunca abre um socket. squid-openssl fornece o mesmo /usr/sbin/squid e a unidade squid.service, e usa Conflicts: squid.

<a id="429f3d06-0037"></a>

<a id="squidclient-and-apache2"></a>

### squidclient e apache2

squidclient (/usr/bin/squidclient) vem em squid-common (já incluído por squid-openssl); não é necessário um pacote separado. Exemplo de PURGE: curl -x http://<cache>:3128 -X PURGE http://<origin>:<port>/<path>

`squid-cgi` (a interface web cachemgr.cgi) deliberadamente NÃO está na lista de pacotes, e não há arquivo complementar apache `yuruna-cachemgr.conf`. O Ubuntu removeu o pacote em 26.04 (Squid 7), portanto solicitá-lo não encontra candidato de instalação e FAZ toda a transação de pacotes do cloud-init FALHAR. Acesse os dados do gerenciador de cache com `squidclient mgr:<page>` na VM; `cachemgr_passwd` continua definido em squid.conf.

<a id="429f3d06-0038"></a>

<a id="monitoring-stack-packages"></a>

### Pacotes da pilha de monitoramento

Pilha de monitoramento: o Prometheus coleta métricas de squid-exporter (localhost:9301); Grafana em :3000 (Viewer anônimo). squid-exporter não tem pacote apt nem URL estável de artefato de versão no GitHub, portanto golang-go é instalado apenas pelo tempo necessário para `go install`; ambas as ferramentas de compilação são removidas no fim de runcmd (~400 MB recuperados). O binário compilado permanece.

loki + alloy sustentam o painel "Recent 100 requests" do Grafana -- o Prometheus armazena apenas agregações, portanto o IP do cliente / URL de destino por requisição não estão disponíveis ali. O Alloy acompanha /var/log/squid/yuruna_access.log (o fluxo `logformat yuruna` personalizado do squid) e envia ao Loki em localhost:3100. Ambos vêm de apt.grafana.com (o mesmo repositório do grafana) -- não é necessária uma origem adicional.

<a id="429f3d06-0039"></a>

<a id="package-acl-for-alloy-log-read"></a>

### Pacote acl para leitura de logs pelo alloy

acl: necessário para a etapa setfacl após zot que concede ao alloy acesso de leitura a /var/log/zot/zot.log (zot grava com modo 0600, portanto apenas a leitura pelo grupo não basta -- alloy não consegue acompanhar o log sem uma ACL).

<a id="429f3d06-003a"></a>

<a id="network-debugging-tool-packages"></a>

### Pacotes de ferramentas de depuração de rede

Ferramentas de depuração de rede para triagem interativa pelo console/SSH. A imagem de nuvem do servidor contém `ip`, mas não `ifconfig` nem `ping`; custam pouco para instalar e facilitam muito o trabalho.

<a id="429f3d06-003b"></a>

<a id="package-openssl-for-ca-generation"></a>

### Pacote openssl para geração da CA

openssl para a etapa de geração da CA em runcmd. A imagem de nuvem contém libssl, mas não a CLI /usr/bin/openssl, portanto `req -x509` falharia com "command not found" e deixaria http_port 3129 do squid sem poder carregar tls-cert/tls-key. Mantido no nível superior (não apt-get em runcmd), para que a falha apareça na fase de instalação de pacotes, não no meio da configuração do cache.

<a id="429f3d06-003c"></a>

<a id="package-unattended-upgrades"></a>

### Pacote unattended-upgrades

unattended-upgrades: aplica diariamente correções de segurança e atualizações pontuais de LTS pelas unidades padrão apt-daily.timer + apt-daily-upgrade.timer habilitadas pelo postinst do pacote. Com o arquivo complementar 20auto-upgrades abaixo, fornece à VM de cache de longa duração uma frequência de atualização mantida automaticamente, para que ela não acumule CVEs entre reconstruções do cache. Um `apt-get -y upgrade` na primeira inicialização, no fim de runcmd, elimina as atualizações pendentes entre a data de construção da imagem de nuvem e o momento atual.

<a id="429f3d06-003d"></a>

<a id="packages-cifs-utils-and-sqlite3-for-nas-replication"></a>

### Pacotes cifs-utils e sqlite3 para replicação no NAS

cifs-utils + sqlite3 sustentam a replicação opcional de serviços de grupo (ypool-nas) de networkStorage: ypool-nas-replicate.timer monta o compartilhamento NAS por SMB3 (cifs) e usa .backup online do sqlite3 para copiar de forma consistente o grafana.db ativo do Grafana. Ambos são pequenos pacotes de Ubuntu-main, sem dependência de versão do kernel, portanto permanecem no nível superior (a falha aparece na fase de pacotes, não no meio de runcmd); o temporizador só é habilitado quando a seed foi construída com replicação configurada.

<a id="429f3d06-003e"></a>

<a id="apt-retries-on-transient-errors"></a>

### Novas tentativas do apt para erros transitórios

Repete a obtenção pelo apt em erros transitórios de rede. O padrão do cloud-init é uma única tentativa; um único prazo excedido ou reset TCP contra archive.ubuntu.com faz toda a instalação de pacotes falhar e deixa a VM sem squid -- a falha "Exit code: 100 / Stdout: -" observada com `apt-get install apache2 squid`. Retries=5 cobre problemas transitórios, mas NÃO oculta 4xx (429/404) -- o apt os trata como fatais, e eles precisam da atenção do operador por /var/log/cloud-init-output.log.

<a id="429f3d06-003f"></a>

<a id="unattended-upgrades-schedule"></a>

### Programação de unattended-upgrades

Sinalizadores de habilitação de unattended-upgrades. Ambos os temporizadores (apt-daily.timer + apt-daily-upgrade.timer) vêm no pacote apt e são habilitados por padrão -- este arquivo complementar ativa a fase de atualização. Update-Package-Lists = executar `apt-get update` diariamente; Unattended-Upgrade = executar a fase de atualização diariamente. Auto-clean mantém /var/cache/apt limitado entre ciclos. O padrão /etc/apt/apt.conf.d/50unattended-upgrades restringe as atualizações apenas ao conjunto de segurança -- mantenha essa escolha conservadora; ampliar para todos os conjuntos arrisca incluir um kernel que precisa de uma reinicialização que não podemos programar em uma máquina de cache de longa duração.

<a id="429f3d06-0040"></a>

<a id="pool-configuration-store-over-read-only-http"></a>

### Armazenamento de configuração dos grupos por HTTP somente para leitura

Armazenamento de configuração dos grupos: servir o repositório Git bare SOMENTE PARA LEITURA pela LAN, usando o protocolo Git estático (dumb-HTTP) do apache. Os hospedeiros de grupos clonam/buscam http://<proxy>/pool-configuration.git para conhecer a composição do grupo, configuredState e os repositórios de cada grupo. O repositório contém apenas configuração SEM SEGREDOS (pools.yml / guests.compatibility.yml); as gravações passam pela CLI de administração no proxy (um caminho local/file://), nunca por essa rota HTTP. Apenas RFC1918, reproduzindo a política de acesso de cachemgr.

O `Alias` aponta para o NAS do grupo, não uma cópia local do proxy: o daemon pool-control-service executa em sua própria VM e só pode fazer PUSH para um local que monta, e esse compartilhamento é o que ele e este proxy montam para leitura e gravação. Apontar o apache para os mesmos bytes mantém um único armazenamento, para que um operador gravando configuração pela interface e um executor buscando-a não possam divergir. A rota retorna 404 enquanto o NAS não está montado, que é a resposta correta; uma cópia local desatualizada ocultaria a indisponibilidade de todos os executores.

<a id="429f3d06-0041"></a>

<a id="squid-drop-in-config-approach"></a>

### Abordagem de configuração por arquivos complementares do Squid

Sobrescritas por arquivos complementares sobre o /etc/squid/squid.conf padrão do Ubuntu. Os arquivos conf.d são incluídos após a configuração principal, portanto as diretivas de mesmo nome daqui têm prioridade. Um arquivo complementar (em vez de uma substituição completa) faz com que futuras atualizações do pacote squid mantenham seus padrões de refresh_pattern e ACL -- apenas as partes específicas de yuruna são substituídas.

O Squid é um proxy/cache HTTP genérico para instalações de VMs de teste. Ele substituiu apt-cacher-ng, que armazenava apenas URLs `.deb` e ainda deixava respostas 429 de security.ubuntu.com chegarem ao subiquity (a obtenção do kernel antes da instalação ia diretamente à origem). O Squid armazena qualquer resposta HTTP que possa ser armazenada em cache, portanto o próprio `apt-get --download-only` do instalador para linux-firmware etc. usa o cache nas instalações seguintes.

NÃO declare `http_port 3128` no arquivo complementar. O /etc/squid/squid.conf padrão do Ubuntu já o declara, e /etc/squid/conf.d/* é INCLUÍDO (não sobreposto) -- uma duplicação faz o squid abrir a porta duas vezes; a segunda falha com EADDRINUSE (`listen ... (98) Address already in use`), enquanto o squid ainda parece 'running'. A abertura padrão (todas as interfaces, :3128) é o que queremos.

<a id="429f3d06-0042"></a>

<a id="snapshot-cache-tuning"></a>

### Ajuste do cache como snapshot

O arquivo complementar `/etc/squid/conf.d/yuruna.conf` ajusta o squid como um **snapshot
reproduzível**, em vez de um cache web otimizado para substituição frequente:

1. os objetos permanecem até o disco estar quase cheio (sem liberação proativa);
2. o cache continua atendendo quando a origem está inacessível ou envia
   cabeçalhos desfavoráveis ao cache;
3. com `offline_mode` (ativado por runcmd após o pré-aquecimento), um cache completo
   permite instalações de convidados sem internet.

**Políticas de substituição.** `cache_replacement_policy heap LFUDA` mantém
objetos grandes usados com frequência (linux-firmware, kernels), em vez de muitos pequenos;
`memory_replacement_policy heap GDSF` faz o mesmo na memória. Quando
a remoção ocorre, objetos pequenos pouco acessados saem primeiro -- os blobs grandes,
caros de obter novamente, sobrevivem, como exige a reprodução offline.
A restrição de ordem é essencial (e permanece no comentário junto à
diretiva): `cache_replacement_policy` DEVE aparecer antes de `cache_dir`,
pois o squid associa a política ao interpretar `cache_dir`, e uma
substituição posterior não tem efeito.

**Cálculo do limite de cache_mem.** `SQUID_CACHE_MEM_PLACEHOLDER` é resolvido com
o perfil de memória da VM: 3 GB de cache Squid em uma VM padrão de 8 GB, ou 7 GB em
um beacon de laboratório de 12 GB. Ambos os perfis recebem metade dos núcleos do
hospedeiro, arredondada para baixo, com um mínimo de quatro vCPUs (Hyper-V ARM64
limita a alocação a duas). RAM e tamanho do cache Squid
devem mudar juntos porque swap está mascarado. O cálculo da folga está em
[caching.md -> dimensionamento da VM de cache](../caching.md#cache-vm-sizing).

**Dimensionamento do cache em disco.** `cache_dir ufs /var/spool/squid 393216 16 256`:
384 GB do disco de 512 GB da VM para squid (393216 MB no formato de três inteiros
tamanho/diretórios-L1/diretórios-L2 do squid), deixando ~128 GB para sistema operacional, logs e folga.
`ufs` é adequado para um cache de desenvolvimento de um único hospedeiro; mude para `aufs`/`diskd` apenas
se o squid bloquear em I/O de disco durante instalações concorrentes.

**Limite de tamanho de objeto.** `maximum_object_size 65 GB` cobre todas as
imagens de instalação provisionadas pelo yuruna, incluindo a imagem de instalação do macOS
(~18 GB) e folga para um pior caso de 64 GB (SDKs incluídos no Xcode, mídia completa
de instalação de Windows Server, modelos completos de VMs de desenvolvimento). O limiar do Squid
é INCLUSIVO -- qualquer objeto estritamente maior NÃO é armazenado em cache, silenciosamente
--, portanto a folga de 1 GB acima de 64 GB importa. Elevar o
limite não aloca disco; apenas muda o limiar de rejeição.

**Objetos até o disco estar quase cheio.** `cache_swap_high 99` / `cache_swap_low 98`:
nunca liberar sem necessidade -- a remoção só começa quando o disco estiver mais
de 98% cheio (~7,7 GB livres de 384 GB) e fica mais agressiva perto de 99%. Os
padrões do squid (baixo 90, alto 95) começariam a remover com ~38 GB ainda livres,
o que é inadequado para um cache de snapshot persistente.

**Reprodução com offline_mode.** `offline_mode on` serve objetos do cache sem
nunca revalidá-los com a origem. Agressivo de propósito -- esta VM
existe para manter os ciclos de teste em execução quando registros de origem (Docker Hub,
registry.k8s.io, registry.opentofu.org, public.ecr.aws etc.) apresentam
incidentes intermitentes de 5xx / limites de requisições. Com `offline_mode` desabilitado (o
padrão do squid), o `refresh_pattern .` abrangente revalida cada acerto,
portanto um único 5xx de origem derruba o ciclo mesmo quando o squid tem
todo o restante em cache. Com `offline_mode` habilitado, MISSes de cache ainda
seguem para a origem (caso contrário, a VM nunca poderia aquecer); apenas HITs são
servidos incondicionalmente. "Mudar o squid para o modo offline" abaixo cobre a
mudança por runcmd após o pré-aquecimento.

**Cache de digests de registros de contêineres (OCI + Docker v2).** Diagnósticos
de ciclos ativos mostraram URLs idênticas de blobs/manifestos fixadas por digest
sendo obtidas várias vezes por ciclo (segundo
`awk '$4 ~ /MISS/' /var/log/squid/yuruna_access.log`):
`/v2/.../manifests/sha256:<hex>` e `/v2/.../blobs/sha256:<hex>` são
imutáveis por definição, mas os registros retornam
`Cache-Control: must-revalidate` (ou `private`) para elas, portanto o
`refresh_pattern .` abrangente padrão revalida a cada requisição. A substituição
atinge apenas URLs fixadas por digest (o segmento `sha256:`); elas ficam em cache durante
o ano inteiro, como arquivos `.deb` do apt. As URLs de manifestos baseadas em tags
(`/manifests/<tag>` sem `sha256:`) continuam sendo revalidadas -- tags SÃO
mutáveis, por exemplo, `:latest`, `:2`, `:v0.28.4`. Elas recebem um intervalo de uma hora
de validade (`60 100% 60`), para que convidados concorrentes no mesmo ciclo usem
o cache, enquanto uma mudança de tag ainda é detectada dentro dessa hora;
`collapsed_forwarding` já agrupa as obtenções paralelas, portanto o intervalo
apenas ultrapassa `must-revalidate`. O padrão de digest corresponde ao CAMINHO da
URL, portanto funciona para qualquer hospedeiro de registro: registry.k8s.io, ghcr.io,
registry-1.docker.io, public.ecr.aws, us-east4-docker.pkg.dev e os
CDNs para os quais redirecionam com 307 (cloudfront, S3, R2 cloudflarestorage) -- todos
contêm o segmento `sha256:` no caminho redirecionado.

As URLs de pacotes versionados usam um intervalo de validade de um ano (525600 minutos). Uma nova versão tem uma nova URL; as substituições de refresh impedem que indicações de cache-control da origem ou de intermediários forcem revalidações redundantes do objeto existente.

<a id="429f3d06-0043"></a>

<a id="upstream-stall-and-fetch-pooling-guards"></a>

### Proteções contra travamento da origem e agrupamento de obtenções

Quatro diretivas que, juntas, impedem uma origem problemática de derrubar um
ciclo inteiro. Ajustadas em conjunto -- mudar uma isoladamente geralmente
desloca o travamento para outro lugar.

**`quick_abort_min -1 KB`** desabilita inteiramente o limiar de interrupção rápida,
para que um cliente que se desconecta durante a obtenção (um convidado reiniciando, por exemplo) não
cancele a transferência. O Squid termina o objeto, e o próximo cliente obtém um
acerto de cache, em vez de reiniciar o download.

**`read_timeout 2 minutes`** limita a inatividade da origem. O padrão do Squid
é 15 minutos e, com `collapsed_forwarding` habilitado, todos os clientes que compartilham uma
obtenção travada ficam travados com ela -- os clientes param no meio do corpo, com os cabeçalhos
já recebidos, exatamente onde nenhum prazo limite de conexão ou de intervalo entre leituras no
cliente é acionado (a classe de armadilha da transferência travada). O prazo limite é baseado em
inatividade e reinicia a cada pacote recebido, portanto um objeto grande lento, mas em progresso,
nunca é interrompido; apenas uma origem realmente silenciosa é.

Os dois minutos do Squid deliberadamente DURAM MAIS que o `Acquire::http::Timeout` dos convidados
(30 s, até três tentativas -- veja `New-AptProxyBlock`). O convidado desiste primeiro de um
índice travado, para que a falha ocorra dentro do limite de tempo da etapa da sequência,
enquanto ainda há tempo para informá-la, e `quick_abort_min -1 KB` acima significa
que desistir não cancela a obtenção: o squid continua recebendo o objeto pelo
restante de seu próprio prazo. Se a origem voltar dentro desse intervalo, o
objeto fica em cache, portanto `retry_with_backoff` do ambiente de testes na etapa obtém um acerto,
em vez de enfrentar o mesmo travamento. Reduzir o prazo do squid para igualar o do convidado
descartaria o objeto em transferência todas as vezes e transformaria cada nova tentativa em uma nova
tentativa na origem.

**`collapsed_forwarding on`** agrupa obtenções idênticas concorrentes: quando N
máquinas iniciam ao mesmo tempo a mesma ISO que não está em cache, o squid encaminha UMA requisição
à origem, e as outras N-1 compartilham a obtenção em andamento. Sem isso, cada
cliente consulta a origem em paralelo, desperdiçando a largura de banda do espelho e atingindo
limites por IP em releases.ubuntu.com quando muitas máquinas são reconstruídas. Aplica-se
a origens HTTP e a HTTPS com SSL-bump em :3129, e não tem
efeito sobre HTTPS em túnel CONNECT (não armazenável em cache por definição).

**`range_offset_limit none`** altera como requisições `Range:` preenchem o
cache. O padrão (`0`) encaminha a parte solicitada à origem e a serve
SEM armazená-la em cache, portanto downloads por intervalo e retomados (BITS, retomada do navegador,
`curl --range`, obtenção de pdiff do apt) não deixam nada para o
próximo cliente. `none` (sem limite) instrui o squid a obter o objeto COMPLETO na
primeira requisição por intervalo e servir os intervalos seguintes do cache --
essencial no caso de "muitas máquinas acessam a mesma ISO grande", em que o
primeiro acesso já pode ser uma retomada.

Junto com essas diretivas, **`cachemgr_passwd none config`** expõe a configuração em
execução em `/squid-internal-mgr/config` sem senha, como
squid-meta-exporter.sh precisa para que o painel leia o estado de EXECUÇÃO do daemon,
em vez do arquivo complementar em disco (que pode estar desatualizado entre uma edição
e `squid -k reconfigure`). A ACL padrão `http_access allow localhost
manager` em squid.conf mantém a saída fora da LAN.

<a id="429f3d06-0044"></a>

<a id="github-release-and-helm-chart-pinning"></a>

### Fixação de versões do GitHub e charts Helm

**Artefatos de versões do GitHub** (kubectl, helm, gh, jq, terraform-provider-*,
tofu, ...) ficam em `github.com/<owner>/<repo>/releases/download/<tag>/<asset>`,
que redireciona com 302 para `objects.githubusercontent.com/<token>/...`. Ambas as
URLs são endereçadas pelo conteúdo usando tag e nome de artefato -- os artefatos de versão são
imutáveis no modelo de dados do GitHub --, portanto ambas recebem a fixação de um ano inteiro. A
regra corresponde ao hospedeiro inteiro, não apenas aos artefatos terraform-provider,
pois binários sem extensão (`kubectl` e `helm` diretamente) não correspondem a nenhum
dos padrões abrangentes `.zip` ou `.tar.gz`.

**Pacotes de charts Helm** baixados por `helm install <repo>/<chart>` têm
URLs terminadas em `.tgz` (por exemplo,
`https://kubernetes.github.io/ingress-nginx/ingress-nginx-X.Y.Z.tgz`).
O padrão `\.tar\.gz$` NÃO corresponde ao formato curto `.tgz`, portanto, sem
uma regra dedicada, o pacote cai no `refresh_pattern .`
abrangente e é revalidado em cada instalação -- uma falha fatal
durante uma indisponibilidade breve de kubernetes.github.io. Os pacotes de charts têm tags de versão e
são imutáveis no modelo de dados do helm, portanto recebem a mesma fixação de um ano inteiro dos
artefatos de versões do GitHub.

**Índices de repositórios Helm** (`index.yaml`, obtido por `helm repo update`) têm
vida curta, mas podem ser armazenados em cache: validade de 60 minutos, com fator de 20%
baseado na última modificação, para que ciclos consecutivos dentro de uma hora usem o cache,
enquanto novas versões de charts ainda cheguem no mesmo dia. A regra se restringe a
hospedeiros conhecidos de repositórios helm, para que outros YAMLs não permaneçam em cache por tempo excessivo.

<a id="429f3d06-0045"></a>

<a id="squid-access-log-and-self-scrape-filtering"></a>

### Log de acesso do Squid e filtragem de coletas do próprio serviço

O logformat `yuruna` alimenta o painel "Recent 100 requests" do Grafana e o
caching-proxy-parser-service. `%>A` fica ausente de propósito: o Squid 6 o transforma em uma
consulta PTR síncrona, e endereços RFC1918 retornam dados inválidos dos
resolvedores de origem. O User-Agent é envolvido em aspas duplas literais porque
`%{...}>h` não escapa sozinho os espaços incorporados.

Ele grava em seu próprio arquivo, em vez do `access.log` padrão, para que
a depuração com cachemgr/`tail` mantenha o formato padrão. Duas entradas `access_log`
apontando para um arquivo corrompem ambas as saídas, portanto a separação é necessária, não apenas visual.

**Por que a exclusão de coletas do próprio serviço usa a origem, não o caminho da URL.**
squid-exporter consulta três endpoints `/squid-internal-mgr` em um intervalo de 15 s
do Prometheus -- aproximadamente 580 requisições por hora de ruído interno em
`yuruna_access.log` e na visualização "Recent 100 requests". O `deny` atua em
`access_log`, não em `http_access`, portanto o exportador ainda recebe sua resposta.

A ACL corresponde a `src 127.0.0.1/32 ::1/128`, pois o exportador executa nesta
VM e coleta de `127.0.0.1:3128`. Uma ACL de expressão regular `urlpath`/`url` não pode ser
avaliada para eventos de log no nível de conexão que não contêm uma requisição HTTP interpretada
(túneis CONNECT, erros de TLS-bump anteriores à requisição); o squid então grava "ACL is used
in context without an HTTP request" em `cache.log` para cada evento desse tipo --
centenas por minuto, ocultando erros reais. `src` está sempre disponível, portanto a
exclusão não gera avisos. O tráfego dos convidados vem da LAN, portanto desviar
loopback para seu próprio `yuruna_loopback.log` remove apenas coletas do próprio
serviço e consultas locais de saúde de `yuruna_access.log`.

O Squid 7 exige o prefixo de módulo em `access_log`; sem `stdio:`, o
interpretador emite um aviso de obsolescência em cada carregamento da configuração.

<a id="429f3d06-0046"></a>

<a id="prometheus-loopback-only"></a>

### Prometheus apenas em loopback

Prometheus: apenas em loopback, para que sua interface aberta não fique exposta na LAN; o Grafana em :3000 é o ponto de entrada.

A tarefa de coleta `pool-host` descobre exportadores acessíveis de hospedeiros pelo agregador, em vez de incorporar endereços DHCP à seed. Ela substitui `instance` pelo `hostId` estável e inclui os rótulos `pool` e `hostType`, mantendo o histórico contínuo após mudanças de endereço e permitindo junções com métricas do grupo. Sua lista de permissões mantém famílias de tempo de CPU, memória, capacidade e latência/fila de discos lógicos, identidade do sistema operacional, saúde da compilação e dos coletores do exportador e famílias selecionadas de tempo de execução e agendamento de processadores lógicos/raiz/convidados do Hyper-V, além de `up` e `scrape_*`. São aceitas tanto as grafias implantadas quanto as mais recentes das métricas de execução. Famílias de Hyper-V não relacionadas e por processo permanecem excluídas. Disponibilidade e unidades são descritas em [métricas do hospedeiro](../host-hyperv.md#42dc5bb9-0010); manter uma métrica não comprova que o exportador instalado a publique.

Para visualizar e aplicar apenas esse filtro a um monitor existente, a partir da raiz do repositório:

```powershell
pwsh test/pool/Sync-PoolHostMetricsOnProxy.ps1 -WhatIf
pwsh test/pool/Sync-PoolHostMetricsOnProxy.ps1
```

Um `-ProxyAddress` opcional substitui o endereço configurado do caching-proxy. O comando usa a conta/chave SSH existente e sudo não interativo. Preserva todas as outras seções de configuração, valida um candidato temporário com `promtool check config`, substitui a configuração atomicamente, envia SIGHUP ao Prometheus e verifica o timestamp e a métrica de sucesso do recarregamento por loopback. Recarregamentos malsucedidos restauram o arquivo anterior e tentam um recarregamento de reversão confirmado; o comando informa quando a confirmação não está disponível. Ele recusa regras keep ambíguas ou personalizadas, em vez de substituir uma tarefa de coleta inteira. Não é necessário reconstruir a VM nem instalar pacotes. Executar o comando sem `-WhatIf` altera o monitor selecionado; editar apenas o repositório não atualiza monitores existentes.

<a id="429f3d06-0047"></a>

<a id="loki-tiered-retention"></a>

### Retenção em níveis do Loki

A seed vincula o Loki a 127.0.0.1:3100 e o Prometheus a 127.0.0.1:9090, substituindo seus padrões 0.0.0.0. Retenção em níveis: 90d para transições (src=cycle) + incidentes (src=incident) -- as contagens Pass/Fail de count_over_time e o histórico de incidentes do painel cobrem 90 dias -- e 7d para eventos por etapa (src=event), detalhamento focado no passado recente (limita o disco). Gravado previamente aqui porque --force-confold do cloud-init o preserva durante atualizações de pacotes.

<a id="429f3d06-0048"></a>

<a id="alloy-timestamp-only-labels"></a>

### Alloy: timestamps sem rótulos adicionais

O Alloy define um rótulo `job` para cada origem e interpreta timestamps de eventos sem usar IPs de clientes ou URLs como rótulos. A seed fixa 1.20.1, valida `/etc/alloy/config.alloy`, para o serviço Promtail legado e importa uma vez suas posições salvas. O estado persistente dos componentes Alloy impede repetição após a reinicialização. Veja [migração do coletor](../caching.md#loki--alloy-boot-order-traps).

**Mantenha os erros de sincronização do zot.** A etapa JSON pode encontrar registros de sync-extension sem um `path` HTTP; esses registros explicam os atrasos de novas tentativas e falhas na origem, mesmo quando a requisição final de manifesto registra uma resposta bem-sucedida. O modelo fornece `NO_HTTP_PATH` para caminhos ausentes, e a etapa de descarte remove apenas coletas do próprio serviço em `/metrics`. A sentinela é mantida, não descartada, para que requisições lentas bem-sucedidas preservem as evidências de suas falhas subjacentes.

<a id="429f3d06-0049"></a>

<a id="alloy-supplementary-groups-drop-in"></a>

### Arquivo complementar de grupos suplementares do Alloy

Arquivo complementar do Alloy: SupplementaryGroups concede leitura aos logs de acesso dos serviços de origem:
- proxy:  /var/log/squid/yuruna_access.log (proxy:proxy 640)
- zot:    /var/log/zot/zot.log             (zot:zot     600; a permissão de leitura vem da ACL)
O serviço executa como o usuário `alloy` do pacote; mantenha ambos os grupos suplementares e as ACLs de arquivo/padrão do Zot.

<a id="429f3d06-004a"></a>

<a id="squid-metadata-exporter"></a>

### Exportador de metadados do Squid

Pequeno script que informa `squid_offline_mode_configured` (1 se `offline_mode on` estiver definido), `squid_listening` (1 se squid estiver atendendo em :3128) e uma consulta de acessibilidade da internet. A saída é um arquivo no formato Prom em /var/www/html, servido pelo apache e coletado pelo Prometheus (job: squid_meta).

`offline_mode` é lido da configuração **em execução** do squid pela pseudo-URL de cachemgr `http://127.0.0.1:3128/squid-internal-mgr/config`, à qual `cachemgr_passwd none config` em yuruna.conf permite acesso sem senha pela ACL localhost manager. Consultar o daemon faz a métrica refletir o que o squid está APLICANDO agora, não o que diz `/etc/squid/conf.d/yuruna.conf` -- que fica desatualizado quando alguém edita o arquivo, mas não executa `squid -k reconfigure`. Se o squid está inativo, curl falha e a métrica informa 0, a resposta correta: um daemon parado não serve nada.

A consulta de conectividade da internet é um GET HTTPS ao conhecido endpoint 204 do Google (a consulta de detecção de portal cativo do Android / Chrome OS), enviado diretamente, sem cadeia de proxies -- esta VM *é* o proxy. O limite superior de 5s trata qualquer resposta mais lenta como "não realmente acessível" para os fins do cache. O cache ainda pode servir HITS offline; esta métrica reflete se MISSES podem ser preenchidos.

Duas razões para NÃO incorporar isso ao squid-exporter:
- squid-exporter lê os contadores de cachemgr do squid; offline_mode é uma diretiva de configuração, não um contador, portanto expô-lo exigiria uma bifurcação.
- Quando o squid está INATIVO, as métricas de squid-exporter deixam de ser publicadas, e o Grafana mostra "No data" -- justamente quando o operador precisa saber se offline_mode deveria estar habilitado. Este exportador publica independentemente do squid, portanto o sinal sobrevive a uma falha do squid.

`squid-meta-exporter.timer` atualiza `/var/www/html/squid-meta`; o Apache serve
esse arquivo independentemente do Squid. Assim, o Prometheus ainda consegue
coletar as leituras da porta e do modo de execução quando o Squid está indisponível.

<a id="429f3d06-004b"></a>

<a id="zot-manifest-canary-exporter"></a>

### Exportador de consulta de manifesto do zot

Mede o tempo do caminho de *manifesto* do cache, em vez de apenas sua disponibilidade, lê a cota compartilhada de pulls do Docker Hub e publica ambos como texto Prometheus em `/var/www/html/zot-meta`, além de uma página legível por pessoas em `/var/www/html/cache-health`. Controlado por `zot-meta-exporter.timer`.

Servido pelo apache, não pelo zot, para que os números sobrevivam exatamente à falha que descrevem: um zot cujo caminho de sincronização está travado ainda responde a `/v2/` e `/metrics` em milissegundos, portanto uma consulta servida PELO zot informaria saúde durante toda a falha.

**Por que a consulta de detecção usa uma tag.** Uma tag é mutável, portanto servi-la executa novamente a sincronização sob demanda com a origem -- o trecho que trava. Uma URL de digest é imutável, recebe resposta do armazenamento local e continua rápida durante toda a indisponibilidade -- inútil como consulta de detecção. O par repo:tag é um que as cargas de trabalho realmente obtêm, portanto o número significa o que a pessoa que o lê pressupõe.

**Por que especificamente `dotnet/sdk`.** Uma consulta por tag é indistinguível de um pull para a origem que ela resolve, portanto a escolha de repositório determina o custo da consulta. `dotnet/sdk` corresponde à entrada com escopo `mcr.microsoft.com` na lista de sincronização, e essa origem não mede consumo -- portanto a consulta executa na frequência exigida pelo travamento que monitora, em vez da frequência permitida por uma cota medida. Um repositório que caísse na regra abrangente do Docker Hub colocaria a consulta de saúde na única cota medida do laboratório, contribuindo para o esgotamento que ela deve informar.

**Por que `Accept:` é explicitado.** Um registro responde a uma requisição de manifesto sem preferência declarada com o que considera padrão; para uma tag multiarch, isso não é o índice resolvido por um pull, portanto uma consulta sem especificação pode seguir um caminho diferente do pull que representa.

**Dois prazos, não um.** `PROBE_MAX` (120s) limita a própria consulta -- um travamento é o sinal, portanto o limite precisa superar a paciência do cliente que esta consulta pretende explicar, mas ainda retornar a tempo da próxima execução do temporizador. `CLIENT_PATIENCE` (30s) é o prazo realmente aplicado pelo cliente: dockerd abandona uma requisição cujos *cabeçalhos de resposta* não chegaram aproximadamente até então, e zot não envia cabeçalhos até resolver sua sincronização sob demanda; portanto um manifesto que finalmente responde em 55s é um manifesto para o qual todos os pulls falham. Informado em sua própria métrica gauge porque o limite da consulta deliberadamente dura mais (medir um travamento exige sobreviver a ele), e uma leitura abaixo do limite amplo nada diz sobre a capacidade de o cliente suportá-la.

O resultado de estar dentro da paciência é calculado em `awk`, não no comando interno `test` do shell: o tempo decorrido é fracionário, e `-le` em `"30.412"` gera erro, em vez de responder, o que, sob `set +e`, deixaria silenciosamente o resultado em 0 para toda leitura com decimal.

**Trecho até a origem.** Medido sem consumir a cota de pulls -- `/v2/` responde 401 em todos os registros daqui e não custa cota, distinguindo "a internet está lenta a partir desta VM" de "zot está lento", sem se tornar um segundo consumidor do limite informado pela métrica de cota. Qualquer status HTTP comprova esse trecho: 401 é a resposta saudável para um `/v2/` não autenticado, e tratar apenas 200 como ativo informaria que todos os registros estão inativos. As linhas de métricas são acrescentadas por consulta, em vez de acumuladas em uma variável de shell, porque uma linha de métrica deve começar na coluna 0, e uma quebra de linha incorporada a uma variável carrega a indentação deste próprio arquivo para o conteúdo enviado.

**Cota do Docker Hub.** O limite anônimo é por IP de saída, portanto é consumido por todos os convidados do laboratório ao mesmo tempo, e seu esgotamento nunca aparece como um 429 claro para um convidado. A falha que ele *produz* depende do repositório: um já armazenado continua sendo servido localmente, portanto nada parece errado até que algo novo seja obtido; esse pull então falha após as tentativas sob demanda, em poucos segundos, e retorna apenas `404 manifest unknown` -- um formato que parece nome de imagem digitado incorretamente, não problema de cota. O formato de cache travado pertence a uma origem *lenta*, em vez de uma que recusa: o pull-through não envia cabeçalhos de resposta até resolver sua sincronização, e o convidado atinge primeiro seu próprio prazo. `HEAD` em `ratelimitpreview/test` é a forma documentada de ler os contadores; informa-os sem consumir uma unidade. Lido, no máximo, uma vez por hora (`HUB_MIN_INTERVAL`) e mantido em cache em disco entre as leituras: os contadores descrevem uma janela de uma hora, portanto uma frequência de dez minutos amostra a mesma janela cinco vezes a mais para um número que não pode ter mudado -- enquanto emite um token a cada vez na origem da qual este arquivo existe para reduzir o tráfego. Entre leituras, os valores anteriores são republicados, para que a métrica mantenha um valor, em vez de cair para zero e indicar uma cota esgotada.

Apenas uma leitura bem-sucedida é persistida. Armazenar uma falha em cache a republicaria pelo restante da hora, transformando um problema transitório de autenticação ou de saída em uma hora de página informando uma cota cuja leitura não falhou de fato durante todo esse período -- e uma cota não lida já é exibida como zero, o mesmo formato do esgotamento.

**Cota autenticada e anônima.** O Hub mede uma sincronização autenticada pela conta e uma anônima pelo IP de saída; os dois limites diferem tanto em tamanho quanto em quem mais os consome, portanto uma contagem restante não significa nada até que o modo seja informado junto. Um token emitido com a conta informa a cota realmente consumida pelos pulls do zot, e a consulta é estritamente de melhor esforço -- uma credencial rotacionada ou revogada deve tirar a precisão da leitura, não sua existência, portanto qualquer falha recorre à requisição anônima, e a página informa qual cota acabou apresentando. A credencial é passada por um arquivo netrc de modo 0600, em vez da linha de comando: argv pode ser lido por todas as contas desta VM por `/proc`, e o objetivo do modo da credencial é impedir a leitura do token. Os campos são extraídos com `sed`, não `jq`, porque esta consulta precisa continuar informando resultados em uma inicialização com instalação de pacotes incompleta, e um campo de um objeto plano não justifica a dependência.

**Três leituras distintas.** A consulta por tag do MCR mede o trecho até a origem de uma imagem mantida no armazenamento por consultas programadas. Ela não comprova que uma imagem arbitrária de convidado já esteja armazenada. Os dados do conjunto aquecido vêm da tarefa de pré-aquecimento: tanto linhas `warm` quanto linhas `cold` concluídas com sucesso contam como armazenadas, enquanto linhas com prazo excedido/falha não contam. A página informa separadamente imagens respondidas a partir do armazenamento e imagens copiadas durante a última execução, preservando se um convidado que chegasse durante aquela execução teria esperado.

A consulta do caminho do convidado envia a mesma requisição de manifesto `?ns=registry.k8s.io` usada pelo containerd, para uma imagem registrada como armazenada na última execução de aquecimento. Isso mede uma origem sob demanda, sem consultas programadas, e evita executar uma sincronização fria completa a cada execução do exportador. Seu resultado de cabeçalhos de resposta é informado separadamente da leitura MCR; um HTTP 200 dentro do limite amplo ainda pode ultrapassar a paciência de 30 segundos do convidado.

`TimeoutStartSec=360` comporta duas consultas de manifesto de 120 segundos, oito leituras limitadas de origens e a consulta à cota do Hub. O prazo padrão do systemd poderia encerrar uma execução lenta válida antes de ela publicar, deixando a página de saúde anterior visível justamente durante uma indisponibilidade. O limite permanece abaixo do intervalo de dez minutos do temporizador. O modo publicado da cota identifica o limite autenticado ou anônimo, mas omite o nome da conta; `/cache-health` é legível sem login.

<a id="429f3d06-004c"></a>

<a id="zot-prewarm"></a>

### Pré-aquecimento do zot

`zot-prewarm.sh`, controlado por `zot-prewarm.timer`, mantém neste cache os conjuntos de imagens obtidos por um convidado Kubernetes e mede cada obtenção, para que a página de saúde informe o caminho percorrido por um pull real. Os detalhes para o operador -- os conjuntos resolvidos, a leitura publicada e o limiar de sincronização fria -- estão em [caching.md](../caching.md#warm-sets-and-the-cold-sync-reading); o que vem a seguir explica por que a unidade tem essa forma.

**Por que aquecer.** zot resolve uma TAG executando novamente a sincronização sob demanda com a origem ANTES de qualquer verificação de armazenamento local. Quando o conteúdo ainda não está armazenado, essa sincronização guarda o índice da tag, e o manifesto e as camadas de cada plataforma são copiados quando um cliente pede esse filho pelo digest, com o cliente esperando nessa requisição. Um convidado que encontra esse estado frio paga minutos por imagem dentro de um limite de tempo de etapa dimensionado para um cache aquecido, por isso a execução pede os filhos `linux/amd64` e `linux/arm64` além da tag: pedir só a tag guardaria o índice e nenhuma das camadas. Aquecer por temporizador tira o custo do caminho em que um convidado espera; não o elimina.

**Por que a medição de tempo fica aqui.** Esta é a única leitura que mostra o caminho frio. Uma tag mantida no armazenamento por uma consulta programada responde localmente em milissegundos, qualquer que seja o comportamento da sincronização fria; portanto uma consulta fixada nessa tag informa saúde por construção -- mede o trecho até a origem e nada sobre quanto demora para chegar uma imagem que o laboratório não armazena. A execução de pré-aquecimento obtém conteúdo realmente ausente, portanto seu próprio tempo decorrido é o número correto.

**`PREWARM_MAX` (900s) é um limite máximo, não uma expectativa.** Ele existe para impedir que uma origem travada prenda a unidade para sempre, não para definir o que é aceitável: uma imagem fria multiarch do plano de controle pode legitimamente levar minutos, e interrompê-la abandonaria uma sincronização que a próxima execução teria de reiniciar.

**`COLD_FLOOR` (5s) separa revalidação de transferência.** O armazenamento local responde em milissegundos, portanto uma leitura em segundos inteiros já significa que o trecho até a origem executou e a requisição moveu conteúdo, em vez de confirmar uma tag já presente no cache.

**`Accept:` é explicitado** pelo mesmo motivo que o exportador de consulta o explicita: uma requisição de manifesto sem preferência recebe o padrão do registro, que, para uma tag multiarch, não é o índice resolvido por um pull real.

**As execuções são serializadas com `flock`.** Duas execuções sobrepostas disputariam os arquivos de estado em `/var/lib/yuruna` e duplicariam o trabalho na origem sem benefício -- e uma execução fria longa que se sobrepõe à próxima execução do temporizador é o caso comum aqui, não uma exceção. Uma execução periódica que encontra o bloqueio ocupado é ignorada, em vez de enfileirada.

**O conjunto aquecido é resolvido, nunca fixado na seed.** Todas as entradas são lidas da mesma origem lida pelo convidado, portanto o conjunto aquecido não pode divergir do conjunto obtido por ele; incluir versões neste arquivo criaria uma segunda fixação que ficaria desatualizada silenciosamente, e a desatualização só apareceria como cache frio durante uma execução de provisionamento. Essas obtenções para resolução vão diretamente à origem: encaminhá-las pelo próprio listener ssl-bump desta VM faria a obtenção depender do proxy que deve manter abastecido.

A lista de imagens do plano de controle vem do `kubeadm config images list` correspondente, pois as versões de CoreDNS, pause e etcd não podem ser calculadas apenas pela versão do Kubernetes. A resolução recorre independentemente, por conjunto, à lista armazenada anterior; o sinalizador de atualização registra se a execução atual a resolveu, para que um resultado vazio não resolvido não se apresente como conjunto aquecido atual. Cada requisição de aquecimento inclui seu namespace de origem para evitar a regra abrangente de roteamento do Docker Hub.

O temporizador de seis horas corresponde à frequência de sincronização programada do zot. Na inicialização, é ativado de forma assíncrona: uma primeira execução fria pode levar dezenas de minutos e não deve reter o aviso de prontidão de cloud-init. Depois do aquecimento, a tarefa atualiza imediatamente a página de saúde publicada, em vez de deixar o estado antigo visível até a próxima execução do exportador, em dez minutos.

<a id="429f3d06-004d"></a>

<a id="squid-exporter-unit"></a>

### Unidade do exportador Squid

Unidade squid-exporter: binário instalado com go em runcmd, apenas em loopback (o Prometheus coleta suas métricas).

<a id="429f3d06-004e"></a>

<a id="grafana-anonymous-viewer"></a>

### Viewer anônimo do Grafana

Grafana: Viewer anônimo (sem login/cadastro); admin/admin continua editável. Variáveis de ambiente GF_* aplicadas por arquivo complementar systemd.

<a id="429f3d06-004f"></a>

<a id="grafana-datasources-pinned-uids"></a>

### UIDs fixados das fontes de dados do Grafana

Fontes de dados do Grafana: UIDs fixados para referências cruzadas estáveis no painel provisionado.

<a id="429f3d06-0050"></a>

<a id="grafana-dashboard-rewriter"></a>

### Reescritor de painéis do Grafana

Reescritor de painéis comunitários do Grafana baixados de grafana.com. Os painéis de origem usam um marcador de modelo $DS_PROMETHEUS cujo padrão incorporado aponta para a fonte de dados do autor original (por exemplo, "VictoriaMetrics Bagno") -- sem reescrita, o painel carrega, mas todos os seus quadros mostram "No data" até que alguém use o seletor. Este script remove o seletor, fixa a fonte de dados de todos os quadros em yuruna-prometheus e atribui um uid estável, para que novas execuções sejam idempotentes. Genérico para qualquer painel que use apenas prometheus; atualmente, o único chamador é a instalação do painel Zot abaixo.

<a id="429f3d06-0051"></a>

<a id="grafana-dashboard-rewriter-panel-repairs"></a>

### Reparos de quadros no reescritor de painéis do Grafana

Além da nova associação de fonte de dados acima, o reescritor contém uma passagem numerada de reparos. Cada etapa existe porque um quadro específico da origem aparece vazio no Grafana 13 com zot v2.x; os números das etapas correspondem aos comentários `# N)` no script reescritor da seed.

**3) Remover quadros que consultam métricas não emitidas por zot v2.x.** O painel comunitário 20501 foi criado para uma compilação mais recente que emite `zot_scheduler_workers_tasks_duration_seconds_bucket`; v2.x não a emite, portanto o quadro mostra "No data" para sempre. Liste outros nomes de métricas ausentes em `BAD_METRICS`. As variáveis de modelo passam pela mesma limpeza: sua consulta `label_values()` referencia a mesma métrica inexistente, portanto o menu suspenso da barra de ferramentas ficaria permanentemente vazio e só apresentaria uma indicação confusa na interface.

**4) Remover linhas órfãs** -- uma linha imediatamente seguida por outra linha, ou uma linha sem quadro depois dela --, para que nenhum cabeçalho de seção sobreviva à remoção de seu único quadro filho.

**5) Substituir diretamente `$storageName`.** Nosso zot tem um backend de armazenamento (`/var/lib/zot`). O painel comunitário o passa por uma variável de modelo para que implantações com vários backends possam escolher um; aqui, essa indireção apenas deixa o mapa de calor vazio até que alguém abra o menu da variável. A substituição é uma expressão regular que corresponde a qualquer valor e cobre futuras adições de backends sem reintroduzir um menu suspenso.

**5.5) Normalizar destinos de mapas de calor para `format=heatmap`.** O painel 20501 de origem contém pelo menos um destino de mapa de calor com `format=time_series`; no mapa de calor React do Grafana 13, o quadro então mostra "No data" mesmo quando o PromQL subjacente retorna intervalos identificados por `le`. A normalização faz a fonte de dados emitir a estrutura de intervalos detectada automaticamente pelo quadro. A mesma etapa reescreve a referência agora órfã a `$storageName` nos títulos dos mapas de calor, para que ela não apareça literalmente.

**5.6) `[$__interval]` para `[$__rate_interval]` em todas as expressões PromQL.** O Grafana resolve `$__interval` como `max(scrape_interval, range / max_data_points)` e, em intervalos de tempo curtos (~1h com a largura típica de um quadro de mapa de calor), chega a 15s -- o próprio intervalo de coleta. `increase(metric[15s])` então tem apenas UMA amostra por janela, e o PromQL não retorna nada, deixando o mapa de calor HTTP Method Latency vazio nos intervalos de 1h e 3h, embora haja acessos ao cache. `$__rate_interval` é garantido como >= 4 * scrape_interval, portanto `increase()`/`rate()` sempre têm amostras suficientes; a documentação "Variables in Prometheus" do Grafana o identifica como o token de intervalo correto para consultas rate/increase.

**5.7) Igualdade de rótulos para expressão regular de rótulos em variáveis multi+includeAll.** O painel 20501 de origem contém o mapa de calor HTTP Method Latency com `zot_http_method_latency_seconds_bucket{method="$http_method"}`, enquanto `http_method` é declarado como `multi: true, includeAll: true, hide: 2`. Com a URL padrão do Grafana (`var-http_method=$__all`) e o formatador pipe do Prometheus, `$http_method` é substituído por `GET|HEAD` -- mas `method="GET|HEAD"` é uma igualdade de cadeia LITERAL e retorna zero séries, portanto o mapa de calor mostra "No data" para sempre, e `hide: 2` remove o menu da barra de ferramentas, impedindo que alguém alcance manualmente um estado funcional. A passagem percorre todas as expressões de quadros e muda `label="$var"` para `label=~"$var"` para cada variável multi+all do painel, cobrindo também futuras variáveis usadas na posição `=`.

**Substituição do quadro de latência de bloqueio de armazenamento.** O mapa de calor "Storage lock latency" da origem (quadro 47) não é exibido no Grafana 13: o caminho de dados do Prometheus retorna estruturas válidas rotuladas por `le`, mas a migração do mapa de calor legado deixa esse quadro vazio, e nem remover seu `repeat: "storageName"`, nem normalizar `target.format` para heatmap, nem copiar campos de exibição de um mapa de calor irmão funcional (quadro 30) o corrige. O reescritor SUBSTITUI o quadro por uma série temporal que mostra P50/P90/P99 da mesma métrica por `histogram_quantile`, dividida por `lockType`: estritamente mais informativa (os números podem ser lidos na legenda), e séries temporais são o tipo de quadro mais consolidado do Grafana. Os quadros são identificados pelo conteúdo da consulta, não pelo ID, portanto uma renumeração na origem não quebra isso.

O instalador marca o painel importado com a tag `community`, lida pelo carimbador de marca. O UID estável reescrito `yuruna-` identifica o painel, mas não distingue conteúdo de origem de um painel criado pelo Yuruna.

<a id="429f3d06-0052"></a>

<a id="grafana-dashboard-provider"></a>

### Provedor de painéis do Grafana

Monitora JSON em /var/lib/grafana/dashboards; sincroniza edições após a inicialização.

<a id="429f3d06-0053"></a>

<a id="grafana-pull-budget-alert"></a>

### Alerta de cota de pulls do Grafana

Regra provisionada de unified-alerting do Grafana (pasta `Yuruna`) que dispara quando a cota de pulls do Docker Hub se esgota. A condição é um PRODUTO de duas métricas gauge -- `(remaining == bool 0) * (probe_ok == bool 1)` --, em vez de uma leitura apenas de `remaining`, pois o exportador também publica uma cota não lida como zero: uma regra que observasse apenas esse número anunciaria um limite esgotado para o que na verdade é uma credencial recusada ou um caminho de saída quebrado, a mesma confusão contra a qual o quadro do painel se protege.

**Por que `== bool` nas duas partes.** Mantém o resultado como uma série `1`/`0` que sempre existe. Escrita apenas como `and`, o caso saudável é um vetor VAZIO, e os alertas não conseguem distinguir um vetor vazio de um exportador que parou de publicar -- portanto uma falha silenciosa pareceria idêntica à saúde. Como está escrito, uma série ausente só pode significar que o exportador desapareceu, e isso vai para `NoData` com seu próprio nome, em vez de usar o resumo desta regra.

**Período pendente e frequência de avaliação.** Avaliada a cada 5 min, com um período pendente de 10 min. Ambos são deliberadamente muito mais lentos que a coleta de 15s: a cota é lida novamente do Hub, no máximo, uma vez por hora e republicada do disco entre leituras, portanto um laço mais rápido apenas reexamina um valor que não pode ter mudado, enquanto 10 min ainda fica bem dentro da janela de uma hora em que a cota é redefinida.

**Sem ponto de contato.** A regra segue a política padrão de notificações do Grafana e, sem SMTP configurado, a entrega não produz efeito e registra uma falha de envio ao disparar. A regra é útil sem isso: transforma um número que alguém precisa perceber em uma condição com estado, horário de início e histórico, e suas anotações `__dashboardUid__`/`__panelId__` mostram esse estado diretamente no quadro *Upstream pull budget left*. Adicionar `contactPoints:` e `policies:` ao mesmo arquivo é toda a mudança necessária para uma entrega real.

<a id="429f3d06-0054"></a>

<a id="yuruna-host-coordinates-for-source-fetch"></a>

### Coordenadas do hospedeiro Yuruna para obtenção de fontes

Coordenadas do hospedeiro Yuruna (status service). Incorporadas à seed por New-VM.ps1 da plataforma (Get-GuestReachableHostIp + statusService.port). O bloco de compilação runcmd abaixo carrega isso para obter as fontes do coletor e do interpretador da árvore de trabalho LOCAL do hospedeiro (http://IP:PORT/yuruna-repo/) -- o repositório do hospedeiro é a fonte de verdade, portanto uma reconstrução nunca espera pelo espelho GitHub privado->público. A mesma resolução de fetch-and-execute.sh. IP/PORT vazios (coordenadas indisponíveis, por exemplo, status service desabilitado) recorrem ao GitHub raw.

`--no-proxy` é necessário no caminho do hospedeiro: o IP do hospedeiro é privado, e o próprio squid desta VM está em `offline_mode`, portanto encaminhar essa obtenção por um proxy falharia. Carregar `host.env` é seguro aqui -- apenas IP/PORT incorporados pelo hospedeiro, nunca texto livre do operador (um valor malformado abortaria a fase runcmd).

Esta VM de cache consulta o diretório do grupo por loopback porque o agregador executa localmente. O resolvedor de endereços de hospedeiros rejeita endereços loopback retornados como endereço anunciado de um hospedeiro, não loopback como endereço de escuta do próprio diretório. O local do diretório é uma propriedade da topologia de serviços desta VM e não depende de sua concessão DHCP.

<a id="429f3d06-0055"></a>

<a id="yuruna-hosts-dashboard-inlined"></a>

### Painel Yuruna hosts incorporado

Painel Yuruna hosts. INCORPORADO (como squid.json), para que seja implantado pelo user-data local -- independentemente da compilação do binário pool-aggregator-service E de qualquer obtenção/espelho do GitHub -- e apareça desde a primeira inicialização ("No data" até que o coletor esteja ativo). Mantenha-o sincronizado com a cópia canônica verificável por lint em test/extension/pool-aggregator-service/grafana-pool-dashboard.json.

<a id="429f3d06-0056"></a>

<a id="yuruna-hosts-dashboard-panel-autofit"></a>

### Ajuste automático dos quadros do painel Yuruna hosts

As alturas dos quadros são fixadas no JSON do painel, e uma altura fixa por linha não acompanha grupos de tamanhos diferentes. `yuruna-fit-pool-dashboard.py` lê a contagem de hospedeiros informada pelo coletor no Prometheus por loopback, recalcula a altura de cada quadro pela geometria da grade do painel (um quadro de `h` unidades tem `38h - 8` px de altura, descontando a moldura da interface, a linha de cabeçalho da tabela e -- na linha do tempo -- o eixo x e a legenda), reposiciona em sequência os quadros abaixo dele e reescreve `/var/lib/grafana/dashboards/pool.json` atomicamente. Apenas os três quadros por hospedeiro mudam: os cartões de resumo no topo -- incluindo "Lab token" (ID de quadro 18), que incorpora a saúde do próprio coletor -- têm altura fixa de 4 unidades, e a sequência começa na borda inferior deles, lida do painel, em vez de presumida, pois [o banner da marca](#grafana-dashboard-brand-tile) fica acima deles e os move para baixo. As alturas são arredondadas PARA CIMA: um quadro alguns px alto demais mostra espaço vazio; um alguns px baixo demais mostra uma barra de rolagem, e apenas a barra é um defeito. Os valores `gridPos.h` incorporados acima são apenas o padrão anterior ao coletor. Um coletor inativo não informa hospedeiros, de forma indistinguível de um grupo vazio, portanto uma contagem zero deixa o arquivo intacto, em vez de reduzir cada quadro a seu cabeçalho. As contagens de linhas acompanham a janela PADRÃO de 24h do painel; um intervalo maior escolhido no seletor de tempo ainda pode mostrar um hospedeiro antigo e gerar rolagem.

<a id="429f3d06-0057"></a>

<a id="dashboard-brand-identity"></a>

### Identidade da marca nos painéis

`/etc/yuruna/brand.env` contém o nome e a versão usados na marca dos painéis: o repositório de framework a partir do qual esta VM foi construída (`Yuruna`, `Yurunadev`, ...) e o VERSION desse checkout. Incorporado à seed porque o convidado não consegue determinar isso sozinho -- recebe artefatos compilados, nunca o repositório do framework -- e fixado durante toda a vida da VM, como todos os outros fatos de construção dela. O hospedeiro resolve ambos por `Get-YurunaBrandIdentity` (test/modules/Test.FrameworkSource.psm1), que lê `repositories.frameworkUrl` quando a configuração o define e o remoto de origem do próprio checkout caso contrário -- a mesma ordem de resolução das páginas de status, para que uma página e um painel não possam nomear repositórios diferentes. Ambos os valores são reduzidos a caracteres seguros dentro do arquivo de ambiente com aspas simples; um nome sem caracteres restantes usa `Yuruna` como alternativa, e um VERSION ilegível informa vazio, em vez de adivinhar.

<a id="429f3d06-0058"></a>

<a id="grafana-dashboard-brand-tile"></a>

### Cartão de marca dos painéis do Grafana

`yuruna-brand-dashboards.py` insere essa identidade no topo de todos os painéis em `/var/lib/grafana/dashboards` -- os três incorporados aqui e o painel comunitário Zot -- como um quadro de texto transparente de largura completa: o nome do repositório, sua versão e, em um painel que não é nosso, a observação de que é conteúdo de origem sem modificações, lado a lado em uma linha. O nome e a versão são o par mostrado no cabeçalho das páginas de status. Ele existe porque um proxy dura mais que o processo de inicialização que o construiu, e um laboratório que executa ambos os repositórios teria, sem isso, dois proxies com painéis indistinguíveis.

O banner ocupa uma linha de altura e nenhuma largura adicional. O seletor de intervalo de tempo do Grafana fica na própria barra de ferramentas do aplicativo, que o JSON do painel não pode alcançar; portanto o banner é um quadro na grade: uma faixa de 24 unidades completas acima da primeira linha, com altura de duas unidades de grade, pois uma unidade tem 30px, e uma linha de texto não cabe depois de descontar o espaçamento interno do próprio quadro. As partes são separadas por espaços inseparáveis -- uma sequência de espaços comuns vira um único espaço no HTML renderizado. Tudo que já está no painel desce pela altura do banner, e nada muda de tamanho, portanto um layout que não podemos prever não precisa de um caso especial: o painel comunitário, cujo layout é obtido durante a construção, desce como o restante, quer comece com um cabeçalho de linha, quer com cartões estreitos demais para ceder espaço.

Idempotente por construção: um painel que já contém o banner tem apenas seu texto atualizado, nunca sua geometria, portanto o temporizador não pode empurrá-lo mais para baixo a cada execução. Os arquivos só são reescritos quando seu conteúdo muda e sempre por renomeação no mesmo diretório, para que o provedor de painéis nunca leia um arquivo parcial. [O ajuste automático dos quadros](#yuruna-hosts-dashboard-panel-autofit) reescreve o mesmo arquivo, e os dois concordam sem coordenação: o ajuste posiciona os quadros a partir da borda inferior do que estiver acima dos quadros por hospedeiro, isto é, o banner mais os cartões de resumo quando o banner existe, e apenas os cartões quando não existe.

O serviço de identificação lê o ambiente fornecido pela inicialização e
reescreve apenas o diretório de dashboards provisionados. Esse diretório é
seu único caminho gravável; `PrivateNetwork` isola uma tarefa que não precisa
de comunicação pela rede.

<a id="429f3d06-0059"></a>

<a id="squid-dashboard-inlined"></a>

### Painel Squid incorporado

Painel mínimo do squid: os quadros mostram "No data" sem erro se os nomes de métricas mudarem entre versões do exportador.

<a id="429f3d06-005a"></a>

<a id="cache-health-dashboard"></a>

### Painel de saúde do cache

Painel Grafana (`uid: yuruna-cache-health`, "Yuruna cache health (registry path)") baseado nas métricas gauge publicadas pelo [exportador de consulta de manifesto do zot](#zot-manifest-canary-exporter). Incorporado à seed pelo mesmo motivo que os outros painéis daqui: é implantado pelo user-data local e aparece desde a primeira inicialização, com "No data" até a primeira execução do exportador.

Os limiares dos quadros expressam o objetivo do exportador. A latência de manifesto fica vermelha em 30s, pois é quando dockerd abandona um pull cujos cabeçalhos de resposta não chegaram -- um cache pode indicar saúde em todas as verificações de disponibilidade e ainda ultrapassar essa linha. A estatística complementar "fast enough for a real pull?" lê `yuruna_zot_manifest_ok_under_client_patience`: a estatística de latência mede o travamento; esta informa se o cliente suporta o que foi medido.

<a id="429f3d06-005b"></a>

<a id="zot-systemd-unit"></a>

### Unidade systemd do zot

Executa zot como usuário de serviço sem privilégios, com ProtectSystem=strict + ReadWritePaths restringindo gravações a /var/lib/zot (armazenamento de blobs) e /var/log/zot. Não há pacote apt para zot em Resolute, portanto instalar um binário e escrever uma unidade systemd manualmente é o caminho mais simples. O binário é instalado em /usr/local/bin/zot por runcmd.

<a id="429f3d06-005c"></a>

<a id="networkstorage-pool-replication-config"></a>

### Configuração de replicação do grupo NetworkStorage

Replicação de serviços de grupo (ypool-nas) de networkStorage: configuração + credencial SMB + rsync dos dados de observabilidade para o NAS controlado por temporizador. Todos os valores são incorporados por New-VM.ps1 a partir da configuração de grupo networkStorage do hospedeiro e do cofre (vazio / REPLICATE=false quando desabilitado).

A tarefa de replicação copia os dados de observabilidade do Loki, Prometheus e Grafana para `<mount>/hosts/<hostId>/services/caching-proxy-service/`, ao lado do diretório `test-cycles/` do hospedeiro. Os caches reconstruíveis de Squid/zot e o cursor de acompanhamento de logs do Alloy são excluídos. A tarefa faz o melhor esforço e publica o status de montagem/cópia em `/ypool-nas-status` para diagnóstico sem SSH. As raízes antigas `<hostId>/services/` não são lidas automaticamente; a recuperação a partir delas é uma operação manual descrita em [armazenamento do grupo](../pool-storage.md).

`yuruna-config-fetch.sh pool` é responsável pela montagem e pela credencial rotacionada obtida por mTLS. A replicação inicia uma atualização de melhor esforço antes de verificar `mountpoint -q`; `findmnt --target` pode aceitar incorretamente o sistema de arquivos raiz que contém o caminho quando o próprio NAS não está montado.

<a id="429f3d06-005d"></a>

<a id="nas-cifs-credentials"></a>

### Credenciais cifs do NAS

Credenciais cifs (0600 root). A conta networkUser -- a única conta do NAS, restrita pelo operador por ACL apenas ao armazenamento (acesso de gravação ao compartilhamento, nada mais).
<a id="429f3d06-005e"></a>

<a id="config-service-client-materials-and-nas-credential-fetch"></a>

### Materiais do cliente do serviço de configuração e obtenção de credenciais do NAS

As informações de conexão e a senha do NAS são obtidas do serviço de
configuração do hospedeiro na inicialização **e a cada hora**, para que uma senha rotacionada do NAS alcance esta
VM em execução sem reconstruí-la. A cadeia do certificado do cliente termina na CA de Config
*deste* hospedeiro, portanto o serviço atende apenas às VMs deste hospedeiro. Os PEMs
são incorporados em base64 (`encoding: b64`) para resistir ao YAML e colocados entre aspas simples, para que
um valor vazio -- um certificado de cliente que nunca foi emitido -- seja interpretado como `''`,
e a condição de runcmd ignore a obtenção, em vez de gerar erro.

`yuruna-config-fetch.sh <stash|pool>` é o único responsável pela
montagem e pelo arquivo de credencial correspondentes. Faz o melhor esforço por projeto e
nunca gera uma falha fatal: todos os caminhos de saída gravam um rastro em
`/var/www/html/config-fetch-<name>-status` (o Apache serve
`/var/www/html`), tornando "configurado, mas não monta" diagnosticável
sem SSH, como `ypool-nas-status`.

Comportamento por nome: **stash** monta somente para leitura para a varredura do agregador;
**pool** monta para leitura e gravação, para que `ypool-nas-replicate.sh` possa executar rsync nele,
no caminho exato de credenciais que esse script já lê.

Quatro armadilhas tratadas por este script:

- **Disputa na inicialização.** Na inicialização do convidado, o serviço de configuração do hospedeiro pode ainda não
  estar aceitando conexões, pois a inicialização do hospedeiro concorre com a da VM. Cinco tentativas curtas
  evitam esperar uma hora pela próxima execução do temporizador; a chamada é idempotente,
  portanto a sequência de tentativas é inofensiva no caminho horário, onde tem sucesso na
  primeira tentativa.
- **IP incorporado do hospedeiro desatualizado.** Quando a obtenção não retorna nada, uma consulta a
  `http://<host>:<statusPort>/livecheck` distingue "hospedeiro acessível, mas
  serviço de configuração inativo" de "hospedeiro inacessível no IP incorporado"
  (causado por uma mudança DHCP do hospedeiro), para que o rastro indique o reparo
  real.
- **Nome de máquina do NAS não resolvível.** O nome do servidor do compartilhamento é resolvido no
  *hospedeiro*, onde pode ser um alias que apenas ele conhece --
  `New-LocalLabStorage` aponta `ypool-nas` para o endereço loopback
  do hospedeiro, que não resolve para nada no convidado e faz a montagem falhar
  com `cifs_mount -111`. Nessa configuração, o hospedeiro *é* o
  servidor de armazenamento, portanto, quando o convidado não consegue resolver o nome, a montagem
  acrescenta `ip=<host>` usando o endereço no qual o serviço de configuração acabou de responder
  -- comprovadamente válido pela própria construção.
- **Sem `iocharset=utf8`.** `nls_utf8` está ausente no kernel mínimo da
  imagem de nuvem, e a montagem falha com `error(79)`. Os nomes em disco são
  ASCII, portanto a opção é omitida.

`printf %s` grava a senha literalmente, sem reinterpretá-la no shell, para que
os caracteres especiais do cofre cheguem intactos ao arquivo de credenciais cifs.
A remontagem só ocorre quando a versão informada muda ou o ponto de
montagem não está montado no momento.

Observação sobre carregamento: `/etc/yuruna/host.env` contém apenas
`YURUNA_STATUS_SERVICE_IP`/`PORT` incorporados pelo hospedeiro (sem texto livre do operador), portanto carregá-lo
é seguro. Arquivos de ambiente fornecidos pelo operador devem ter seus valores extraídos com sed.

O nome de máquina TLS estável (SAN) é mapeado para o IP atual do hospedeiro por
`curl --connect-to`, para que uma mudança DHCP do hospedeiro nunca invalide o certificado
folha do servidor.

<a id="429f3d06-005f"></a>

<a id="internal-authentication-key"></a>

### Chave de autenticação interna

A chave de autenticação interna que protege o controle remoto, a superfície de envio POST /ingest do agregador e a obtenção de credenciais entre hospedeiros. Incorporada a `/etc/yuruna/internal-auth.key` (a substituição `INTERNAL_AUTH_KEY_PLACEHOLDER`) por New-VM a partir do cofre do hospedeiro que constrói a VM -- usuário lógico `internal-auth-key`, com as entradas antigas `lab-auth-token` e legadas `pool-auth-token` do cofre aceitas como alternativas, para que um hospedeiro inscrito sob qualquer um desses nomes lógicos continue funcionando; os daemons que leem o arquivo recorrem ao caminho antigo `/etc/yuruna/lab-auth.token` quando o novo está ausente, para que uma VM que ainda contém o caminho antigo continue funcionando até ser reconstruída. Quando o cofre não contém nenhum dos três, New-VM emite uma chave de autenticação interna aleatória e a armazena antes de incorporá-la, para que um proxy nunca seja construído com chave vazia; um proxy de chave vazia (não emite provas de controle, /ingest responde 503, o cartão Lab token do painel mostra "off") é um estado de falha diagnosticável, não um estado inicial normal. O agregador remove espaços em branco nas extremidades. Modo 0640 root:proxy: legível pelo agregador executado como proxy, não legível por todas as pessoas.

**`host/macos.utm/guest.caching-proxy-service/New-VM.ps1`, `host/ubuntu.kvm/guest.caching-proxy-service/New-VM.ps1`, `host/windows.hyper-v/guest.caching-proxy-service/New-VM.ps1`.**

Se não houver um token armazenado, gere um e armazene-o imediatamente, para que
o proxy nunca seja criado com um token vazio. Um token vazio impediria a emissão
de provas de controle, manteria /ingest em 503, ocultaria o Lab token no painel
e faria o controle remoto de cada novo hospedeiro receber 403. O hospedeiro que
cria o proxy torna-se o primeiro membro inscrito no laboratório; os demais
recebem o mesmo valor pelo Lab token do painel
(pwsh test/lab/Set-LabToken.ps1).

<a id="429f3d06-0060"></a>

<a id="runcmd-errexit-leaks-across-items"></a>

### errexit de runcmd vaza entre itens

O cloud-init concatena todos os itens `runcmd` em UM script `/bin/sh`. Portanto, um `set -e` em qualquer item permanece ativo para todos os seguintes, e uma única saída diferente de zero aborta toda a fase restante -- nesta seed, a geração da CA, a inicialização de ssl_db, o pré-aquecimento, os exportadores, a pilha de monitoramento e o aviso de prontidão então nunca executam, silenciosamente. A falha é invisível na saída de `systemctl` porque `write_files` ainda executou; apenas `cloud-init status --long` a mostra.

Duas convenções mantêm isso contido; ambas são essenciais, não estilísticas:

- **Envolva qualquer bloco `set -e` em um subshell** `( ... ) || echo "== YURUNA: ... FAILED =="`. Os parênteses mantêm errexit local e dão à etapa sua própria linha de falha diagnosticável. Um subshell também limita o escopo de um `exit 0` isolado, que, no nível superior, encerraria todo o script runcmd, em vez de apenas aquela etapa.
- **Acrescente `|| true` a comandos que podem legitimamente falhar**, especialmente `systemctl start squid`. Sem isso, uma inicialização malsucedida aborta o restante da fase e deixa uma falha de inicialização sem diagnóstico; com isso, a etapa de espera pela porta abaixo informa e diagnostica a falha.

<a id="429f3d06-0061"></a>

<a id="stop-squid-before-ca-bootstrap"></a>

### Parar squid antes da inicialização da CA

Pare o squid iniciado pelo postinst do apt: ele termina com FATAL (yuruna.conf referencia ca.pem antes de sua geração) ou executa com configuração parcial/padrão. Não execute `squid -z` aqui -- ele também interpreta yuruna.conf e termina com FATAL pelo certificado ausente, deixando apenas uma entrada de log alarmante.

<a id="429f3d06-0062"></a>

<a id="ssl-bump-capable-squid-binary"></a>

### Binário squid com suporte a SSL-bump

O Ubuntu 26.04 fornece squid como uma *alternativa* Debian. O pacote `squid` instala
`/usr/sbin/squid-gnutls` (uma compilação GnuTLS sem ssl-bump, sem `at_step` e sem
`security_file_certgen`); `squid-openssl` instala `/usr/sbin/squid-openssl`; e
`/usr/sbin/squid` é um link simbólico por `/etc/alternatives/squid`.

O apt inclui `squid` automaticamente junto com o `squid-openssl` solicitado por esta
seed, e o dpkg configura `squid` **primeiro** -- portanto seu postinst inicia
`squid.service` enquanto o binário GnuTLS ainda é a alternativa selecionada. Essa
inicialização termina com FATAL na configuração ssl-bump, e a unidade que falhou nunca é iniciada novamente. O
FATAL indica `at_step`, que parece uma mudança de sintaxe do squid e faz o primeiro
diagnóstico procurar uma mudança inexistente; a falha real é a seleção do binário.

Portanto, a seed fixa a alternativa explicitamente, em vez de confiar na ordem de instalação,
verifica se o binário selecionado informa `--with-openssl` e instala
`squid-openssl` como alternativa se não informar. Depois executa
`systemctl reset-failed squid`: a inicialização malsucedida do postinst deixa a unidade
em falha, e, sem a redefinição, o limitador de reinicializações do systemd recusa a inicialização real
no fim de `runcmd`.

<a id="429f3d06-0063"></a>

<a id="ssl-bump-ca-bootstrap"></a>

### Inicialização da CA de SSL-bump

Ambas as etapas são idempotentes, para que novas execuções não rotacionem a CA (a rotação deixaria sem referência os convidados que já confiavam nela). A chave privada permanece proxy:proxy 700; o certificado público é servido pelo Apache. CN inclui um timestamp para distinguir reconstruções deliberadas.

**Por que `-addext`, não `-extensions v3_ca`.** `-extensions v3_ca` produz silenciosamente um certificado que não é de CA quando `/etc/ssl/openssl.cnf` da compilação instalada de openssl 3.x não contém uma seção `[ v3_ca ]`. O resultado carrega, mas squid o rejeita -- "No valid signing certificate configured for HTTP_port [::]:3129" -- e nunca abre a porta. O formato `-addext` é autossuficiente. `keyCertSign` é necessário para a emissão de certificados folha por nome de máquina no ssl-bump.

**Por que CommonName é truncado rigidamente em 64 caracteres.** X.509 limita CommonName a 64 caracteres (`ub-common-name`), e o openssl rejeita a solicitação INTEIRA acima disso: "ASN1_mbstring_ncopy: string too long ... maxsize=64". A falha é silenciosa de ponta a ponta -- nenhum `ca.pem` é gravado, e squid nunca pode abrir :3129. `$(hostname)` sozinho já se aproxima do limite, portanto qualquer prefixo literal o ultrapassa; o script trunca com `printf '%.64s'`, em vez de confiar que os componentes continuem curtos.

<a id="429f3d06-0064"></a>

<a id="pool-aggregator-service-tls-leaf"></a>

### Certificado folha TLS do pool-aggregator service

Certificado folha TLS do pool-aggregator-service: emitir um certificado de servidor para a superfície :9400 do agregador (métricas + ingestão), assinado pela CA do squid acima (reutilizada -- nenhuma nova CA), para que o trecho da LAN seja criptografado e autenticado. Idempotente (sem rotação). SAN contém o IP LAN do proxy (os executores se conectam por IP) + 127.0.0.1 (Prometheus por loopback). A chave permanece proxy:proxy 600 (o agregador executa como proxy). Melhor esforço: uma falha de emissão não deixa certificado folha, e o agregador recorre a HTTP sem criptografia.

Quando existe um certificado TLS, o agregador atende TLS e HTTP simples na
mesma porta `:9400`, mantendo os links do navegador utilizáveis. A coleta local
do Prometheus usa `insecure_skip_verify`: a autenticação do par não acrescenta
uma fronteira em `127.0.0.1`, e a coleta funciona tanto com localhost quanto
somente com endereços IP no SAN do certificado.

<a id="429f3d06-0065"></a>

<a id="resolve-pool-dashboard-aggregator-url"></a>

### Resolver a URL do agregador no painel de grupos

Resolva a URL base do agregador do painel Yuruna hosts. Os links de dados "open cycle results" e "share cycle results" da linha do tempo apontam para os redirecionamentos /go/cycle e /go/cycle-share deste proxy, que resolvem no servidor o IP ATUAL de cada hospedeiro, para que os links sobrevivam a uma mudança de IP do hospedeiro. O IP LAN do próprio proxy só é conhecido na inicialização (DHCP), portanto substitua-o aqui. Idempotente: uma nova execução não encontra marcador. O provedor de painéis sincroniza novamente o arquivo editado, portanto isso pode ocorrer antes ou depois de grafana-server iniciar.

**Sempre http sem criptografia, mesmo depois que o agregador tem seu certificado folha TLS.** Os links do painel só alcançam os redirecionamentos `/go/*` do agregador, que levam o navegador do operador às páginas de status dos hospedeiros por HTTP sem criptografia. Um trecho https aqui colocaria uma tela intermediária de CA do proxy (os navegadores dos operadores não confiam na CA do proxy) antes de cada clique em hospedeiro, sem proteger nada que o próximo trecho já não transmita em texto simples. O agregador responde a ambos os protocolos em :9400, portanto os clientes que usam tokens mantêm seu TLS.

<a id="429f3d06-0066"></a>

<a id="squid-ssl_db-initialization"></a>

### Inicialização de ssl_db do Squid

`-c` de security_file_certgen cria um banco novo e gera erro se ele já existir, portanto a verificação de existência protege novas execuções. O banco contém certificados folha emitidos por nome de máquina SNI -- 4 MB é uma capacidade generosa (cada entrada tem ~1 KB).

O `install -d` para /var/lib/squid NÃO é redundante: no Ubuntu, o postinst de squid-openssl não garante esse diretório, e Create() de security_file_certgen cria apenas o diretório folha `ssl_db/`, não o pai. Sem isso, o auxiliar termina com FATAL "Cannot create /var/lib/squid/ssl_db", os processos filhos sslcrtd falham e reiniciam em cada criação, squid encerra com "The sslcrtd_program helpers are crashing too rapidly, need help!", e squid-parent bloqueia a reinicialização por 3600s. Executar como `proxy` evita um chown posterior e confirma o acesso de gravação.

<a id="429f3d06-0067"></a>

<a id="publish-squid-ca-cert"></a>

### Publicar o certificado da CA do squid

Publique o certificado público da CA em http://<cache>/yuruna-squid-ca.crt, para que os convidados possam obtê-lo e confiar nele durante a instalação. Apenas o certificado público é copiado -- ca.key permanece em /etc/squid/ssl_cert/. O modo 644 é deliberado: a acessibilidade RFC1918 é imposta na camada de rede (switch/bridge/NAT do hospedeiro), para que a distribuição de confiança funcione sem um arquivo complementar adicional `Require ip` no estilo cachemgr.

<a id="429f3d06-0068"></a>

<a id="publish-pool-ca-cert"></a>

### Publicar o certificado da CA do grupo

Publique a MESMA CA com um nome específico de grupo, para que um executor possa fixar o certificado folha TLS do pool-aggregator-service (assinado por esta CA) sem se acoplar ao nome de arquivo da CA do squid. Apenas o certificado público; a chave nunca sai de /etc/squid/ssl_cert.

<a id="429f3d06-0069"></a>

<a id="pre-warm-the-cache"></a>

### Pré-aquecer o cache

security.ubuntu.com limita requisições de linux-firmware (~330 MB) a ponto de toda instalação fria de convidado receber 429 nesse pacote. Obtê-lo antecipadamente pelo proxy local o coloca no squid antes de qualquer convidado solicitar, para que a primeira instalação seja servida pelo cache. Obtenha também o metapacote HWE, para que os .debs de kernel, modules-extra, headers e microcode sejam armazenados junto.

Aguarde até 60s pelo listener do squid. O postinst do apt normalmente já o deixa ativo, mas a inicialização pode ser lenta na primeira execução.

Se a porta nunca ficar disponível, a inicialização copia o journal do Squid
para `cloud-init-output.log`. A busca por erros passa a mostrar causas como
`EADDRINUSE` por declarações duplicadas de `http_port`, em vez de apenas
relatar uma conexão TCP malsucedida.

<a id="429f3d06-006a"></a>

<a id="route-vm-apt-through-local-squid"></a>

### Encaminhar o apt da VM pelo squid local

Apenas AGORA encaminhe o próprio apt desta VM pelo squid local -- o squid está comprovadamente atendendo, portanto o laço de proxy para si mesmo é seguro. Gravar esse arquivo complementar durante write_files (antes de `packages:` executar) trava o apt: ele obtém o próprio squid por 127.0.0.1:3128, que ainda não está atendendo, e a instalação termina com Exit 100.

<a id="429f3d06-006b"></a>

<a id="prewarm-download-loop"></a>

### Laço de downloads de pré-aquecimento

Cada chamada: primeiro --reinstall --download-only (força nova obtenção de pacotes já instalados, como linux-firmware); recorra a download-only simples para pacotes ainda não instalados (linux-generic-hwe-24.04 e semelhantes). `|| true` na alternativa, para que uma ausência não aborte o laço.

<a id="429f3d06-006c"></a>

<a id="reclaim-apt-cache-after-prewarm"></a>

### Recuperar espaço do cache apt após o pré-aquecimento

O Squid agora mantém os .debs grandes em cache em /var/spool/squid. Limpe /var/cache/apt (o armazenamento do squid é separado) para recuperar ~1 GB.

<a id="429f3d06-006d"></a>

<a id="remove-prewarm-apt-proxy-dropin"></a>

### Remover o arquivo complementar de proxy apt do pré-aquecimento

Remova o arquivo complementar de proxy apt, para que futuros apt nesta VM não passem pelo próprio squid. Os convidados ainda alcançam o squid em 3128 pela rede.

<a id="429f3d06-006e"></a>

<a id="flip-squid-into-offline-mode"></a>

### Mudar o squid para o modo offline

Mude o squid para offline_mode agora que o pré-aquecimento terminou. Com offline_mode habilitado, o squid serve objetos em cache sem contatar a origem -- um acerto retorna conteúdo armazenado; uma ausência ainda consulta a origem. Isso permite o fluxo "totalmente desconectado se tudo estiver em cache": os convidados podem instalar pacotes apt por este proxy sem internet no hospedeiro.

Faça a mudança DEPOIS do pré-aquecimento -- com o cache aquecido, ela não tem custo e economiza uma requisição condicional por objeto. Incluído como arquivo conf.d separado, para que um operador possa atualizar pela origem removendo apenas esse arquivo e executando `squid -k reconfigure`.

<a id="429f3d06-006f"></a>

<a id="offline_mode-echo-yaml-mapping-trap"></a>

### Armadilha de mapeamento YAML no echo de offline_mode

Use aspas simples no echo, para que YAML não interprete `cache:` como uma chave de mapeamento. shellify() do cloud-init falha com um dict em runcmd e aborta TODA a fase runcmd -- isso já aconteceu, deixando uma VM com a página padrão do Apache, sem cachemgr, sem offline_mode e sem monitoramento, embora write_files e packages tenham executado.

<a id="429f3d06-0070"></a>

<a id="build-squid-exporter-and-caching-proxy-parser-service"></a>

### Compilar squid-exporter e caching-proxy-parser-service

Compile e instale squid-exporter + caching-proxy-parser-service. Nenhum deles tem pacote apt; `go install` (squid-exporter) e `go build` sobre as fontes obtidas (caching-proxy-parser-service) mantêm esse caminho entre arquiteturas funcionando -- amd64 em Hyper-V/KVM, arm64 em UTM, sem adivinhar URLs. squid-exporter é fixado em v1.13.0, a versão de mudança: removeu o suporte à URI legada `cache_mgr://` e passou ao caminho HTTP `/squid-internal-mgr/` do Squid 7. O Ubuntu 26.04 (Resolute) contém Squid 7.x, que rejeita a URI antiga; versões fixadas anteriores (v1.10.5 e inferiores) instalam e coletam sem erro (squid_up ainda é publicado), mas informam squid_up=0 e métricas de contadores zeradas porque o caminho de requisição ao squid é inacessível -- todos os quadros do Grafana que consultam `squid_client_http_*_total` ficam vazios. Veja https://github.com/boynux/squid-exporter/releases/tag/v1.13.0 para a troca de cache_mgr -> squid-internal-mgr. Ambas as execuções ocorrem DEPOIS da limpeza do proxy de pré-aquecimento, para que a obtenção de módulos Go (HTTPS para proxy.golang.org + GitHub) não passe pelo squid -- squid HTTP não armazena HTTPS em cache sem SSL-bump.

A mesma fase de compilação prepara o agregador do grupo e o daemon de gerenciamento do caching-proxy com suas árvores completas de dependências Go. `extension-sdk` é um módulo separado e deve permanecer como irmão do diretório de compilação de cada daemon, conforme sua diretiva relativa `replace`. A árvore preparada também inclui pacotes transitivos, como a dependência i18n de `labgate`. Todos os diretórios de destino devem existir antes que `wget -O` grave os arquivos de fonte.

<a id="429f3d06-0071"></a>

<a id="purge-go-toolchain-after-builds"></a>

### Remover a cadeia de ferramentas Go após as compilações

Recupere ~400 MB: a cadeia de ferramentas Go só é necessária para as compilações acima, e tanto squid-exporter quanto caching-proxy-parser-service são binários estáticos.

<a id="429f3d06-0072"></a>

<a id="start-the-monitoring-stack"></a>

### Iniciar a pilha de monitoramento

daemon-reload carrega a unidade squid-exporter e o arquivo complementar grafana-server gravados por write_files. O Grafana é reiniciado (não apenas habilitado), para que as variáveis de ambiente de Viewer anônimo tenham efeito mesmo se o postinst do pacote deb já o iniciou.

<a id="429f3d06-0073"></a>

<a id="start-the-caching-proxy-management-service"></a>

### Iniciar o serviço de gerenciamento do caching proxy

`caching-proxy-service` é o plano de gerenciamento desta VM: uma superfície de leitura sobre
squid, zot e os dois controles do operador, além do beacon que coloca o proxy na
linha **Extension hosts** do grupo, como qualquer outro serviço. Habilitado com
`|| true`, como os dois serviços Go ao lado dele -- um plano de gerenciamento que
não inicia não deve fazer a VM falhar na inicialização, pois não transporta seu tráfego.
O proxy continua atendendo em qualquer caso; o que se perde é a capacidade de consultar esta VM
sobre si mesma, e os controles offline / no-upstream voltam a exigir SSH.

O daemon lê seus sinalizadores de um arquivo de ambiente, para que um operador possa redirecioná-lo sem editar uma unidade que uma atualização substituirá. Os valores da seed são extraídos com `sed`, em vez de carregar o arquivo; aspas de shell malformadas não devem abortar a fase de inicialização. O agregador fica nesta VM, mas os beacons de presença usam seu endereço LAN, preferencialmente HTTPS. O agregador deriva o endereço anunciado do serviço da origem da requisição e rejeita loopback, portanto um beacon enviado por `127.0.0.1` nunca anunciaria esta extensão. O beacon pode recorrer a HTTP quando nenhum certificado folha TLS está disponível.

<a id="429f3d06-0074"></a>

<a id="enable-squid-metadata-exporter-timer"></a>

### Habilitar o temporizador do exportador de metadados do squid

Exportador de metadados Squid: o temporizador controla um oneshot que grava /var/www/html/squid-meta a cada 30s. Iniciado DEPOIS de apache2 (já ativo na fase de pacotes), para que a primeira coleta não receba 404.

<a id="429f3d06-0075"></a>

<a id="prime-squid-metadata-exporter-once"></a>

### Executar uma vez o exportador de metadados do squid

Execute o script uma vez imediatamente, para que /var/www/html/squid-meta exista antes da primeira coleta do Prometheus, evitando um período de 15 segundos de "No data" no painel durante a inicialização.

<a id="429f3d06-0076"></a>

<a id="enable-zot-metadata-exporter-timer"></a>

### Habilitar o temporizador do exportador de metadados do zot

Ativado aqui, executado inicialmente após a instalação do zot abaixo: uma primeira execução contra um registro que ainda não existe publicaria uma leitura DOWN como primeiro dado do serviço.

<a id="429f3d06-0077"></a>

<a id="enable-caching-proxy-parser-service"></a>

### Habilitar o caching-proxy-parser service

caching-proxy-parser-service falha de forma segura (o binário pode estar ausente se a compilação acima falhou); `|| true` mantém o restante de runcmd em execução, para que loki+alloy+grafana ainda iniciem.

<a id="429f3d06-0078"></a>

<a id="enable-pool-aggregator-service"></a>

### Habilitar o pool-aggregator service

pool-aggregator-service: visualização de grupos somente para leitura. Falha tolerada, como a do interpretador -- o binário pode estar ausente se a compilação acima falhou; prometheus já tem a tarefa de coleta pool-aggregator-service (ela apenas informa 'down' até que o daemon esteja ativo).

O `ExecStart` da unidade contém `-auth-token-file /etc/yuruna/internal-auth.key -host-ttl 24h -lab-token-rotate 60s`. O arquivo de token contém a chave de autenticação interna (veja "Chave de autenticação interna" acima); o daemon recorre a `/etc/yuruna/lab-auth.token` quando esse caminho está ausente. `-lab-token-rotate` controla a troca de token do laboratório: o agregador emite um token de conexão de laboratório de 6 caracteres (a-z0-9 em minúsculas), o rotaciona nesse intervalo, o mostra no cartão "Lab token" do painel (pela métrica informativa `yuruna_pool_lab_token`) e serve o endpoint aberto `POST /api/v1/lab-token` em :9400 (corpo `{"labToken":"<code>"}` -> 200 com a chave de autenticação interna; 400 malformado, 403 código desconhecido/expirado, 429 limitação por IP, 503 troca desabilitada). Um código exibido permanece resgatável por cerca de três rotações; `0` desabilita o cartão e a troca. As trocas são contadas em `yuruna_pool_lab_token_exchanges_total`, e todas as tentativas são auditadas (log do agregador + Loki, rótulo src="lab-token"). Um hospedeiro se inscreve com `pwsh test/lab/Set-LabToken.ps1 -LabToken <code>`.

O tempo durante o qual um hospedeiro permanece nessa visualização após seu último contato é `-host-ttl` no `ExecStart` da unidade (padrão `24h`): altere-o e execute `systemctl daemon-reload && systemctl restart pool-aggregator-service` -- sem reconstrução. O `daemon-reload` é essencial; sem ele, o systemd reinicia usando sua cópia em cache da unidade, e o valor antigo permanece em vigor silenciosamente (a mesma armadilha documentada em [caching.md](../caching.md) para as unidades squid). Um valor não positivo recorre a 24h. Um binário anterior ao sinalizador termina imediatamente ao recebê-lo, e `Restart=on-failure` transforma isso em reinicializações contínuas por falha; portanto reprovisione primeiro esse proxy.

Reiniciar não é gratuito e, para esse ajuste, trabalha parcialmente contra você. Na inicialização, o agregador recria registros provisórios de hospedeiros pelo fluxo de presença do Loki durante `-rehydrate-window` (padrão `168h`, **não** o TTL do hospedeiro) e marca cada registro como visto pela última vez *agora*; portanto uma máquina ausente por dias reaparece como linha `Reachable=false` e sobrevive a um TTL inteiro de hospedeiro com consultas malsucedidas: a reinicialização feita para reduzir o TTL recria as linhas que você tentava remover. Uma reinicialização também redefine a trava de histerese de degradação/alerta. Portanto, `-host-ttl` define o intervalo em estado estável; para remover deterministicamente um hospedeiro específico desativado, use `Remove-PoolHost.ps1` / `POST /api/v1/forget-host`, que também limpa seus contadores acumulados.

Essas 24h não são o intervalo de tempo padrão do painel acima nem a janela de último contato que `Remove-PoolHost.ps1` exige antes de esquecer um registro. Três valores diferentes de 24 horas, três significados diferentes.

<a id="429f3d06-0079"></a>

<a id="pool-configuration-store-seeding"></a>

### Inicialização do armazenamento de configuração dos grupos

O armazenamento de configuração dos grupos Yuruna é um repositório Git bare que os
hospedeiros dos grupos clonam e atualizam somente para leitura por HTTP, pela
configuração Apache `yuruna-pool-configuration`. A CLI de administração envia para cá a
composição dos grupos e `configuredState`. Inicialize `main` com um `pools.yml`
vazio usando `schemaVersion: 4`: um esquema antigo permite clonar o repositório,
mas falha na validação da primeira gravação administrativa. A inicialização
ignora um repositório existente, e falhas na configuração do Git são toleradas
para permitir que o provisionamento dos demais serviços continue.

Defina `receive.updateServerInfo=true` para atualizar os índices dumb-HTTP após
cada push. Os modos definidos pela montagem CIFS impedem tornar executável um
hook `post-update`, por isso é necessário usar a configuração interna do Git.
Defina `core.fileMode=false` porque o CIFS deriva os modos dos arquivos das
opções de montagem. Essas opções também atribuem a propriedade; evite `chown`,
que pode impor uma ACL exclusiva ao proprietário e bloquear a VM de controle
do grupo que grava no mesmo compartilhamento.

Crie o repositório apenas enquanto o NAS do grupo estiver montado. Inicializá-lo sob um ponto de montagem não montado colocaria a configuração no disco da VM; uma montagem posterior ocultaria esse repositório e deixaria inacessíveis as atualizações feitas nesse intervalo.

<a id="429f3d06-007a"></a>

<a id="wait-for-grafana-server-to-bind"></a>

### Aguardar grafana-server abrir a porta

Aguarde grafana-server abrir :3000 e exiba o journal se isso não ocorrer. Em uma primeira inicialização lenta, grafana pode levar ~15s para ficar ativo após `restart` retornar. Sem essa verificação, uma inicialização malsucedida só aparece quando um operador tenta abrir o painel e recebe "connection refused" -- quando os logs de cloud-init já podem ter sido rotacionados. Reproduz a proteção de diagnóstico de squid:3128, para que ambos os modos de falha apareçam da mesma maneira em /var/log/cloud-init-output.log.

<a id="429f3d06-007b"></a>

<a id="enable-yuruna-hosts-dashboard-panel-autofit"></a>

### Habilitar o ajuste automático dos quadros do painel yuruna hosts

Habilite o temporizador que mantém os quadros por hospedeiro do painel Yuruna hosts dimensionados para o grupo (veja "Ajuste automático dos quadros do painel Yuruna hosts" acima). Ele executa pela primeira vez 3min após a inicialização -- até então, o coletor já consultou o grupo pelo menos uma vez -- e a cada 5min depois disso, para que um hospedeiro que entra ou sai apareça em até uma execução periódica mais os 30s de recarregamento do provedor de painéis. `--now` também o executa uma vez aqui: duas consultas por loopback, sem efeito em um grupo que ainda não se cadastrou.

<a id="429f3d06-007c"></a>

<a id="install-community-zot-dashboard"></a>

### Instalar o painel comunitário Zot

Instale o painel comunitário Zot (ID Grafana 20501) ao lado do painel caching-proxy-service feito para o Yuruna. O reescritor de write_files (veja "Reescritor de painéis do Grafana" acima) o fixa em yuruna-prometheus com um uid estável e um título amigável, para que novas execuções sejam idempotentes. O provisionador de painéis em /etc/grafana/provisioning/dashboards/yuruna.yaml carrega o arquivo na próxima execução de 30s. O ramo `else` mantém os ciclos: uma indisponibilidade transitória de grafana.com resulta em "painel adicional ausente", em vez de fazer toda a fase runcmd falhar.

<a id="429f3d06-007d"></a>

<a id="enable-grafana-dashboard-brand-tile"></a>

### Habilitar o cartão de marca dos painéis do grafana

Habilite o temporizador que mantém [o cartão de marca](#grafana-dashboard-brand-tile) em todos os painéis e depois marque-os uma vez aqui. É a última das etapas de painéis, para que o painel comunitário Zot já esteja em disco e receba a marca na mesma passagem dos três incorporados. O `start` explícito é o que os marca agora -- habilitar o temporizador apenas programa a próxima execução, e os primeiros minutos de vida de um proxy com painéis anônimos são justamente o período em que um operador os acompanha. O temporizador (2min após a inicialização, a cada 15min depois disso) é a proteção para um painel que chega mais tarde; não reescreve nada quando nada precisa mudar. O `|| echo` reduz uma marcação malsucedida a painéis sem marca, em vez de fazer a fase runcmd falhar, e usa um escalar de bloco porque a mensagem contém dois-pontos e espaço, interpretados como mapeamento por um escalar YAML simples.

<a id="429f3d06-007e"></a>

<a id="enable-nas-replication-timer-conditionally"></a>

### Habilitar condicionalmente o temporizador de replicação no NAS

Replicação de serviços de grupo (ypool-nas) de networkStorage: habilite o temporizador apenas quando a seed foi construída com replicação configurada (REPLICATE=true). Leia esse valor com grep de linha exata, NÃO carregando o arquivo -- um valor malformado abortaria toda a fase runcmd, pois o erro de interpretação de `.` ocorre antes de qualquer `|| true`. O escalar de bloco evita a armadilha YAML de dois-pontos e espaço; grep evita o aborto ao carregar.

<a id="429f3d06-007f"></a>

<a id="verify-alloy-supplementary-groups"></a>

### Verificar os grupos suplementares do alloy

Verifique se alloy recebeu AMBOS os grupos suplementares. O arquivo complementar grava "SupplementaryGroups=proxy zot"; a ausência de qualquer um mantém vazio o quadro Recent-100 correspondente. A verificação deve confirmar cada grupo explicitamente: procurar apenas `proxy` deixa um grupo `zot` ausente passar pela observabilidade.

<a id="429f3d06-0080"></a>

<a id="first-boot-security-upgrade"></a>

### Atualização de segurança na primeira inicialização

unattended-upgrades e os temporizadores apt diários continuam obtendo correções daqui em diante; esta execução elimina as atualizações pendentes entre a data de construção da imagem de nuvem e o dia da inicialização. Encaminhada por 127.0.0.1:3128 (squid já está ativo, e o arquivo complementar de proxy de pré-aquecimento já habilitou o apt desta VM via seu próprio proxy), para que a atualização use o cache para qualquer conteúdo já obtido por outros convidados. `|| true`, para que um problema transitório de archive.ubuntu.com não faça todo o ciclo falhar -- o apt-daily-upgrade.timer diário tenta novamente em até 24 h.

<a id="429f3d06-0081"></a>

<a id="confirm-apt-daily-timers-armed"></a>

### Confirmar a ativação dos temporizadores diários do apt

Confirme que os temporizadores que controlam a frequência de 24 horas estão ativados. Se o postinst do pacote apt não os habilitou (raro no Ubuntu, mas observado em imagens de nuvem minimizadas), mostre um rastro claro para que um operador perceba ANTES que CVEs se acumulem.

<a id="429f3d06-0082"></a>

<a id="zot-install-binary-and-activation"></a>

### Instalação do binário zot e ativação

Instalação do zot (obtenção do binário + ativação systemd). ZOT_VERSION é fixado para reprodutibilidade, e o binário baixado só é instalado quando o seu SHA-256 corresponde a `ZOT_SHA256_AMD64` ou `ZOT_SHA256_ARM64`; uma divergência não deixa nenhum arquivo para trás. Os hashes ficam fixados no seed em vez de baixados junto com o binário, para que um artefato de release substituído não possa atestar a si mesmo. Para atualizar: leia https://github.com/project-zot/zot/releases, inclusive as mudanças de sync e compat, verifique se os nomes dos artefatos ainda correspondem a `zot-linux-{amd64,arm64}` (NÃO `-minimal` -- a extensão sync é necessária para cache pull-through sob demanda), altere ZOT_VERSION e copie os dois hashes do `checksums.sha256.txt` da release, depois faça o commit: o hook de pre-commit executa `python3 tools/Test-ZotRelease.py`, que baixa a release fixada uma vez, sincroniza as imagens de teste pela tabela de roteamento do seed com o próprio autoteste de sincronização do seed e registra a aprovação que o gate de release exige (veja [When a zot release cannot sync the lab's images](../caching.md#when-a-zot-release-cannot-sync-the-labs-images)). Um host pode instalar outra release no lugar, por meio de `vmStart.cachingProxyZotVersion` e `vmStart.cachingProxyZotSha256`; o binário então só é instalado quando corresponde a esse checksum. Depois que o zot inicia, `zot-sync-selftest.py --heal` sincroniza as imagens de teste por ele e publica o veredito em `/cache-health` e `/zot-meta`. O download do binário vai DIRETAMENTE ao GitHub (não pelo próprio squid desta VM -- dependência circular) e ocorre uma vez por construção de VM, portanto a transferência de ~220 MB não se repete.

Sem uma conta Docker Hub configurada, remova `credentialsFile` do JSON do zot antes de excluir o arquivo de credencial. Uma sequência interrompida então deixa um arquivo não usado, em vez de uma configuração que referencia um arquivo ausente e impede o zot de iniciar. A reescrita do JSON deve preservar a ordem de `registries[]`, pois esse vetor é a tabela de roteamento das origens. Ative o pré-aquecimento após a ativação, em vez de esperar pelo primeiro conjunto frio durante cloud-init.

<a id="429f3d06-0083"></a>

<a id="service-readiness-summary"></a>

### Resumo de prontidão dos serviços

Uma verificação final que exibe uma linha por serviço, porta e artefato em disco
dos quais o operador -- e `Test-CachingProxyService.ps1` -- depende. Sem ela,
uma inicialização parcialmente malsucedida parece idêntica a uma boa até que algo adiante
quebre, longe da causa.

O resumo inclui a primeira consulta de manifesto e a leitura do conjunto aquecido, pois a disponibilidade de `/v2/` sozinha não mostra um caminho de manifesto quebrado nem um cache reconstruído vazio. Identifique as linhas de conteúdo armazenado pelo padrão de espaços em branco iniciais, em vez de uma contagem fixa de indentação, para que mudanças inofensivas no aninhamento da página não as ocultem do log de inicialização.

<a id="429f3d06-0084"></a>

<a id="ready-banner-yaml-mapping-trap"></a>

### Armadilha de mapeamento YAML no aviso de prontidão

Entre aspas simples: o `: ` isolado após "ready" faz o YAML interpretar o escalar como um mapeamento, shellify() recebe um dict, em vez de uma cadeia, e TODA a fase runcmd aborta (geração da CA, inicialização de ssl_db, pré-aquecimento, squid-exporter, monitoramento -- nada executa). A mesma armadilha do echo de offline_mode acima, igualmente silenciosa na saída de systemctl porque write_files ainda executou; apenas `cloud-init status --long` mostra o TypeError.

---

<a id="429f3d06-0085"></a>

<a id="stash-service-seed-topics"></a>

## Tópicos da seed do Stash-service

Tópicos de `host/vmconfig/stash-service.base.user-data`, acessados pela seed como
`# --- REGION: https://yuruna.link/429f3d06-0086`.

<a id="429f3d06-0086"></a>

<a id="host-agent-runs-first"></a>

### O agente do hospedeiro executa primeiro

Em uma rede em bridge, o hospedeiro não observa nenhuma concessão DHCP, portanto não pode informar o endereço desta VM até que o agente do convidado responda -- e cada etapa runcmd posterior pode executar por minutos. O overlay do agente vem primeiro, para que a descoberta no hospedeiro não espere pelo restante da inicialização.

<a id="429f3d06-0087"></a>

<a id="bring-up-driven-by-systemd-not-runcmd"></a>

### Inicialização controlada por systemd, não por runcmd

A inicialização é um script controlado por uma unidade systemd, em vez de etapas `runcmd` diretas. `runcmd` é um módulo do cloud-init POR INSTÂNCIA, e o instance-id desta seed é constante, portanto `runcmd` tem exatamente UMA tentativa durante a vida da VM: uma inicialização interrompida no meio -- a VM parada enquanto o cloud-init ainda compila o daemon -- nunca é tentada novamente. Todas as inicializações seguintes a ignoram, cloud-init ainda informa `status: done, errors: []`, e a VM permanece incompleta para sempre, sem daemon, sem unidade e sem nada que indique a causa. Controlada por systemd, uma inicialização interrompida termina na próxima inicialização da VM.

Portanto, o script é idempotente por construção e seguro para executar novamente; é a ÚNICA parte que instala o daemon. Cada estágio define `+e` e informa os resultados, em vez de abortar, para que um estágio que não termina (um compartilhamento inacessível, um status service do hospedeiro inativo) deixe os seguintes livres para fazer o que ainda conseguem.

<a id="429f3d06-0088"></a>

<a id="stash-nas-cifs-mount-options"></a>

### Opções de montagem cifs do NAS de stash

A montagem é persistida em `/etc/fstab`, para que sobreviva à reinicialização e o systemd exponha uma unidade `mnt-ystash\x2dnas.mount`, em relação à qual o daemon pode ordenar `After=`. A prontidão é verificada com `mountpoint -q`, NÃO `findmnt --target`, que resolve um caminho não montado para a montagem que o contém e aprova incorretamente.

Os modos são deliberadamente abertos (`file_mode=0666`, `dir_mode=0777`), em vez de restritivos. O servidor mapeia o modo de montagem cifs para a ACL NTFS do objeto criado, portanto `dir_mode=0700` restringiria cada pasta criada pela VM apenas a quem a criou -- embora o compartilhamento stash pai conceda controle total a todos os usuários --, e os outros pares do grupo (e o hospedeiro) não conseguiriam listar o stash. Corresponder ao pai aberto é a escolha correta, não uma redução das restrições.

`noperm` impede que o cliente bloqueie o daemon por um mapeamento inesperado de proprietário. Deliberadamente **não** há `iocharset=utf8`: `nls_utf8` está ausente no kernel mínimo da imagem de nuvem, e a montagem falha com `mount error(79)`; os nomes de stash em disco são ASCII.

Um convidado Linux frequentemente não consegue resolver um nome NetBIOS simples (por exemplo, `wserver`), portanto `ip=` -- resolvido no hospedeiro ao construir a seed -- permite ao cifs conectar sem resolução de nome.

---

<a id="429f3d06-0089"></a>

<a id="download-agent-service-seed-topics"></a>

## Tópicos da seed do Download-agent-service

Tópicos de `host/vmconfig/download-agent-service.base.user-data`, acessados pela seed como
`# --- REGION: https://yuruna.link/429f3d06-008a`.

<a id="429f3d06-008a"></a>

<a id="powershell-install-is-best-effort"></a>

### Instalação de PowerShell por melhor esforço

O PowerShell é instalado **apenas para a família Windows 11**. Essa família não tem uma URL que wget possa obter: a Microsoft emite uma URL assinada de curta duração por requisição, e Fido a solicita -- sob pwsh, porque Fido é um script PowerShell.

A etapa faz o melhor esforço de propósito. Sem interpretador, o daemon informa a família como ausente, e cada hospedeiro mantém seu caminho atual (Hyper-V e UTM executam Fido por conta própria, KVM solicita um download manual), portanto nada nesta etapa pode fazer a construção falhar.

O repositório apt prod da Microsoft é tentado primeiro. Ele publica uma suíte por versão do Ubuntu, mas nem sempre fornece um pacote `powershell` NAQUELA suíte, e uma instalação apt que não encontra candidato deixa o convidado sem interpretador e sem nada útil no log -- portanto o candidato é verificado (`apt-cache policy`), não presumido. O arquivo tar da versão, independente de distribuição e usado pelos scripts de inicialização dos convidados irmãos, cobre as versões que o repositório ainda não acompanhou.

A versão estável mais recente é resolvida seguindo `/releases/latest`, não pela API do GitHub: chamadas não autenticadas à API são limitadas a 60/hr para todo o laboratório.

<a id="429f3d06-008b"></a>

<a id="powershell-tarball-hash-verification"></a>

### Verificação do hash do arquivo tar de PowerShell

O arquivo tar é verificado contra os hashes publicados da versão antes de descompactar, pois este interpretador executa Fido com os privilégios do daemon.

O artefato `hashes.sha256` pode ser UTF-16 (gerado no Windows), portanto uma consulta à marca de ordem de bytes seleciona a normalização para UTF-8. A conversão deve ter sucesso antes da interpretação. A linha da soma de verificação deve nomear o arquivo exato, com o prefixo `*` opcional usado por ferramentas de soma de verificação. Ambos os digests devem conter 64 caracteres hexadecimais e corresponder após a normalização de maiúsculas/minúsculas.

Apenas um arquivo verificado é descompactado. Uma soma de verificação ausente, malformada, que não inclua o arquivo ou que não corresponda faz a instalação opcional do PowerShell ser ignorada e registra o motivo. Sem PowerShell, a família Windows 11 permanece indisponível; o daemon download-agent ainda pode ser compilado e servir suas outras famílias.

<a id="429f3d06-008c"></a>

<a id="fido-pinned-tag-and-hash"></a>

### Tag e hash fixados de Fido

Fido é fixado na mesma versão com tag e verificado contra o mesmo SHA-256 fixado pelos scripts de hospedeiro macOS e Hyper-V (`host/macos.utm/guest.windows.11/Get-Image.ps1` e `host/windows.hyper-v/guest.windows.11/Get-Image.ps1`). Fido executa com os privilégios do daemon, portanto uma referência móvel não fixada seria um trecho de execução remota de código sem verificação; uma divergência de hash, por isso, deixa **nenhum arquivo para trás**, em vez de um não verificado.

Como a etapa PowerShell, esta faz o melhor esforço, e sua última linha informa diretamente o estado resultante -- porque "o agente nunca serve Windows 11" e "o agente está bem, este laboratório apenas não tem Fido" parecem idênticos do ponto de vista de um hospedeiro.

O destino deve permanecer em um dos caminhos pesquisados pelo daemon quando `--fido-script` está vazio. Movê-lo para outro lugar desabilita a família **silenciosamente**, pois Fido ausente é um estado suportado, não um erro.

---

**`host/macos.utm/guest.windows.11/Get-Image.ps1`, `host/windows.hyper-v/guest.windows.11/Get-Image.ps1`.**

Altere as configurações do Fido para baixar outra edição ou idioma.
O Fido fica fixado em uma versão com tag, em vez da referência móvel `master`,
e o hash do script é verificado antes da execução. Fido.ps1 executa com os
privilégios deste script; portanto, uma referência móvel sem fixação permitiria
executar código remoto sem verificação. Ao adotar uma nova versão do Fido,
atualize a tag na URL e substitua o hash pelo do novo arquivo:
(Get-FileHash -Algorithm SHA256).Hash.

<a id="429f3d06-008d"></a>

<a id="maintenance-notes"></a>

## Notas de manutenção

- Novos tópicos: acrescente uma seção `### <topic name>` aqui, depois, em user-data,
  execute `tools/Invoke-DocAnchor.ps1 -Update -Path docs/vmconfig.md` e emita uma
  única linha `# --- REGION:` usando o semi-GUID atribuído.
- Tópicos removidos: remova a seção aqui E a referência de uma linha em
  todos os convidados onde ela aparecia. Procure o semi-GUID em `host/` para encontrar
  os locais que o referenciam.
- A lista de ordem recomendada no início deste arquivo é a
  convenção oficial; desviar dela em um convidado específico é aceitável quando
  existe uma dependência real, mas documente o motivo em um comentário de uma linha
  ao lado da etapa fora de ordem.

<a id="429f3d06-008e"></a>

<a id="caching-proxy-service-seed-maintenance"></a>

### Manutenção da seed do Caching-proxy-service

- Novo tópico: acrescente uma seção `### <topic name>` em
  [Tópicos da seed do Caching-proxy-service](#caching-proxy-service-seed-topics) acima,
  atribua uma âncora permanente e acrescente um apontador `# See` para esse semi-GUID
  na indentação correspondente de user-data.
- Tópico removido: remova a seção aqui E o apontador de uma linha no
  user-data. Procure o semi-GUID em `host/vmconfig/` para encontrar os locais que o referenciam.
- Comentários dentro dos artefatos implantados (squid.conf, scripts incorporados, unidades
  systemd) ficam intencionalmente no user-data; documente a justificativa no nível do subsistema
  aqui e deixe o "porquê" no nível da linha ao lado do código com o qual é enviado.

<a id="429f3d06-008f"></a>

<a id="adding-a-new-placeholder"></a>

### Adição de um novo marcador

1. Acrescente o token literal `<NAME>_PLACEHOLDER` a
   `host/vmconfig/ubuntu.server.base.user-data` no lugar apropriado.
2. Acrescente a entrada correspondente à tabela hash `-Replacement` de todos os chamadores
   `New-VM.ps1`. A proteção detecta qualquer chamador que esqueceu.
3. Se o valor vier do repositório (um novo script auxiliar incluído), acrescente-o
   a `Get-YurunaGuestScriptBase64` e deixe `New-CloudInitUserData`
   preenchê-lo automaticamente.

<a id="429f3d06-0090"></a>

<a id="adding-a-new-platform-overlay"></a>

### Adição de um novo overlay de plataforma

1. Crie `host/vmconfig/ubuntu.server.<platform>.overlay.yml` com os
   seis cabeçalhos de âncora (conteúdos vazios para âncoras que a plataforma não
   usa).
2. Acrescente um `New-VM.ps1` em `host/<platform>/guest.ubuntu.server.{24,26}/`
   que chame `New-CloudInitUserData` com o novo caminho de overlay.
3. O combinador valida a cobertura das âncoras ao combinar -- uma âncora ausente
   no overlay gera uma exceção.

---

<a id="429f3d06-0091"></a>

<a id="image-acquisition-and-provisioning"></a>

## Obtenção de imagens e provisionamento

Justificativa do fluxo de imagens `Get-Image.ps1` / `New-VM.ps1`,
compartilhado entre hospedeiros, mas longo demais para manter no código. (A proteção de download
que ignora uma mesma origem e a captura de Last-Modified da sentinela da imagem
ficam em
[guest-image-setup.md -> proteção que ignora uma mesma origem](../guest-image-setup.md#skip-if-same-source-guard).)

<a id="429f3d06-0092"></a>

<a id="macos-utm-qcow2-punchhole-alignment"></a>

### Alinhamento de punchhole em qcow2 do UTM no macOS

Os scripts `Get-Image.ps1` da infraestrutura UTM no macOS (`guest.caching-proxy-service`,
`guest.stash-service`) mantêm o artefato final como **qcow2**, em vez de
convertê-lo para raw:

- O backend QEMU do UTM inicia qcow2 nativamente, portanto nenhuma conversão para raw é necessária.
  (O Hyper-V converte para VHDX porque não pode iniciar qcow2 -- uma diferença real
  de hipervisor, não divergência.)
- qcow2 também é **necessário para a correção** no macOS: o UTM conecta
  discos de leitura e gravação com `discard=unmap,detect-zeroes=unmap`, e o backend
  file-posix do QEMU no macOS atende a esses descartes por
  `fcntl(F_PUNCHHOLE)`, que rejeita qualquer solicitação não alinhada ao tamanho de bloco
  APFS de 4 KiB com `EINVAL` ("Invalid argument"). Uma imagem raw abre
  espaços vazios na granularidade de descarte de 512 bytes do convidado e atinge essa falha; qcow2
  só abre esses espaços nos limites de seus clusters de 64 KiB, sempre
  alinhados a 4 KiB.

Ambos os fluxos de infraestrutura UTM correspondem, e o mesmo raciocínio se aplica ao
seu `New-VM.ps1`: o disco de inicialização por VM é uma cópia de qcow2, nunca uma conversão
para raw. A etapa de redimensionamento de `Get-Image.ps1` trabalha em uma cópia temporária
do qcow2 baixado e a promove no bloco de finalização, para que uma falha de
redimensionamento nunca corrompa a imagem base.

<a id="429f3d06-0093"></a>

<a id="hyper-v-iso-ace-bloat"></a>

### Acúmulo de ACEs na ISO do Hyper-V

Crescimento excessivo da ACL de imagens base do Hyper-V por acúmulo de ACEs por VM.

<a id="429f3d06-0094"></a>

<a id="symptom"></a>

#### Sintoma

`New-VM.ps1` falha ao conectar a imagem base de instalação:

```
Add-VMDvdDrive: Failed to add device 'Virtual CD/DVD Disk'.
Hyper-V Virtual Machine Management service Account does not have permission
to open attachment ... Failed to set security info ...
Error: 'Access is denied.' (0x80070005).
... 'The inherited access control list (ACL) or access control entry (ACE)
could not be built.' ('0x8007053C').
```

Isso aparece subitamente em um hospedeiro que executou muitos ciclos e **persiste
mesmo quando o PowerShell está elevado (Run as Administrator)**.

<a id="429f3d06-0095"></a>

<a id="root-cause-the-isos-acl-is-full-not-a-permissions-problem"></a>

#### Causa raiz: a ACL da ISO está cheia, não é um problema de permissões

O texto é enganoso. Não se trata de um problema de elevação nem de
"conceder acesso à conta de serviço" -- a **DACL do arquivo cresceu
até que o Windows não consegue mais acrescentar outra entrada**.

Toda vez que `Add-VMDvdDrive -Path <baseImage>` executa, o Hyper-V concede à nova
VM acesso de leitura **acrescentando uma ACE explícita** ao arquivo para a
conta virtual específica dessa VM:

- exibida como `NT VIRTUAL MACHINE\<VM-GUID>:(R)` (formato de nome), ou
- como SID bruto `S-1-5-83-1-...:(R)` depois que a VM deixa de existir (ambos são a mesma
  família de contas por VM `S-1-5-83-1`).

A mesma concessão ocorre para **qualquer** arquivo conectado a uma VM -- uma ISO por
`Add-VMDvdDrive`, um VHDX conectado diretamente --, portanto o auxiliar de remoção abaixo
recebe um caminho de arquivo arbitrário.

Dois fatos se combinam para causar a falha:

1. **`Remove-VM` nunca remove essa ACE.** A limpeza exclui a VM e seu
   disco por VM, mas a concessão na imagem base *compartilhada* permanece.
2. **A imagem base é baixada uma vez e reutilizada para todas as VMs.** Portanto, essas
   ACEs se acumulam -- uma por VM já criada -- sem limite.

A DACL de um descritor de segurança do Windows é limitada a **~64 KB**. Quando a DACL da imagem
base se aproxima desse limite, `SetNamedSecurityInfo` não consegue mais construir
uma ACL maior para a ACE da próxima VM -> **`0x8007053C`
(ERROR_INVALID_INHERITANCE_ACL)**. Como essa ACE nunca é gravada, a
conta do processo de trabalho da VM não consegue abrir o arquivo -> **`0x80070005`
(Access denied)**.

<a id="429f3d06-0096"></a>

<a id="why-elevation-is-irrelevant"></a>

##### Por que a elevação é irrelevante

Seu token de administrador autoriza *você* a chamar `Add-VMDvdDrive`. As operações
que falham são (1) Hyper-V/VMMS gravando a nova ACE no arquivo e (2) a
conta virtual da VM (`NT VIRTUAL MACHINE\<guid>`) abrindo o arquivo -- ambas
controladas pela **ACL do arquivo**, que está cheia. A elevação não reduz uma
ACL grande demais.

<a id="429f3d06-0097"></a>

<a id="why-only-shared-base-images-are-affected"></a>

##### Por que apenas imagens base compartilhadas são afetadas

| Arquivo | Compartilhado? | Acumula? |
|---|---|---|
| ISO base de instalação (`...guest.windows.11.iso`, `...ubuntu.server.24/26.iso`) | reutilizada para todas as VMs | **sim** -- uma ACE por VM, para sempre |
| ISO de seed por VM (`seed.iso` na pasta de cada VM) | uma VM | não -- no máximo uma ACE |
| Disco por VM (`<VMName>.vhdx`) | uma VM | não |
| VHDX base (`...guest.amazon.linux.2023.vhdx`, `...caching-proxy-service.vhdx`) | copiado por VM, **nunca conectado diretamente** | não |

Medido em um hospedeiro de desenvolvimento após muitos ciclos: a
ISO base de Windows 11 já continha **1,412 ACEs** (1,020 entradas SID bruto +
387 entradas por VM no formato de nome), totalizando **~56.5 KB / 64 KB**, com **zero**
VMs ativas no hospedeiro. As ISOs base de Linux acumulavam da mesma maneira.

<a id="429f3d06-0098"></a>

<a id="fix"></a>

#### Correção

**Remova as ACEs por VM de VMs que não existem mais**, mantendo intactas as VMs
ativas. O auxiliar compartilhado `Remove-OrphanedVMFileAccess` (em
[host/windows.hyper-v/modules/Yuruna.Host.psm1](../../host/windows.hyper-v/modules/Yuruna.Host.psm1))
constrói o conjunto de SIDs das VMs existentes, remove todas as ACEs não herdadas
`S-1-5-83-1-*` que não estão nesse conjunto e grava o descritor
reduzido com `Set-Acl`. Gravar um descritor *menor* tem sucesso mesmo
quando a ACL em disco já está no limite, portanto o auxiliar recupera um hospedeiro
que já falhou. Ele preserva ACEs herdadas, admin/SYSTEM, o grupo
de todas as VMs (`S-1-5-83-0`), SIDs de capacidades e as ACEs das próprias VMs ativas, portanto
é seguro executá-lo enquanto outras VMs usam o arquivo (o caso de grupo com várias VMs).
Se não conseguir enumerar/traduzir as VMs ativas, ele aborta, em vez de arriscar
remover o acesso de uma VM ativa.

Dois locais de chamada mantêm a DACL limitada:

- **(A) Antes de cada conexão** -- `New-VM.ps1` para `guest.windows.11`,
  `guest.ubuntu.server.24` e `guest.ubuntu.server.26` remove as entradas da imagem
  base imediatamente antes de `Add-VMDvdDrive`. Nesse momento, a VM que está sendo criada
  está ativa, portanto sua ACE (ainda não acrescentada) está segura; as ACEs das VMs anteriores foram removidas,
  limitando a DACL a aproximadamente *(VMs ativas + 1)*.
- **(B) Durante a limpeza** -- `Remove-OrphanedVMFiles.ps1` remove as entradas de todas as
  imagens base mantidas a cada execução (sem efeito nas imagens VHDX base, que não
  acumulam nada), recuperando espaço da ACL mesmo quando nenhuma VM está sendo criada. Executa
  antes da solicitação de exclusão porque é manutenção segura: apenas remove
  acesso para VMs que não existem mais.

<a id="429f3d06-0099"></a>

<a id="manual-remediation-already-failing-host"></a>

##### Correção manual (hospedeiro que já está falhando)

Execute com elevação. Remova apenas as entradas das VMs inexistentes (preferível -- mantém as VMs ativas):

```powershell
Import-Module .\host\windows.hyper-v\modules\Yuruna.Host.psm1 -Force
Remove-OrphanedVMFileAccess -Path "C:\ProgramData\Microsoft\Windows\Virtual Hard Disks\host.windows.hyper-v.guest.windows.11.iso"
```

...ou, se nenhuma VM precisa da imagem no momento, redefina toda a ACL (tem sucesso
mesmo no limite, pois *substitui* o descritor, em vez de aumentá-lo):

```powershell
icacls "C:\ProgramData\Microsoft\Windows\Virtual Hard Disks\host.windows.hyper-v.guest.windows.11.iso" /reset
```

O próximo `Add-VMDvdDrive` acrescenta novamente apenas a ACE da VM atual. Faça o mesmo para
as imagens base `...ubuntu.server.24/26.iso`.

<a id="429f3d06-009a"></a>

<a id="diagnostics"></a>

##### Diagnóstico

```powershell
$iso = "C:\ProgramData\Microsoft\Windows\Virtual Hard Disks\host.windows.hyper-v.guest.windows.11.iso"
$acl = Get-Acl $iso
$acl.Access.Count                                        # total ACEs
$acl.GetSecurityDescriptorBinaryForm().Length            # bytes -- approaching 65535 is the cause
```

<a id="429f3d06-009b"></a>

<a id="scope"></a>

#### Escopo

Específico de Hyper-V -- decorre do modelo de ACEs de contas virtuais por VM do Hyper-V.
KVM e macOS/UTM concedem acesso a arquivos dos convidados de outra forma e não acumulam
ACEs por VM em imagens compartilhadas.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.10.18

Back to [Yuruna](../../README.md)
