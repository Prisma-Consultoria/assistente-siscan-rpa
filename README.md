# Assistente SISCan RPA
**Assistente SISCan RPA — Instalador remoto**

Este repositório contém um instalador remoto modular (PowerShell + Bash) para instalar, atualizar e gerenciar o serviço "Assistente SISCan RPA".

**Resumo**
- **Objetivo:** fornecer um instalador extremamente simples para usuários finais (não técnicos) que:
	# Assistente SISCan RPA

	Uma coleção de scripts (PowerShell + Bash) para instalar, atualizar e gerenciar o serviço Assistente SISCan RPA de forma guiada — pensada para usuários técnicos e não técnicos.

	**Conteúdo deste README**
	- **Visão geral**
	- **Pré-requisitos**
	- **Instalação rápida**
	- **Configuração (`.env`)**
	- **Estrutura do repositório**
	- **Como funciona**
	- **Resolução de problemas (troubleshooting)**

	## Visão geral

	O instalador solicita as informações necessárias (token para registry, credenciais SISCAN, caminhos de diretórios) e cria/atualiza os serviços Docker via `docker-compose`.

	Para usuários não técnicos: você só precisa fornecer algumas informações básicas e criar pastas no Windows quando solicitado. O instalador trata do resto.

	## Pré-requisitos

	- Docker Desktop (Windows) ou Docker Engine (Linux/macOS).
	- Docker Compose (v2 integrado ao Docker Desktop ou `docker-compose`).
	- Acesso à internet para baixar imagens e módulos, ou acesso ao registry privado com token.

	## Instalação rápida

	- Windows (PowerShell):

	```powershell
	irm "https://raw.githubusercontent.com/Prisma-Consultoria/assistente-siscan-rpa/main/install.ps1" | iex
	```

	- Linux / macOS (Bash):

	```bash
	curl -sSL https://raw.githubusercontent.com/Prisma-Consultoria/assistente-siscan-rpa/main/install.sh | bash
	```

	Se preferir inspecionar os scripts antes de executar, clone este repositório e execute `install.ps1` / `install.sh` localmente.

	## Configuração (`.env`)

	1) Copie o arquivo de exemplo:

	```bash
	cp .env.sample .env
	```

	2) Preencha os campos necessários (em especial os marcados como OBRIGATÓRIO):

	- `SISCAN_USER` e `SISCAN_PASSWORD`: credenciais do SISCAN (obrigatório).
	- `HOST_MEDIA_ROOT`: pasta no Windows onde serão salvos screenshots, vídeos e downloads (ex.: `C:\siscan\media`).
	- `HOST_DOWNLOAD_DIR`: pasta de downloads do Playwright (ex.: `C:\siscan\media\downloads`).
	- `HOST_SISCAN_REPORTS_INPUT_DIR`: pasta onde os PDFs de entrada ficam (ex.: `C:\siscan\reports\input`).
	- `HOST_SISCAN_REPORTS_OUTPUT_DIR`: pasta onde serão gerados os JSON/Excel (ex.: `C:\siscan\reports\output`).
	- `HOST_SISCAN_CONSOLIDATED_REPORT_PATH`: pasta/arquivo opcional para consolidados (ex.: `C:\siscan\reports\`).
	- `HOST_EXCEL_COLUMNS_MAPPING_PATH`: caminho para um arquivo JSON opcional de mapeamento de colunas (ex.: `C:\siscan\config\excel_columns_mapping.json`).

	Observações para não técnicos:
	- Use caminhos do Windows (ex.: `C:\siscan\media`) quando executando no Windows. Se usar WSL, também funciona com caminhos `/mnt/c/...` dependendo da sua configuração do Docker.
	- Se não souber algum valor, peça ao time de infraestrutura ou deixe em branco temporariamente e solicite ajuda.

	## Comandos úteis

	- Para iniciar os serviços manualmente (quando o `docker-compose.yml` já existir):

	```bash
	docker compose up -d
	```

	- Para ver logs:

	```bash
	docker compose logs -f
	```

	## Estrutura do repositório

	- `install.ps1` / `install.sh`: bootstrap que interage com o usuário e baixa módulos.
	- `scripts/modules/`: módulos que executam tarefas (docker, siscan, etc.).
	- `docker-compose.yml`: gerado pelo instalador quando necessário.
	- `.env.sample`: exemplo de variáveis de ambiente (copiar e preencher como `.env`).

	## Como funciona (resumo técnico)

	- O bootstrap baixa módulos em `scripts/modules/` e executa o fluxo.
	- Módulos são cacheados localmente para execução offline/recuperação.
	- Credenciais e tokens são solicitados via entrada segura (não são gravados em texto puro nos logs).

	## Troubleshooting básico

	- Erro: `docker` não encontrado — instale Docker Desktop (Windows) ou Docker Engine (Linux).
	- Erro: `docker compose` não encontrado — instale a versão compatível do Compose.
	- Erro no `docker login` — verifique o token/usuário e permissões do registry.
	- Problema de permissões em pastas (Windows): execute o PowerShell como Administrador ou ajuste permissões das pastas indicadas em `HOST_*`.

	## Boas práticas e próximos passos

	- Use tokens de acesso com escopo mínimo (apenas pull) para o registry privado.
	- Considere adicionar verificação de integridade (SHA256) para os módulos baixados.
	- Podemos adicionar suporte específico para registries (GHCR, ACR, ECR) caso precise.

	## Contato / Ajuda

	Se quiser, eu posso:
	- Gerar um `.env` de exemplo com valores preenchidos;
	- Verificar o `docker-compose.yml` e ajustar mapeamentos `HOST_*`;
	- Implementar verificação de assinatura/SHA para módulos.

	---

	Repositório da imagem principal (referência): https://github.com/Prisma-Consultoria/siscan-rpa

Este repositório atua apenas como **instalador, configurador e gerenciador** do SISCan-RPA.

	## Documentação de Deploy e Operação

	Este repositório agora inclui documentação completa para deploy, operação e troubleshooting do Assistente SISCAN RPA. Os documentos estão em `docs/`:

	- `docs/DEPLOY.md` — Manual completo de deploy: introdução, arquitetura, pré-requisitos e passo a passo.
	- `docs/TROUBLESHOOTING.md` — Guia aprofundado de troubleshooting com comandos e árvores de decisão.
	- `docs/ERRORS_TABLE.md` — Tabela extensa de erros comuns (causa provável e solução).
	- `docs/CHECKLISTS.md` — Checklists operacionais (antes, depois e emergência).

	Consulte esses documentos para procedimentos passo a passo e fluxos de diagnóstico.
