# Mouse Zoom & Follow para OBS Studio

Feito por **Pablo Ruan**. Licença [MIT](LICENSE). Downloads na página de [Releases](https://github.com/pabloruancoder/mouse-zoom-follow/releases).

🇺🇸 [English version](README.md)

Script para OBS Studio (Windows) que dá zoom na tela em volta do cursor e faz a imagem seguir o mouse. Tem animações suaves, controle pela rodinha, botões e teclado, e todas as opções são configuráveis.

## Instalação

1. No OBS: **Ferramentas > Scripts**.
2. Clique em **+** e escolha `mouse-zoom-follow.lua`.
3. Em **Fonte ou cena para dar zoom**, deixe **Automático**, que usa a Captura de Tela visível na cena atual. Se preferir, escolha uma fonte específica ou uma cena inteira.
4. Use **Shift + rodinha** ou **Ctrl+Alt+Z** para dar zoom.

**Idioma:** a interface está em português e inglês. Escolha em **Idioma / Language**, no topo das configurações do script. "Automático" segue o idioma do OBS. A tela muda na hora; os nomes dos atalhos e a descrição mudam depois de recarregar o script (↻).

Para confirmar a versão carregada, abra **Log do Script**: a linha "Mouse Zoom & Follow X.Y.Z carregado" aparece a cada carregamento.

O zoom funciona em qualquer cena em que a fonte aparecer, inclusive em cenas aninhadas e no modo estúdio.

## Controles padrão

### Mouse
Configure em Ferramentas > Scripts, grupo "Controles pelo mouse".

| Ação | Padrão |
|---|---|
| Aumentar / diminuir zoom | Shift + rodinha |
| Ativar/desativar zoom | (nenhum). Pode ser o botão do meio ou um botão lateral, com ou sem tecla |
| Zoom enquanto segurar | (nenhum) |
| Ativar/desativar seguir | (nenhum) |

A tecla da rodinha pode ser Shift, Ctrl, Alt, uma combinação delas ou nenhuma. A combinação precisa ser exata: com "Shift", Ctrl+Shift+rodinha não dá zoom.

### Teclado
Mude em **Configurações > Teclas de atalho** (procure por "Mouse Zoom").

| Ação | Atalho |
|---|---|
| Ativar/desativar zoom | Ctrl+Alt+Z |
| Zoom enquanto segurar | Ctrl+Alt+X |
| Ativar/desativar seguir o mouse | Ctrl+Alt+F |
| Aumentar zoom | Ctrl+Alt+↑ |
| Diminuir zoom (sai do zoom abaixo do mínimo) | Ctrl+Alt+↓ |
| Voltar ao nível de zoom padrão | Ctrl+Alt+0 |
| Centralizar no mouse | Ctrl+Alt+C |

## Opções

**Zoom:** nível padrão, passo, mínimo e máximo, lembrar o último nível, duração e curva da animação, origem do zoom (ponto fixo sob o cursor, centralizar no cursor ou centro) e qualidade da ampliação (bilinear, bicúbico, Lanczos, ponto).

**Seguir o mouse:** seguir automaticamente, velocidade, zona morta (área central onde o mouse anda sem mover a câmera), seguir fora da tela capturada, sair do zoom após o mouse ficar parado.

**Controles pelo mouse:** ligar/desligar a rodinha, tecla da rodinha, zoom por clique da rodinha, inverter direção, duração da animação da rodinha, e botões (meio, lateral 1, lateral 2) com tecla para cada ação.

**Cursor do mouse:**
- **Aparência:**
  - **Original:** o cursor que a Captura de Tela já mostra.
  - **Seta:** cor da seta e do contorno configuráveis.
  - **Imagem personalizada:** PNG, GIF animado, JPG etc., com escala e ponto da ponta (hotspot).
  - **Ponto colorido.**
  - **Oculto.**
- Em qualquer aparência diferente de "Original", o script desliga o "Capturar cursor" da captura e liga de novo quando você volta para "Original" ou descarrega o script.
- Tamanho do cursor e opção de esconder o cursor depois de alguns segundos parado.
- **Destaque:** círculo colorido em volta do cursor, com cor e tamanho configuráveis.
- **Efeito de clique:** anel que se expande a cada clique, com cores diferentes para o botão esquerdo e o direito, tamanho e duração configuráveis.
- **Manter o tamanho durante o zoom:** por padrão, o cursor é ampliado junto com a imagem, como o cursor real. Marque esta opção para ele manter o mesmo tamanho na tela.

Os tamanhos são em pixels da tela capturada.

**Monitor:**
- **Automático:** usa o monitor da Captura de Tela; para uma cena, usa a primeira Captura de Tela dentro dela.
- **Um monitor específico.**
- **Manual:** área X/Y/largura/altura, para outros tipos de fonte.

## Como funciona

Quando alguma opção de cursor está ativa, o script adiciona à fonte o filtro **Mouse Zoom (cursor)**, que desenha o cursor e os efeitos antes do zoom. Por isso eles são ampliados junto com a imagem.

Para o zoom, o script adiciona à fonte dois filtros próprios, **Mouse Zoom (crop)** e **Mouse Zoom (scale)**. O recorte seleciona a área ampliada e a escala devolve a imagem ao tamanho original. A transformação da fonte nas cenas nunca é alterada. Fora do zoom os filtros ficam desativados, e são removidos quando o script é descarregado ou o OBS fecha. Não edite esses filtros manualmente.

A rodinha e os botões do mouse são lidos pelo Raw Input do Windows. O evento continua chegando ao programa em foco: com Shift + rodinha, um navegador também vai rolar para o lado. Se isso atrapalhar, escolha outra tecla, como Ctrl + Alt.

## Uso de IA

Este script foi escrito com a ajuda de um assistente de programação com IA (Claude Code, da Anthropic), que gerou a maior parte do código a partir dos requisitos e do feedback do autor. O autor definiu as funcionalidades e testou cada versão no OBS Studio 32.2.2 no Windows. A lógica também foi verificada com testes automatizados que rodam o script sobre uma API do OBS simulada.

## Limitações conhecidas

- Por enquanto funciona só no Windows.
- O recorte usa pixels inteiros, então movimentos muito lentos podem avançar de 1 em 1 pixel da fonte.
- O cursor personalizado mantém sempre o mesmo formato. Ele não vira mãozinha ou barra de texto como o cursor do Windows.
- Na aparência "Original", o destaque é desenhado por cima do cursor real, que fica levemente tingido pela cor do destaque.
- Se o OBS fechar à força com um estilo personalizado ativo, o "Capturar cursor" da captura pode ficar desligado. Para corrigir, volte a aparência para "Original" ou religue a opção nas propriedades da captura.
- Ao escolher uma cena inteira, o modo Automático assume que a Captura de Tela ocupa a cena toda. Se não ocupar, use o modo Manual.
