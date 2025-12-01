

## 🛠️ Guia de Solução de Problemas do Assistente SISCAN RPA (Versão Simplificada)

Este guia ajuda a identificar e corrigir os problemas mais comuns durante a instalação ou operação do Assistente SISCAN RPA.

### **Regra de Ouro Antes de Começar**

Sempre anote o que aconteceu, a data e a hora do erro. Se precisar de ajuda mais avançada, envie o máximo de informações possível.

---

### 1. Verificações Rápidas e Coleta de Informações

Antes de tentar qualquer solução, vamos checar o status do seu sistema.

#### **A. Abra o Terminal de Comandos (PowerShell como Administrador)**

* **O que fazer:** Clique no menu Iniciar, digite `PowerShell`, clique com o botão direito em **Windows PowerShell** e escolha **Executar como administrador**.
* **Por que:** Muitos comandos de diagnóstico e correção precisam de permissões especiais.

#### **B. Colete as Informações Principais (Comandos)**

Execute os seguintes comandos e copie a saída para um arquivo de texto.

| Comando | O que ele faz |
| :--- | :--- |
| `docker info` | Mostra se o Docker está rodando e o status geral. |
| `docker compose ps` | Lista os componentes do Assistente e seus status (rodando, parado, etc.). |
| `docker logs <NomeDoServiço>` | Mostra o que aconteceu dentro de um componente específico. |
| **Para obter os logs completos de todos os serviços:** | `docker compose logs` |

> **Dica:** Se o `docker compose ps` mostrar o nome de um serviço (por exemplo, `siscan-api`), substitua `<NomeDoServiço>` por esse nome no comando `docker logs`.

---



### 🐳 2. Problemas com o Docker (O Motor do Assistente) - (Revisado)

O Docker é o programa que funciona como o **motor** que roda o Assistente SISCAN RPA no seu computador.

#### **Problema: O Docker não está funcionando**

O sintoma é: A mensagem **"Cannot connect to the Docker daemon"** apareceu no seu PowerShell.

| Passo | O que Fazer | Como Fazer |
| :--- | :--- | :--- |
| **1. Verificar o Status do Docker Desktop** | **Abra o Docker Desktop no menu Iniciar.** | **Como Fazer:** Clique no menu **Iniciar** do Windows (o ícone da bandeira) e digite `Docker Desktop`. Clique no aplicativo que aparecer. Ao abrir, o ícone do Docker na sua barra de tarefas (perto do relógio) deve ficar verde e a tela inicial do programa deve mostrar um *status* como **"Docker Desktop is running"** (O Docker Desktop está rodando). Se o ícone estiver cinza ou o status for **"Stopped"** (Parado), ele não está funcionando. |
| **2. Tentar Reiniciar** | No **PowerShell Admin**, digite o comando: `Restart-Service com.docker.service` | Este comando tenta **desligar e ligar** o motor do Docker novamente, corrigindo falhas temporárias. |
| **3. Verificar Recursos do Computador** | **Certifique-se de que o seu computador tem espaço em disco livre e memória RAM.** | **Como Fazer (Espaço em Disco):** Abra o **Explorador de Arquivos** (o ícone da pasta amarela). Clique em **"Este Computador"**. Verifique o **Disco Local (C:)** para garantir que você tenha pelo menos **20 GB a 50 GB livres**. Se estiver quase cheio, o Docker não tem espaço para as imagens e volumes.  |
| | | **Como Fazer (Memória RAM):** Pressione as teclas `CTRL + SHIFT + ESC` ao mesmo tempo para abrir o **Gerenciador de Tarefas**. Clique na aba **Desempenho** e olhe o item **Memória**. O número total (por exemplo, 16 GB) é a memória RAM. Se você estiver usando um computador com menos de **8 GB** de RAM, o Docker terá dificuldades para rodar, sendo **16 GB** o recomendado. |
| **4. Se Usar WSL2 (Subsistema Linux)** | No PowerShell Admin, digite: `wsl --update` | Se você usa o WSL2 para rodar o Docker (geralmente usado por quem instalou o Docker Desktop mais recentemente), este comando **atualiza** o componente WSL e, em seguida, você deve **reiniciar o Docker Desktop** pelo menu do programa. |
---

### 3. Problemas de Acesso (Login, Chaves e Imagens)

O Assistente precisa de permissão para baixar as atualizações (Imagens) de onde elas estão guardadas (`ghcr.io`).

#### **Problema: Falha de Login ou Mensagem "unauthorized" / "pull access denied"**

Significa que a chave (Token) usada para fazer o login no repositório de imagens é inválida ou expirou.

| Passo | O que Fazer | Detalhes para o Leigo |
| :--- | :--- | :--- |
| **1. Sair e Entrar Novamente** | No PowerShell Admin, digite: `docker logout ghcr.io` e depois `docker login ghcr.io` | O comando `login` pedirá o **Nome de Usuário do GitHub** e a **Chave/Token de Acesso Pessoal (PAT)**. Certifique-se de usar o token **correto**. |
| **2. Verificar a Chave (Token)** | Acesse a página de **Tokens de Acesso Pessoal (PAT)** no GitHub. | A chave (Token) usada para o login precisa ter as permissões `read:packages` e, se o repositório for privado, `repo`. Se estiver expirada ou sem as permissões corretas, **gere uma nova**. |

---

### 4. Problemas de Permissão de Pastas (Mount denied)

O Docker precisa de permissão para acessar a pasta do Assistente no seu computador.

#### **Problema: Erro "Mount denied" ou "invalid mount config"**

O Docker não consegue ler ou gravar na pasta do projeto no seu Windows.

| Passo | O que Fazer | Detalhes para o Leigo |
| :--- | :--- | :--- |
| **1. Compartilhar o Drive** | **Abra o Docker Desktop** -> Vá em **Settings** (Configurações) -> **Resources** -> **File Sharing** (Compartilhamento de Arquivos). | Certifique-se de que o **Drive C:** (ou o drive onde está a pasta do Assistente) esteja listado e **selecionado** para compartilhamento. |
| **2. Verificar a Pasta** | Verifique se a pasta de instalação do Assistente no seu computador (**Exemplo:** `C:\assistente-siscan`) realmente existe e se está com as permissões corretas. | O caminho **tem que ser o mesmo** usado no arquivo `docker-compose.yml` ou no script de *deploy*. |

---

### 5. Problemas com o Assistente (Containers em Loop)

#### **Problema: Um componente (Container) do Assistente não inicia e fica Reiniciando sem parar**

Isso é chamado de *CrashLoop*. O componente está tentando iniciar, mas encontra um erro e se desliga imediatamente.

| Passo | O que Fazer | Detalhes para o Leigo |
| :--- | :--- | :--- |
| **1. Coletar o Log do Erro** | No PowerShell Admin, use o comando para ver os logs do componente que está falhando: `docker logs <NomeDoServiço>` | **Procure por mensagens de erro em letras maiúsculas, *stacktrace*, ou palavras-chave como `ERROR`, `Failed`, ou `Exception`.** Isso geralmente indica qual variável de ambiente está faltando ou se há um arquivo de configuração errado. |
| **2. Parar e Recriar** | Se a causa for corrigida (ex: variável ajustada), execute: `docker compose down` e depois `docker compose up -d` | Isso força o Docker a parar, remover e recriar o componente com as novas configurações, eliminando o erro de *CrashLoop*. |

---

### 6. Problemas com o Windows Defender e Scripts

#### **Problema: O Windows bloqueia a execução do script de instalação (`.ps1`)**

Você pode receber uma mensagem dizendo que o script não pode ser carregado.

| Passo | O que Fazer | Detalhes para o Leigo |
| :--- | :--- | :--- |
| **1. Ajustar a Política (Se permitido)** | No PowerShell Admin, digite: `Set-ExecutionPolicy RemoteSigned -Scope LocalMachine` | Este comando permite que *scripts* que você baixou da Internet rodem no seu computador. **Atenção:** Se a sua área de TI não permitir isso, não prossiga. |
| **2. Checar o Antivírus** | Verifique as notificações e logs do **Windows Defender** ou do seu Antivírus. | O programa pode estar bloqueando o Docker ou a pasta do Assistente. Peça à TI para adicionar o **Docker** e a **pasta do Assistente SISCAN RPA** como exceções. |


#####  Solução para o Erro: "Execução de scripts foi desabilitada"

Você precisa temporariamente relaxar a política de segurança do PowerShell para permitir a execução de scripts locais.

| Passo | O que Fazer | Detalhes Importantes |
| :--- | :--- | :--- |
| **1. Abrir o PowerShell como Administrador** | Clique no menu Iniciar, digite `PowerShell`, clique com o botão direito em **Windows PowerShell** e escolha **Executar como administrador**. | **É fundamental** que você execute como Administrador, ou o comando no Passo 2 não funcionará. |
| **2. Ajustar a Política de Execução** | No PowerShell Admin, digite o seguinte comando e pressione Enter: `Set-ExecutionPolicy RemoteSigned -Scope LocalMachine` | Este comando muda a política para `RemoteSigned`, o que significa que scripts criados localmente (como o seu `siscan-assistente.ps1`) podem ser executados, enquanto scripts baixados da internet ainda precisarão de uma assinatura digital. |
| **3. Confirmar a Mudança** | O PowerShell irá perguntar se você tem certeza. Digite a letra `S` (Sim) e pressione Enter. | Se tudo der certo, o PowerShell voltará para a linha de comando sem mensagens de erro. |
| **4. Tentar Rodar o Script Novamente** | Feche e reabra o seu terminal normal (sem ser como Administrador) na pasta correta (`C:\Users\jailt\assistente-siscan-rpa>`). | Execute o comando original: `.\siscan-assistente.ps1` |

---

#####  E se o problema persistir?

Se o passo 3 retornar a mensagem **"Acesso negado"**, isso significa que as configurações de segurança da sua empresa (política de grupo) estão impedindo a mudança.

Neste caso, você terá que contatar o **Departamento de TI (NetOps)** da prefeitura para que eles alterem a política de execução ou autorizem a execução do script `siscan-assistente.ps1` no seu computador.

Deu certo a alteração da política de execução?

---

## Coleta de Informações para Suporte Avançado

Se nenhuma das soluções acima funcionar, reúna todos os seguintes arquivos e informações para enviar à equipe de suporte.

1.  **Logs do Compose:**
    * `docker compose logs --no-log-prefix > compose-logs.txt`
2.  **Informações do Docker:**
    * `docker info > docker-info.txt`
    * `docker version > docker-version.txt`
3.  **Status do Sistema:**
    * **Data e Hora Exata** do momento da falha.
    * **Passos Exatos** que você seguiu antes do erro ocorrer.
    * Uma **Captura de Tela (Screenshot)** da mensagem de erro.

