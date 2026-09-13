<a id="42a76c30-0001"></a>

# Implantação no Kubernetes

Implante aplicações em contêineres no Kubernetes em localhost, Azure e AWS
com um único fluxo de trabalho (GCP está planejado, ainda não disponível).
Escreva a configuração uma vez; troque a nuvem alterando um parâmetro.

Consulte [Arquitetura do Yuruna](../architecture.md) para o modelo de três
fases (Recursos->Componentes->Cargas de trabalho), os pontos de entrada da
CLI e o layout do projeto. Este documento é o guia rápido de Kubernetes
voltado ao usuário.

Os pré-requisitos estão em [Dependências de preflight](../operator.md#b2-preflight-dependencies).

<a id="42a76c30-0002"></a>

## Início rápido (localhost)

Implante o site de exemplo em `.NET` no Kubernetes do Docker Desktop. Não
é necessária uma conta de nuvem.

```
git clone https://github.com/alissonsol/yuruna.git
cd yuruna
./Add-AutomationToPath.ps1
```

Crie o certificado de desenvolvimento HTTPS (a carga de trabalho
`ubuntu.server.24.k8s.sh` faz isso automaticamente nesse convidado):

```
$pfxDir = Join-Path $HOME ".aspnet/https"
if (!(Test-Path $pfxDir)) { New-Item -ItemType Directory -Path $pfxDir -Force | Out-Null }
openssl req -x509 -newkey rsa:4096 -keyout "$pfxDir/aspnetapp.key" -out "$pfxDir/aspnetapp.crt" -days 365 -nodes -subj '/CN=localhost' 2>$null
openssl pkcs12 -export -out "$pfxDir/aspnetapp.pfx" -inkey "$pfxDir/aspnetapp.key" -in "$pfxDir/aspnetapp.crt" -password pass:password
Remove-Item "$pfxDir/aspnetapp.key", "$pfxDir/aspnetapp.crt" -Force
```

Implante:

```
cd project/example
Set-Resource.ps1  website localhost -logLevel Debug
Test-Runtime.ps1
Set-Component.ps1 website localhost -logLevel Debug
Set-Workload.ps1  website localhost -logLevel Debug
```

O `Set-Workload.ps1` imprime a URL.

<a id="42a76c30-0003"></a>

## Implantação em nuvem

Autentique-se uma vez e depois troque `localhost` pela sua nuvem:

```
# Azure
az login --use-device-code
az account set --subscription <your-subscription-id>
Set-Resource.ps1 website azure; Set-Component.ps1 website azure; Set-Workload.ps1 website azure

# AWS
aws configure
Set-Resource.ps1 website aws;   Set-Component.ps1 website aws;   Set-Workload.ps1 website aws

# GCP (planned, not yet available)
gcloud auth application-default login
Set-Resource.ps1 website gcp;   Set-Component.ps1 website gcp;   Set-Workload.ps1 website gcp
```

<a id="42a76c30-0004"></a>

### Reforço do acesso ao plano de controle (obrigatório para EKS / AKS)

Os clusters gerenciados restringem seu servidor de API do Kubernetes a uma
lista de permissões CIDR explícita em vez de expô-lo a toda a internet,
portanto uma implantação de EKS ou AKS **exige** `apiServerAuthorizedCidrs`
nas `globalVariables` do seu `resources.yml`:

```yaml
globalVariables:
  # Comma-separated CIDR allow-list for the cluster API server. MUST include
  # the machine running Set-Workload (its public egress IP as a /32) or the
  # first kubectl/helm call is locked out. Add admin / VPN ranges as needed.
  apiServerAuthorizedCidrs: "203.0.113.5/32,198.51.100.0/24"
```

Ela se conecta a `endpoint_public_access_cidrs` no EKS e a
`api_server_access_profile.authorized_ip_ranges` no AKS. **Não há padrão** --
omiti-la falha em `tofu plan` (falha fechada) em vez de expor silenciosamente
`0.0.0.0/0`. O EKS mantém o acesso ao endpoint privado ativo para o tráfego
de nós/pods dentro da VPC; a implantação externa via `kubectl`/`helm` usa a
lista de permissões. Para um plano de controle totalmente privado, defina
`endpoint_public_access = false` no EKS / `private_cluster_enabled = true` no
AKS e execute a implantação a partir de uma VPN ou de uma máquina dentro da
VPC/VNet.

O módulo do EKS não inclui a ServiceAccount `admin-user` do dashboard
vinculada a `cluster-admin`: a identidade de implantação já tem privilégio
de administrador do cluster (`enable_cluster_creator_admin_permissions`). Se
você quiser o dashboard do Kubernetes, conceda uma função com escopo
restrito e gere um token de curta duração sob demanda (`kubectl create
token`) em vez de deixar no cluster um segredo permanente de cluster-admin.

Detalhes, contas de serviço e habilitação de APIs: [Autenticação do Yuruna ...](../authentication.md).

<a id="42a76c30-0005"></a>

## Limpeza de recursos de nuvem

**Estas instruções destruirão recursos.** Informe os parâmetros corretos.
Recursos de nuvem geram cobranças, então sempre limpe o que não usar.

<a id="42a76c30-0006"></a>

### Limpeza automática

Limpe os recursos de uma determinada configuração:

```
Invoke-Clear.ps1 [project_root] [config_subfolder]
```

Limpando o projeto `website` na nuvem `azure` (supondo que as etapas de
[Autenticação do Yuruna ...](../authentication.md) tenham sido seguidas):

```
Invoke-Clear.ps1 website azure
```

Você também pode excluir recursos diretamente da pasta que contém os
arquivos iniciais de implantação (`.yuruna/$config_subfolder/resources/$resourceName` -- por exemplo,
`.yuruna/azure/resources/website-cluster` para `Invoke-Clear.ps1 website azure`):

```
tofu destroy -auto-approve -refresh=false
```

Isso exige que a pasta `.terraform` criada ainda esteja disponível; sem ela
você verá `0 destroyed` -- nesse caso, siga a limpeza manual abaixo.

Não se esqueça de excluir o contexto do cluster de `[user]/.kube/config`. A
[extensão do Kubernetes](https://marketplace.visualstudio.com/items?itemName=ms-kubernetes-tools.vscode-kubernetes-tools)
do [Visual Studio Code](https://code.visualstudio.com/)
ou o [`kubectl`](https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#-em-delete-context-em-)
podem fazer isso.

<a id="42a76c30-0007"></a>

### Limpeza manual por nuvem

- **AWS** -- no [AWS Management Console](https://console.aws.amazon.com/),
  exclua clusters, registries, VPCs, IPs e outros recursos.
- **Azure** -- no [Azure Portal](https://portal.azure.com), exclua os
  Grupos de Recursos do Azure criados; excluir um grupo de recursos exclui
  todos os recursos associados. Há um recurso global para o registry e os
  clusters, e cada cluster Kubernetes tem um grupo de recursos de nós do AKS
  correspondente (veja o [FAQ do AKS](https://learn.microsoft.com/en-us/azure/aks/faq))
  nomeado com o sufixo `_nodes`.
- **GCP** -- no [GCP Console](https://console.cloud.google.com/), exclua
  quaisquer recursos criados anteriormente.

<a id="42a76c30-0008"></a>

## Pré-requisitos no convidado

As cargas de trabalho dos convidados instalam o conjunto comum de ferramentas
do cluster local: Git, Docker, Kubernetes, PowerShell, Helm, OpenTofu e mkcert.
O Windows instala adicionalmente o Graphviz e as CLIs do Azure, da AWS e do
Google Cloud. O Ubuntu omite intencionalmente essas ferramentas opcionais: as
CLIs de nuvem são necessárias apenas nos exemplos que implantam em uma nuvem,
o Graphviz é recomendado em vez de obrigatório e instalar o conjunto completo
acrescenta um custo substancial de transferência e configuração, enquanto
alguns pacotes dos fornecedores continuam indisponíveis em ARM64. Adicione-os
por meio de uma carga de trabalho explícita e opcional quando um convidado
precisar deles, em vez de tornar mais lenta a compilação de todas as imagens
para clusters locais. Veja [Dependências de
preflight](../operator.md#b2-preflight-dependencies). Padrão de carga de
trabalho de convidado: [Arquitetura do Yuruna](../architecture.md).

| Convidado | Comando |
|---|---|
| **Ubuntu Server 24.04** | `/usr/local/lib/yuruna/fetch-and-execute.sh guest/ubuntu.server.24/ubuntu.server.24.k8s.sh` |
| **Ubuntu Server 26.04** | `/usr/local/lib/yuruna/fetch-and-execute.sh guest/ubuntu.server.26/ubuntu.server.26.k8s.sh` |
| **Windows 11** | `irm ".../guest/windows.11/windows.11.k8s.ps1$nc" \| iex` (veja [Windows 11 ...](../../guest/windows.11/README.md)) |

**Ubuntu -- opcional depois:** altere o nome da máquina com
`sudo hostnamectl set-hostname <name>`; pode ser necessário reiniciar o
terminal para aplicar as novas permissões de grupo.

<a id="42a76c30-0009"></a>

### Verificação

```
docker images
docker ps -a
kubectl get nodes
kubectl get pods -A
kubectl config current-context
```

<a id="42a76c30-000a"></a>

## Notas sobre a sequência de testes

<a id="42a76c30-000b"></a>

### Por que a verificação de prontidão do site aguarda a disponibilidade do Deployment, e não os Endpoints

O script da carga de trabalho do site termina aguardando a **disponibilidade
do Deployment**, e não os endereços de Endpoints, antes da etapa de teste de
GUI que vem em seguida:

```
kubectl wait --for=condition=available deployment/website -n website --timeout=240s
```

Verificar `endpoints/website-service` estaria errado por dois motivos:

1. **Nome errado.** O Service do helm chart é `website`, e não
   `website-service` -- esse nome está no manifesto independente em
   `components/frontend/website/`, usado para `kubectl apply` pontual, e não
   dentro do cluster.
2. **Sinal errado.** Ele relatava `NotFound` instantaneamente quando o
   Deployment estava 0/1 pronto, mascarando a falha real (um pod despejado
   por pressão de armazenamento efêmero, com seu substituto preso no
   taint de disk-pressure).

`--for=condition=available` bloqueia no sinal de prontidão de
`Deployment.status.conditions`, então o teste espera os 240 s completos e o
diagnóstico captura um estado de pod útil.

<a id="42a76c30-000c"></a>

### Recupere espaço em disco do cache de compilação antes da implantação

A compilação do SDK do dotnet deixa ~1,3 GiB no território do
`docker buildx prune` e outros ~0,5 GiB de imagens intermediárias órfãs. Em
um disco de nó de 14 GiB isso bastava para atingir o limite de 85% de
armazenamento efêmero do kubelet, fazer com que os pods da carga de trabalho
+ nginx-ingress fossem despejados e deixar seus substitutos presos no taint
de disk-pressure. Os scripts de carga de trabalho limpam os dois caches
antes de o cluster implantar; uma falha ali não é fatal -- só o efeito
colateral importa.

<a id="42a76c30-000d"></a>

## Veja também

- [Arquitetura do Yuruna](../architecture.md#cli-entry-points) -- referência da CLI para as três fases
- [Soluções alternativas e FAQ do Yuruna](../workarounds.md)
- [Exemplo de site do Yuruna](https://github.com/alissonsol/yuruna-project/tree/main/example/website), [Leitura adicional](../README.md#further-reading)

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Última revisão: 2026.09.13

Voltar para [Yuruna](../../README.md)
