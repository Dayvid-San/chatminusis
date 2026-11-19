# Supabase (Etapa 11)

Backend alternativo ao Firebase, com as mesmas garantias: o servidor só guarda blobs MLS opacos.

| Arquivo | Conteúdo |
|---|---|
| `migrations/20261119000000_init.sql` | Tabelas, RLS e funções atômicas (época com compare-and-set, KeyPackage de uso único, criação de conversa, membros) |
| `tests/` | Testes das políticas num PostgreSQL comum (`tests/run.sh`) com um "shim" do esquema `auth` do Supabase |
| `functions/notify/` | Edge Function de push genérico ("Nova mensagem") via FCM |

## Diferenças em relação ao Firebase
- A tabela `profiles` **não pode ser lida diretamente** por outros usuários: só via `find_profile_by_nickname` (exato) e `get_profile` (id conhecido). Listar usuários é impossível.
- Toda escrita em conversas passa por funções `SECURITY DEFINER`; não há política de INSERT/UPDATE direta.
- Retenção de 30 dias via `pg_cron` (se a extensão estiver ativa).

## Como ativar
1. Crie o projeto e ative **Auth → Email → Confirm email** (sem sessão antes da verificação).
2. `supabase db push` (aplica a migração). Ative a extensão `pg_cron` se quiser a retenção automática.
3. Edge Function: `supabase functions deploy notify` e defina os segredos `FCM_SERVICE_ACCOUNT` e `WEBHOOK_SECRET`.
   Crie **dois Database Webhooks** apontando para a função, ambos com o cabeçalho `x-webhook-secret`: um em `INSERT` de `public.mls_messages` (push de nova mensagem) e outro em `INSERT` de `public.backup_downloads` (alerta de download do backup).
4. Rode o app com:
   ```
   flutter run --dart-define=BACKEND=supabase --dart-define=SUPABASE_URL=https://<projeto>.supabase.co --dart-define=SUPABASE_KEY=<publishable key>
   ```
   (a chave publicável é pública por natureza; a proteção está no RLS.)
5. Auto-hospedagem (opcional): o Supabase pode rodar em servidor próprio, reduzindo os metadados expostos a terceiros.

## Migração de usuários do Firebase
As identidades MLS são ligadas ao `uid` da conta, e as contas do Supabase têm ids diferentes. Por isso **conversas e backups do Firebase não migram**:
cada pessoa cria conta no Supabase, escolhe o nickname de novo e recomeça as conversas. Como o app ainda não está em produção, essa é a opção recomendada.
