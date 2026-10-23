# Evidência de build — Windows 0.6.0

Registro de 23/10/2026, posterior à geração dos pacotes. Núcleo: 261 checks; ponte, demonstrações e geometria: 105; descoberta Claude e ConPTY sintético: 83; instalador: 85. Total: 534 verificações aprovadas. WPF e WinUI/XAML compilaram nativamente com .NET SDK 10.0.402. O MSIX e o instalador foram gerados, assinados com o certificado local de teste e verificados. Integridade e confiança do payload incorporado passaram.

O diagnóstico do executável 0.6 retornou `/usage` com o PATH normal, sem `claude.exe` diretamente no PATH: três janelas recebidas, duas de conta e uma por modelo, em 10,5 segundos; nenhum Job próprio permaneceu ativo. Não houve login, alteração permanente do PATH, execução de shim ou concessão de confiança. Isso comprova a correção de descoberta do executável npm; o aplicativo 0.5 instalado não incluía essa descoberta.

As temperaturas físicas de CPU/GPU continuam indisponíveis ao coletor nesta máquina. Fixtures comprovam o controle visual quando há leitura e preservam ausência sem inventar zero.

SHA256 dos artefatos assinados:

- Setup: `9a5bb0fd682236e2892ae12af322d44a259d565b6888b27578808236e70b4fcd`.
- Companion MSIX: `9b2063106febe92d30872c42da6ebb08e2f8006fa22fbf0f65e1e8be54d98179`.

A instalação 0.6 e a medição do preview hospedado ainda não foram concluídas: a sessão gráfica ficou indisponível para controle/captura. Fixtures geométricas não comprovam ausência de corte ou oclusão externa na taskbar. A assinatura local de teste não equivale a reputação pública de distribuição.

Este registro complementa os documentos incorporados aos pacotes, que refletem as etapas anteriores à verificação final. Recursos e diferenças remanescentes estão em [PARITY-0.6.md](PARITY-0.6.md).
