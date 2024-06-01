#!/bin/bash
#
#  rem_arq_dinamic.sh - Retenção de backups dinâmica
#
#  Autor: Iago Braga da Silva
#
#  +-----------------------------------------------------------------------------------+
#  | Este script é responsável pela retenção de backups.                               |
#  | Ele verifica o uso do disco e a quantidade de backups existentes,                 |
#  | e com base nessas informações, decide se um arquivo de backup antigo              |
#  | deve ser removido ou não. Isso ajuda a gerenciar o espaço em disco e a manter     |
#  | um número específico de backups conforme definido nas configurações.              |
#  +-----------------------------------------------------------------------------------+
#
#  Exemplo de agendamento no crontab:
#
#  ###########################
#  # Remover backups antigos #
#  */5 * * * * /scripts/rem_arq_dinamic.sh &> /dev/null
#
#####################################
#       CONFIGURAÇÃO DO SCRIPT      #
#####################################
#
# Versão do script
VERSAO="1.3.3"
#
# Pega data e hora do sistema
# DATA=09022024 HORA=235700
DATA=$(date +'%d%m%Y')
HORA=$(date +'%H%M%S')
#
# Pega o nome atual do script
# Ex: NOME_SCRIPT=rem_arq_dinamic.sh
NOME_SCRIPT=$(basename $0)
#
# Define padrão do nome do arquivo de configuração.
# Ex: DIR_CONFIG="/db/backup/scripts" ARQ_CONFIG="rem_arq_dinamic.conf"
DIR_CONFIG="/scripts"
ARQ_CONFIG="${NOME_SCRIPT%.*}.conf"
#
# Modelo do arquivo de configuração para facilitar a implantação, criado caso não exista um
MODELO_CONFIG="\
#
# Arquivo de configuração gerado automaticamente pelo script ${NOME_SCRIPT} na versão ${VERSAO}
#
# Instruções:
#
# 1) Linhas começando com a cerquilha '#' são consideradas comentários e ignoradas pelo parser. Use para identificar sessões de backups.
# 2) Separe cada sessão por uma linha em branco.
# 3) Evite espaços em branco no início ou final das linhas.
# 4) Use o formato chave=valor, sem espaços entre eles, aspas ou caracteres adicionais.
# 5) O script busca pelo padrão dentro dos parênteses '[]' para remoção, evite coringas soltos '[*]'.
# 6) A ordem das chaves é crucial para a correta retenção dos arquivos. Siga os exemplos de uso.
#
# Chaves:
#
# tipo_backup           = Especifíca se é um arquivo ou diretório. Valor 'arquivo' ou 'diretorio'
# diretorio             = Caminho absoluto onde os backups estão armazenados. Valor /Caminho/dos/backups
# limite_disco          = Porcentagem de uso do disco (df -h). Ao atingir esse valor, o script inicia a remoção. Valor entre 1 e 99
# qtd_minima_backups    = Quantidade mínima de backups a serem mantidos no ambiente. Ao atingir esse valor, os backups não serão removidos
# qtd_maxima_backups    = Quantidade máxima de backups que será mantida no ambiente. Acima desse valor, serão excluídos os backups mais antigos
#
# Exemplos de uso:
#
# # == Oracle BASE ==
# [backup*tar.z]
# tipo_backup=arquivo
# diretorio=/db/backup/backup_old
# limite_disco=90
# qtd_minima_backups=15
# qtd_maxima_backups=200"
#
# Tempo máximo em segundos que o comando 'df -h' pode executar antes de ser interrompido.
# Ex: DURACAO_TIMEOUT=5
DURACAO_TIMEOUT=5
#
# Tempo em segundos em que o loop será pausado até a próxima validação da retenção dos backups
# Ex: DELAY_FREQ=2
DELAY_FREQ=2
#
# Define se o script irá gerar arquivos de log, apenas saída no terminal ou nenhuma saída (Desativar a saída ajuda a debugar o script).
# 1 = Apenas para o terminal  / 2 = Gera também arquivos de log / Restante = Nenhuma saída
PRINTLOG=2
#
# Local e nome dos arquivos de log gerados pela retenção caso esteja configurado a variavel PRINTLOG e o número máximo de linhas do arquivo de log.
# Ex: DIR_LOG="/db/backup/checklist" ARQ_LOG="rem_arq_dinamic_09022024.log" LIMITE_LINHA_LOG=100000000
DIR_LOG="/db/backup/checklist"
ARQ_LOG="${NOME_SCRIPT%.*}.log"
LIMITE_LINHA_LOG=1000000
#
# Local e nome do arquivo de trava temporária para evitar simultaneidade de execução do script
# Ex: DIR_LOCK="/tmp" ARQ_LOCK="rem_arq_dinamic.lock"
DIR_LOCK="/tmp"
ARQ_LOCK="${NOME_SCRIPT%.*}.lock"
#
# Coleta o PID do script em execução no momento para criar o arquivo .lock
# Ex: SCRIPT_PID=39880
SCRIPT_PID=$$
#
# Mostra mensagem de ajuda
MSG_AJUDA="\
Uso: $NOME_SCRIPT [OPÇÃO]
Opções:
    -v, --version           Imprime a versão do script
    -h, --help              Exibe essa mensagem de ajuda
    -c, --config            Abre o arquivo de configuração em modo de edição
    -l, --log               Exibe o log gerado pelo script em modo somente leitura
    -o, --overwrite         Gera um arquivo de configuração modelo ou sobrescreve-o se existir

Obs:
    * Use o script sem parâmetros para executar o modo de retenção de arquivos
    * O arquivo de configuração deve estar localizado em \"${DIR_CONFIG}/${ARQ_CONFIG}\"
    * O arquivo de log deve estar localizado em \"${DIR_LOG}/${ARQ_LOG}\"
"
#
#
#####################################
#              FUNÇÕES              #
#####################################
#
# Formatação das informações de log
#
function print_log() {
    case "$PRINTLOG" in
        1) echo "[ $(date +'%d/%m/%Y - %H:%M:%S') ] :: $*" ;;
        2) echo "[ $(date +'%d/%m/%Y - %H:%M:%S') ] :: $*" | tee -a "${DIR_LOG}/${ARQ_LOG}" ;;
    esac
}
function print_erro() {
    case "$PRINTLOG" in
        1) echo "[ $(date +'%d/%m/%Y - %H:%M:%S') ] :: ERRO! $*" ;;
        2) echo "[ $(date +'%d/%m/%Y - %H:%M:%S') ] :: ERRO! $*" | tee -a "${DIR_LOG}/${ARQ_LOG}" ;;
    esac
    exit 1
}
function print_linha() {
    case "$PRINTLOG" in
        1) echo "------------------------------------------------------------------------------------------------" ;;
        2) echo "------------------------------------------------------------------------------------------------" | tee -a "${DIR_LOG}/${ARQ_LOG}" ;;
    esac
}
function limpa_log() {
    if [ -z "$LIMITE_LINHA_LOG" ] || [ "$LIMITE_LINHA_LOG" -le "0" ];then
        print_erro "LOG: Limite de linhas definido é insuficiente, considere utilizar um valor maior para auditoria"
    else
        local qtd_linha_atual=$(wc -l < "${DIR_LOG}/${ARQ_LOG}")
        if [ $qtd_linha_atual -gt $LIMITE_LINHA_LOG ]; then
            local linhas_a_remover=$((qtd_linha_atual - LIMITE_LINHA_LOG))
            sed -i "1,${linhas_a_remover}d" "${DIR_LOG}/${ARQ_LOG}"
        fi
    fi
}
#
# Locks de execução do ambiente
#
function lock_exec() {
    echo "$SCRIPT_PID" > "${DIR_LOCK}/${ARQ_LOCK}"
}
function unlock_exec() {
    find "$DIR_LOCK" -type f -name "$ARQ_LOCK" -delete
}
function validar_lock() {
    local lock_file="${DIR_LOCK}/${ARQ_LOCK}"
    # Verifica se há outra instância do script em execução no momento
    if [ -e "$lock_file" ]; then
        # Pega o PID do arquivo de lock
        OLD_PID=$(cat "${lock_file}")
        if [ -n "$OLD_PID" ] && ps -p "$OLD_PID" -o cmd= | grep -q "$NOME_SCRIPT"; then
            print_erro "LOCK: O script ${NOME_SCRIPT} já está em execução! Abortando a operação para evitar conflitos"
        else
            lock_exec
        fi
    fi
}
#
# Validações do ambiente
#
validar_ponto_montagem() {
    local ponto_montagem=$1
    if ! timeout ${DURACAO_TIMEOUT:=5}s df -h "$ponto_montagem" &>/dev/null; then
        print_log "AVISO: Não foi possível avaliar o diretorio, ele não existe ou é um ponto de montagem travado => $ponto_montagem"
        return 1
    else
        return 0
    fi
}
#
# Arquivo de configuração.
#
function cria_arquivo_configuracao() {
    echo "${MODELO_CONFIG}" > "${DIR_CONFIG}/${ARQ_CONFIG}"
}
function validar_arquivo_configuracao() {
    if [ ! -f "${DIR_CONFIG}/${ARQ_CONFIG}" ]; then
        cria_arquivo_configuracao
        print_erro "CONFIG: Não foi possível encontrar o arquivo de configuração no caminho ${DIR_CONFIG}/${ARQ_CONFIG} Um modelo foi adicionado para referência"
    fi
    ULTIMA_LINHA="$(tail -1 ${DIR_CONFIG}/${ARQ_CONFIG})"
    if [ -n "$ULTIMA_LINHA" ]; then
        echo "" >> "${DIR_CONFIG}/${ARQ_CONFIG}"
    fi
}
function limpar_variaveis_arquivo_configuracao() {
    config_base=""
    config_tipo_backup=""
    config_diretorio=""
    config_limite_disco=""
    config_qtd_minima_backups=""
    config_qtd_maxima_backups=""
}
#
# Extrai e trata as informações do arquivo de configuração
#
function parser_arquivo_configuracao() {
    print_linha
    BASES_CONFIG=()
    limpar_variaveis_arquivo_configuracao
    # Lê cada linha do arquivo de configuração, realiza trativas, e adiciona ao array para a função remove_backup
    while IFS="=" read -r key value; do
        # Ignora linhas em branco
        if [[ -z "$key" ]]; then
            continue
        fi
        # Realiza o parser e valida as informações
        case "$key" in
            \#*) # Ignora comentários
                continue
            ;;
            "["*"]") # Redefine todas as variáveis de configuração para valores vazios e avalia se existem coringas * isolados no script
                limpar_variaveis_arquivo_configuracao
                if [[ "$(echo -n "$key" | tr -d '[]')" =~ ^(\*)+$ ]]; then
                    print_erro "PARSER: O padrão não pode ser composto apenas por asteriscos, pois isso poderia resultar na remoção de todos os arquivos"
                else
                    config_base=${key:1:${#key}-2}
                fi
            ;;
            "tipo_backup") # Avalia se tipo é arquivo ou diretorio
                case "$value" in
                    arquivo)
                        config_tipo_backup="f"
                    ;;
                    diretorio)
                        config_tipo_backup="d"
                    ;;
                    *)
                        print_erro "PARSER: O tipo de backup definido é inválido! => $value. Verifique se o tipo de backup está correto"
                    ;;
                esac
            ;;
            "diretorio") # Avalia se o diretório existe e se não é um ponto de montagem travado
                if ! validar_ponto_montagem "$value"; then
                    continue
                fi
                if [ -d "$value" ]; then
                    config_diretorio="$value"
                else
                    print_erro "PARSER: O diretório informado não existe => $value. Verifique se o caminho do diretório está correto"
                fi
            ;;
            "limite_disco") # Avalia se o valor é válido
                if [[ ! $value =~ ^[0-9]+$ ]] || [ "$value" -ge 100 ] || [ "$value" -le 0 ]; then
                    print_erro "PARSER: Valor inválido para limite_disco => $value. O valor deve ser um número entre 1 e 99"
                else
                    config_limite_disco="$value"
                fi
            ;;
            "qtd_minima_backups") # Avalia quantidade mínima de backups
                if [[ ! $value =~ ^[0-9]+$ ]] || [ "$value" -le 0 ]; then
                    print_erro "PARSER: Valor inválido para qtd_minima_backups => $value. O valor deve ser um número inteiro"
                else
                    config_qtd_minima_backups="$value"
                fi
            ;;
            "qtd_maxima_backups") # Avalia a quantidade máxima de backups
                if [[ ! $value =~ ^[0-9]+$ ]] || [ "$value" -le 0 ]; then
                    print_erro "PARSER: Valor inválido para qtd_maxima_backups => $value. O valor deve ser um número inteiro"
                else
                    config_qtd_maxima_backups="$value"
                fi
            ;;
            *) # Tratativa de erro de digitação das chaves
                if [[ ! $key =~ ^(tipo_backup|diretorio|limite_disco|qtd_minima_backups|qtd_maxima_backups)$ ]]; then
                    print_erro "PARSER: Chave desconhecida => $key. Verifique se a chave está correta"
                elif [[ -z $value ]]; then
                    print_erro "PARSER: Valor inválido para $key. Verifique se o valor está correto"
                fi
            ;;
        esac
        # Se todas as configurações estão preenchidas, adiciona ao array
        if [[ -n $config_base && -n $config_tipo_backup && -n $config_diretorio && -n $config_limite_disco && -n $config_qtd_minima_backups && -n $config_qtd_maxima_backups ]]; then
            BASES_CONFIG+=("$config_base:$config_tipo_backup:$config_diretorio:$config_limite_disco:$config_qtd_minima_backups:$config_qtd_maxima_backups")
            limpar_variaveis_arquivo_configuracao
        fi
    done < "${DIR_CONFIG}/${ARQ_CONFIG}"
    # Valida se o array não está vazio.
    if [ ! "${#BASES_CONFIG}" -gt 0 ]; then
        print_erro "PARSER: Nenhuma base para reter foi encontrada. Por favor, verifique o arquivo de configuração"
    fi
    # Temporario
    print_log "PARSER: Arquivo de configuração lido com sucesso. Bases configuradas => ${BASES_CONFIG[*]}"
}
#
# Remove backups antigos e avalia espaço no disco
#
function remove_backup () {
    print_linha
    # Chave Liga/Desliga loop responsável pela remoção
    REMOVER=true
    while [ "$REMOVER" = true ]; do
        # Desliga loop, ativa se as condições forem favoráveis
        REMOVER=false
        for BASE_CONFIG in "${BASES_CONFIG[@]}"; do
            # Configura variáveis
            local PADRAO_BACKUP=$(echo $BASE_CONFIG | cut -d':' -f1)
            local TIPO_BKP=$(echo $BASE_CONFIG | cut -d':' -f2)
            local DIR_BKP=$(echo $BASE_CONFIG | cut -d':' -f3)
            local LIMITE_DISCO=$(echo $BASE_CONFIG | cut -d':' -f4)
            local MIN_BKPS=$(echo $BASE_CONFIG | cut -d':' -f5)
            local MAX_BKPS=$(echo $BASE_CONFIG | cut -d':' -f6)
            local QTD_BKP=0
            local USO_DISCO=0
            local BKP_OLD=""
            local BKP_SIZE=""
            # Inicia analise de filesystem
            if ! validar_ponto_montagem "$DIR_BKP"; then
                continue
            fi
            print_log "Analisando backups para o padrão => $PADRAO_BACKUP"
            # USO_DISCO=$(                        \
            #     df -h "$DIR_BKP"                \
            #     | awk 'NR==2 {print $5}'        \
            #     | cut -d'%' -f1                 \
            # )
            USO_DISCO=$(                            \
                df -h "$DIR_BKP"                    \
                | awk 'NR>1 && /%/ {print $(NF-1)}' \
                | cut -d'%' -f1                     \
            )
            if [ -z $USO_DISCO ] || [ $USO_DISCO -lt 0 ] || [ $USO_DISCO -gt 100 ]; then
                print_erro "RETENCAO: O valor de uso do disco não é válido => $USO_DISCO. Verifique se o valor está correto"
            else
                print_log "O uso atual do disco é de ${USO_DISCO}%"
                print_log "O limite máximo permitido de uso do disco é de ${LIMITE_DISCO}%"
            fi
            QTD_BKP=$(                          \
                find "$DIR_BKP"                 \
                    -maxdepth 1                 \
                    -type "${TIPO_BKP}"         \
                    -name "${PADRAO_BACKUP}"    \
                    -printf "%T@ %p\n"          \
                    | sort -n -r -k1            \
                    | wc -l                     \
            )
            print_log "Encontrado(s) $QTD_BKP backup(s) no diretório $DIR_BKP"
            if [ $QTD_BKP -le 0 ]; then
                print_log "RETENCAO: A quantidade de backups é menor que o esperado. Por favor, verifique a configuração da retenção ou os backups do diretório"
                continue
            else
                print_log "A quantidade mínima de backups configurada é $MIN_BKPS"
                print_log "A quantidade máxima de backups configurada é $MAX_BKPS"
            fi
            # Principal verificação para decidir a remoção do arquivo de backup
            if [ $USO_DISCO -ge $LIMITE_DISCO ] || [ $QTD_BKP -gt $MAX_BKPS ]; then
                if [ $QTD_BKP -gt $MIN_BKPS ]; then
                    # Ligar loop, é possível remover backups
                    REMOVER=true
                    # Pega o arquivo de backup mais antigo e seu tamanho
                    BKP_OLD=$(                          \
                        find "$DIR_BKP"                 \
                            -maxdepth 1                 \
                            -type "${TIPO_BKP}"         \
                            -name "${PADRAO_BACKUP}"    \
                            -printf "%T@ %p\n"          \
                            | sort -n -r -k1            \
                            | awk '{ print $2 }'        \
                            | tail -1                   \
                    )
                    if [ -z $BKP_OLD ]; then
                        print_erro "RETENCAO: Não foi possível encontrar o arquivo de backup mais antigo!"
                    else
                        print_log "Backup mais antigo encontrado: $BKP_OLD"
                        BKP_OLD_NAME=$(basename "$BKP_OLD")
                    fi
                    TAMANHO_BKP=$(                  \
                        du -sh $BKP_OLD             \
                        | awk '{print $1}'          \
                    )
                    if [ -z $TAMANHO_BKP ]; then
                        print_erro "RETENCAO: Não foi possível avaliar o tamanho do arquivo de backup mais antigo!"
                    fi
                    # Realiza a remoção
                    if [[ -n "$BKP_OLD_NAME" ]]; then
                        find "$DIR_BKP" -maxdepth 1 -name "$BKP_OLD_NAME" -type "$TIPO_BKP" -exec rm -rf {} \;
                        print_log "O backup $BKP_OLD foi removido! Foi liberado $TAMANHO_BKP de espaço em disco"
                    else
                        print_erro "RETENCAO: Ocorreu um erro ao tentar remover o arquivo de backup!"
                    fi
                else
                    print_log "A retenção do padrão ${PADRAO_BACKUP} atingiu seu limite mínimo de $MIN_BKPS backup(s) no diretório $DIR_BKP"
                fi
            else
                print_log "O espaço em disco está adequado. Uso atual => ${USO_DISCO}% em $DIR_BKP"
            fi
        done
        print_linha
        sleep $DELAY_FREQ
    done
    unlock_exec
}
#
#####################################
#            PARAMETROS             #
#####################################
#
# Trata parâmetros passados ao script
#
while [ -n "$1" ]; do
    case "$1" in
        -v | --version) # Imprime a versão do script
            echo "$VERSAO"
            exit 0
        ;;
        -h | --help) # Exibe essa mensagem de ajuda
            echo "$MSG_AJUDA"
            exit 0
        ;;
        -c | --config) # Abre o arquivo de configuração em modo de edição
            vim "${DIR_CONFIG}/${ARQ_CONFIG}" || vi "${DIR_CONFIG}/${ARQ_CONFIG}" || nano "${DIR_CONFIG}/${ARQ_CONFIG}"
            exit 0
        ;;
        -l | --log) # Exibe o log gerado pelo script em modo somente leitura
            cat "${DIR_LOG}/${ARQ_LOG}" | less
            exit 0
        ;;
        -o | --overwrite) # Gera um arquivo de configuração modelo ou sobrescreve-o se existir
            cria_arquivo_configuracao
            print_log "Arquivo de configuração adicionado/sobrescrito: ${DIR_CONFIG}/${ARQ_CONFIG}"
            exit 0
        ;;
        *) # Tratativa para parâmetros inválidos
            print_erro "PARAMETRO: O parâmetro informado está incorreto! Utilize o script com o parâmetro '-h' ou '--help' para exibir a ajuda"
        ;;
    esac
    shift
done
#
#
#####################################
#             RETENÇÃO              #
#####################################
validar_lock
validar_arquivo_configuracao
parser_arquivo_configuracao
remove_backup
limpa_log
exit 0
