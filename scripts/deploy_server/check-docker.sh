#!/usr/bin/env bash
# -------------------------------------------
# Specialist: check-docker
# Summary: Daemon Docker, grupo, pool de redes + teste real network create/rm
# -------------------------------------------
# Valida saúde do Docker daemon e capacidade de criar redes — cobre o problema
# mais recorrente do chat ICI (apareceu em 2 VMs distintas, 19/03 e 27/03):
# daemon.json com default-address-pools de uma /24 única, esgotando o pool.
#
# Checks:
#   - docker info responde (daemon acessível)
#   - systemctl is-active docker (se systemd disponível)
#   - usuário corrente no grupo docker
#   - /var/run/docker.sock existe
#   - daemon.json: pool size sane (se configurado)
#   - TESTE REAL: docker network create teste && rm teste (gold standard)
# -------------------------------------------

set -uo pipefail

SPECIALIST_NAME="check-docker"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./_common.sh
source "$SCRIPT_DIR/_common.sh"

usage() {
    cat <<EOF
Uso: bash $(basename "$0") [--quiet | --json] [--help]

Verifica saúde do Docker daemon e capacidade de criar redes.

Exit code: 0 = OK · 1 = FAIL · 2 = uso inválido
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        *)
            if common_parse_arg "$@"; then shift "$shift_count"
            else echo "argumento desconhecido: $1" >&2; usage >&2; exit 2; fi
            ;;
    esac
done

command -v docker >/dev/null 2>&1 || fail "docker não está instalado (rode check-deps primeiro)"

CAT_DAEMON="Daemon"
CAT_PERMS="Permissões"
CAT_POOL="Pool de redes (daemon.json)"
CAT_NETWORK="Teste real de criação de rede"

# Daemon acessível
print_category_header "$CAT_DAEMON" "Docker daemon acessível e serviço systemd ativo — pré-requisito de tudo."
if docker info >/dev/null 2>&1; then
    server_ver=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "desconhecida")
    add_ok "$CAT_DAEMON" daemon 0 "docker info" "server $server_ver"
else
    add_fail "$CAT_DAEMON" daemon 0 "docker info" "daemon não acessível — veja systemd status / grupo docker / socket"
fi

# Serviço systemd (se disponível)
if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet docker 2>/dev/null; then
        add_ok "$CAT_DAEMON" systemd 0 "systemctl is-active docker" "ativo"
    else
        # Em WSL não há systemd; só reporta FAIL se systemctl está acessível e responde 'inactive'
        if systemctl status docker >/dev/null 2>&1; then
            add_fail "$CAT_DAEMON" systemd 0 "systemctl is-active docker" "serviço inativo — sudo systemctl start docker"
        else
            warn "systemd não está acessível neste host — pulando check de serviço"
        fi
    fi
fi

# Socket
print_category_header "$CAT_PERMS" "Acesso do usuário corrente ao daemon Docker via socket + grupo."
if [ -S /var/run/docker.sock ]; then
    add_ok "$CAT_PERMS" socket 0 "/var/run/docker.sock" "presente"
else
    add_fail "$CAT_PERMS" socket 0 "/var/run/docker.sock" "ausente — daemon não foi iniciado"
fi

# Usuário NÃO-root (Fase 2 do siscan-server-setup.sh + restrição do runner GitHub Actions)
# O config.sh do runner recusa instalação como root. Specialists e doctor devem
# rodar como o mesmo usuário não-root (siscan, por convenção do setup).
current_user="$(whoami)"
current_uid=$(id -u)
if [ "$current_uid" -eq 0 ]; then
    add_fail "$CAT_PERMS" user 0 "user atual" "root (uid=0) — GitHub Actions runner recusa rodar como root; faça setup como usuário dedicado (ex: 'siscan')"
else
    add_ok "$CAT_PERMS" user 0 "user atual" "$current_user (uid=$current_uid, não-root)"
fi

# Grupo docker
if id -nG "$current_user" 2>/dev/null | grep -qw docker; then
    add_ok "$CAT_PERMS" group 0 "grupo docker (user $current_user)" "membro"
else
    add_fail "$CAT_PERMS" group 0 "grupo docker (user $current_user)" "não membro — sudo usermod -aG docker $current_user (logout/login depois)"
fi

# Pool de redes via daemon.json
# Caso real (chat ICI 19/03 + 27/03): { "default-address-pools": [{"base": "192.168.4.0/24", "size": 24}] }
# Esse pool tem 1 subnet só, já ocupada pela bridge bip → falha ao criar redes novas.
print_category_header "$CAT_POOL" "Verifica config do daemon.json — pool /24 único é o problema mais recorrente do chat ICI (TROUBLESHOOTING Servidor #1)."
DAEMON_JSON=/etc/docker/daemon.json
if [ -f "$DAEMON_JSON" ]; then
    if command -v jq >/dev/null 2>&1 && jq -e . "$DAEMON_JSON" >/dev/null 2>&1; then
        pools=$(jq -c '.["default-address-pools"] // []' "$DAEMON_JSON")
        pool_count=$(echo "$pools" | jq 'length')
        if [ "$pool_count" -eq 0 ]; then
            add_ok "$CAT_POOL" config 0 "default-address-pools" "ausente (usando default do Docker — 172.17.0.0/16)"
        else
            risky=false
            for i in $(seq 0 $((pool_count - 1))); do
                base=$(echo "$pools" | jq -r ".[$i].base")
                size=$(echo "$pools" | jq -r ".[$i].size // 24")
                # Pool "restrito" = base /24 com size 24 = 1 subnet só, ocupada pela bip
                base_cidr=$(echo "$base" | grep -oE '/[0-9]+$' | tr -d '/')
                if [ -n "$base_cidr" ] && [ "$base_cidr" -ge "$size" ]; then
                    risky=true
                    add_fail "$CAT_POOL" config 0 "pool $base size=$size" "pool /$base_cidr cabe ≤ 1 subnet /$size — ESGOTADO pela bridge bip — TROUBLESHOOTING Servidor #1"
                fi
            done
            $risky || add_ok "$CAT_POOL" config 0 "default-address-pools" "$pool_count pool(s) — pelo menos uma subnet disponível"
        fi
    else
        warn "daemon.json existe mas não é JSON válido (ou jq indisponível) — pulando análise do pool"
    fi
else
    add_ok "$CAT_POOL" config 0 "daemon.json" "não configurado (padrão Docker)"
fi

# Listar redes Docker existentes + subnets (P2)
# Útil pra diagnosticar conflitos de pool (sub-rede já em uso) antes do
# 'network create' falhar.
print_category_header "Redes Docker existentes" "Inventário de redes e sub-redes em uso — diagnóstico complementar pra conflitos de pool."

CAT_NETLIST="Redes Docker existentes"
net_count=0
while IFS= read -r net_id; do
    [ -z "$net_id" ] && continue
    net_name=$(docker network inspect "$net_id" --format '{{.Name}}' 2>/dev/null)
    net_subnet=$(docker network inspect "$net_id" --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null | xargs)
    if [ -n "$net_subnet" ]; then
        add_ok "$CAT_NETLIST" net 0 "$net_name" "subnet: $net_subnet"
    else
        add_ok "$CAT_NETLIST" net 0 "$net_name" "(sem IPAM config — provavelmente bridge default ou none)"
    fi
    net_count=$((net_count + 1))
done < <(docker network ls -q 2>/dev/null)

[ "$net_count" -eq 0 ] && add_ok "$CAT_NETLIST" net 0 "(nenhuma)" "nenhuma rede encontrada"

# TESTE REAL: criar e remover network. Esse é o gold standard — passa exatamente
# o cenário do chat ICI (docker network create teste falhando com address pool esgotado).
print_category_header "$CAT_NETWORK" "Gold standard: cria e remove uma rede de teste. Se passar aqui, o pool funciona; se falhar, o erro real aparece embaixo."
TEST_NET="siscan-check-$$"
if docker network create "$TEST_NET" >/dev/null 2>&1; then
    docker network rm "$TEST_NET" >/dev/null 2>&1 || warn "criou mas falhou ao remover $TEST_NET"
    add_ok "$CAT_NETWORK" net 0 "docker network create/rm" "OK"
else
    err_msg=$(docker network create "$TEST_NET" 2>&1 | tail -1 | head -c 120)
    add_fail "$CAT_NETWORK" net 0 "docker network create/rm" "falhou: $err_msg"
fi

render_results
finalize_exit
