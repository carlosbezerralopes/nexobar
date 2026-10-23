# Instalador Windows — 0.5.0

`NexoBar-Setup-x64.exe` é um aplicativo WPF para Windows 11 x64, autocontido e de arquivo único. Não exige PowerShell, .NET SDK, Visual Studio ou SignTool na máquina de destino. Executa como usuário; somente a importação opcional e consentida do certificado público usa um helper elevado do próprio EXE.

O usuário escolhe faixa, bandeja e WidBar independentemente, revisa o destino e confirma a instalação. A inicialização automática é uma escolha separada: sem alteração explícita da opção, nenhum atalho Startup é escrito. Em instalação nova, somente CPU/memória começam habilitadas; todos os indicadores de IA ficam desligados.

O aplicativo fica em `%LOCALAPPDATA%/Programs/NexoBar/versions/0.5.0`. O recibo `install-state.json` e o atalho próprio no menu Iniciar identificam a instalação. Versões anteriores são preservadas; uma versão superior não é substituída. Uma versão igual e íntegra é reutilizada. Um destino desconhecido ou alterado é recusado, sem reparo destrutivo automático. Se NexoBar estiver em execução, use **Sair** no aplicativo e **Verificar novamente** no instalador.

As preferências em `%LOCALAPPDATA%/NexoBar/indicators.json` recebem somente os três booleanos de apresentação confirmados. Campos desconhecidos, ordem, nomes, pastas das CLIs, largura e posições são preservados. JSON corrompido ou schema desconhecido permanece intacto e gera pendência; alteração concorrente exige nova revisão. Nenhuma CLI de IA, autenticação ou coletor é instanciado pelo instalador.

WidBar é um produto separado, identificado pela [página oficial na Microsoft Store](https://apps.microsoft.com/detail/9PKLDNM83TP9). O instalador apresenta a página/termos antes da confirmação. Reutiliza o host compatível; se necessário, usa `winget` já existente com ID exato, fonte `msstore` e `--no-upgrade`. Sem winget, abre a Store e permite retomar. Resultado de processo não prova instalação: o pacote é consultado novamente. O instalador não inicia login nem aceita termos automaticamente.

O companion é instalado pelo `PackageManager.AddPackageAsync` com `DeploymentOptions.None`, sem fechar aplicações nem remover a versão anterior. A instalação do aplicativo permanece válida se Store, confiança ou companion ficarem pendentes. Feche o host caso o Windows informe pacote em uso e execute novamente. Ao concluir, abra WidBar e adicione/arraste **NexoBar** pelo catálogo. Não há posicionamento automático: configurações privadas do host não são alteradas.

## Integridade e confiança

O manifesto e o ZIP são recursos internos do EXE, cobertos pela assinatura final do executável. Cada arquivo é conferido por tamanho/SHA256; caminhos absolutos, traversal, ADS, links, reparse points e duplicatas sem distinção de caixa são recusados. A assinatura CMS do MSIX é verificada e `WinVerifyTrust` com `WTD_HASH_ONLY_FLAG` comprova o digest via SIP separadamente da verificação normal de confiança. Uma falha de cadeia nunca é aceita como prova de integridade.

Se o certificado não for confiável, a confirmação mostra subject, issuer, validade, SHA256 do certificado e do pacote. A autorização permite importar **somente o certificado público DER incorporado** em `LocalMachine/TrustedPeople`, após UAC. O helper revalida payload, identidade, assinatura e certificado; não recebe caminhos, certificados ou destinos arbitrários. Não importa PFX/chaves, não copia o aplicativo e não altera preferências/Store sob outra identidade. Cancelamento mantém o companion pendente. A política local pode impedir a instalação; o instalador não muda essa política.

APIs documentadas: [WINTRUST_DATA](https://learn.microsoft.com/windows/win32/api/wintrust/ns-wintrust-wintrust_data), [AddPackageAsync](https://learn.microsoft.com/uwp/api/windows.management.deployment.packagemanager.addpackageasync). As verificações criptográficas usam somente o cache local de revogação, sem prometer verificação online de revogação.

## Compilar

Desenvolvimento exige Windows x64, PowerShell 7, SDK .NET 10 e acesso ao NuGet. Gere primeiro o portátil 0.5.0 e o companion MSIX 0.5.0.0 assinado. A identidade exigida é `NexoBar.Widget`, publisher `CN=NexoBar`, arquitetura x64.

```powershell
pwsh -NoProfile -File windows/setup/build.ps1 `
  -PortableDirectory C:/build/portable/publish `
  -SignedCompanion C:/build/NexoBar-WidBar-x64-0.5.0-signed.msix `
  -PublicCertificate C:/build/publisher.cer `
  -ArtifactsDirectory C:/build/setup
```

O certificado é opcional quando a cadeia já é confiável, mas necessário para o fluxo de consentimento do certificado local. Deve ser público DER e coincidir com o signatário. O build recusa MSIX não assinado/confiável no ambiente de build e material privado; inclui app/runtime, documentação e licenças, excluindo harnesses, fonte, PDBs, caches, relatórios e scripts de diagnóstico. Gera `publish/NexoBar-Setup-x64.exe`, `build-result.json` e a verificação do recurso incorporado. A assinatura do EXE é etapa de distribuição separada, obrigatória antes da entrega final. O script não instala nem publica nada.

Um build de desenvolvimento sem `SetupPayloadDirectory` compila e mostra erro claro de recurso ausente; não instala arquivos fictícios. Os modos `--verify-embedded-payload` e `--verify-package <arquivo.msix>` são somente leitura e retornam JSON/exit code quando a saída é redirecionada.

```powershell
dotnet run --project windows/setup/tests/NexoBar.Setup.Tests.csproj -c Release `
  --artifacts-path C:/build/setup-tests -- C:/build/setup-fixtures
```

O harness utiliza diretórios exclusivos e serviços injetáveis. Store, MSIX, certificados e atalhos Windows são simulados; a transação e as gravações em arquivos são reais somente dentro do diretório de fixtures. Cobre hash/ZIP, versões, reuso, rollback, cancelamento, pendências, concorrência de preferências e ausência de escrita no Startup. Build e testes não comprovam instalação física, UAC, Store, aparência WPF ou descoberta no WidBar; essas verificações exigem execução nativa separada e autorização explícita.
