#!/bin/bash

# Configurar o nome do arquivo JSON
JSON_FILE="lists.json"


create_json_file() {
    cat <<EOF > "$JSON_FILE"
    [
        {
            "name": "adservers.txt",
            "description": "A reliable host file containing advertising domains, trackers, malwares and other unsafe domains. I collect these domains from my Pi-hole and I test them for a few days before adding to the list. You can request additional domains or report existing domains via issues tab.",
            "url": "https://raw.githubusercontent.com/anudeepND/blacklist/master/adservers.txt"
        },
        {
            "name": "adaway.org",
            "description": "AdAway is an open source ad blocker for Android using the hosts file.",
            "url": "https://adaway.org/hosts.txt"
        },
        {
            "name": "AdguardDNS",
            "description": "This is sourced from an \"adblock\" style list which is flat-out NOT designed to work with DNS sinkholes",
            "url": "https://v.firebog.net/hosts/AdguardDNS.txt"
        }
    ]
EOF

    echo "Arquivo JSON '$JSON_FILE' criado com sucesso!\n"
}

# Verificar se o arquivo JSON existe
if [ ! -f "$JSON_FILE" ]; then
    echo "Arquivo $JSON_FILE não encontrado.\n"
	create_json_file
fi

# Nome do arquivo de saída com data e hora
OUTPUT_FILE="pihole-list-$(date +"%Y-%m-%d_%H-%M-%S").txt"

# Array para armazenar as URLs incluídas
urls_to_include=()

# Função para adicionar todas as URLs
add_all_urls() {
    local total=$1
    for ((j=0; j<$total; j++)); do
        local name=$(jq -r ".[$j].name" "$JSON_FILE")
        local url=$(jq -r ".[$j].url" "$JSON_FILE")
        urls_to_include+=("$url")
        echo -e "URL '$name' será incluída."
    done
    echo -e "\nTodas as listas foram adicionadas!\n"
}

# Função para adicionar URLs a serem incluídas
add_url() {
    local index=$1
    local name=$(jq -r ".[$index].name" "$JSON_FILE")
    local description=$(jq -r ".[$index].description" "$JSON_FILE")
    local url=$(jq -r ".[$index].url" "$JSON_FILE")

    echo -e "\n=== Lista ${index+1} ===\n"
    echo -e "Lista: $name\n"
    echo -e "Descrição: $description\n\n"
    read -p "Deseja anexar esta lista? (S/N): " choice
    if [[ "$choice" == "S" || "$choice" == "s" ]]; then
        urls_to_include+=("$url")
        echo -e "\nURL '$name' será incluída.\n"
    fi
}

# Interface interativa
total_lists=$(jq length "$JSON_FILE")
echo -e "\n=== Total de listas disponíveis: $total_lists ===\n"
read -p "Deseja adicionar todas as listas? (S/N): " choice_all

if [[ "$choice_all" == "S" || "$choice_all" == "s" ]]; then
    add_all_urls "$total_lists"
else
    for ((i=0; i<$total_lists; i++)); do
        add_url $i
    done
fi

# Concatenar todos os arquivos
echo "Concatenando conteúdo..."
for url in "${urls_to_include[@]}"; do
    curl -s "$url" >> "$OUTPUT_FILE"
done

## Processar o arquivo
echo "Processando arquivo..."

# Verificar se o GNU Parallel está instalado
if ! command -v parallel &> /dev/null; then
    echo "GNU Parallel não está instalado."
    
    # Detectar o sistema operacional
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        echo "Detectado macOS. Instalando via Homebrew..."
        if ! command -v brew &> /dev/null; then
            echo "Homebrew não está instalado. Por favor, instale primeiro:"
            echo '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
            exit 1
        fi
        brew install parallel
        
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # Linux
        if command -v apt-get &> /dev/null; then
            # Debian/Ubuntu
            echo "Detectado Debian/Ubuntu. Instalando via apt..."
            sudo apt-get update && sudo apt-get install -y parallel
        elif command -v dnf &> /dev/null; then
            # Fedora
            echo "Detectado Fedora. Instalando via dnf..."
            sudo dnf install -y parallel
        elif command -v yum &> /dev/null; then
            # CentOS/RHEL
            echo "Detectado CentOS/RHEL. Instalando via yum..."
            sudo yum install -y parallel
        elif command -v pacman &> /dev/null; then
            # Arch Linux
            echo "Detectado Arch Linux. Instalando via pacman..."
            sudo pacman -Sy parallel
        else
            echo "Distribuição Linux não reconhecida."
            echo "Por favor, instale o GNU Parallel manualmente."
            exit 1
        fi
        
    elif [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" ]]; then
        # Windows (Git Bash/Cygwin)
        echo "Detectado Windows."
        echo "Por favor, instale o GNU Parallel através do Cygwin ou WSL."
        echo "Ou baixe diretamente de: https://git.savannah.gnu.org/cgit/parallel.git"
        exit 1
    else
        echo "Sistema operacional não reconhecido: $OSTYPE"
        echo "Por favor, instale o GNU Parallel manualmente."
        exit 1
    fi
fi

# Silenciar a notificação de citação do GNU Parallel
if [ ! -f ~/.parallel/will-cite ]; then
    mkdir -p ~/.parallel
    touch ~/.parallel/will-cite
fi

# Criar diretório temporário
temp_dir=$(mktemp -d)

echo "Diretório temporário criado: $temp_dir"

trap 'rm -rf "$temp_dir"' EXIT

# Determinar o número de processadores
get_num_processors() {
    if command -v nproc &> /dev/null; then
        nproc
    elif command -v sysctl &> /dev/null; then
        # macOS e alguns Unix
        sysctl -n hw.ncpu
    elif [ -f /proc/cpuinfo ]; then
        # Linux sem nproc
        grep -c ^processor /proc/cpuinfo
    else
        # Valor padrão se não conseguir detectar
        echo "4"
    fi
}

# Obter número de processadores
total_processors=$(get_num_processors)
num_processors=$((total_processors / 2))

# Garantir pelo menos 1 processador
if [ $num_processors -lt 1 ]; then
    num_processors=1
fi

echo "Total de processadores disponíveis: $total_processors"
echo "Utilizando $num_processors processadores para o processamento"

# Dividir o arquivo em chunks para processamento paralelo
echo "Dividindo arquivo em $num_processors partes..."
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS: usa uma sintaxe diferente para split
    split -n "$num_processors" "$OUTPUT_FILE" "$temp_dir/chunk_"
else
    # Linux e outros sistemas
    split -n "l/$num_processors" "$OUTPUT_FILE" "$temp_dir/chunk_"
fi

# Função para processar cada linha
process_line() {
    local line="$1"
    # Remover espaços em branco no início e fim
    line=$(echo "$line" | xargs)
    
    # Pular linhas vazias, que começam com # ou ::1
    [[ -z "$line" || $line =~ ^[[:space:]]*# || $line =~ ^[[:space:]]*::1 ]] && return
    
    # Substituir 0.0.0.0 por 127.0.0.1
    line=${line/0.0.0.0/127.0.0.1}
    
    # Se a linha não começa com um IP, adicionar 127.0.0.1
    if ! [[ $line =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        # Verificar se a linha não está vazia antes de adicionar o IP
        if [[ ! -z "$line" ]]; then
            line="127.0.0.1 $line"
        fi
    fi
    
    # Só retorna a linha se ela não estiver vazia
    [[ ! -z "$line" ]] && echo "$line"
}
export -f process_line

# Processar cada chunk em paralelo
find "$temp_dir" -name 'chunk_*' | parallel --bar "cat {} | while IFS= read -r line; do process_line \"\$line\"; done > {}.processed"

# Combinar todos os arquivos processados, ordenar e remover duplicatas
echo "# Gerado Pelo Script makeList.sh do repositório - @https://github.com/c3t4r4/Make-List-Pi-Hole" > "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"  # Linha em branco após o cabeçalho
find "$temp_dir" -name '*.processed' -exec cat {} \; | sort -u >> "$OUTPUT_FILE"

echo "Arquivo final gerado com sucesso: $OUTPUT_FILE"