# Evidência de build — Windows 0.6.0

Registro de 23/10/2026, posterior à geração dos pacotes. Núcleo: 261 checks; ponte, demonstrações e geometria: 105; descoberta Claude e ConPTY sintético: 83; instalador: 85. Total: 534 verificações aprovadas. WPF e WinUI/XAML compilaram nativamente com .NET SDK 10.0.402. O MSIX e o instalador foram gerados, assinados com o certificado local de teste e verificados. Integridade e confiança do payload incorporado passaram.

O diagnóstico do executável 0.6 retornou `/usage` com o PATH normal, sem `claude.exe` diretamente no PATH: três janelas recebidas, duas de conta e uma por modelo, em 10,5 segundos; nenhum Job próprio permaneceu ativo. Não houve login, alteração permanente do PATH, execução de shim ou concessão de confiança. Isso comprova a correção de descoberta do executável npm; o aplicativo 0.5 instalado não incluía essa descoberta.

As temperaturas físicas de CPU/GPU continuam indisponíveis ao coletor nesta máquina. Fixtures comprovam o controle visual quando há leitura e preservam ausência sem inventar zero.

SHA256 dos artefatos assinados:

- Setup: `9a5bb0fd682236e2892ae12af322d44a259d565b6888b27578808236e70b4fcd`.
- Companion MSIX: `9b2063106febe92d30872c42da6ebb08e2f8006fa22fbf0f65e1e8be54d98179`.

A instalação 0.6 e a medição do preview hospedado ainda não foram concluídas: a sessão gráfica ficou indisponível para controle/captura. Fixtures geométricas não comprovam ausência de corte ou oclusão externa na taskbar. A assinatura local de teste não equivale a reputação pública de distribuição.

Este registro complementa os documentos incorporados aos pacotes, que refletem as etapas anteriores à verificação final. Recursos e diferenças remanescentes estão em [PARITY-0.6.md](PARITY-0.6.md).

## Atualização 0.6.1 — testes sem Computer Use

A instalação 0.6.0 foi posteriormente concluída e preservou preferências. Durante a validação foi encontrado um caso de inicialização: o preview inicialmente oculto não procurava o aplicativo enquanto o estado de habilitação era desconhecido. A versão 0.6.1 mantém essa descoberta até receber a primeira configuração. Três verificações adicionais cobrem estado desconhecido, ausência inicial e recuperação; total atual: 537 checks (261 núcleo, 108 ponte, 83 descoberta/ConPTY, 85 instalador).

Em 23/10/2026, a atualização 0.6.1 foi aplicada sem controle de tela por um runner que referencia os assemblies compilados do instalador e executa `InstallTransaction` e `PackageDeployment`. O verificador confirmou integridade e confiança antes da instalação. O recibo indica 0.6.1; os 529 arquivos instalados coincidiram com o manifesto; o MSIX instalado é 0.6.1.0, status Ok. Preferências foram comparadas semanticamente e preservadas, a versão anterior permaneceu e a inicialização automática continuou desativada.

Com o aplicativo instalado em execução, a leitura do pipe confirmou Claude disponível com duas janelas de conta (e uma por modelo), Codex com uma janela, largura 402, cinco componentes, gap 4, cotas empilhadas e renovação habilitada. Posições preservadas: CPU/memória na primeira linha e Claude/Codex/Kiro na segunda. NexoBar, WidBar e companion foram observados em execução. Kiro retornou indisponível nessa rodada; não foi substituído por zero.

A leitura do pipe comprova os dados oferecidos ao companion, não seu consumo nem a aparência final no host. O teste visual final e a ausência de corte na taskbar permanecem não verificados, por opção de testar sem Computer Use. Temperaturas físicas continuam indisponíveis nesta máquina.

Artefatos finais 0.6.1 (SHA256):

- Setup assinado: `b4ce349b758d5fed5fbc951751707e036d18435b6c4bca225ee5885f73fb1c2e`.
- MSIX assinado: `ec23400d23ab1791b842105066085f984f30fb8d343e31156b16aec47e611eaf`.
- ZIP portátil: `029c0863c92f36bc1a7864c87eb150a2dfd6fb0fddfffcf2e575910ae7281731`.

Os documentos incorporados aos pacotes precedem esta verificação final. A assinatura continua sendo de teste local. O runner externo teve um aviso NU1900 de consulta de vulnerabilidades indisponível; sua compilação concluiu sem erros. Uma primeira tentativa parou antes da transação por acesso incorreto ao nó Displays no runner, corrigido antes da aplicação.
