<a id="427ac634-0001"></a>

# Instruções de autenticação do Yuruna

Como um operador se autentica em cada nuvem suportada, como o pipeline
de push de componentes se autentica em um registro de contêineres de
forma não assistida e o modelo de ameaças do repositório de credenciais
do harness de testes.

<a id="427ac634-0002"></a>

## Docker Desktop

- Não é necessário autenticar!

<a id="427ac634-0003"></a>

## AWS

- Crie um usuário administrador (não o usuário root) conforme a [orientação da AWS](https://docs.aws.amazon.com/IAM/latest/UserGuide/getting-started_create-admin-group.html).
- Faça login com a [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-quickstart.html) (uma vez por sessão do PowerShell):
  - `aws configure` -- informe `AWS Access Key ID`, `AWS Secret Access Key`, `Default region name`, `Default output format`.
  - Mostre a [configuração atual](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-files.html): `aws configure list`.
  - Verifique se a conta está pronta: `aws eks list-clusters`.

<a id="427ac634-0004"></a>

## Azure

- Faça login e selecione uma assinatura (uma vez por sessão do PowerShell):
  - `az login --use-device-code`
  - Se necessário: liste e defina uma assinatura padrão:
    - `az account list -o table`
    - `az account set --subscription xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxx`
    - Mostre a atual: `az account show --query "{name:name, isDefault:isDefault, id:id, user:user.name}" -o tsv`

<a id="427ac634-0005"></a>

## Google Cloud

> **Observação:** a implantação no GCP está planejada e ainda não está
> disponível -- os modelos de recurso em `global/resources/gcp/` ainda não
> são distribuídos. Estas etapas preparam o terreno para isso.

- Inicialização única:
  - Verifique a configuração ativa no momento: `gcloud config list`
  - `gcloud init --skip-diagnostics` -- inicie uma nova configuração e projeto para não atrapalhar outros trabalhos.
  - Habilite as APIs necessárias (ajuste o nome do projeto conforme necessário). Se esta for a primeira API habilitada para o projeto, o faturamento também precisa ser habilitado.
    - <https://console.developers.google.com/apis/library/compute.googleapis.com?project=yuruna> -> `Enable API`
    - <https://console.developers.google.com/apis/library/containerregistry.googleapis.com?project=yuruna> -> `Enable API`
  - Defina uma região padrão para o projeto (de preferência a mesma região usada na configuração de recursos do OpenTofu):
    - Inspecione: `gcloud compute project-info describe --project [project]`
    - Altere: `gcloud compute project-info add-metadata --metadata google-compute-default-region=[region]`
  - Acesso ao Docker Registry do GCP:
    - Crie uma conta de serviço com a função 'Container Registry Service Agent' (ou reutilize aquela [adicionada automaticamente](https://cloud.google.com/container-registry/docs/overview#container_registry_service_account) quando você habilitou a API do Container Registry).
    - Crie o arquivo JSON de chave de acesso:
      - Abra a página de [credenciais de API](https://console.cloud.google.com/apis/credentials?project=yuruna) e clique na conta de serviço.
      - Em "Keys", selecione `Add Key` -> `Create new key` -> `JSON` -> `CREATE`. Salve o arquivo baixado como `global/config/gcp/gcp-access-key.json`.

- Autenticação por sessão:
  - Verifique os padrões: `gcloud config list`
  - Configuração ativa: `gcloud config configurations list`; ative com `gcloud config configurations activate [configuration]`.
  - Projeto ativo: `gcloud projects list`; depois `gcloud config set project [project]`.
  - Autorize o SDK: `gcloud auth application-default login`.

<a id="427ac634-0006"></a>

## Login no registro de componentes

As etapas acima são o que um operador digita uma vez por sessão. O
pipeline de push de componentes em
[`automation/Yuruna.Component.psm1`](../../automation/Yuruna.Component.psm1)
faz o equivalente de forma não assistida: faz login no registro de
contêineres de destino antes de enviar a imagem compilada. Os
registros suportados (Azure ACR, AWS ECR, Google Artifact Registry,
Docker Hub, login genérico do Docker) usam, cada um, uma CLI e um
modelo de credenciais diferentes. O despachante em
[`automation/Yuruna.Component.Registry.psm1`](../../automation/Yuruna.Component.Registry.psm1)
pergunta ao registro de provedores de credenciais em
[`automation/Yuruna.CredentialProvider.psm1`](../../automation/Yuruna.CredentialProvider.psm1)
"qual é o comando de login para `<host>`?" e canaliza a resposta
pelo mesmo wrapper `Invoke-ComponentCommand` que cuida de
build / tag / push, de modo que a fase `registryLogin` compartilha
`docker.stderr.log` e `docker.rc` com o resto do pipeline.

O despachante mantém o conhecimento sobre registros fora do
`Yuruna.Component`, que não carrega nenhuma ramificação por registro
como `if ($registryLocation -like '*azurecr.io*')`. Adicionar um tipo
de registro (ECR, GAR, Docker Hub, Harbor, Nexus, ...) é uma única
chamada a `Register-CredentialProvider`; nada em `Yuruna.Component`
muda.

<a id="427ac634-0007"></a>

### Camadas

Tanto o `Yuruna.Component` quanto o registro de provedores de
credenciais vivem em `automation/`: o registro (a âncora
`$global:YurunaCredentialProviders`, `Register-CredentialProvider`,
`Get-CredentialProvider` e os cinco registros de provedores embutidos)
está em
[`automation/Yuruna.CredentialProvider.psm1`](../../automation/Yuruna.CredentialProvider.psm1),
de modo que o pipeline de push de componentes em tempo de execução
nunca importa de `test/`: não existe aresta de importação
`automation/ -> test/`. Os auxiliares exclusivos de teste
(`Get-CredentialProviderMatrix`, `Repair-Credential`,
`Clear-CredentialProvider`) permanecem em
[`test/modules/Test.CredentialProvider.psm1`](../../test/modules/Test.CredentialProvider.psm1),
que importa o módulo de automação com `-Global` e reexpõe
`Register`/`Get` aos chamadores de teste. O arquivo-ponte
[`automation/Yuruna.Component.Registry.psm1`](../../automation/Yuruna.Component.Registry.psm1)
concentra o despacho em um único lugar.

<a id="427ac634-0008"></a>

### Superfície pública

| Função | Módulo | Usada por |
|---|---|---|
| `Register-CredentialProvider -Type -Pattern -Authenticator [-LoginCommand]` | `Yuruna.CredentialProvider` | Registros embutidos no carregamento do módulo; módulos externos podem adicionar mais |
| `Get-CredentialProvider -Target` | `Yuruna.CredentialProvider` | Despachante; introspecção |
| `Get-CredentialProviderMatrix` | `Test.CredentialProvider` | Disponível para uma matriz de capacidades; sem chamador hoje |
| `Repair-Credential -Target` | `Test.CredentialProvider` | Disponível para um chamador que queira reautenticar após um 401; **nenhum invocador automático hoje** |
| `Clear-CredentialProvider` | `Test.CredentialProvider` | Apenas testes |
| `Resolve-ComponentRegistryLogin -RegistryLocation` | `Yuruna.Component.Registry` | O pipeline de push; retorna a string do comando de login ou `$null` |

Cada provedor expõe dois scriptblocks:

- **`Authenticator`** -- o ponto de entrada de reautenticação
  (`Repair-Credential`, se algum chamador o invocar). Executa a autenticação
  no próprio processo (chama `az acr login`,
  `gcloud auth print-access-token | docker login`, ...). Retorna `[bool]`.
- **`LoginCommand`** -- pipeline em lote
  (push do `Yuruna.Component`). Retorna a string de comando de shell que o
  pipeline de push canaliza pelo seu próprio wrapper de log, ou `$null`
  quando o ambiente não tem as credenciais.

<a id="427ac634-0009"></a>

### Provedores embutidos

| Tipo | Padrão | Formato do comando de login |
|---|---|---|
| `azurecr` | `\.azurecr\.io(/\|$)` | `az acr login -n <registry>` |
| `ecr` | `\.dkr\.ecr\.[^.]+\.amazonaws\.com(/\|$)` | `aws ecr get-login-password --region <region> \| docker login --username AWS --password-stdin <host>` |
| `gar` | `-docker\.pkg\.dev(/\|$)` | `gcloud auth print-access-token \| docker login -u oauth2accesstoken --password-stdin https://<host>` |
| `dockerhub` | `^(index\.)?docker\.io(/\|$)` | `$env:YURUNA_DOCKER_HUB_PASSWORD \| docker login --username $env:YURUNA_DOCKER_HUB_USERNAME --password-stdin` |
| `docker-generic` | `.+` | `$env:YURUNA_REGISTRY_PASSWORD \| docker login --username $env:YURUNA_REGISTRY_USERNAME --password-stdin <host>` |

A ordem importa e é preservada: padrões mais específicos precedem o
`docker-generic`, que captura todo o resto. A tolerância a sufixo de
caminho (`(/|$)`) faz com que `foo.azurecr.io/myimage` corresponda ao
mesmo provedor que o host puro.

<a id="427ac634-000a"></a>

### Variáveis de ambiente de credenciais

O Docker Hub e o `docker-generic` leem credenciais de variáveis de
ambiente; os demais derivam a autenticação do contexto de CLI do
operador (`az login`, `aws configure`, `gcloud auth login`) configurado
acima:

| Variável de ambiente | Usada por |
|---|---|
| `YURUNA_DOCKER_HUB_USERNAME` / `YURUNA_DOCKER_HUB_PASSWORD` | provedor `dockerhub` |
| `YURUNA_REGISTRY_USERNAME` / `YURUNA_REGISTRY_PASSWORD` | provedor `docker-generic` |

Quando qualquer um dos pares de variáveis de ambiente está ausente, o
`LoginCommand` daquele provedor retorna `$null`: o pipeline de push pula
a fase de login e o auxiliar de credenciais do docker já existente do
operador cuida do push. Esse é o padrão "nenhum login necessário" para
qualquer registro sem credenciais fornecidas por um provedor.

<a id="427ac634-000b"></a>

### Adicionando um novo tipo de registro

1. Escolha um nome de `Type` (`harbor`, `nexus`, `quay`, ...) e um
   `Pattern` de regex que corresponda ao formato do host.
2. Implemente os dois scriptblocks (`Authenticator` de autocorreção e
   `LoginCommand` em lote); retorne `[bool]` e `[string]`, respectivamente.
3. Chame `Register-CredentialProvider` no fim de
   [`Yuruna.CredentialProvider`](../../automation/Yuruna.CredentialProvider.psm1)
   na ordem de registro -- padrões mais específicos primeiro.
4. O pipeline de push passa a usar o novo provedor no próximo
   reinício externo.

<a id="427ac634-000c"></a>

### Registros relacionados

- [Registro de condições de hospedeiro](../test-harness.md#host-condition-registry) -- mesma primitiva `New-YurunaRegistry`, domínio diferente.
- [Registro de E/S de hospedeiro](../host-io.md) -- o registro mais antigo, de dois níveis, que estabeleceu o padrão.
- [Despachante de remediação](../failure-schema.md#remediation-dispatcher) -- classifica um 401 como `credential_expired` e RECOMENDA a reautenticação. Ele não chama `Repair-Credential`; aplicar a recomendação é tarefa do chamador.

<a id="427ac634-000d"></a>

## Cofre do harness de testes — modelo de ameaças

O harness de testes mantém um repositório de credenciais separado e
leve em `test/status/extension/authentication/vault.yml`. **Esse arquivo
é YAML em texto puro por design.** Ele NÃO é um cofre de segredos de
produção.

O que vai parar nele: senhas por ciclo das contas descartáveis do
sistema operacional convidado que o harness cria (`yauser1`, `yuuser24`,
`yt2sqluser`, etc.) em VMs de teste apagadas e reconstruídas a cada
ciclo. As contas existem apenas dentro da VM de teste; o harness
rotaciona a senha no primeiro contato via `Set-Password`, armazena tanto
`password` quanto `previousPassword` para que uma rotação aplicada pela
metade possa se recuperar, e nunca exporta o valor para fora da máquina
local.

O que nunca vai parar nele: credenciais de provedores de nuvem
(`aws configure` / `az login` / `gcloud auth ...` mantêm seus próprios
arquivos, veja as seções acima), chaves de API, tokens de registro,
chaves de host SSH (essas ficam em `test/status/ssh/`) ou qualquer
credencial pessoal do operador.

Limite de confiança:

| Camada | Mecanismo | Por que texto puro é aceitável |
|-------|-----------|----------------------------|
| Sistema de arquivos | O arquivo está no gitignore (regra `test/status/*/` do `.gitignore`); nunca é commitado, nunca é sincronizado. | Um atacante com acesso de leitura ao sistema de arquivos já está na máquina do operador, com capacidade equivalente ou maior. |
| Processo | Leitura+escrita serializadas por um mutex nomeado a partir do SHA-1 do caminho; gravação atômica em arquivo temporário e renomeação. | Ciclos concorrentes não podem corromper o arquivo; não é um controle de confidencialidade. |
| Auditoria | Cada leitura / escrita / rotação é acrescentada ao `events.log` como uma linha JSON. Senhas nunca aparecem no log. | Detecção de adulteração, não criptografia. |

Se você estender o harness para operar um sistema de produção, NÃO
adicione credenciais de produção a esse cofre. Conecte uma extensão de
autenticação separada (veja [API de extensões](../extensions-api.md))
apoiada em DPAPI / chaveiro do sistema / um gerenciador de segredos de
verdade. A extensão `default` de hoje é intencionalmente mínima.

Implementação:
[`test/extension/authentication/default.psm1`](../../test/extension/authentication/default.psm1)
(o comentário de cabeçalho dela traz um ponteiro de uma linha de volta
para esta seção).

---

<a id="427ac634-000e"></a>

## O MCP não acrescenta nenhum tipo de credencial

Todo daemon Go do Yuruna e o framework central servem o Model Context Protocol
(veja [API de extensões -- endpoints MCP](../extensions-api.md#mcp-endpoints)), e
nenhum deles introduz um novo segredo, sessão ou limite de confiança para
fazer isso.

- Uma **ferramenta que altera estado** passa pelo mesmo controle de token de
  laboratório por que passa a rota HTTP dela, e recusa com os mesmos tokens de
  motivo: `auth-unconfigured` quando o serviço não tem nenhuma via de entrada
  configurada, `lab-token-unavailable` quando o validador não pode ser
  alcançado. Há uma única resposta por serviço para "este chamador pode mudar
  alguma coisa", e o MCP a consulta em vez de respondê-la.
- Uma **ferramenta somente leitura** carrega exatamente a exposição da rota que
  ela encapsula. Essas rotas são abertas na LAN confiável por design, e as
  ferramentas também.
- O **token rotativo do laboratório continua sendo o caminho humano**. Nada no MCP
  cunha, armazena ou encaminha um; um cliente que queira uma ferramenta que
  altera estado apresenta a mesma chave de autenticação interna que um chamador
  de automação apresenta à rota.
- O **servidor stdio do framework central não guarda credencial alguma**, porque
  o transporte dele é o limite: ele não tem listener, e um processo que lê o
  stdin de um operador pode fazer exatamente o que aquele operador já pode fazer
  digitando o comando ele mesmo.

A consequência prática é que revogar ou rotacionar a chave de autenticação interna
fecha a superfície MCP exatamente como fecha a HTTP -- não há um segundo
lugar para procurar.

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Última revisão: 2026.09.12

Voltar para [Yuruna](../../README.md)
