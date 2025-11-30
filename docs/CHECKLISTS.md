# Checklists Operacionais - Assistente SISCAN RPA
<a name="checklists"></a>

Versão: 1.0
Data: 2025-11-30

## Checklist Antes do Deploy (staging / homologação primeiro)

- Backup: snapshot ou cópia dos volumes críticos.
- Credenciais: token GHCR válido com `read:packages` e credenciais SISCAN corretas.
- Acesso: usuário que executa o deploy é membro de `docker-users` e tem privilégios necessários.
- Docker: `docker version` e `docker info` sem erros.
- Docker Compose: `docker compose config` válido.
- Rede: `nslookup ghcr.io` e `Test-NetConnection ghcr.io -Port 443` OK.
- Espaço em disco: espaço livre >= requisito do ambiente.
- Variáveis: `.env` preenchido (não commitá-lo em VCS).
- Permissões: `icacls` nas pastas do projeto garantindo leitura/escrita.
- Janela de manutenção: notificar stakeholders e agendar downtime se necessário.

## Checklist Após Deploy

- Containers: `docker compose ps` → todos os serviços `Up`/`healthy`.
- Logs: `docker compose logs` sem erros novos críticos.
- Healthcheck: endpoint `/health` retorna `200`.
- Volumes: `docker volume ls` mostra volumes esperados.
- Usuário/teste: executar um teste funcional (fluxo principal do RPA) em staging/prod.
- Monitoramento: alertas/observability configurados (se aplicável).

## Checklist Antes de Atualizar/Upgrade

- Revisar o registro de alterações (changelog) e notas de release.
- Testar nova imagem em staging com tag específica.
- Backup de volumes e dados críticos.
- Planejar rollback: manter tag anterior disponível.
- Janela de atualização comunicada aos envolvidos.

## Checklist de Emergência / Rollback

- Ter disponível imagem/tag anterior: `ghcr.io/<org>/assistente-siscan-rpa:<previous_tag>`.
- Comandos rápidos para rollback:
```powershell
docker pull ghcr.io/<org>/assistente-siscan-rpa:<previous_tag>
docker compose down
docker compose up -d
```
- Coletar logs e artefatos (ver `docs/TROUBLESHOOTING.md` - solução de problemas)
- Informar time de DevOps e liberar canal de comunicação (telefone/pager)

---

> Mantenha estes checklists como referência rápida durante procedimentos de operação e emergência.
