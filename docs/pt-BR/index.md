# Documentação do Yuruna em português (Brasil)

Esta pasta contém a tradução para português do Brasil do subconjunto de
documentos voltados ao operador. O inglês continua sendo a fonte de
verdade: cada arquivo aqui é uma cópia traduzida, e o original em inglês
nunca é alterado por uma tradução.

> **Revisão por documento.** O manifesto de traduções do framework registra
> a revisão aceita para cada arquivo. `tools/Test-DocTranslation.ps1`
> verifica esse registro e mudanças no original em inglês. Alterações
> posteriores na tradução precisam de nova revisão humana; a verificação
> de integridade não substitui essa revisão.

## Documentos

| Português | Original em inglês |
|---|---|
| [Yuruna](README.md) | [`README.md`](../../README.md) |
| [Instalação -- ponto de entrada](install/README.md) | [`install/README.md`](../../install/README.md) |
| [Guia do operador](operator.md) | [`docs/operator.md`](../operator.md) |
| [Guia do operador de laboratório](lab-operator.md) | [`docs/lab-operator.md`](../lab-operator.md) |
| [Instalação](install.md) | [`docs/install.md`](../install.md) |
| [Kubernetes](kubernetes.md) | [`docs/kubernetes.md`](../kubernetes.md) |
| [Autenticação](authentication.md) | [`docs/authentication.md`](../authentication.md) |
| [Soluções alternativas](workarounds.md) | [`docs/workarounds.md`](../workarounds.md) |
| [Guia de administração de grupos](pool-admin.md) | [`docs/pool-admin.md`](../pool-admin.md) |
| [Infraestrutura de testes](test-harness.md) | [`docs/test-harness.md`](../test-harness.md) |
| [API de extensões](extensions-api.md) | [`docs/extensions-api.md`](../extensions-api.md) |
| [Esquema do registro de falha](failure-schema.md) | [`docs/failure-schema.md`](../failure-schema.md) |
| [Referência dos tópicos de vmconfig](vmconfig.md) | [`docs/vmconfig.md`](../vmconfig.md) |
| [Notas de implementação do framework](framework-implementation-notes.md) | [`docs/framework-implementation-notes.md`](../framework-implementation-notes.md) |
| [Notas de implementação do hospedeiro](host-implementation-notes.md) | [`docs/host-implementation-notes.md`](../host-implementation-notes.md) |
| [Notas de implementação de projetos e testes](project-implementation-notes.md) | [`docs/project-implementation-notes.md`](../project-implementation-notes.md) |

O projeto de exemplo tem seu próprio conjunto traduzido, no repositório
`yuruna-project`, em `docs/pt-BR/`.

## Para quem revisa

Os títulos das seções em inglês são endereços públicos: links externos
apontam para eles. Por isso os títulos do original **não** mudam, e os
títulos traduzidos aqui não servem como destino desses links.

Nomes de arquivos, comandos, chaves de configuração, identificadores e
todo o conteúdo dentro de blocos de código permanecem em inglês de
propósito -- o operador precisa digitá-los exatamente como aparecem no
sistema.
