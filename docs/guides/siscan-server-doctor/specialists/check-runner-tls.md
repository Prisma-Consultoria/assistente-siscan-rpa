# check-runner-tls

Specialist de **diagnóstico estruturado de TLS** para o GitHub Actions self-hosted runner.

| Item | Valor |
|---|---|
| Arquivo | [`scripts/deploy_server/check-runner-tls.sh`](../../../../scripts/deploy_server/check-runner-tls.sh) |
| Origem | [TSK00.04.05 #82](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/82) (helper) + [TSK00.04.08 #87](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/87) (extensão DNS+curl) + [TSK00.04.10 #89](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/89) (extração como specialist) |
| Helper canônico | `runner_diagnose_tls_failure` em [`scripts/deploy_server/_runner.sh`](../../../../scripts/deploy_server/_runner.sh) |
| Modos | `--pre-flight` (proativo) e `--reactive` (pós-falha) |

## Propósito

Tornar **descobrível e reaproveitável** a lógica de diagnóstico TLS que originalmente vivia inline em `_runner.sh` como helper invocado por `runner_register`. Com o specialist, o operador pode:

- Diagnosticar TLS **antes** de tentar registrar o runner (`--pre-flight`)
- Diagnosticar TLS **depois** de uma falha de `runner_register` (`--reactive`)
- Invocar via doctor (`bash siscan-server-doctor.sh --only check-runner-tls`)
- Invocar standalone para troubleshooting (`bash scripts/deploy_server/check-runner-tls.sh --pre-flight`)

Mantém o helper `runner_diagnose_tls_failure` em `_runner.sh` como fonte de verdade — specialist é wrapper que reaproveita.

## Modos

### `--pre-flight` (default — invocado pelo doctor sem argumentos extras)

Diagnóstico **proativo** do ambiente — não requer log do runner, pode rodar a qualquer momento:

- `[2]` Variáveis de proxy/http no env (com redação de userinfo `***:***@`)
- `[3]` CAs custom em `/usr/local/share/ca-certificates/`
- `[4]` Resolução DNS de `api.github.com`

Subset das 6 seções do diagnóstico completo — as 3 outras seções (`[1]` log, `[5]` triagem, `[6]` curl reachability) dependem do log do runner que só existe pós-tentativa de registro.

### `--reactive [RUNNER_DIR]`

Diagnóstico **completo** pós-falha (6 seções estáveis) — delega ao helper canônico `runner_diagnose_tls_failure` em `_runner.sh`:

| Seção | Conteúdo |
|---|---|
| `[1]` | `tail -100` do `_diag/Runner_*.log` mais recente (com redação de token-like paths) |
| `[2]` | Variáveis de proxy (com redação de credenciais) |
| `[3]` | CAs custom em `/usr/local/share/ca-certificates/` |
| `[4]` | DNS de `api.github.com` + endpoint extraído do log (quando disponível) |
| `[5]` | Triagem por padrão conhecido do .NET (CA bundle / DNS-IPv6 / proxy / firewall EOF) |
| `[6]` | Teste de alcance direto via `curl -k` ao URL extraído de `[5]` |

`RUNNER_DIR` default: `$HOME/actions-runner`.

## Invocação

### Standalone (operador)

```bash
# Pre-flight (validação preventiva, antes de tentar registrar)
bash scripts/deploy_server/check-runner-tls.sh --pre-flight

# Reactive (após config.sh falhar)
bash scripts/deploy_server/check-runner-tls.sh --reactive ~/actions-runner
```

### Via doctor

```bash
# Específico
bash siscan-server-doctor.sh --only check-runner-tls

# Como parte da bateria completa
bash siscan-server-doctor.sh

# Lista todos (vê o specialist na descoberta)
bash siscan-server-doctor.sh --list
```

### Invocação automática (de `runner_register`)

Quando `config.sh --unattended --replace` falha durante `runner_register`, o helper `_runner.sh:runner_register` **delega ao specialist** em modo `--reactive`:

```bash
# Pseudo-código de runner_register
if ! (cd "$dir" && ./config.sh ...); then
    printf "Falha ao registrar o runner. ...\n" >&2
    if [ -x "$script_dir/check-runner-tls.sh" ]; then
        bash "$script_dir/check-runner-tls.sh" --reactive "$dir" || true
    else
        runner_diagnose_tls_failure "$dir"   # fallback inline
    fi
    return 1
fi
```

**Fallback gracioso**: se o specialist não estiver presente (ex.: VM com versão antiga do assistente), invoca o helper inline. Preserva backward compatibility e ordem de operação.

## Saída exemplo (`--pre-flight`)

```
══════════════════════════════════════════════════
  CHECK-RUNNER-TLS — modo pre-flight
══════════════════════════════════════════════════

[2] Variáveis de proxy/http:
    (nenhuma variável de proxy definida no ambiente)

[3] CAs custom em /usr/local/share/ca-certificates/:
    (diretório vazio — nenhuma CA custom instalada)

[4] Resolução DNS de api.github.com:
    4.228.31.149    api.github.com

══════════════════════════════════════════════════
  FIM DO PRE-FLIGHT
══════════════════════════════════════════════════

Para diagnóstico completo (após tentar registrar e falhar):
  bash check-runner-tls.sh --reactive /home/siscan/actions-runner
```

## Saída exemplo (`--reactive`)

Ver [`docs/guides/siscan-runner-recover.md`](../../siscan-runner-recover.md) seção "Diagnóstico TLS automático na falha de `runner_register`" para o output completo das 6 seções com exemplo real do lab #259.

## Exit code

| Code | Significado |
|---|---|
| `0` | Diagnóstico emitido (sempre — best-effort) |
| `2` | Uso inválido ou `RUNNER_DIR` ausente em `--reactive` |

O exit code é **sempre 0** em ambos os modos quando os argumentos são válidos. O diagnóstico é informativo, não bloqueante por design — o caller (geralmente `runner_register`) é quem decide o exit code da operação.

## Decisão arquitetural: por que specialist, não helper inline?

A decisão de extrair `runner_diagnose_tls_failure` para um specialist (TSK00.04.10) é motivada pelo padrão arquitetural do projeto:

1. **Specialists detêm o "como diagnosticar"; orquestradores invocam, módulos compartilhados não duplicam.** O helper inline em `_runner.sh` violava esse padrão.

2. **Descobribilidade via doctor** — operador roda `bash siscan-server-doctor.sh --only check-runner-tls --json` para coletar dados antes de abrir ticket, sem precisar conhecer um helper escondido em biblioteca.

3. **Reaproveitamento em modo proativo** — `--pre-flight` cobre cenário "operador suspeita que algo está errado e quer diagnosticar sem precisar quebrar primeiro".

4. **Single Responsibility** — `_runner.sh` é "lifecycle do runner" (download, register, install, start, stop, remove). Diagnóstico TLS pós-falha é tarefa ortogonal.

A fonte de verdade da lógica (234 linhas com extração de URL, triagem, redação de tokens, curl reachability) permanece em `_runner.sh:runner_diagnose_tls_failure`. O specialist é um wrapper que adiciona o modo `--pre-flight` e expõe a função via doctor.

## Testes

Cobertura em [`tests/unit/test_check_runner_tls_specialist.bats`](../../../../tests/unit/test_check_runner_tls_specialist.bats) — 15 cenários:

- Modo `--pre-flight`: header, seções [2]/[3]/[4], hint para `--reactive`, rc=0
- Default (sem args) → `--pre-flight` (descoberta via doctor)
- Modo `--reactive`: delega ao helper de 6 seções, erro com exit 2 quando dir inexistente, default `$HOME/actions-runner`
- Argparse: `--help`, `--runner-dir`, mensagem clara em argumento desconhecido
- Integração: doctor `--list` inclui, doctor `--only check-runner-tls` executa

Helper canônico continua coberto por [`tests/unit/test_runner_diagnose_tls_failure.bats`](../../../../tests/unit/test_runner_diagnose_tls_failure.bats) — 37 cenários cobrindo as 6 seções estáveis, redação de tokens/credenciais, casos edge.

## Ver também

- [`../../siscan-runner-recover.md`](../../siscan-runner-recover.md) — guia do `siscan-runner-recover.sh` que herda o diagnóstico via `runner_register`
- [`../index.md`](../index.md) — guia geral do `siscan-server-doctor.sh`
- [`check-network.md`](check-network.md) — specialist gêmeo que valida endpoints HTTPS/TCP
- [`../../../../scripts/deploy_server/_runner.sh`](../../../../scripts/deploy_server/_runner.sh) — `runner_diagnose_tls_failure` helper canônico
- [TSK00.04.10 #89](https://github.com/Prisma-Consultoria/assistente-siscan-rpa/issues/89) — TSK que motivou a extração
