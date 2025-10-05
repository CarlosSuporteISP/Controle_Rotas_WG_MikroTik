#!/usr/bin/env python3
# ==================================================================
# CONTROLE WG - VERSÃO PYTHON
# Executa comandos diretamente no MikroTik via SSH
# ==================================================================

import os
import sys
import subprocess
import re
from pathlib import Path
from collections import Counter

# Configurações COM CHAVE SSH
MIKROTIK_IP = "10.130.130.0"
MIKROTIK_USER = "admin"
SSH_KEY = str(Path.home() / ".ssh" / "mikrotik_wgkey")
SSH_PORT = "22"
CONFIG_FILE = str(Path.home() / ".wg_isps.conf")

# Arrays para manter a ordem pelos gateways
ISP_NAMES = []
ISP_GATEWAYS = {}

def executar_mikrotik(comando):
    """Função para executar no MikroTik via SSH"""
    try:
        cmd = [
            'ssh', '-o', 'StrictHostKeyChecking=no',
            '-o', 'ConnectTimeout=10',
            '-p', SSH_PORT,
            '-i', SSH_KEY,
            f'{MIKROTIK_USER}@{MIKROTIK_IP}',
            comando
        ]
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        
        # Considerar sucesso se o returncode for 0 OU se há saída no stdout
        if result.returncode == 0 or result.stdout:
            return result.stdout
        else:
            return ""
    except subprocess.TimeoutExpired:
        return ""
    except Exception as e:
        return ""

def configurar_rotas_mikrotik(gateway):
    """Função para configurar rotas no MikroTik"""
    print("🔄 Removendo rotas antigas...")
    remove_output = executar_mikrotik('/ip route remove [find where comment~"ROTA ACC WG RFC"]')
    
    # Na remoção, é normal "falhar" se não existem rotas para remover
    if not remove_output:
        print("ℹ️  Nenhuma rota antiga encontrada para remover (isso é normal)")
    
    print("🔄 Adicionando novas rotas...")
    
    # Adiciona cada rota individualmente para melhor controle de erro
    sucesso = 0
    rotas = [
        ("10.0.0.0/8", "ROTA ACC WG RFC 1918 CLASS A"),
        ("172.16.0.0/12", "ROTA ACC WG RFC 1918 CLASS B"),
        ("192.168.0.0/16", "ROTA ACC WG RFC 1918 CLASS C"),
        ("100.64.0.0/10", "ROTA ACC WG RFC 6598")
    ]
    
    for dst, comment in rotas:
        comando = f'/ip route add dst-address={dst} gateway={gateway} comment="{comment}"'
        output = executar_mikrotik(comando)
        
        # No MikroTik, comandos de add bem-sucedidos geralmente retornam string vazia
        # ou mensagem de erro se falhar
        if output == "" or "failure" not in output.lower():
            print(f"✅ Rota {dst} adicionada")
            sucesso += 1
        else:
            print(f"❌ Falha ao adicionar rota {dst}")
    
    # Log no MikroTik (não crítico se falhar)
    executar_mikrotik(f':log info "Rotas WG configuradas para gateway: {gateway} ({sucesso}/4 rotas)"')
    
    # Mensagem final
    if sucesso >= 2:  # Pelo menos 2 rotas configuradas consideramos sucesso
        print("\n" + "=" * 42)
        print("✅ ROTAS WG CONFIGURADAS COM SUCESSO!")
        print(f"Gateway: {gateway}")
        print(f"Rotas: {sucesso}/4")
        print("=" * 42)
        return True
    else:
        print("\n" + "=" * 42)
        print("⚠️ CONFIGURAÇÃO PARCIAL")
        print(f"Gateway: {gateway}")
        print(f"Rotas configuradas: {sucesso}/4")
        print("=" * 42)
        return sucesso > 0  # Retorna True se pelo menos 1 rota foi configurada

def verificar_chave_ssh():
    """Função para verificar e configurar chave SSH"""
    if not os.path.exists(SSH_KEY):
        print("❌ CHAVE SSH NÃO ENCONTRADA:", SSH_KEY)
        print("\nPara criar a chave SSH, execute:")
        print("  ssh-keygen -t ed25519 -f ~/.ssh/mikrotik_wgkey -N \"\"")
        print("\nDepois copie a chave pública para o MikroTik:")
        print("  cat ~/.ssh/mikrotik_wgkey.pub")
        print("\nE configure o usuário no MikroTik:")
        print("  /user add name=admin group=WG-ACC_ROTAS")
        print("  /user set admin ssh-keys=\"$(cat ~/.ssh/mikrotik_wgkey.pub)\"")
        print()
        sys.exit(1)
    
    # Verificar permissões da chave
    key_perms = oct(os.stat(SSH_KEY).st_mode)[-3:]
    if key_perms != "600":
        print("🔒 Ajustando permissões da chave SSH...")
        os.chmod(SSH_KEY, 0o600)

def testar_conexao_ssh():
    """Função para testar conexão SSH"""
    print(f"🔌 Testando conexão SSH com {MIKROTIK_IP}:{SSH_PORT}...")
    output = executar_mikrotik("/system identity print")
    if output and "name:" in output:
        print("✅ Conexão SSH funcionando perfeitamente!")
        
        # Teste adicional: verificar se consegue listar rotas
        print("🔍 Testando acesso às rotas...")
        if executar_mikrotik("/ip route print count-only"):
            print("✅ Acesso às rotas confirmado!")
            return True
        else:
            print("⚠️ Conexão OK, mas sem acesso às rotas. Verifique permissões do usuário.")
            return False
    else:
        print("❌ Falha na conexão SSH")
        print("\n📋 Soluções possíveis:")
        print("1. Verifique se a chave pública foi adicionada ao usuário no MikroTik")
        print(f"2. Teste manualmente: ssh -i {SSH_KEY} {MIKROTIK_USER}@{MIKROTIK_IP} -p {SSH_PORT}")
        print("3. Verifique as permissões do usuário 'admin' no MikroTik")
        print(f"4. Confirme que o IP do MikroTik está correto: {MIKROTIK_IP}")
        print(f"5. Confirme a porta SSH: {SSH_PORT}")
        return False

def obter_isps_ordenados():
    """Função para obter ISPs ordenados por gateway"""
    gateways_temp = []
    gateway_to_name = {}
    
    for isp in ISP_NAMES:
        gateway = ISP_GATEWAYS[isp]
        gateways_temp.append(gateway)
        gateway_to_name[gateway] = isp
    
    # Ordenar gateways numericamente
    sorted_gateways = sorted(gateways_temp, key=lambda x: [int(i) for i in x.split('.')])
    
    # Reconstruir array de nomes na ordem dos gateways
    ordered_names = [gateway_to_name[gateway] for gateway in sorted_gateways]
    
    return ordered_names

def carregar_isps():
    """Função para carregar configuração de ISPs"""
    global ISP_NAMES, ISP_GATEWAYS
    
    if os.path.exists(CONFIG_FILE):
        print(f"📁 Carregando configuração de ISPs de {CONFIG_FILE}...")
        ISP_NAMES = []
        ISP_GATEWAYS.clear()
        
        with open(CONFIG_FILE, 'r') as f:
            for line in f:
                line = line.strip()
                if '=' in line:
                    key, value = line.split('=', 1)
                    key = key.strip()
                    value = value.strip()
                    if re.match(r'^[A-Za-z0-9_-]+$', key) and re.match(r'^[0-9.]+$', value):
                        ISP_NAMES.append(key)
                        ISP_GATEWAYS[key] = value
        
        print(f"✅ Carregados {len(ISP_NAMES)} ISPs")
    else:
        print("📝 Criando configuração padrão de ISPs...")
        criar_configuracao_padrao()

def criar_configuracao_padrao():
    """Função para criar configuração padrão"""
    global ISP_NAMES, ISP_GATEWAYS
    
    ISP_NAMES = [f"ISP-{i:02d}" for i in range(1, 65)]
    
    # Gateways em ordem crescente
    gateways = [
        "10.131.131.1", "10.131.131.5", "10.131.131.9", "10.131.131.13",
        "10.131.131.17", "10.131.131.21", "10.131.131.25", "10.131.131.29",
        "10.131.131.33", "10.131.131.37", "10.131.131.41", "10.131.131.45",
        "10.131.131.49", "10.131.131.53", "10.131.131.57", "10.131.131.61",
        "10.131.131.65", "10.131.131.69", "10.131.131.73", "10.131.131.77",
        "10.131.131.81", "10.131.131.85", "10.131.131.89", "10.131.131.93",
        "10.131.131.97", "10.131.131.101", "10.131.131.105", "10.131.131.109",
        "10.131.131.113", "10.131.131.117", "10.131.131.121", "10.131.131.125",
        "10.131.131.129", "10.131.131.133", "10.131.131.137", "10.131.131.141",
        "10.131.131.145", "10.131.131.149", "10.131.131.153", "10.131.131.157",
        "10.131.131.161", "10.131.131.165", "10.131.131.169", "10.131.131.173",
        "10.131.131.177", "10.131.131.181", "10.131.131.185", "10.131.131.189",
        "10.131.131.193", "10.131.131.197", "10.131.131.201", "10.131.131.205",
        "10.131.131.209", "10.131.131.213", "10.131.131.217", "10.131.131.221",
        "10.131.131.225", "10.131.131.229", "10.131.131.233", "10.131.131.237",
        "10.131.131.241", "10.131.131.245", "10.131.131.249", "10.131.131.253"
    ]
    
    for i, isp in enumerate(ISP_NAMES):
        ISP_GATEWAYS[isp] = gateways[i]
    
    salvar_isps()

def salvar_isps():
    """Função para salvar configuração de ISPs"""
    with open(CONFIG_FILE, 'w') as f:
        # Salvar ordenado por nome para consistência
        sorted_names = sorted(ISP_NAMES)
        for isp in sorted_names:
            f.write(f"{isp}={ISP_GATEWAYS[isp]}\n")
    print(f"💾 Configuração salva em: {CONFIG_FILE}")

def detectar_gateway_atual():
    """Função para detectar gateway atual - VERSÃO CORRIGIDA"""
    rotas_output = executar_mikrotik('/ip route print where comment~"ROTA ACC WG"')
    
    if not rotas_output:
        return ""
    
    # Procurar todos os IPs no formato 10.131.131.X
    todos_ips = re.findall(r'10\.131\.131\.\d+', rotas_output)
    
    if not todos_ips:
        return ""
    
    # Contar frequência de cada IP
    contador = Counter(todos_ips)
    
    # O gateway será o IP que mais aparece (provavelmente)
    gateway_mais_comum = contador.most_common(1)[0][0]
    
    return gateway_mais_comum

def obter_isp_atual():
    """Função para obter ISP atual"""
    current_gw = detectar_gateway_atual()
    
    if current_gw:
        for isp in ISP_NAMES:
            if ISP_GATEWAYS[isp] == current_gw:
                return isp
        return f"DESCONHECIDO({current_gw})"
    else:
        return "NENHUM"

def gerenciar_isps():
    """Função para gerenciar nomes de ISPs"""
    global ISP_NAMES, ISP_GATEWAYS
    
    while True:
        os.system('clear')
        print("=== GERENCIAR NOMES DE ISP ===")
        print()
        
        isps_ordenados = obter_isps_ordenados()
        
        for i, isp in enumerate(isps_ordenados, 1):
            print(f"{i:3d}. {isp:<20} -> {ISP_GATEWAYS[isp]}")
        
        print()
        print("1. Renomear ISP")
        print("2. Adicionar novo ISP")
        print("3. Remover ISP")
        print("4. Voltar ao menu principal")
        print()
        
        opcao_gerenciar = input("Escolha uma opção: ")
        
        if opcao_gerenciar == "1":
            print()
            print("ISPs disponíveis para renomear:")
            isps_array = obter_isps_ordenados()
            for i, isp in enumerate(isps_array, 1):
                print(f"{i}. {isp}")
            print()
            
            try:
                num_isp = int(input("Número do ISP para renomear: "))
                if 1 <= num_isp <= len(isps_array):
                    isp_antigo = isps_array[num_isp - 1]
                    novo_nome = input(f"Novo nome para '{isp_antigo}': ").strip()
                    if novo_nome:
                        gateway_temp = ISP_GATEWAYS[isp_antigo]
                        ISP_GATEWAYS[novo_nome] = gateway_temp
                        del ISP_GATEWAYS[isp_antigo]
                        
                        # Atualizar a lista global de nomes
                        ISP_NAMES = [novo_nome if name == isp_antigo else name for name in ISP_NAMES]
                        salvar_isps()
                        print(f"✅ ISP renomeado: '{isp_antigo}' -> '{novo_nome}'")
                else:
                    print("❌ Número inválido!")
            except ValueError:
                print("❌ Número inválido!")
            
            input("Pressione ENTER para continuar")
            
        elif opcao_gerenciar == "2":
            print()
            novo_isp = input("Nome do novo ISP: ").strip()
            novo_gateway = input("Gateway (ex: 10.131.131.XXX): ").strip()
            if novo_isp and novo_gateway:
                ISP_NAMES.append(novo_isp)
                ISP_GATEWAYS[novo_isp] = novo_gateway
                salvar_isps()
                print(f"✅ ISP '{novo_isp}' adicionado!")
            else:
                print("❌ Nome e gateway são obrigatórios!")
            
            input("Pressione ENTER para continuar")
            
        elif opcao_gerenciar == "3":
            print()
            print("ISPs disponíveis para remover:")
            isps_array = obter_isps_ordenados()
            for i, isp in enumerate(isps_array, 1):
                print(f"{i}. {isp}")
            print()
            
            try:
                num_isp = int(input("Número do ISP para remover: "))
                if 1 <= num_isp <= len(isps_array):
                    isp_remover = isps_array[num_isp - 1]
                    confirmar = input(f"Confirmar remoção de '{isp_remover}'? (s/N): ").strip().lower()
                    if confirmar == 's':
                        del ISP_GATEWAYS[isp_remover]
                        ISP_NAMES = [name for name in ISP_NAMES if name != isp_remover]
                        salvar_isps()
                        print(f"✅ ISP '{isp_remover}' removido!")
                else:
                    print("❌ Número inválido!")
            except ValueError:
                print("❌ Número inválido!")
            
            input("Pressione ENTER para continuar")
            
        elif opcao_gerenciar == "4":
            break
        else:
            print("❌ Opção inválida!")
            import time
            time.sleep(1)

def menu_principal():
    """Menu principal"""
    while True:
        os.system('clear')
        print("=== 🌐 CONTROLE WG - COMANDOS DIRETOS ===")
        print(f"IP: {MIKROTIK_IP} | Usuário: {MIKROTIK_USER} | Porta: {SSH_PORT}")
        print(f"ISP Atual: {obter_isp_atual()}")
        print("=" * 64)
        
        isps_ordenados = obter_isps_ordenados()
        
        count = 0
        for i, isp in enumerate(isps_ordenados, 1):
            print(f"{i:3d}. {isp:<40}", end='')
            count += 1
            if count % 2 == 0:
                print()
        
        if count % 2 != 0:
            print()
        
        print("=" * 64)
        print("98. 🛠️ Gerenciar nomes de ISP")
        print("99. 🔄 Próximo ISP automático")
        print("00. 👁️ Ver ISP atual (detalhado)")
        print("88. 🔌 Testar conexão SSH")
        print("77. 🚪 Sair")
        print()
        
        opcao = input("Escolha o ISP (pelo número) ou uma opção: ")
        
        isp_escolhido = ""
        gateway = ""

        if opcao == "77":
            print("👋 Saindo...")
            sys.exit(0)
            
        elif opcao == "88":
            testar_conexao_ssh()
            input("Pressione ENTER para continuar")
            
        elif opcao == "98":
            gerenciar_isps()
            continue
            
        elif opcao == "00":
            print()
            print("🔍 Verificando configuração atual...")
            
            print()
            print("📋 Buscando rotas WG no MikroTik...")
            rotas_output = executar_mikrotik('/ip route print where comment~"ROTA ACC WG"')
            
            if not rotas_output:
                print("❌ Nenhuma rota WG encontrada no MikroTik.")
            else:
                print("✅ Rotas WG encontradas:")
                print(rotas_output)
                
                current_gw = detectar_gateway_atual()
                
                if current_gw:
                    print()
                    print(f"✅ Gateway atual detectado: {current_gw}")
                    
                    isp_encontrado = False
                    for isp in ISP_NAMES:
                        if ISP_GATEWAYS[isp] == current_gw:
                            print(f"✅ ISP atual: {isp}")
                            isp_encontrado = True
                            break
                    
                    if not isp_encontrado:
                        print(f"⚠️ Gateway ({current_gw}) não corresponde a nenhum ISP na lista.")
                        print("💡 Gateways disponíveis na configuração:")
                        for isp in list(ISP_NAMES)[:5]:
                            print(f"   {isp} = {ISP_GATEWAYS[isp]}")
                else:
                    print("⚠️ Não foi possível detectar o gateway atual.")
            
            input("Pressione ENTER para continuar")
            
        elif opcao == "99":
            print("🔄 Detectando ISP atual...")
            
            # Usa a mesma função da opção 00 para detectar o gateway
            current_gw = detectar_gateway_atual()
            
            if not current_gw:
                print("❌ Não foi possível detectar o ISP atual.")
                print("💡 Use a opção 00 para ver detalhes ou configure um ISP manualmente.")
                input("Pressione ENTER para continuar")
                continue
            
            print(f"🔍 Gateway atual: {current_gw}")
            
            # Encontrar o ISP atual na lista ordenada
            isps_ordenados = obter_isps_ordenados()
            current_index = -1
            current_isp = ""
            
            for i, isp in enumerate(isps_ordenados):
                if ISP_GATEWAYS[isp] == current_gw:
                    current_index = i
                    current_isp = isp
                    break
            
            if current_index == -1:
                print("❌ ISP atual não encontrado na lista.")
                input("Pressione ENTER para continuar")
                continue
            
            print(f"📡 ISP atual: {current_isp} (índice {current_index})")
            
            # Calcular próximo índice (rotação circular)
            next_index = (current_index + 1) % len(isps_ordenados)
            isp_escolhido = isps_ordenados[next_index]
            gateway = ISP_GATEWAYS[isp_escolhido]
            
            print(f"🔄 Próximo ISP: {isp_escolhido} (índice {next_index})")
            print(f"🔜 Gateway: {gateway}")
            
        else:
            try:
                num_opcao = int(opcao)
                isps_ordenados = obter_isps_ordenados()
                if 1 <= num_opcao <= len(isps_ordenados):
                    isp_escolhido = isps_ordenados[num_opcao - 1]
                    gateway = ISP_GATEWAYS[isp_escolhido]
                else:
                    print("❌ Opção inválida!")
                    import time
                    time.sleep(1)
                    continue
            except ValueError:
                print("❌ Opção inválida!")
                import time
                time.sleep(1)
                continue
        
        # Se um ISP foi escolhido (diretamente ou pelo modo automático)
        if isp_escolhido and gateway:
            print()
            print(f"⚡ Configurando: {isp_escolhido} -> {gateway}")
            
            if configurar_rotas_mikrotik(gateway):
                print(f"🎉 SUCESSO! ISP '{isp_escolhido}' aplicado.")
            else:
                print(f"⚠️ Configuração parcial do ISP '{isp_escolhido}'.")
            
            input("Pressione ENTER para continuar")

def main():
    """Função principal"""
    print("=== INICIANDO CONTROLE WG (COMANDOS DIRETOS) ===")
    verificar_chave_ssh()
    
    if testar_conexao_ssh():
        carregar_isps()
        menu_principal()
    else:
        print("❌ Não foi possível conectar ao MikroTik. Encerrando.")
        sys.exit(1)

if __name__ == "__main__":
    main()
