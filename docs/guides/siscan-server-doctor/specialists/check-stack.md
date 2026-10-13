# check-stack — categorias com prazo

Este guia cobre as verificações do `check-stack` que fazem perguntas ao Docker e por isso precisam de prazo: se o contêiner aceita comando, por que o healthcheck reprova, quantos processos ele tem, se há cliente `docker exec` preso no host e se o daemon responde. As demais verificações (compose file, imagem, serviços, restart loop, portas) estão descritas no [guia do doctor](../index.md#check-stack--compose-ps--exec--daemon--port-collision--restart-loop).

| Item | Valor |
|---|---|
| Arquivo | [`scripts/deploy_server/check-stack.sh`](../../../../scripts/deploy_server/check-stack.sh) |
| Origem | [#116](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/116) |
| Testes | [`tests/unit/test_check_stack_exec_health.bats`](../../../../tests/unit/test_check_stack_exec_health.bats) |

## Por que estas verificações existem

Em 13/10/2026, o deploy de produção do `siscan-rpa` ficou 6 horas preso em dois passos que chamavam `docker compose exec -T app`. Enquanto isso, o `app` aparecia como `running` e respondia `GET /health` com HTTP 200, e o `exec` no `rpa-scheduler` funcionava. O `check-stack` da época só dizia `healthcheck: fail`, sem o porquê, e nada nele separava "contêiner de pé" de "contêiner que aceita comando". A investigação está em [siscan-rpa#1915](https://github.com/Prisma-Consultoria/siscan-rpa/issues/1915).

Um diagnóstico que fala com o Docker sem prazo trava junto com o que ele diagnostica. Por isso cada verificação desta página roda sob `timeout`.

## Prazos

Os três valores ficam declarados no topo do script, e o ambiente os sobrescreve:

| Variável | Default | Usada em |
|---|---|---|
| `SISCAN_STACK_EXEC_TIMEOUT` | 15 s | `docker compose exec -T <serviço> true` |
| `SISCAN_STACK_DOCKER_TIMEOUT` | 10 s | `docker inspect`, `docker top`, `docker info`, `systemctl is-active docker` |
| `SISCAN_STACK_EXEC_STALE_SECONDS` | 900 s | Idade a partir da qual um cliente `docker exec` no host reprova |

Quando o prazo estoura, o `timeout` manda `TERM` e, depois de alguns segundos, `KILL` (`timeout -k`).

## Categorias

| Categoria | Target | Aprova quando | Reprovação, e o que ela quer dizer |
|---|---|---|---|
| `Saúde dos containers` | `healthcheck` | Nenhum contêiner `unhealthy` | `unhealthy: <contêiner> (FailingStreak=N, última tentativa exit=X: <saída>)`, um por contêiner, separados por `;`. O `exit=-1` com `Health check exceeded timeout` indica que o próprio healthcheck não terminou: o Docker roda o healthcheck como um `exec` dentro do contêiner. |
| `Exec nos containers` | `service <nome>` | O `exec` terminou dentro do prazo | `exec não respondeu em Ns`: o contêiner está de pé mas não aceita comando. Todo `docker compose exec` nele (backup, diagnóstico, healthcheck) vai travar. Serviço que não está `running` sai como `skipped`. |
| `Processos nos containers` | `service <nome>` | `docker top` respondeu e nenhum processo está `defunct` | `N processo(s), M defunct`: há processos zumbis que nenhum processo recolhe. `docker top não respondeu` é falha do próprio daemon ao listar o contêiner. |
| `Processos no host` | `docker exec` | Nenhum cliente `docker exec` / `docker compose exec` mais velho que o limite | `N cliente(s) exec vivo(s) há mais de Ss; o mais antigo (PID P) há Ts`. Só saem PID e idade, porque a linha de comando pode carregar `-e VAR=valor`. Para ver o comando, rode `ps -o args= -p P` no host. |
| `Daemon Docker` | `docker info` | O daemon respondeu dentro do prazo | `não respondeu em Ns`: o daemon está travado ou sobrecarregado, e as outras verificações tendem a reprovar junto. |
| `Daemon Docker` | `systemctl docker` | `active` (só com systemd) | `estado: <estado>`. |

## Como rodar

```bash
bash siscan-server-doctor.sh --only check-stack --product rpa
# prazos mais longos num servidor lento
SISCAN_STACK_EXEC_TIMEOUT=30 bash siscan-server-doctor.sh --only check-stack --product rpa
```

## O que este guia não cobre

- **Os comandos anteriores do specialist** (`docker compose config` e `docker compose ps`) continuam sem prazo. Se o daemon estiver travado, o specialist pode parar antes de chegar às verificações desta página. Quem chama o doctor deve impor um teto externo.
- **O motivo de o `exec` travar dentro do contêiner.** As verificações mostram o efeito e o processo cliente preso; a causa (processo principal, limite de PIDs, runtime) ainda exige olhar o host.
