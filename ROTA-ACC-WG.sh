#!/bin/bash

# ==================================================================
# CONTROLE WG - VERSÃO FINAL SEM SCRIPT INTERNO
# Executa comandos diretamente no MikroTik via SSH
# ==================================================================

# Configurações COM CHAVE SSH
MIKROTIK_IP="10.130.130.0"
MIKROTIK_USER="admin"
SSH_KEY="$HOME/.ssh/mikrotik_wgkey"
SSH_PORT="22"
CONFIG_FILE="$HOME/.wg_isps.conf"

# Função para executar no MikroTik (COM SSH KEY)
executar_mikrotik() {
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -p "$SSH_PORT" -i "$SSH_KEY" "$MIKROTIK_USER@$MIKROTIK_IP" "$1"
}

# Função para configurar rotas no MikroTik (COMANDOS DIRETOS - CORRIGIDA)
configurar_rotas_mikrotik() {
    local gateway="$1"
    
    echo "🔄 Removendo rotas antigas..."
    if ! executar_mikrotik "/ip route remove [find where comment~\"ROTA ACC WG RFC\"]"; then
        echo "⚠️ Aviso: Falha ao remover rotas antigas (pode não existir nenhuma)"
    fi
    
    echo "🔄 Adicionando novas rotas..."
    
    # Adiciona cada rota individualmente para melhor controle de erro
    local sucesso=0
    
    if executar_mikrotik "/ip route add dst-address=10.0.0.0/8 gateway=$gateway comment=\"ROTA ACC WG RFC 1918 CLASS A\""; then
        echo "✅ Rota 10.0.0.0/8 adicionada"
        ((sucesso++))
    else
        echo "❌ Falha ao adicionar rota 10.0.0.0/8"
    fi
    
    if executar_mikrotik "/ip route add dst-address=172.16.0.0/12 gateway=$gateway comment=\"ROTA ACC WG RFC 1918 CLASS B\""; then
        echo "✅ Rota 172.16.0.0/12 adicionada"
        ((sucesso++))
    else
        echo "❌ Falha ao adicionar rota 172.16.0.0/12"
    fi
    
    if executar_mikrotik "/ip route add dst-address=192.168.0.0/16 gateway=$gateway comment=\"ROTA ACC WG RFC 1918 CLASS C\""; then
        echo "✅ Rota 192.168.0.0/16 adicionada"
        ((sucesso++))
    else
        echo "❌ Falha ao adicionar rota 192.168.0.0/16"
    fi
    
    if executar_mikrotik "/ip route add dst-address=100.64.0.0/10 gateway=$gateway comment=\"ROTA ACC WG RFC 6598\""; then
        echo "✅ Rota 100.64.0.0/10 adicionada"
        ((sucesso++))
    else
        echo "❌ Falha ao adicionar rota 100.64.0.0/10"
    fi
    
    # Log no MikroTik
    executar_mikrotik ":log info \"Rotas WG configuradas para gateway: $gateway ($sucesso/4 rotas)\""
    
    # Mensagem final
    if [ $sucesso -eq 4 ]; then
        echo ""
        echo "=========================================="
        echo "✅ TODAS AS ROTAS WG CONFIGURADAS!"
        echo "Gateway: $gateway"
        echo "Rotas: $sucesso/4"
        echo "=========================================="
        return 0
    else
        echo ""
        echo "=========================================="
        echo "⚠️ CONFIGURAÇÃO PARCIAL"
        echo "Gateway: $gateway"
        echo "Rotas configuradas: $sucesso/4"
        echo "=========================================="
        return 1
    fi
}

# Função para verificar e configurar chave SSH
verificar_chave_ssh() {
    if [ ! -f "$SSH_KEY" ]; then
        echo "❌ CHAVE SSH NÃO ENCONTRADA: $SSH_KEY"
        echo ""
        echo "Para criar a chave SSH, execute:"
        echo "  ssh-keygen -t ed25519 -f ~/.ssh/mikrotik_wgkey -N \"\""
        echo ""
        echo "Depois copie a chave pública para o MikroTik:"
        echo "  cat ~/.ssh/mikrotik_wgkey.pub"
        echo ""
        echo "E configure o usuário no MikroTik:"
        echo "  /user add name=admin group=WG-ACC_ROTAS"
        echo "  /user set admin ssh-keys=\"\$(cat ~/.ssh/mikrotik_wgkey.pub)\""
        echo ""
        exit 1
    fi
    
    local key_perms
    key_perms=$(stat -c %a "$SSH_KEY")
    if [ "$key_perms" != "600" ]; then
        echo "🔒 Ajustando permissões da chave SSH..."
        chmod 600 "$SSH_KEY"
    fi
}

# Função para testar conexão SSH
testar_conexao_ssh() {
    echo "🔌 Testando conexão SSH com $MIKROTIK_IP:$SSH_PORT..."
    if executar_mikrotik "/system identity print" >/dev/null 2>&1; then
        echo "✅ Conexão SSH funcionando perfeitamente!"
        
        # Teste adicional: verificar se consegue listar rotas
        echo "🔍 Testando acesso às rotas..."
        if executar_mikrotik "/ip route print count-only" >/dev/null 2>&1; then
            echo "✅ Acesso às rotas confirmado!"
            return 0
        else
            echo "⚠️ Conexão OK, mas sem acesso às rotas. Verifique permissões do usuário."
            return 1
        fi
    else
        echo "❌ Falha na conexão SSH"
        echo ""
        echo "📋 Soluções possíveis:"
        echo "1. Verifique se a chave pública foi adicionada ao usuário no MikroTik"
        echo "2. Teste manualmente: ssh -i $SSH_KEY $MIKROTIK_USER@$MIKROTIK_IP -p $SSH_PORT"
        echo "3. Verifique as permissões do usuário 'admin' no MikroTik"
        echo "4. Confirme que o IP do MikroTik está correto: $MIKROTIK_IP"
        echo "5. Confirme a porta SSH: $SSH_PORT"
        return 1
    fi
}

# Arrays para manter a ordem pelos gateways
declare -a ISP_NAMES=()
declare -A ISP_GATEWAYS=()

# Função para obter ISPs ordenados por gateway
obter_isps_ordenados() {
    declare -a gateways_temp=()
    declare -A gateway_to_name=()
    
    for isp in "${ISP_NAMES[@]}"; do
        local gateway="${ISP_GATEWAYS[$isp]}"
        gateways_temp+=("$gateway")
        gateway_to_name["$gateway"]="$isp"
    done
    
    # Ordenar gateways numericamente
    local IFS=$'\n'
    # shellcheck disable=SC2207
    sorted_gateways=($(printf '%s\n' "${gateways_temp[@]}" | sort -t . -k 1,1n -k 2,2n -k 3,3n -k 4,4n))
    unset IFS
    
    # Reconstruir array de nomes na ordem dos gateways
    local ordered_names=()
    for gateway in "${sorted_gateways[@]}"; do
        ordered_names+=("${gateway_to_name[$gateway]}")
    done
    
    printf '%s\n' "${ordered_names[@]}"
}

# Função para carregar configuração de ISPs
carregar_isps() {
    if [ -f "$CONFIG_FILE" ]; then
        echo "📁 Carregando configuração de ISPs de $CONFIG_FILE..."
        ISP_NAMES=()
        # Limpar array associativo
        for key in "${!ISP_GATEWAYS[@]}"; do
            unset ISP_GATEWAYS["$key"]
        done
        
        while IFS='=' read -r key value; do
            # Remove espaços em branco
            key=$(echo "$key" | tr -d '[:space:]')
            value=$(echo "$value" | tr -d '[:space:]')
            if [[ $key =~ ^[A-Za-z0-9_-]+$ ]] && [[ $value =~ ^[0-9.]+$ ]]; then
                ISP_NAMES+=("$key")
                ISP_GATEWAYS["$key"]="$value"
            fi
        done < "$CONFIG_FILE"
        
        echo "✅ Carregados ${#ISP_NAMES[@]} ISPs"
    else
        echo "📝 Criando configuração padrão de ISPs..."
        criar_configuracao_padrao
    fi
}

# Função para criar configuração padrão
criar_configuracao_padrao() {
    ISP_NAMES=(
        "ISP-01" "ISP-02" "ISP-03" "ISP-04" "ISP-05" "ISP-06" "ISP-07" "ISP-08" "ISP-09" "ISP-10"
        "ISP-11" "ISP-12" "ISP-13" "ISP-14" "ISP-15" "ISP-16" "ISP-17" "ISP-18" "ISP-19" "ISP-20"
        "ISP-21" "ISP-22" "ISP-23" "ISP-24" "ISP-25" "ISP-26" "ISP-27" "ISP-28" "ISP-29" "ISP-30"
        "ISP-31" "ISP-32" "ISP-33" "ISP-34" "ISP-35" "ISP-36" "ISP-37" "ISP-38" "ISP-39" "ISP-40"
        "ISP-41" "ISP-42" "ISP-43" "ISP-44" "ISP-45" "ISP-46" "ISP-47" "ISP-48" "ISP-49" "ISP-50"
        "ISP-51" "ISP-52" "ISP-53" "ISP-54" "ISP-55" "ISP-56" "ISP-57" "ISP-58" "ISP-59" "ISP-60"
        "ISP-61" "ISP-62" "ISP-63" "ISP-64"
    )
    
    # Gateways em ordem crescente
    declare -A temp_gateways=(
        ["ISP-01"]="10.131.131.1"   ["ISP-02"]="10.131.131.5"   ["ISP-03"]="10.131.131.9"   ["ISP-04"]="10.131.131.13"
        ["ISP-05"]="10.131.131.17"  ["ISP-06"]="10.131.131.21"  ["ISP-07"]="10.131.131.25"  ["ISP-08"]="10.131.131.29"
        ["ISP-09"]="10.131.131.33"  ["ISP-10"]="10.131.131.37" ["ISP-11"]="10.131.131.41" ["ISP-12"]="10.131.131.45"
        ["ISP-13"]="10.131.131.49" ["ISP-14"]="10.131.131.53" ["ISP-15"]="10.131.131.57" ["ISP-16"]="10.131.131.61"
        ["ISP-17"]="10.131.131.65" ["ISP-18"]="10.131.131.69" ["ISP-19"]="10.131.131.73" ["ISP-20"]="10.131.131.77"
        ["ISP-21"]="10.131.131.81" ["ISP-22"]="10.131.131.85" ["ISP-23"]="10.131.131.89" ["ISP-24"]="10.131.131.93"
        ["ISP-25"]="10.131.131.97" ["ISP-26"]="10.131.131.101" ["ISP-27"]="10.131.131.105" ["ISP-28"]="10.131.131.109"
        ["ISP-29"]="10.131.131.113" ["ISP-30"]="10.131.131.117" ["ISP-31"]="10.131.131.121" ["ISP-32"]="10.131.131.125"
        ["ISP-33"]="10.131.131.129" ["ISP-34"]="10.131.131.133" ["ISP-35"]="10.131.131.137" ["ISP-36"]="10.131.131.141"
        ["ISP-37"]="10.131.131.145" ["ISP-38"]="10.131.131.149" ["ISP-39"]="10.131.131.153" ["ISP-40"]="10.131.131.157"
        ["ISP-41"]="10.131.131.161" ["ISP-42"]="10.131.131.165" ["ISP-43"]="10.131.131.169" ["ISP-44"]="10.131.131.173"
        ["ISP-45"]="10.131.131.177" ["ISP-46"]="10.131.131.181" ["ISP-47"]="10.131.131.185" ["ISP-48"]="10.131.131.189"
        ["ISP-49"]="10.131.131.193" ["ISP-50"]="10.131.131.197" ["ISP-51"]="10.131.131.201" ["ISP-52"]="10.131.131.205"
        ["ISP-53"]="10.131.131.209" ["ISP-54"]="10.131.131.213" ["ISP-55"]="10.131.131.217" ["ISP-56"]="10.131.131.221"
        ["ISP-57"]="10.131.131.225" ["ISP-58"]="10.131.131.229" ["ISP-59"]="10.131.131.233" ["ISP-60"]="10.131.131.237"
        ["ISP-61"]="10.131.131.241" ["ISP-62"]="10.131.131.245" ["ISP-63"]="10.131.131.249" ["ISP-64"]="10.131.131.253"
    )
    
    # Copiar para o array global
    for key in "${!temp_gateways[@]}"; do
        ISP_GATEWAYS["$key"]="${temp_gateways[$key]}"
    done
    
    salvar_isps
}

# Função para salvar configuração de ISPs
salvar_isps() {
    > "$CONFIG_FILE"
    # Salvar ordenado por nome para consistência
    local sorted_names
    IFS=$'\n' sorted_names=($(printf "%s\n" "${ISP_NAMES[@]}" | sort))
    unset IFS
    
    for isp in "${sorted_names[@]}"; do
        echo "$isp=${ISP_GATEWAYS[$isp]}" >> "$CONFIG_FILE"
    done
    echo "💾 Configuração salva em: $CONFIG_FILE"
}

# Função para gerenciar nomes de ISPs
gerenciar_isps() {
    while true; do
        clear
        echo "=== GERENCIAR NOMES DE ISP ==="
        echo ""
        
        local count=0
        # shellcheck disable=SC2207
        local isps_ordenados=($(obter_isps_ordenados))
        
        for isp in "${isps_ordenados[@]}"; do
            printf "%-3s. %-20s -> %s\n" "$((++count))" "$isp" "${ISP_GATEWAYS[$isp]}"
        done
        
        echo ""
        echo "1. Renomear ISP"
        echo "2. Adicionar novo ISP"
        echo "3. Remover ISP"
        echo "4. Voltar ao menu principal"
        echo ""
        
        read -p "Escolha uma opção: " opcao_gerenciar
        
        case $opcao_gerenciar in
            1) # Renomear
                read -p "Número do ISP para renomear: " num_isp
                if [[ $num_isp =~ ^[0-9]+$ ]] && [ "$num_isp" -ge 1 ] && [ "$num_isp" -le ${#isps_ordenados[@]} ]; then
                    local isp_antigo="${isps_ordenados[$((num_isp-1))]}"
                    read -p "Novo nome para '$isp_antigo': " novo_nome
                    if [ -n "$novo_nome" ]; then
                        local gateway_temp="${ISP_GATEWAYS[$isp_antigo]}"
                        ISP_GATEWAYS["$novo_nome"]="$gateway_temp"
                        unset ISP_GATEWAYS["$isp_antigo"]
                        
                        local new_names=()
                        for name in "${ISP_NAMES[@]}"; do
                            if [ "$name" == "$isp_antigo" ]; then
                                new_names+=("$novo_nome")
                            else
                                new_names+=("$name")
                            fi
                        done
                        ISP_NAMES=("${new_names[@]}")
                        
                        salvar_isps
                        echo "✅ ISP renomeado: '$isp_antigo' -> '$novo_nome'"
                    fi
                else
                    echo "❌ Número inválido!"
                fi
                read -p "Pressione ENTER para continuar"
                ;;
            2) # Adicionar
                read -p "Nome do novo ISP: " novo_isp
                read -p "Gateway (ex: 10.131.131.XXX): " novo_gateway
                if [ -n "$novo_isp" ] && [ -n "$novo_gateway" ]; then
                    ISP_NAMES+=("$novo_isp")
                    ISP_GATEWAYS["$novo_isp"]="$novo_gateway"
                    salvar_isps
                    echo "✅ ISP '$novo_isp' adicionado!"
                else
                    echo "❌ Nome e gateway são obrigatórios!"
                fi
                read -p "Pressione ENTER para continuar"
                ;;
            3) # Remover
                read -p "Número do ISP para remover: " num_isp
                if [[ $num_isp =~ ^[0-9]+$ ]] && [ "$num_isp" -ge 1 ] && [ "$num_isp" -le ${#isps_ordenados[@]} ]; then
                    local isp_remover="${isps_ordenados[$((num_isp-1))]}"
                    read -p "Confirmar remoção de '$isp_remover'? (s/N): " confirmar
                    if [[ $confirmar =~ ^[Ss]$ ]]; then
                        unset ISP_GATEWAYS["$isp_remover"]
                        local new_names=()
                        for name in "${ISP_NAMES[@]}"; do
                            [ "$name" != "$isp_remover" ] && new_names+=("$name")
                        done
                        ISP_NAMES=("${new_names[@]}")
                        salvar_isps
                        echo "✅ ISP '$isp_remover' removido!"
                    fi
                else
                    echo "❌ Número inválido!"
                fi
                read -p "Pressione ENTER para continuar"
                ;;
            4) break ;;
            *) echo "❌ Opção inválida!" && sleep 1 ;;
        esac
    done
}

# Função para obter ISP atual
obter_isp_atual() {
    local current_gw
    current_gw=$(executar_mikrotik "/ip route get [find where comment~\"ROTA ACC WG RFC\"] gateway" 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
    
    if [ -n "$current_gw" ]; then
        for isp in "${ISP_NAMES[@]}"; do
            if [ "${ISP_GATEWAYS[$isp]}" == "$current_gw" ]; then
                echo "$isp"
                return 0
            fi
        done
        echo "DESCONHECIDO($current_gw)"
    else
        echo "NENHUM"
    fi
}

# Menu principal
menu_principal() {
    while true; do
        clear
        echo "=== 🌐 CONTROLE WG - COMANDOS DIRETOS ==="
        echo "IP: $MIKROTIK_IP | Usuário: $MIKROTIK_USER | Porta: $SSH_PORT"
        echo "ISP Atual: $(obter_isp_atual)"
        echo "================================================================"
        
        local count=0
        # shellcheck disable=SC2207
        local isps_ordenados=($(obter_isps_ordenados))
        
        for isp in "${isps_ordenados[@]}"; do
            printf "%-3s. %-40s" "$((++count))" "$isp"
            (( count % 2 == 0 )) && echo ""
        done
        [[ $((count % 2)) -ne 0 ]] && echo ""
        
        echo "================================================================"
        echo "98. 🛠️ Gerenciar nomes de ISP"
        echo "99. 🔄 Próximo ISP automático"
        echo "00. 👁️ Ver ISP atual (detalhado)"
        echo "88. 🔌 Testar conexão SSH"
        echo "77. 🚪 Sair"
        echo ""
        
        read -p "Escolha o ISP (pelo número) ou uma opção: " opcao
        
        local isp_escolhido=""
        local gateway=""

        case $opcao in
            77) echo "👋 Saindo..." && exit 0 ;;
            88) 
                testar_conexao_ssh
                read -p "Pressione ENTER para continuar"
                ;;
            98) gerenciar_isps ;;
            00) # Ver ISP atual detalhado
                echo ""
                echo "🔍 Verificando configuração atual..."
                
                # Primeiro, mostrar todas as rotas WG que existem
                echo ""
                echo "📋 Buscando rotas WG no MikroTik..."
                local rotas_output
                rotas_output=$(executar_mikrotik "/ip route print where comment~\"ROTA ACC WG\"" 2>/dev/null)
                
                if [ -z "$rotas_output" ]; then
                    echo "❌ Nenhuma rota WG encontrada no MikroTik."
                    echo ""
                    echo "🔍 Tentando buscar rotas com comentários similares..."
                    executar_mikrotik "/ip route print where comment~\"WG\"" 2>/dev/null
                    echo ""
                    echo "🔍 Listando todas as rotas para diagnóstico:"
                    executar_mikrotik "/ip route print brief" 2>/dev/null | head -10
                else
                    echo "✅ Rotas WG encontradas:"
                    echo "$rotas_output"
                    
                    # Extrair gateway CORRETAMENTE - PEGAR DA COLUNA GATEWAY
                    local current_gw
                    
                    # Método CORRETO: Extrair da coluna GATEWAY (segunda coluna após DST-ADDRESS)
                    # Formato: "0 As 10.0.0.0/8      10.131.131.5  main                  1"
                    current_gw=$(echo "$rotas_output" | grep -E "^[0-9]+" | head -1 | awk '{print $3}')
                    
                    # Verificar se é um IP válido
                    if [[ ! "$current_gw" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
                        # Tentar método alternativo: buscar IP após o DST-ADDRESS
                        current_gw=$(echo "$rotas_output" | grep -E "^[0-9]+" | head -1 | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -2 | tail -1)
                    fi
                    
                    if [ -n "$current_gw" ] && [[ "$current_gw" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
                        echo ""
                        echo "✅ Gateway atual detectado: $current_gw"
                        
                        # Buscar ISP correspondente
                        local isp_encontrado=0
                        for isp in "${ISP_NAMES[@]}"; do
                            if [ "${ISP_GATEWAYS[$isp]}" == "$current_gw" ]; then
                                echo "✅ ISP atual: $isp"
                                isp_encontrado=1
                                break
                            fi
                        done
                        
                        if [ $isp_encontrado -eq 0 ]; then
                            echo "⚠️ Gateway ($current_gw) não corresponde a nenhum ISP na lista."
                            echo "💡 Gateways disponíveis na configuração:"
                            for isp in "${ISP_NAMES[@]}"; do
                                echo "   $isp = ${ISP_GATEWAYS[$isp]}"
                            done | head -5
                        fi
                    else
                        echo "⚠️ Não foi possível extrair o gateway das rotas encontradas."
                        echo "🔍 Debug: Primeira linha com rota:"
                        echo "$rotas_output" | grep -E "^[0-9]" | head -1
                    fi
                fi
                read -p "Pressione ENTER para continuar"
                ;;
            99) # Próximo ISP automático - CORRIGIDO
                echo "🔄 Detectando ISP atual..."
                
                # Usa a mesma função da opção 00 para detectar o gateway
                local rotas_output
                rotas_output=$(executar_mikrotik "/ip route print where comment~\"ROTA ACC WG\"" 2>/dev/null)
                
                local current_gw
                if [ -n "$rotas_output" ]; then
                    current_gw=$(echo "$rotas_output" | grep -E "^[0-9]+" | head -1 | awk '{print $3}')
                    
                    if [[ ! "$current_gw" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
                        current_gw=$(echo "$rotas_output" | grep -E "^[0-9]+" | head -1 | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -2 | tail -1)
                    fi
                fi
                
                if [ -z "$current_gw" ]; then
                    echo "❌ Não foi possível detectar o ISP atual."
                    echo "💡 Use a opção 00 para ver detalhes ou configure um ISP manualmente."
                    read -p "Pressione ENTER para continuar"
                    continue
                fi
                
                echo "🔍 Gateway atual: $current_gw"
                
                # Encontrar o ISP atual na lista ordenada
                local current_index=-1
                for i in "${!isps_ordenados[@]}"; do
                    if [ "${ISP_GATEWAYS[${isps_ordenados[$i]}]}" == "$current_gw" ]; then
                        current_index=$i
                        current_isp="${isps_ordenados[$i]}"
                        break
                    fi
                done
                
                if [ $current_index -eq -1 ]; then
                    echo "❌ ISP atual não encontrado na lista."
                    read -p "Pressione ENTER para continuar"
                    continue
                fi
                
                echo "📡 ISP atual: $current_isp (índice $current_index)"
                
                # Calcular próximo índice (rotação circular)
                local next_index=$(( (current_index + 1) % ${#isps_ordenados[@]} ))
                isp_escolhido="${isps_ordenados[$next_index]}"
                gateway="${ISP_GATEWAYS[$isp_escolhido]}"
                
                echo "🔄 Próximo ISP: $isp_escolhido (índice $next_index)"
                echo "🔜 Gateway: $gateway"
                ;;
            *) # Escolha por número
                if [[ $opcao =~ ^[0-9]+$ ]] && [ "$opcao" -ge 1 ] && [ "$opcao" -le ${#isps_ordenados[@]} ]; then
                    isp_escolhido="${isps_ordenados[$((opcao-1))]}"
                    gateway="${ISP_GATEWAYS[$isp_escolhido]}"
                else
                    echo "❌ Opção inválida!" && sleep 1 && continue
                fi
                ;;
        esac
        
        # Se um ISP foi escolhido (diretamente ou pelo modo automático)
        if [ -n "$isp_escolhido" ] && [ -n "$gateway" ]; then
            echo ""
            echo "⚡ Configurando: $isp_escolhido -> $gateway"
            
            if configurar_rotas_mikrotik "$gateway"; then
                echo "🎉 SUCESSO! ISP '$isp_escolhido' aplicado."
            else
                echo "❌ ERRO: Falha ao configurar o ISP '$isp_escolhido'."
            fi
            read -p "Pressione ENTER para continuar"
        fi
    done
}

# Função principal
main() {
    echo "=== INICIANDO CONTROLE WG (COMANDOS DIRETOS) ==="
    verificar_chave_ssh
    
    if testar_conexao_ssh; then
        carregar_isps
        menu_principal
    else
        echo "❌ Não foi possível conectar ao MikroTik. Encerrando."
        exit 1
    fi
}

# Executar o script
main "$@"
