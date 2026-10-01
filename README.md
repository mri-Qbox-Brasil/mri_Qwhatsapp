# mri_Qwhatsapp: Manual

**Whatzap**: mensageiro para o [sd-phone](https://github.com/Samuels-Development/sd-phone) e o sd-tablet. Conversas, grupos, status, fotos, GIFs, áudio, localização, contatos e ligações, com o visual de um mensageiro moderno, tema claro e escuro e textos em pt-BR e inglês.

O app entra pela API oficial de apps do sd-phone, então aparece sozinho no celular **e** no tablet, sem alterar nenhum dos dois. No celular o layout é de uma coluna; no tablet a lista de conversas e a conversa ficam lado a lado.

---

## Sumário

1. [Dependências](#dependências)
2. [Instalação](#instalação)
3. [Funcionalidades](#funcionalidades)
4. [Configuração](#configuração)
5. [Mídia e áudio](#mídia-e-áudio)
6. [Banco de dados](#banco-de-dados)
7. [Localização](#localização)

---

## Dependências

| Recurso | Obrigatório | Observação |
|---|---|---|
| `sd-phone` | Sim | Número, agenda, notificações, câmera, galeria e discador |
| `ox_lib` | Sim | Callbacks e locale |
| `oxmysql` | Sim | Tabelas próprias `mri_whatsapp_*` |
| `sd-tablet` | Não | O app aparece também no tablet (sem ligações, que são só do celular) |
| `qbx_core` | Não | Nome do personagem como nome inicial do perfil |

---

## Instalação

1. Coloque a pasta `mri_Qwhatsapp` em `resources/`.
2. Garanta que ela inicia **depois** do `sd-phone` no `server.cfg`:
   ```
   ensure sd-phone
   ensure sd-tablet
   ensure mri_Qwhatsapp
   ```
3. Pronto. As tabelas são criadas na primeira subida e o app já vem instalado no celular de todo mundo.

---

## Funcionalidades

- **Conversas:** texto, foto (câmera ou galeria, com legenda), GIF, mensagem de voz, localização (um toque marca no GPS) e cartão de contato.
- **Mensagens:** responder, reagir, editar, apagar para mim ou para todos, encaminhar, favoritar, copiar e salvar foto na galeria.
- **Confirmações:** enviada, entregue e lida, "digitando...", "gravando áudio...", online e visto por último.
- **Lista:** busca em conversas e mensagens, filtros (tudo, não lidas, grupos), fixar, arquivar, silenciar, limpar e apagar.
- **Grupos:** foto, nome, descrição, admins, adicionar e remover participantes, "só admins enviam", sair do grupo e avisos de sistema.
- **Status:** texto com cor de fundo ou foto, some depois de 24 horas, com lista de quem viu.
- **Ligações:** usam o discador do sd-phone e ficam registradas na aba Ligações.
- **Privacidade:** visto por último e confirmação de leitura (recíprocos), bloqueio de contatos.
- **Notificações:** banner e badge no celular, respeitando conversas silenciadas.

A identidade é o número do sd-phone: com chip (unique phones), o Whatzap segue o número do chip em uso.

---

## Configuração

Os limites ficam em `data/config.json`:

| Chave | Padrão | O que faz |
|---|---|---|
| `maxMessageLength` | `2000` | Tamanho máximo de uma mensagem |
| `pageSize` | `40` | Mensagens carregadas por página |
| `maxGroupMembers` | `64` | Participantes por grupo |
| `maxForward` | `5` | Conversas por encaminhamento |
| `statusHours` | `24` | Duração de um status |
| `editWindowMinutes` | `15` | Tempo para editar uma mensagem |
| `revokeWindowMinutes` | `60` | Tempo para apagar para todos |
| `callLogLimit` | `60` | Ligações mostradas no registro |

---

## Mídia e áudio

Fotos e GIFs vêm da câmera, galeria e seletor de GIF do próprio sd-phone. Mensagens de voz são enviadas pelo upload do sd-phone, então precisam da chave de mídia configurada nele (Fivemanage ou Qbox CDN, em `configs/server/apikeys.lua` do sd-phone). Sem a chave, o resto do app funciona e o áudio mostra um aviso.

---

## Banco de dados

Tabelas criadas automaticamente:

`mri_whatsapp_accounts`, `mri_whatsapp_chats`, `mri_whatsapp_members`, `mri_whatsapp_messages`, `mri_whatsapp_reactions`, `mri_whatsapp_hidden`, `mri_whatsapp_starred`, `mri_whatsapp_blocks`, `mri_whatsapp_statuses`, `mri_whatsapp_status_views`, `mri_whatsapp_calls`.

Status vencidos são limpos sozinhos a cada 10 minutos.

---

## Localização

O app segue o idioma do celular (pt-BR ou inglês). Os textos do servidor (notificações) ficam em `locales/` e seguem o `ox:locale`.
