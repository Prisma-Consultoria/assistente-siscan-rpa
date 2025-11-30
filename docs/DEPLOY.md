# Documentação de Deploy - Assistente SISCAN RPA

Versão: 1.0
Data: 2025-11-30

## **Introdução**

**O que é o Assistente SISCAN RPA**

O Assistente SISCAN RPA é uma aplicação empacotada em containers Docker destinada a automatizar fluxos relacionados ao sistema SISCAN. A aplicação processa laudos, gera manifestos, organiza downloads e expõe endpoints locais de monitoramento.

**O que ele faz**
- Extrai e processa laudos e documentos.
- Gera arquivos de manifesto e relatórios.
- Persiste arquivos de entrada/saída e logs em volumes Docker mapeados no host.
- Pode expor uma API ou painel HTTP para verificação de saúde e status.

**Requisitos mínimos de hardware e software**
- CPU: 2 vCPU (produção: 4+ vCPU)
- RAM: 4 GB (produção: 8+ GB)
- Disco: 20 GB livres (mais conforme volume de dados)
- Windows 10/11 Pro ou Windows Server 2019+ com WSL2 ou Hyper-V habilitado
- Docker Desktop (20.10+) com Docker Compose integrado (v2)
- PowerShell 7+ (recomendado) ou PowerShell 5.1
- Conectividade com `ghcr.io` (porta 443)

**Perfis de usuários envolvidos**
- Operador: executa o deploy e opera o serviço (Nível 1)
- Administrador Windows: configura host, permissões e rede
- DevOps/Infra: gerencia imagens no GHCR, tokens e pipelines
- Suporte N2/N3: troubleshooting avançado e recuperação

---

## **Estrutura do Ambiente**

### **Componentes técnicos**

- **Docker:** Engine que executa os containers.
- **Docker Compose:** Orquestra serviços e volumes via `docker-compose.yml`.
- **GitHub Container Registry (GHCR):** onde as imagens estão hospedadas (`ghcr.io/<org>/assistente-siscan-rpa:<tag>`).
- **Script PowerShell:** auxiliar para autenticar, puxar imagens e executar compose (não incluiremos scripts neste repositório por hora).
- **Repositório público (IEX/git):** código fonte e artefatos públicos usados para instalar/configurar.
- **Repositório privado de imagem:** GHCR privado para imagens oficiais do produto.
- **Chave/token de acesso:** Personal Access Token (PAT) com permissão `read:packages` para pull de imagens privadas.

### **Arquitetura do deploy (fluxo)**

1. O operador executa o workflow de deploy (manual ou via script).
2. Autenticação no GHCR (`docker login ghcr.io`) com token.
3. Pull da(s) imagem(ns) necessárias.
4. `docker compose up -d` para criar containers, redes e volumes.
5. Containers inicializam e se conectam a recursos locais (volumes, portas, redes).

**Comunicação entre peças**
- PowerShell → Docker CLI (execução de comandos)
- Docker Engine ↔ GHCR (HTTPS TLS) para pull/push
- Containers ↔ Volumes (persistência em host)
- Containers ↔ Rede bridge ou rede customizada do Docker (acesso a portas)

**Locais de arquivos e logs (exemplo recomendado)**
- Código e compose: `C:\assistente-siscan\` (Windows)
- Downloads/processados: `C:\assistente-siscan\media\downloads\`
- Logs: `C:\assistente-siscan\logs\`
- Volumes Docker: nomes declarados em `docker-compose.yml` (ex.: `assistente_data`)

---

## **Pré-requisitos antes do deploy**

> Antes de iniciar, confirme que você tem: usuário com privilégios locais (administrador recomendado), token GHCR com `read:packages`, e acesso à rede para `ghcr.io`.

### **3.1 Docker**

- Instalação:
  - Baixe Docker Desktop: https://www.docker.com/get-started
  - Siga o instalador e habilite WSL2 (Windows Home) ou Hyper-V (Pro/Enterprise/Server).
- Verificação:
```powershell
docker version
docker info
```
- Configurações recomendadas:
  - Resources: CPU 2+, RAM 4GB+, Swap 1GB+
  - Enable WSL2 integration se disponível
  - Ajustar compartilhamento de drives (C:) se volumes bind forem usados

### **3.2 Docker Compose**

- Verificação:
```powershell
docker compose version
docker compose config
```
- Teste sem script:
```powershell
docker compose pull
docker compose config --quiet
docker compose up -d
docker compose ps
```

### **3.3 Windows**

- Virtualização:
  - `systeminfo` e procurar por ‘Virtualization’ ou usar `Get-ComputerInfo`.
- WSL2 vs Hyper-V:
  - WSL2 recomendado em Windows Home; Hyper-V pode ser usado em Pro/Server.
- Diferenças por edição do Windows:
  - Home: somente WSL2; Pro/Ent: Hyper-V disponível.

### **3.4 Rede e Internet**

- DNS:
```powershell
nslookup ghcr.io
Resolve-DnsName ghcr.io
```
- Conectividade:
```powershell
Test-NetConnection ghcr.io -Port 443
curl -v https://ghcr.io/v2/
```
- Proxy / Firewall / SSL:
  - Se existir proxy corporativo, configurar `HTTP_PROXY`/`HTTPS_PROXY` no Docker Desktop e no ambiente.
  - Para inspeção TLS (SSL intercept), importar CA corporativa no Windows e no Docker.

### **3.5 Permissões**

- Políticas do PowerShell:
```powershell
Get-ExecutionPolicy
Set-ExecutionPolicy RemoteSigned -Scope LocalMachine   # (Admin)
```
- Permissões de pasta:
```powershell
icacls C:\assistente-siscan /grant "Administradores:(OI)(CI)F" /T
```
- Grupo Docker:
  - Adicionar usuários ao `docker-users` local se o Docker Desktop criou esse grupo.
- Acesso GHCR:
  - Token com `read:packages`; não salvar em repositório.

---

## **Passo a Passo Completo do Deploy**

Siga estas etapas em ambiente de teste antes da produção.

1) Preparação do diretório

```powershell
mkdir C:\assistente-siscan
cd C:\assistente-siscan
```

2) Obter arquivos de deploy

- Opção com `git`:
```powershell
git clone https://github.com/<org>/assistente-siscan-rpa.git .
```
- Opção sem `git`: baixar `docker-compose.yml`, `README.md` e arquivos de configuração do repositório oficial.

3) Criar arquivo de variáveis `.env` com base no arquivo `.env.sample`.

4) Autenticar no GHCR

```powershell
docker login ghcr.io -u <usuario> -p <token>
```

5) Pull das imagens

```powershell
docker compose pull
```

6) Verificar imagens

```powershell
docker images | Where-Object { $_.Repository -like '*assistente*' }
docker image inspect ghcr.io/<org>/assistente-siscan-rpa:<tag>
```

7) Subir serviços

```powershell
docker compose up -d
docker compose ps
```

8) Validar serviço

```powershell
Invoke-WebRequest -UseBasicParsing http://localhost:8080/health
docker compose logs -f
```

9) Checklist rápido pós-deploy

- `docker compose ps` → containers Up
- `docker compose logs` sem erros críticos
- Health endpoint retorna 200
- Volumes e diretórios no host com permissões corretas

---

## **Operações diárias**

- Reiniciar serviço:
```powershell
cd C:\assistente-siscan
docker compose restart
```
- Atualizar imagem e redeploy:
```powershell
docker login ghcr.io -u <user> -p <token>
docker pull ghcr.io/<org>/assistente-siscan-rpa:<tag>
docker compose down
docker compose up -d
```
- Verificar logs:
```powershell
docker compose logs -f
docker logs <container> --since 10m --tail 200
```
- Limpar imagens antigas (cautela):
```powershell
docker image prune -a
docker system prune -a
```
- Inspecionar volumes:
```powershell
docker volume ls
docker volume inspect <volume>
docker run --rm -v <volume>:/data -it mcr.microsoft.com/dotnet/runtime ls -la /data
```

---

## **Troubleshooting (visão geral)**

Uma seção resumida de problemas e comandos diagnósticos:

- `docker info` — estado do daemon
- `docker compose config` — validação do compose
- `docker logs <container>` — logs do container
- `Test-NetConnection ghcr.io -Port 443` — conectividade com GHCR
- `nslookup ghcr.io` — resolução DNS

Para troubleshooting detalhado, veja `docs/TROUBLESHOOTING.md`.

---

## **Boas práticas**

- Não commitar tokens ou segredos.
- Usar arquivos `.env` locais ou secret managers.
- Versionar imagens com tags sem `latest` como única referência.
- Rotina de backups para volumes críticos.
- Monitoramento e alertas (Prometheus/Grafana/ELK).

---

## **Conclusão**

Este documento é a referência central para o deploy do Assistente SISCAN RPA. Complementos importantes:
- Troubleshooting detalhado: `docs/TROUBLESHOOTING.md`
- Tabela de erros e soluções: `docs/ERRORS_TABLE.md`
- Checklists operacionais: `docs/CHECKLISTS.md`

Mantenha este manual atualizado conforme novas versões e práticas.
