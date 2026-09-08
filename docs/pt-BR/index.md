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
