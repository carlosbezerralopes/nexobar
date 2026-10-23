# Estado de validação

Última verificação local: 23/10/2026. Esta matriz descreve evidências obtidas; não é uma garantia de compatibilidade com todas as máquinas ou versões dos clientes.

| Entrega | Evidência | Limite |
|---|---|---|
| macOS 0.3.1 | 156 testes Swift aprovados; bundle arm64 assinado localmente; sensores e consulta Claude verificados em Apple M5 Pro | Outros chips, Intel, notarização e lojas não verificados |
| Claude macOS | PTY temporário consultou janelas reais e encerrou seus processos; parser, refresh, datas, bloqueios e lifecycle cobertos por fixtures | Painel textual depende da versão do cliente; não valida Windows |
| Windows 0.4.0 | 148 checks do núcleo; WPF win-x64 autocontido compilado no Mac | Execução física de GUI, sensores, ConPTY, transparência, maximização e bandeja pendente |
| Ponte WidBar | 20 checks de protocolo/política, incluindo pipe real do mesmo usuário e transições offline | ACL entre usuários e integração Windows precisam de validação nativa |
| Companion WidBar | Biblioteca C# compilada contra WidBar.SDK2.1.0 e WindowsAppSDK2.3.1 | XAML, MSIX, assinatura, instalação e host Windows pendentes |

O teste de comunicação por pipe requer um ambiente que permita sockets locais; o sandbox que bloqueou essa comunicação não foi tratado como sucesso. Os checks passaram fora dessa restrição, usando apenas dados sintéticos.

Os pacotes ficam em `dist/`, fora do controle de versão. O build produz manifesto SHA256 do conteúdo. No Windows, use [smoke-windows.ps1](windows/scripts/smoke-windows.ps1); consultas reais de Claude são opt-in, separadas dos testes sintéticos.

Detalhamento: [matriz Windows](windows/docs/VALIDATION.md), [Claude macOS](docs/CLAUDE-USAGE-MAC.md), [ConPTY](windows/docs/CLAUDE-CONPTY.md) e [WidBar](windows/widbar/README.md).

O aplicativo não altera a ocultação da barra do macOS. O problema histórico de reaparecimento do menu em tela cheia não é declarado corrigido.
